"""Enregistreur réseau passif → HAR 1.2 (top-frame).

On écoute passivement les events `Network.*` du tab top. Les handlers d'events
INTERMÉDIAIRES (requestWillBeSent, responseReceived) ne font que recopier des
références brutes dans `in_flight` — aucun `await`, aucun calcul. Les events
TERMINAUX (loadingFinished, loadingFailed, et la clôture d'un hop de redirect)
retirent l'entrée de `in_flight` et lancent une tâche `_finalize` : c'est le SEUL
endroit qui `await` (fetch des corps via command) et qui met en forme le HAR.
`drain_page_har()` ne fait que **vider** le buffer `done` (le « delta » depuis le
dernier appel). Voir `project_cyborg_redesign`.

Concurrence (asyncio mono-thread) : aucun lock. Comme aucun handler n'`await`,
son corps est atomique vis-à-vis des autres tasks (pas de préemption hors point
d'await) → la mutation de `in_flight` est sûre sans verrou. `_finalize`, seul à
`await`, ne touche que `done` (append atomique) et un `rec` déjà sorti de
`in_flight`.

Portée top-frame : pas d'OOPIF cross-origin (d'où `network_page.har`).

Bodies : récupérés pour XHR/Fetch/Document/Script uniquement, JAMAIS tronqués.
Si le browser n'a pas pu bufferiser (dépassement de `_HAR_BUF_BYTES`) ou si
l'appel échoue, le corps est omis (`text` absent) plutôt que partiel.

Surface publique :
  * setup_network_capture(tab) — arme `Network` et branche les handlers.
  * drain_page_har() -> bytes  — sérialise + vide le delta d'entrées finalisées.
  * har_headers(d) -> list     — helper de shaping HAR (partagé avec /net).
"""

import asyncio
import base64
import json
from datetime import datetime, timezone
from typing import Any

from nodriver import cdp

_HAR_BUF_BYTES = 2 ** 24  # 16 MiB : buffers par-ressource / total / post-data.


def _new_record(rid: Any) -> dict:
    return {
        "rid": rid,
        "request": None,     # cdp.network.Request (brut), posé à requestWillBeSent
        "response": None,    # cdp.network.Response (brut) | None
        "resource_type": "",
        "wall_time": 0.0,    # epoch s (startedDateTime)
        "ts_start": 0.0,     # MonotonicTime s
        "ts_end": 0.0,       # MonotonicTime s (loadingFinished/Failed)
        "encoded_data_length": 0.0,
        "error": None,
    }


class _NetCapture:
    def __init__(self) -> None:
        self.in_flight: dict[Any, dict] = {}
        self.done: list[dict] = []
        self.tab = None


_CAP = _NetCapture()

# Types de ressources dont on capture le corps de reponse. Au-dela des XHR/Fetch
# (donnees applicatives), on prend le document HTML et les scripts JS pour
# pouvoir relire la logique metier du front. Rien d'autre (ni CSS, ni images,
# ni fontes).
_BODY_RESOURCE_TYPES = ("XHR", "Fetch", "Document", "Script")


# ── Shaping HAR 1.2 ───────────────────────────────────────────────────────────

def har_headers(d: dict) -> list:
    return [{"name": str(k), "value": str(v)} for k, v in d.items()]


def _header(headers: list, name: str) -> str:
    """Valeur d'un header HAR (`[{name,value}]`), insensible à la casse."""
    name = name.lower()
    for h in headers:
        if h["name"].lower() == name:
            return h["value"]
    return ""


def _set_body(slot: dict, text: str, b64: bool) -> None:
    """Pose `text`/`encoding`/`size` sur un `content` ou `postData` HAR.
    `size` = octets réels (base64 décodé) ; -1 si indécodable."""
    slot["text"] = text
    if b64:
        slot["encoding"] = "base64"
        try:
            slot["size"] = len(base64.b64decode(text))
        except Exception:
            slot["size"] = -1
    else:
        slot["size"] = len(text.encode("utf-8"))


def _har_request(req) -> dict:
    return {
        "method": req.method,
        "url": req.url,
        "httpVersion": "HTTP/1.1",
        "headers": har_headers(dict(req.headers or {})),
        "queryString": [],
        "cookies": [],
        "headersSize": -1,
        "bodySize": -1,
    }


def _har_response(status, status_text, headers, mime_type) -> dict:
    h = har_headers(dict(headers or {}))
    return {
        "status": status,
        "statusText": status_text,
        "httpVersion": "HTTP/1.1",
        "headers": h,
        "cookies": [],
        "content": {"size": 0, "mimeType": mime_type},
        "redirectURL": _header(h, "location"),
        "headersSize": -1,
        "bodySize": -1,
    }


def _empty_response() -> dict:
    """Réponse HAR minimale, créée seulement au seal pour une requête sans
    `ResponseReceived` (échec, ou en vol au moment du snap) — HAR exige
    l'objet `response`."""
    return {
        "status": 0, "statusText": "", "httpVersion": "HTTP/1.1",
        "headers": [], "cookies": [],
        "content": {"size": 0, "mimeType": ""},
        "redirectURL": "", "headersSize": -1, "bodySize": -1,
    }


def _attach_post(request: dict, text: str, b64: bool) -> None:
    """Greffe le corps de requête sur le dict `request` HAR. `postData` n'a pas
    de champ `size` en HAR → on reporte la taille octets sur `request.bodySize`."""
    pd = {"mimeType": _header(request["headers"], "content-type"), "text": text}
    _set_body(pd, text, b64)
    request["bodySize"] = pd.pop("size")
    request["postData"] = pd


def _compute_timings(t, ts_start: float, ts_end: float) -> tuple[dict, float]:
    """Mappe `ResourceTiming` → timings HAR (ms). `-1` = inconnu. Renvoie aussi
    le temps total de l'entrée."""
    wall_total = max(0.0, (ts_end - ts_start) * 1000.0) if ts_end else -1.0
    if t is None:
        return ({"blocked": -1, "dns": -1, "connect": -1, "send": -1,
                 "wait": -1, "receive": wall_total, "ssl": -1}, wall_total)

    def span(a: float, b: float) -> float:
        return (b - a) if (a >= 0 and b >= a) else -1.0

    timings = {
        "blocked": -1,
        "dns": span(t.dns_start, t.dns_end),
        "connect": span(t.connect_start, t.connect_end),
        "ssl": span(t.ssl_start, t.ssl_end),
        "send": span(t.send_start, t.send_end),
        "wait": span(t.send_end, t.receive_headers_end),
    }
    if ts_end:
        total = max(0.0, (ts_end - t.request_time) * 1000.0)
        recv = total - t.receive_headers_end if t.receive_headers_end >= 0 else -1.0
        timings["receive"] = recv if recv >= 0 else -1.0
    else:
        total = wall_total
        timings["receive"] = -1.0
    return (timings, total if total >= 0 else wall_total)


def _build_entry(rec: dict, post, body) -> dict:
    """Assemble l'`entry` HAR — PUR, aucun `await`. `post`/`body` sont les
    tuples `(text, base64)` déjà fetchés (ou None)."""
    req, resp = rec["request"], rec["response"]
    timings, total = _compute_timings(
        resp.timing if resp is not None else None, rec["ts_start"], rec["ts_end"])

    request = _har_request(req)
    if post is not None:
        _attach_post(request, post[0], post[1])

    if resp is not None:
        response = _har_response(
            resp.status, resp.status_text, resp.headers, resp.mime_type)
        response["bodySize"] = int(rec["encoded_data_length"])
        if body is not None:
            _set_body(response["content"], body[0], body[1])
        server_ip = resp.remote_ip_address or ""
    else:
        response = _empty_response()
        server_ip = ""

    started = ""
    if rec["wall_time"]:
        started = datetime.fromtimestamp(
            rec["wall_time"], tz=timezone.utc).isoformat()

    entry = {
        "startedDateTime": started,
        "time": total,
        "request": request,
        "response": response,
        "cache": {},
        "timings": timings,
        "serverIPAddress": server_ip,
        "_resourceType": rec["resource_type"],
    }
    if rec["error"]:
        entry["_error"] = rec["error"]
    return entry


async def _finalize(rec: dict, *, fetch_post: bool, fetch_body: bool) -> None:
    """SEULE fonction qui `await`. Tirée en `create_task` par les events
    terminaux. Récupère les corps si besoin (via command, asynchrone) puis
    assemble l'entry et la verse dans `done`."""
    req = rec["request"]
    # Corps de requête : inline si déjà présent dans l'event, sinon command.
    post = None
    if req is not None and req.post_data is not None:
        post = (req.post_data, False)             # inline → string telle quelle
    elif fetch_post and req is not None and req.has_post_data:
        try:
            # getRequestPostData renvoie (postData, base64Encoded).
            post = await _CAP.tab.send(
                cdp.network.get_request_post_data(request_id=rec["rid"]))
        except Exception:
            post = None

    # Corps de réponse : uniquement pour les types pertinents, jamais tronqué.
    body = None
    if fetch_body and rec["resource_type"] in _BODY_RESOURCE_TYPES:
        try:
            body = await _CAP.tab.send(
                cdp.network.get_response_body(request_id=rec["rid"]))
        except Exception:
            body = None  # corps évincé/indispo → omis, jamais partiel

    entry = _build_entry(rec, post, body)
    _CAP.done.append(entry)  # append atomique : aucun await ici


# ── Handlers d'events : collecte brute uniquement (sync de fait, AUCUN await) ──
#
# Pas de lock : nodriver dispatche chaque handler dans sa propre task, mais comme
# aucun handler n'`await`, son corps s'exécute atomiquement (asyncio mono-thread →
# pas de préemption hors point d'await). C'est exactement la garantie qui rend la
# mutation de `in_flight` sûre sans verrou. Le seul code qui `await`, `_finalize`,
# ne touche QUE `done` (append atomique) et le `rec` déjà retiré de `in_flight`.

async def _on_request_will_be_sent(ev, conn=None) -> None:
    rid = ev.request_id
    # Un redirect réutilise le requestId : le hop précédent est TERMINÉ ici (sa
    # réponse = `redirect_response`). On le pop et on le scelle via une tâche
    # dédiée — pas de corps de réponse à tirer, et fetch_post coupé car le rid
    # désigne déjà la NOUVELLE requête.
    if ev.redirect_response is not None and rid in _CAP.in_flight:
        prev = _CAP.in_flight.pop(rid)
        prev["response"] = ev.redirect_response
        asyncio.create_task(_finalize(prev, fetch_post=False, fetch_body=False))

    rec = _new_record(rid)
    rec["request"] = ev.request
    rec["resource_type"] = ev.type_.value if ev.type_ is not None else ""
    rec["wall_time"] = float(ev.wall_time)
    rec["ts_start"] = float(ev.timestamp)
    _CAP.in_flight[rid] = rec


async def _on_response_received(ev, conn=None) -> None:
    rec = _CAP.in_flight.get(ev.request_id)
    if rec is None:
        return
    rec["response"] = ev.response
    if ev.type_ is not None:
        rec["resource_type"] = ev.type_.value


async def _on_loading_finished(ev, conn=None) -> None:
    rec = _CAP.in_flight.pop(ev.request_id, None)
    if rec is None:
        return
    rec["ts_end"] = float(ev.timestamp)
    rec["encoded_data_length"] = float(ev.encoded_data_length)
    asyncio.create_task(_finalize(rec, fetch_post=True, fetch_body=True))


async def _on_loading_failed(ev, conn=None) -> None:
    rec = _CAP.in_flight.pop(ev.request_id, None)
    if rec is None:
        return
    rec["ts_end"] = float(ev.timestamp)
    rec["error"] = ev.error_text
    asyncio.create_task(_finalize(rec, fetch_post=True, fetch_body=False))


# ── Surface publique ──────────────────────────────────────────────────────────

async def setup_network_capture(tab) -> None:
    """Active `Network` sur le tab top et branche les handlers. Idempotent à
    l'échelle d'un process (un seul tab top suivi)."""
    _CAP.tab = tab
    await tab.send(cdp.network.enable(
        max_total_buffer_size=_HAR_BUF_BYTES,
        max_resource_buffer_size=_HAR_BUF_BYTES,
        max_post_data_size=_HAR_BUF_BYTES,
    ))
    tab.add_handler(cdp.network.RequestWillBeSent, _on_request_will_be_sent)
    tab.add_handler(cdp.network.ResponseReceived, _on_response_received)
    tab.add_handler(cdp.network.LoadingFinished, _on_loading_finished)
    tab.add_handler(cdp.network.LoadingFailed, _on_loading_failed)


def drain_page_har() -> bytes:
    """Sérialise en HAR 1.2 et **vide** le buffer des entrées finalisées (le delta
    depuis le dernier appel). Synchrone, aucun await → échange atomique."""
    entries = _CAP.done
    _CAP.done = []
    har = {
        "log": {
            "version": "1.2",
            "creator": {"name": "cyborg", "version": "1"},
            "pages": [],
            "entries": entries,
        }
    }
    return json.dumps(har).encode("utf-8")
