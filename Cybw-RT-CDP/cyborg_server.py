#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["nodriver", "quart"]
# ///
"""Cyborg `/cyborg` data-plane server (Host-Android side).

Long-running HTTP server that sits next to Chrome and executes query/tap/fill
server-side, collapsing many CDP round-trips into one `/cyborg` action RTT. It
attaches to an already-running Chrome over CDP (`127.0.0.1:9222`) via nodriver
and speaks the contract défini par `Cyborg-User-SDK/cyborg.fish`:

    POST /visit  (tar in)                 -> navigate ; url depuis fichier `url`
    POST /query  (tar in/out)             -> per hit: text + html (dossier `<i>/`) ;
         max depuis fichier `max` (int, 0/absent -> cap 1000)
    POST /tap    (tar in, flat)           -> click first match (single selecteur)
    POST /fill   (tar in, flat)           -> focus first match + type text ;
         text depuis fichier `text` ; OU, si le sous-dossier `files/` est
         présent, injecte chaque `files/<basename>` dans le match (input
         type=file) en mémoire renderer : File + DataTransfer + input.files
         (nom préservé = nom vu par la page, mimetype deviné de l'extension)
         — pas de focus/scroll (input souvent caché)
    POST /select (tar in, flat)           -> select <option> by innerText ;
         text depuis fichier `text`
    POST /js              (tar in/out)    -> callFunctionOn(script.js, args.json)
    POST /snap            (tar out)       -> page.html + <frame_id>.html + screenshot.png + network_page.har
    POST /cookie (tar in/out)             -> cookie.txt (header Cookie) +
         user-agent.txt ; url depuis fichier `url`
    POST /net    (tar in/out)             -> entry.har : entree HAR {request, response}
         (`response` null au stade `request`, rempli au stade `response`) ;
         url + timeout depuis fichiers `url` / `timeout`
    GET  /status                          -> {"page": bool, "last_action": rfc3339}

Tous les endpoints data sont en POST : les parametres scalaires (url, max, text,
timeout) sont lus depuis des FICHIERS du tar de requete (via `read_tar_dir`), en
strippant le `\n` final ajoute par le client (`echo`). Les selecteurs sont des
fichiers `<index>.json` du tar (`load_selectors`) ; les actions mono-selecteur
(tap/fill/select) prennent l'unique selecteur. `/status` reste en GET (health/lease).

Vocabulaire :
  * **Selecteur** : un `.json` produit par le CLI (argparse -> jq). Compile en
    CssSelector cote serveur (`_parse_locator_file`). Schema :

        {"element": "<css>", "pierce": false, "iframe": "<--frame>|null",
         "nth": <int>|null, "exact_text": "<str>|null", "mode": "attached"}

    `iframe` (option `--frame`) : mini-syntaxe `iframe[url<op>"v"]…` compilee en
    filtres (cf. `_parse_frame_selector`). Virgule = OR, `[url…]` accoles = AND ;
    operateurs `=` exact, `*=` sous-chaine, `^=` prefixe, `$=` suffixe, `~=`
    regex. Si present, la recherche est restreinte aux iframes matchant ; sinon
    au top frame UNIQUEMENT. `mode` = attached | visible | hidden (par selecteur).
    `nth` = index 0-based facon Playwright (aucun garde de taille).

  * Une recherche = UN selecteur (plus de fallback multi-locator). Cote requete :
      - /query : plusieurs `<index>.json` a la racine, nommes par index client.
      - /tap, /fill, /select : un seul `.json` a la racine.

  * **Target**  : l'identifiant opaque Chrome d'une page ou d'une iframe
    (`targetId`). Listing des frames trivial : top tab + chaque
    `Target.getTargets()` de type 'iframe' (OOPIFs cross-origin). Walking du
    DOM uniquement pour découvrir les shadow roots à l'intérieur de chaque
    frame (querySelectorAll ne traverse ni shadow ni iframe boundaries).

Pierce + attach : `DOM.getDocument(pierce=true)` traverse les shadows fermés en
une passe. Pour les OOPIFs cross-origin (invisibles depuis le target parent —
ex. cf-turnstile sur challenges.cloudflare.com), on attache via
`Target.attachToTarget(flatten=true)` qui multiplexe les sessions sur la même
WebSocket. Voir
`~/AntiDocs/SmokeTest-CdpClickTurnstile/README_CONCLUSION_KNOWLEDGE.md`.

Design constraints (see project memory `cyborg-redesign`):
  * No authentication — accepts all requests.
  * CDP DOM-only pour les ACTIONS (focus/scroll passent par DOM.focus /
    DOM.scrollIntoViewIfNeeded, click via input.dispatchMouseEvent — pas
    de Runtime.evaluate qui exposerait du JS détectable). EXCEPTIONS : la
    LECTURE d'innerText d'un hit utilise Runtime.callFunctionOn (resolve_node
    + `function() { return this.innerText }`), seul moyen d'obtenir la
    sémantique innerText (display:none ignoré, normalisation whitespace) ;
    et /select pilote le <select> via callFunctionOn (popup natif hors page,
    impilotable en CDP pur) — events input/change synthétiques, assumé.
  * Pas de fallback silencieux : les erreurs CDP remontent.

`/snap` : produit `page.html` (top frame) + un fichier `<frame_id>.html` par
sub-frame (OOPIF). Aucune transformation du HTML : les iframes gardent leur
`src` original, le caller reconstruit lui-même la correspondance frame_id ↔
iframe element. Shadow roots inlinés via `<template shadowrootmode>`
(Declarative Shadow DOM, HTML5 standard).

Async natif via Quart : un seul event loop, pas de bridge sync/async, pas de
lock global. Les requêtes restent sérialisées de fait par le client (un seul
opérateur).

`/status` unifies health and lease introspection. Its body carries `last_action`,
which Farm-Cell pulls over the cloudflared tunnel to learn the effective
`expires_at` (= last_action + 120s); its HTTP code (200 page present / 503 not)
serves health monitoring. Every recognised data action (visit/query/tap/fill/select/snap)
refreshes `last_action`; `/status` itself does not.
"""

import _fix_nodriver   # noqa: F401 — MUST precede `import nodriver`. # type: ignore

import asyncio
import base64
import json
import mimetypes
import os
import posixpath
import sys
import time
from datetime import datetime, timezone
from urllib.parse import parse_qsl, urlsplit

import nodriver
import quart
from nodriver import cdp

import cyborg_dom
import cyborg_har
from cyborg_dom import (
    download_req_tar, load_selector, load_selectors, read_tar_dir, build_tar,
    list_frame_ids, get_frame_by_id, collect_frames, find_frame,
    _search_selector, _send, _tab,
)
from cyborg_tap import reliable_tap, _TapTimeout, _NoMatch

CDP_HOST = "127.0.0.1"
CDP_PORT = int(os.environ["CDP_PORT"])
HTTP_HOST = "127.0.0.1"
HTTP_PORT = 9224

# Last recognised action, refreshed by `_touch()`. Seeded at boot so a freshly
# provisioned cell reports a sane value before the first action.
_LAST_ACTION = datetime.now(timezone.utc)


def _touch() -> None:
    global _LAST_ACTION
    _LAST_ACTION = datetime.now(timezone.utc)


# ── Node-tree → HTML serializer (snap) ────────────────────────────────────────

_VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "keygen",
         "link", "meta", "param", "source", "track", "wbr"}


def _serialize_cdp_node(n) -> str:
    """Node CDP → HTML. Shadow roots inlinés en `<template shadowrootmode>`
    (Declarative Shadow DOM). Iframes laissées telles quelles."""
    nt = n.node_type
    if nt == 3:
        return (n.node_value or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    if nt == 8: return f"<!--{n.node_value or ''}-->"
    if nt == 10: return f"<!DOCTYPE {n.node_name}>"
    if nt in (9, 11):
        return "".join(_serialize_cdp_node(c) for c in (n.children or []))
    if nt != 1: return ""

    tag = (n.node_name or "").lower()
    a = n.attributes or []
    attrs = "".join(
        f' {k}="{(v or "").replace("&", "&amp;").replace(chr(34), "&quot;")}"'
        for k, v in zip(a[::2], a[1::2]))
    if tag in _VOID:
        return f"<{tag}{attrs}>"
    shadows = "".join(
        f'<template shadowrootmode="{m}">'
        + "".join(_serialize_cdp_node(c) for c in (sr.children or []))
        + "</template>"
        for sr in (n.shadow_roots or [])
        if (m := sr.shadow_root_type or "open") != "user-agent")
    children = "".join(_serialize_cdp_node(c) for c in (n.children or []))
    return f"<{tag}{attrs}>{shadows}{children}</{tag}>"


def _doc_to_html(doc_node) -> bytes:
    h = _serialize_cdp_node(doc_node)
    if not h.lstrip().lower().startswith("<!doctype"):
        h = "<!DOCTYPE html>" + h
    return h.encode("utf-8")


# ── HTTP server ───────────────────────────────────────────────────────────────

app = quart.Quart(__name__)
# Les tars de /fill embarquent des fichiers d'upload : le défaut quart (16 Mio)
# les refuserait en 413 silencieux. 256 Mio = MAX_SIZE websocket de nodriver.
app.config["MAX_CONTENT_LENGTH"] = 256 * 1024 * 1024


@app.post("/visit")
async def visit():
    _touch()

    with download_req_tar(await quart.request.get_data()) as req_tar:
        members = read_tar_dir(req_tar)
    visit_url = members.get("url", b"").decode("utf-8").rstrip("\n")

    tab = await _tab()

    await tab.send(cdp.page.navigate(visit_url))

    return quart.Response(build_tar({}), mimetype="application/x-tar")


@app.post("/query")
async def query():
    _touch()

    with download_req_tar(await quart.request.get_data()) as req_tar:
        selectors = load_selectors(req_tar)
        members = read_tar_dir(req_tar)
    max_raw = members.get("max", b"0").decode("utf-8").rstrip("\n")
    given_budget = int(max_raw) if max_raw else 0

    if not selectors:
        return "bad selectors", 400
    budget = given_budget if given_budget > 0 else 1_000

    tab = await _tab()

    # Le mode (attached/visible/hidden) est porté PAR sélecteur (`sel.mode`).
    # Chaque sélecteur est nommé par son index client (0, 1, …) => `<index>/…`.
    files = {}
    for name, sel in selectors.items():
        hits = await _search_selector(tab, sel, budget, sel.mode)
        budget = max(0, budget - len(hits))

        for i, h in enumerate(hits):
            base = f"{name}/{i:04d}"
            files[f"{base}/text"] = h.inner_text.encode("utf-8")
            files[f"{base}/html"] = h.outer_html.encode("utf-8")

        if budget <= 0:
            break

    return quart.Response(build_tar(files), mimetype="application/x-tar")


@app.post("/tap")
async def tap():
    _touch()

    # Tar plat mono-sélecteur : on prend le premier (seul), comme /fill /select.
    with download_req_tar(await quart.request.get_data()) as req_tar:
        sel = next(iter(load_selectors(req_tar).values()), None)

    # /tap renvoie TOUJOURS un tar : `tries/NNNN.json` (une tentative par fichier)
    # + `error.txt` si echec. Le client (cgi/tap.fish) decide succes/echec par la
    # presence de error.txt ; c'est donc lui qui gere l'erreur, pas le transport.
    if not sel:
        return quart.Response(build_tar({"error.txt": b"bad selector"}),
                              mimetype="application/x-tar")

    # Page top.
    tab = await _tab()

    # Click fiable (toutes techniques Playwright A-F activees en dur). `tries` est
    # rempli par reliable_tap tentative par tentative, y compris en cas d'echec.
    tries: list = []
    error = None
    try:
        await reliable_tap(tab, sel, tries=tries)
    except _NoMatch as e:
        error = f"no match: {e}"
    except _TapTimeout as e:
        error = f"tap not actionable: {e}"

    files = {f"tries/{i + 1:04d}.json": json.dumps(t).encode("utf-8")
             for i, t in enumerate(tries)}
    if error is not None:
        files["error.txt"] = error.encode("utf-8")

    return quart.Response(build_tar(files), mimetype="application/x-tar")


@app.post("/fill")
async def fill():
    _touch()

    with download_req_tar(await quart.request.get_data()) as req_tar:
        sel = next(iter(load_selectors(req_tar).values()), None)
        members = read_tar_dir(req_tar)
    text = members.get("text", b"").decode("utf-8").rstrip("\n")
    uploads = {posixpath.basename(n): data for n, data in members.items()
               if n.startswith("files/")}

    if not sel:
        return "bad selector", 400

    tab = await _tab()

    # Éxécute la recherche (les uploads sous `files/` ne sont pas des .json à la
    # racine => load_selectors les ignore, pas besoin de les retirer).
    hits = await _search_selector(tab, sel, 1,
                              mode="attached" if uploads else "visible")
    if not hits:
        return "no match", 404
    h = hits[0]

    if uploads:
        # Chrome peut tourner sur une autre machine que ce serveur (Android via
        # adb forward) : un chemin local + DOM.setFileInputFiles n'y référence
        # rien — la commande ne valide pas l'existence et la page voit un File
        # vide. On injecte donc le contenu en mémoire renderer (technique
        # Playwright) : File + DataTransfer + input.files, events synthétiques
        # (isTrusted:false, assumé comme /select). Ni scroll ni focus — les
        # <input type=file> sont souvent display:none derrière un bouton stylé.
        payload = [{
            "name": name,
            "type": mimetypes.guess_type(name)[0] or "application/octet-stream",
            "b64": base64.b64encode(data).decode("ascii"),
        } for name, data in sorted(uploads.items())]
        remote = await _send(tab, cdp.dom.resolve_node(
            backend_node_id=h.backend_node_id), h.frame_sid)
        _, exc = await _send(tab, cdp.runtime.call_function_on(
            function_declaration="""function(files) {
                if (this.nodeName !== 'INPUT' || this.type !== 'file')
                    throw new Error('not a file input: <' + this.nodeName + '>');
                if (files.length > 1 && !this.multiple)
                    throw new Error('multiple files on non-multiple input');
                const dt = new DataTransfer();
                for (const f of files) {
                    const bytes = Uint8Array.from(atob(f.b64), c => c.charCodeAt(0));
                    dt.items.add(new File([bytes], f.name, {type: f.type}));
                }
                this.files = dt.files;
                this.dispatchEvent(new Event('input', {bubbles: true}));
                this.dispatchEvent(new Event('change', {bubbles: true}));
            }""",
            object_id=remote.object_id,
            arguments=[cdp.runtime.CallArgument(value=payload)],
            return_by_value=True,
        ), h.frame_sid)
        if exc is not None:
            # Locator posé ailleurs que sur l'<input type=file> (ex. le bouton
            # stylé par-dessus), ou page qui a remplacé le node.
            desc = exc.exception.description if exc.exception else exc.text
            return f"set files failed: {desc}", 400
        return quart.Response(build_tar({}), mimetype="application/x-tar")

    # Focus et met le texte:

    await _send(tab, cdp.dom.scroll_into_view_if_needed(
        backend_node_id=h.backend_node_id), h.frame_sid)
    await _send(tab, cdp.dom.focus(
        backend_node_id=h.backend_node_id), h.frame_sid)
    await _send(tab, cdp.input_.insert_text(text), h.frame_sid)

    return quart.Response(build_tar({}), mimetype="application/x-tar")


@app.post("/select")
async def select():
    _touch()

    with download_req_tar(await quart.request.get_data()) as req_tar:
        sel = next(iter(load_selectors(req_tar).values()), None)
        members = read_tar_dir(req_tar)
    text = members.get("text", b"").decode("utf-8").rstrip("\n")

    if not sel:
        return "bad selector", 400

    tab = await _tab()

    # Éxécute la recherche
    hits = await _search_selector(tab, sel, 1)
    if not hits:
        return "no match", 404
    h = hits[0]

    # Focus puis sélectionne l'option par son innerText. Events `input` et
    # `change` synthétiques (isTrusted:false, assumé).

    await _send(tab, cdp.dom.scroll_into_view_if_needed(
        backend_node_id=h.backend_node_id), h.frame_sid)
    await _send(tab, cdp.dom.focus(
        backend_node_id=h.backend_node_id), h.frame_sid)

    remote = await _send(tab, cdp.dom.resolve_node(
        backend_node_id=h.backend_node_id), h.frame_sid)
    result, exc = await _send(tab, cdp.runtime.call_function_on(
        function_declaration="""function(text) {
            for (const o of this.options) {
                if (o.innerText === text) {
                    this.value = o.value;
                    this.dispatchEvent(new Event('input', {bubbles: true}));
                    this.dispatchEvent(new Event('change', {bubbles: true}));
                    return true;
                }
            }
            return false;
        }""",
        object_id=remote.object_id,
        arguments=[cdp.runtime.CallArgument(value=text)],
        return_by_value=True,
    ), h.frame_sid)

    if exc is not None:
        raise RuntimeError(f"select callFunctionOn failed: {exc}")
    if not result.value:
        return "no option", 404

    return quart.Response(build_tar({}), mimetype="application/x-tar")


@app.post("/js")
async def js():
    _touch()

    with download_req_tar(await quart.request.get_data()) as req_tar:
        members = read_tar_dir(req_tar)
        # `frame.json` (optionnel) : sélecteur d'iframe (`--frame`) qui choisit la
        # FRAME où évaluer. On résout la frame par son URL, puis on éval dedans.
        frame_sel = load_selector(req_tar, "frame")

    arguments = [
        cdp.runtime.CallArgument(value=v)
        for v in json.loads(members["args.json"].decode("utf-8"))
    ]
    # `/output` == "json" => returnByValue + on renvoie la valeur ; vide sinon.
    want_value = members["output"].strip() == b"json"

    tab = await _tab()

    # `this` = globalThis. Sans `rel`, c'est le top frame. Avec `rel`, c'est le
    # globalThis de la frame portant l'élément matché (OOPIF ou in-process) :
    # callFunctionOn s'exécute dans le contexte qui possède l'objectId, donc
    # récupérer `window` via un node de la frame suffit à router l'éval là-bas.
    frame_sid = None
    if frame_sel is not None:
        frame = await find_frame(tab, frame_sel)
        if frame is None:
            return quart.Response(build_tar({"error": b"frame: no match"}),
                                  mimetype="application/x-tar")
        frame_sid = frame.frame_sid
        # globalThis de la frame = document.defaultView. resolve_node par
        # backendNodeId marche pour OOPIF (session dédiée) comme pour in-process.
        doc_remote = await _send(tab, cdp.dom.resolve_node(
            backend_node_id=frame.frame_doc.backend_node_id), frame_sid)
        glob, exc = await _send(tab, cdp.runtime.call_function_on(
            function_declaration="function() { return this.defaultView; }",
            object_id=doc_remote.object_id,
        ), frame_sid)
        if exc is not None:
            raise RuntimeError(f"/js frame globalThis resolve failed: {exc}")
    else:
        # callFunctionOn exige un objet hôte : `this` = globalThis du top frame.
        glob, exc = await tab.send(cdp.runtime.evaluate(expression="globalThis"))
        if exc is not None:
            raise RuntimeError(f"/js globalThis eval failed: {exc}")

    result, exc = await _send(tab, cdp.runtime.call_function_on(
        function_declaration=members["script.js"].decode("utf-8"),
        object_id=glob.object_id,
        arguments=arguments,
        return_by_value=want_value,
        await_promise=True,
    ), frame_sid)
    if exc is not None:
        desc = exc.exception.description if exc.exception else exc.text
        files = {"error": desc.encode("utf-8")}
        return quart.Response(build_tar(files), mimetype="application/x-tar")

    files = {"output": json.dumps(result.value).encode("utf-8")} if want_value else {}
    return quart.Response(build_tar(files), mimetype="application/x-tar")


@app.post("/snap")
async def snap():
    tab = await _tab()
    files: dict = {}

    # ── DEBUG TEMPORAIRE : Page.getFrameTree vs Target.getTargets (+ timing) ──
    # Vérifie si getFrameTree énumère les frames SAME-ORIGIN (que getTargets,
    # OOPIF-only, rate) et à quel coût, pour décider s'il remplace l'énumération
    # par targets + le walk manuel des nœuds IFRAME. À retirer une fois tranché.
    try:
        def _fmt_tree(node, depth, out):
            fr = node.frame
            out.append("  " * depth + f"id={fr.id_} "
                       f"parent={getattr(fr, 'parent_id', None)} "
                       f"origin={getattr(fr, 'security_origin', '')} url={fr.url}")
            for ch in (node.child_frames or []):
                _fmt_tree(ch, depth + 1, out)
            return out

        t0 = time.perf_counter()
        ft = await tab.send(cdp.page.get_frame_tree())
        dt_ft = (time.perf_counter() - t0) * 1000.0

        t0 = time.perf_counter()
        tgts = await tab.send(cdp.target.get_targets())
        dt_tg = (time.perf_counter() - t0) * 1000.0
        iframe_tgts = [ti for ti in tgts if getattr(ti, "type_", "") == "iframe"]

        tree = _fmt_tree(ft, 0, [])
        print(f"[cyborg/DEBUG] getFrameTree: {len(tree)} frame(s) in {dt_ft:.2f}ms "
              f"| getTargets: {len(iframe_tgts)} iframe-target(s) in {dt_tg:.2f}ms",
              file=sys.stderr, flush=True)
        for ln in tree:
            print(f"[cyborg/DEBUG] FT {ln}", file=sys.stderr, flush=True)
        for ti in iframe_tgts:
            print(f"[cyborg/DEBUG] TGT iframe id={ti.target_id} "
                  f"url={getattr(ti, 'url', '')}", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"[cyborg/DEBUG] frame-tree debug failed: {e!r}",
              file=sys.stderr, flush=True)

    for frame in (await collect_frames(tab)):
        frame_name = "page" if frame.frame_is_top else f"{frame.frame_tid}"

        files[f"frame_{frame_name}/target.json"] = json.dumps({
            "is_top": frame.frame_is_top,
            "url": frame.frame_url,
            "target_id": frame.frame_tid,
        }).encode('utf-8')

        files[f"frame_{frame_name}/document.html"] = _doc_to_html(frame.frame_doc)

    shot_b64 = await tab.send(cdp.page.capture_screenshot(format_="png"))
    if shot_b64:
        files["screenshot_full.png"] = base64.b64decode(shot_b64)

    # Delta réseau depuis le dernier snap (top-frame).
    files["network_page.har"] = cyborg_har.drain_page_har()

    _touch()
    return quart.Response(build_tar(files), mimetype="application/x-tar")


@app.post("/cookie")
async def cookie():
    _touch()

    with download_req_tar(await quart.request.get_data()) as req_tar:
        members = read_tar_dir(req_tar)
    url = members.get("url", b"").decode("utf-8").rstrip("\n")

    tab = await _tab()

    cookies = await tab.send(cdp.network.get_cookies(urls=[url]))
    version = await tab.send(cdp.browser.get_version())

    # Header `Cookie` tel que l'enverrait le client : `name=value; name2=value2`.
    header = "; ".join(f"{c.name}={c.value}" for c in (cookies or []))
    user_agent = version[3]

    files = {
        "cookie.txt": header.encode("utf-8"),
        "user-agent.txt": user_agent.encode("utf-8"),
    }
    return quart.Response(build_tar(files), mimetype="application/x-tar")


@app.post("/net")
async def net():
    """Arme l'interception Fetch (ephemere) et attend la PROCHAINE requete dont
    l'url matche le glob `url` (wildcards `*`/`?`), jusqu'a `timeout` secondes.
    Relache la requete, desactive Fetch, et renvoie `entry.har` = une entree HAR
    {request, response} ou `request` est reconstruit a la main. Si rien ne matche
    avant T : tar vide (pas de entry.har). `url`/`timeout`/`stade` toujours fournis
    par le client (fichiers du tar de requete `url` / `timeout` / `stade`).

    `stade` (`request` | `response`, defaut `response`) choisit a quel stade Fetch
    relache :
      * `request`  -> interception au stade REQUEST : on ne voit que la requete
                      sortante, `response` = `null`.
      * `response` -> interception au stade RESPONSE : on attend la reponse et on
                      remplit `response` au format HAR (status, headers, body via
                      `Fetch.getResponseBody`). Body indisponible sur les redirects
                      (3xx) -> `content` vide.

    Les cookies sont injectes depuis le cookie store (`Network.getCookies`), ce
    qui inclut les PARTITIONNES (CHIPS, ex. `cf_clearance` Cloudflare) que l'inter-
    ception Fetch ne voit pas -> le request est rejouable tel quel (Cookie +
    User-Agent dans `headers`, plus le tableau `cookies`)."""
    _touch()

    with download_req_tar(await quart.request.get_data()) as req_tar:
        members = read_tar_dir(req_tar)
    url_glob = members.get("url", b"").decode("utf-8").rstrip("\n")
    timeout = float(members.get("timeout", b"60").decode("utf-8").rstrip("\n"))
    stade = members.get("stade", b"response").decode("utf-8").rstrip("\n") or "response"
    want_response = stade != "request"
    request_stage = (cdp.fetch.RequestStage.RESPONSE if want_response
                     else cdp.fetch.RequestStage.REQUEST)

    tab = await _tab()
    fut: asyncio.Future = asyncio.get_running_loop().create_future()

    async def _capture_response(ev):
        # Objet HAR `response` depuis un event Fetch pause au stade RESPONSE.
        # `getResponseBody` DOIT etre appele PENDANT la pause (avant continue_request
        # / disable). Indisponible sur les redirects (3xx) -> content vide.
        header_pairs = [(h.name, h.value) for h in (ev.response_headers or [])]
        ctype = next((v for k, v in header_pairs if k.lower() == "content-type"), "")
        location = next((v for k, v in header_pairs if k.lower() == "location"), "")

        text, size, encoding = "", -1, None
        try:
            body, b64 = await tab.send(cdp.fetch.get_response_body(request_id=ev.request_id))
            text = body
            size = len(base64.b64decode(body)) if b64 else len(body.encode("utf-8"))
            encoding = "base64" if b64 else None
        except Exception:
            pass  # redirect / body indisponible

        content = {"size": max(size, 0), "mimeType": ctype, "text": text}
        if encoding:
            content["encoding"] = encoding

        return {
            "status": ev.response_status_code or 0,
            "statusText": ev.response_status_text or "",
            "httpVersion": "HTTP/1.1",
            "headers": [{"name": n, "value": v} for n, v in header_pairs],
            "cookies": [],
            "content": content,
            "redirectURL": location,
            "headersSize": -1,
            "bodySize": size,
        }

    async def _on_paused(ev, conn=None):
        # 1ere requete matchee -> on memorise (request, response?), puis on relache.
        try:
            if not fut.done():
                har_response = await _capture_response(ev) if want_response else None
                fut.set_result((ev.request, har_response))
        finally:
            try:
                await tab.send(cdp.fetch.continue_request(request_id=ev.request_id))
            except Exception:
                pass

    tab.add_handler(cdp.fetch.RequestPaused, _on_paused)
    captured = None
    try:
        await tab.send(cdp.fetch.enable(patterns=[
            cdp.fetch.RequestPattern(
                url_pattern=url_glob,
                request_stage=request_stage,
            )
        ]))
        try:
            captured = await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            captured = None
    finally:
        try:
            await tab.send(cdp.fetch.disable())  # libere les requetes en pause
        except Exception:
            pass
        tab.remove_handler(cdp.fetch.RequestPaused, _on_paused)

    if captured is None:
        return quart.Response(build_tar({}), mimetype="application/x-tar")

    request, har_response = captured

    # Reconstruit l'objet HAR `request` depuis l'objet CDP, enrichi des cookies du
    # store (`getCookies` voit les PARTITIONNES/CHIPS comme cf_clearance, invisibles
    # a l'interception Fetch) + de la queryString. Schema HAR 1.2.
    headers = dict(request.headers or {})
    body = request.post_data

    raw_cookies = await tab.send(cdp.network.get_cookies(urls=[request.url]))
    cookie_list = [(c.name, c.value) for c in (raw_cookies or [])]
    if cookie_list and not any(k.lower() == "cookie" for k in headers):
        headers["Cookie"] = "; ".join(f"{n}={v}" for n, v in cookie_list)

    query_string = [{"name": k, "value": v}
                    for k, v in parse_qsl(urlsplit(request.url).query, keep_blank_values=True)]

    har_request = {
        "method": request.method,
        "url": request.url,
        "httpVersion": "HTTP/1.1",
        "headers": cyborg_har.har_headers(headers),
        "queryString": query_string,
        "cookies": [{"name": n, "value": v} for n, v in cookie_list],
        "headersSize": -1,
        "bodySize": len(body.encode("utf-8")) if body is not None else -1,
    }
    if body is not None:
        har_request["postData"] = {
            "mimeType": headers.get("Content-Type", headers.get("content-type", "")),
            "text": body,
        }

    # Entree HAR : `request` reconstruit + `response` (null au stade REQUEST, rempli
    # au format HAR au stade RESPONSE).
    har_entry = {"request": har_request, "response": har_response}

    files = {"entry.har": json.dumps(har_entry).encode("utf-8")}
    return quart.Response(build_tar(files), mimetype="application/x-tar")


# ── Profil : cookies + localStorage/sessionStorage ────────────────────────────
# Restaurer le localStorage AVANT le 1er script de page : un token vivant
# UNIQUEMENT en localStorage (pas en cookie) doit être présent au load, sinon
# l'app (ex. panel admin) redirige. Seul `Page.addScriptToEvaluateOnNewDocument`
# le garantit (docstring CDP : « before loading frame's scripts »), en main world
# (`world_name=None`). `dom_storage.set_dom_storage_item` exigerait un document
# same-origin déjà vivant → trop tard ; réservé à l'export (lecture).

def _cookie_origin(c) -> str:
    """Origine approximative d'un cookie (énumération + wipe par origine)."""
    host = (c.domain or "").lstrip(".")
    return f"{'https' if c.secure else 'http'}://{host}"


def _cookie_to_param(c):
    """network.Cookie → network.CookieParam : round-trip complet (HttpOnly,
    SameSite, partition_key/CHIPS préservés). source_port=-1 (unspecified) → None.
    expires : Cookie.from_json le désérialise en float NU, mais CookieParam.to_json
    appelle .to_json() dessus → on le re-type en TimeSinceEpoch (sinon AttributeError
    sur tout cookie non-session).
    __Host- : Chrome INTERDIT l'attribut Domain (cookie host-only) → on omet domain
    et on passe par `url`, sinon setCookies rejette « Invalid cookie fields »."""
    host_only = c.name.startswith("__Host-")
    url = None
    if host_only:
        url = f"https://{(c.domain or '').lstrip('.')}{c.path or '/'}"
    return cdp.network.CookieParam(
        name=c.name, value=c.value, url=url,
        domain=(None if host_only else c.domain), path=c.path,
        secure=c.secure, http_only=c.http_only, same_site=c.same_site,
        expires=(cdp.network.TimeSinceEpoch(c.expires) if c.expires is not None else None),
        priority=c.priority, source_scheme=c.source_scheme,
        source_port=(c.source_port if c.source_port not in (None, -1) else None),
        partition_key=c.partition_key,
    )


def _seed_js(origin: str, local: dict, session: dict) -> str:
    """Script seedé : gardé par origine, pose le storage avant le JS de page.
    `localStorage.clear()` interne → ordre clear→set atomique par origine."""
    return (
        f"if(location.origin==={json.dumps(origin)}){{try{{"
        f"localStorage.clear();"
        f"var L={json.dumps(local)};for(var k in L)localStorage.setItem(k,L[k]);"
        f"var S={json.dumps(session)};for(var k in S)sessionStorage.setItem(k,S[k]);"
        f"}}catch(e){{}}}}"
    )


async def _wait_ready(tab, timeout: float = 15.0) -> None:
    """Attend `document.readyState=='complete'` (borné). Best-effort : le seed a
    déjà tourné au commit de la nav ; ceci laisse seulement la page se poser."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            res = await tab.send(cdp.runtime.evaluate(
                expression="document.readyState", return_by_value=True))
            if res and res[0] and res[0].value == "complete":
                return
        except Exception:
            return
        await asyncio.sleep(0.2)


@app.post("/export-profile")
async def export_profile():
    """Exporte TOUT le profil atteignable (sans URL) : cookies complets +
    localStorage/sessionStorage par origine. Origines = domaines de cookies ∪
    arbre de frames ∪ page courante. Tar `{cookies.json, storage/<origin>.json}`."""
    _touch()
    tab = await _tab()
    await tab.send(cdp.dom_storage.enable())

    cookies = await tab.send(cdp.storage.get_cookies()) or []

    origins: set[str] = {_cookie_origin(c) for c in cookies}
    tree = await tab.send(cdp.page.get_frame_tree())

    def _walk(node):
        u = getattr(node.frame, "url", None)
        if u and u.startswith(("http://", "https://")):
            p = urlsplit(u)
            origins.add(f"{p.scheme}://{p.netloc}")
        for ch in (node.child_frames or []):
            _walk(ch)
    _walk(tree)

    storage: dict[str, dict] = {}
    for o in origins:
        entry = {"local": {}, "session": {}}
        for is_local, key in ((True, "local"), (False, "session")):
            try:
                sid = cdp.dom_storage.StorageId(is_local_storage=is_local, security_origin=o)
                items = await tab.send(cdp.dom_storage.get_dom_storage_items(sid))
                entry[key] = {it[0]: it[1] for it in (items or [])}  # Item = [k, v]
            except Exception:
                pass
        if entry["local"] or entry["session"]:
            storage[o] = entry

    files = {"cookies.json": json.dumps([c.to_json() for c in cookies]).encode("utf-8")}
    for o, e in storage.items():
        safe = o.replace("://", "_").replace(":", "_").replace("/", "_")
        files[f"storage/{safe}.json"] = json.dumps({"origin": o, **e}).encode("utf-8")

    return quart.Response(build_tar(files), mimetype="application/x-tar")


@app.post("/set-profile")
async def set_profile():
    """Restaure un profil : WIPE (cookies + données par origine, service workers
    inclus via « all ») puis set cookies, puis seed localStorage AVANT le JS de
    page (anti-redirect) via addScriptToEvaluateOnNewDocument + navigate."""
    _touch()

    with download_req_tar(await quart.request.get_data()) as req_tar:
        members = read_tar_dir(req_tar)

    cookies_json = (json.loads(members["cookies.json"].decode("utf-8"))
                    if "cookies.json" in members else [])
    storage: dict[str, dict] = {}
    for name, raw in members.items():
        if name.startswith("storage/") and name.endswith(".json"):
            d = json.loads(raw.decode("utf-8"))
            storage[d["origin"]] = {"local": d.get("local", {}), "session": d.get("session", {})}

    tab = await _tab()
    cooks = [cdp.network.Cookie.from_json(c) for c in cookies_json]
    origins = set(storage) | {_cookie_origin(c) for c in cooks}

    # WIPE (jamais un merge).
    await tab.send(cdp.storage.clear_cookies())
    for o in origins:
        try:
            await tab.send(cdp.storage.clear_data_for_origin(origin=o, storage_types="all"))
        except Exception:
            pass

    # COOKIES (sans navigation ; HttpOnly/CHIPS réinjectés). Chrome rejette TOUT le
    # batch (« Invalid cookie fields ») dès qu'un seul cookie est malformé → on
    # retombe en pose 1-à-1 pour isoler et logger le(s) fautif(s), poser le reste,
    # et ne pas faire échouer le set-profile entier.
    if cooks:
        params = [_cookie_to_param(c) for c in cooks]
        try:
            await tab.send(cdp.storage.set_cookies(params))
        except Exception as batch_err:
            print(f"[cyborg] set-profile: batch set_cookies KO ({batch_err!r}) → pose 1-à-1",
                  file=sys.stderr, flush=True)
            ok = skipped = 0
            for p in params:
                try:
                    await tab.send(cdp.storage.set_cookies([p]))
                    ok += 1
                except Exception as e:
                    skipped += 1
                    print(f"[cyborg] set-profile: cookie REJETÉ ({e!r}) :: {json.dumps(p.to_json())}",
                          file=sys.stderr, flush=True)
            print(f"[cyborg] set-profile: {ok} posés, {skipped} ignorés",
                  file=sys.stderr, flush=True)

    # SEED localStorage avant le 1er script de page (un identifier par origine).
    script_ids = []
    for o, e in storage.items():
        sid = await tab.send(cdp.page.add_script_to_evaluate_on_new_document(
            source=_seed_js(o, e["local"], e["session"])))
        script_ids.append(sid)

    # NAVIGATE séquentiel : le seed tourne au commit de chaque document.
    for o in storage:
        res = await tab.send(cdp.page.navigate(o + "/"))
        err = res[2] if isinstance(res, (list, tuple)) and len(res) > 2 else None
        if err:
            print(f"[cyborg] set-profile nav {o} failed: {err}", file=sys.stderr, flush=True)
        await _wait_ready(tab)

    # CLEANUP après la dernière nav : sinon le seed (avec son localStorage.clear)
    # se rejoue sur chaque page suivante de l'utilisateur et détruit l'état vivant.
    for sid in script_ids:
        await tab.send(cdp.page.remove_script_to_evaluate_on_new_document(sid))

    return quart.Response(build_tar({}), mimetype="application/x-tar")


@app.get("/status")
async def status():
    # Health = "le tab existe et CDP répond". Ping non-mutant via Target domain.
    try:
        tab = await _tab()
        await tab.send(cdp.target.get_targets())
        ok = True
    except Exception:
        ok = False

    body = json.dumps({
        "page": ok,
        "last_action": _LAST_ACTION.isoformat(sep=" ", timespec="seconds"),
        "flavor": "cdp",
    })
    return quart.Response(
        body, status=200 if ok else 503, mimetype="application/json")


async def main():
    deadline = time.monotonic() + 30
    last_err = None
    while time.monotonic() < deadline:
        try:
            # browser_executable_path obligatoire mais reste inutilisé
            cyborg_dom.BROWSER = await nodriver.Browser.create(
                host=CDP_HOST, port=CDP_PORT,
                browser_executable_path="/usr/bin/true",
            )
            break
        except Exception as e:
            last_err = e
            await asyncio.sleep(0.2)
    else:
        raise RuntimeError(f"CDP not reachable before deadline: {last_err}")

    await cyborg_dom.BROWSER.get("about:blank")
    await cyborg_har.setup_network_capture(await _tab())
    print(
        f"[cyborg] data plane on http://{HTTP_HOST}:{HTTP_PORT} "
        f"→ CDP {CDP_HOST}:{CDP_PORT}",
        flush=True,
    )
    await app.run_task(host=HTTP_HOST, port=HTTP_PORT)


if __name__ == "__main__":
    asyncio.run(main())
