#!/usr/bin/env -S uv run
"""Cyborg `/cyborg` data-plane server (Host-Android side).

Long-running HTTP server that sits next to Chrome and executes query/tap/input
server-side, collapsing many CDP round-trips into one `/cyborg` action RTT. It
attaches to an already-running Chrome over CDP (`127.0.0.1:9222`) via nodriver
and speaks le contrat de `Cybw-Cli/lib/transport.fish`.

TRANSPORT — tar in, tar out. Toute reponse (succes, erreur metier, crash) est un
tar `application/x-tar` contenant `ok.txt` XOR `error.txt` :

    succes -> `ok.txt` (vide, sauf /js) + le payload de l'endpoint
    echec  -> `error.txt` (le message) + les artefacts eventuels (trace de /tap)

Le client ne lit PAS le code HTTP : il untar et tranche sur le marqueur. C'est
`_resp_ok` / `_resp_error` qui garantissent l'invariant, tout `return` passe par
l'une des deux ; les exceptions sont rattrapees par `_on_exception` (traceback
dans `error.txt`), une vue pouvant declarer un rendu local via `on_error` pour y
joindre ses artefacts sans try/except (cf. /tap).

    POST /visit           -> ok.txt ; url depuis fichier `url`
    POST /query           -> ok.txt + par hit `<i>/NNNN/{text,html}` ;
         max depuis fichier `max` (int, 0/absent -> cap 1000)
    POST /tap             -> ok.txt + `tries/NNNN.json` (une tentative par
         fichier) ; en echec : error.txt + la meme trace
    POST /input           -> ok.txt ; focus + insert_text depuis `text`, OU
         `select-value` (select <option> par value), OU le sous-dossier `files/` :
         injecte chaque `files/<basename>` dans le match (input type=file) en
         memoire renderer via File + DataTransfer + input.files (nom preserve =
         nom vu par la page, mimetype devine de l'extension) — pas de
         focus/scroll (input souvent cache)
    POST /js              -> ok.txt = l'output DEJA en texte brut (comme `jq -r`,
         vide si le client n'a pas demande `output` == "json") ;
         callFunctionOn(script.js, args.json), frame.json optionnel
    POST /snap            -> ok.txt + `frame_<page|tid>/{target.json,document.html}`
         + screenshot_full.png + network_page.har
    POST /net             -> ok.txt + entry.har : entree HAR {request, response}
         (`response` null au stade `request`, rempli au stade `response`) ;
         deadline ecoulee = ok.txt SANS entry.har ; url + timeout + stade depuis
         les fichiers de meme nom
    POST /profile-save    -> ok.txt + cookies.json
    POST /profile-restore -> ok.txt ; cookies.json en entree (WIPE, pas un merge)
    GET  /status          -> {"page": bool, "last_action": rfc3339} en JSON (seul
         endpoint hors contrat tar : health/lease, 200 ou 503)

Tous les endpoints data sont en POST : les parametres scalaires (url, max, text,
timeout) sont lus depuis des FICHIERS du tar de requete, mis en memoire des la
reception (`read_req_tar` -> `dict[str, bytes]`, aucun TarFile ne circule).
`tar_member_text(..., strip=True)` pour les scalaires « une ligne » que le client
ecrit avec `echo` ; brut pour les valeurs utilisateur (`text`, `select-value`).
Les selecteurs sont des fichiers `<index>.json` du tar (`load_selectors`) ; les
actions mono-selecteur (tap/input) prennent `0.json` (`load_selector`).

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
    et /input pilote le <select> via callFunctionOn (popup natif hors page,
    impilotable en CDP pur) — events input/change synthétiques, assumé.
  * Pas de fallback silencieux : les erreurs CDP remontent — jusqu'a
    `_on_exception`, qui les rend en `error.txt` avec leur traceback.

`/snap` : produit `frame_page/document.html` (top frame) + un dossier
`frame_<target_id>/` par sub-frame (OOPIF), chacun avec son `target.json`.
Aucune transformation du HTML : les iframes gardent leur `src` original, le
caller reconstruit lui-même la correspondance frame_id ↔ iframe element. Shadow
roots inlinés via `<template shadowrootmode>` (Declarative Shadow DOM, HTML5
standard).

Async natif via Quart : un seul event loop, pas de bridge sync/async, pas de
lock global. Les requêtes restent sérialisées de fait par le client (un seul
opérateur).

`/status` unifies health and lease introspection. Its body carries `last_action`,
which Farm-Cell pulls over the cloudflared tunnel to learn the effective
`expires_at` (= last_action + 120s); its HTTP code (200 page present / 503 not)
serves health monitoring. Every recognised data action (visit/query/tap/input/js/
snap/net/profile-*) refreshes `last_action`; `/status` itself does not.
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
import traceback
from datetime import datetime, timezone
from urllib.parse import parse_qsl, urlsplit

import nodriver
import quart
from nodriver import cdp
from werkzeug.exceptions import HTTPException

import cyborg_dom
import cyborg_har
import cyborg_profile
from cyborg_dom import (
    read_req_tar, load_selector, load_selectors, build_tar,
    list_frame_ids, get_frame_by_id, collect_frames, find_frame,
    _search_selector, _send, _tab, tar_filter_dir, tar_member_text,
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
# le défaut quart était 16 Mio. Il a été changé à 256 Mio car c'est le MAX_SIZE websocket de nodriver.
app.config["MAX_CONTENT_LENGTH"] = 256 * 1024 * 1024


# ── Transport : toute réponse est un tar `ok.txt` XOR `error.txt` ──────────────

def _resp_ok(files: dict[str, bytes] | None = None,
             ok: bytes = b"") -> quart.Response:
    """Succès : `ok.txt` (vide, sauf /js qui y met son output) + payload."""
    return quart.Response(build_tar({**(files or {}), "ok.txt": ok}),
                          mimetype="application/x-tar")


def _resp_error(msg: str, files: dict[str, bytes] | None = None,
                status: int = 200) -> quart.Response:
    """Échec : `error.txt` + artefacts éventuels (ex. la trace de /tap).

    200 par défaut : une erreur métier EST une réponse d'op valide, le client
    tranche sur la présence de `error.txt` et ne lit pas le code HTTP."""
    return quart.Response(build_tar({**(files or {}), "error.txt": msg.encode("utf-8")}),
                          status=status, mimetype="application/x-tar")


def on_error(render):
    """Déclare le rendu d'erreur DE CETTE REQUÊTE : `render(exc) -> Response`.

    Sert aux vues dont l'échec remonte du fond d'un appel (/tap) et doit
    emporter des artefacts qui sont des LOCALES de la vue : `render` est une
    fonction interne, donc elle ferme dessus, et l'exception continue de
    remonter naturellement à quart — pas de try/except dans la vue.

    `quart.g` n'est pas un global : `RequestContext._push_appctx` pousse un app
    context par requête et `g` est un LocalProxy sur le contextvar `_cv_app`,
    donc chaque requête (chaque tâche) a le sien."""
    quart.g.on_error = render
    return render


# Échecs attendus : message court. Le reste = bug, on veut la traceback.
_EXPECTED = (_NoMatch, _TapTimeout)


def _describe(exc: BaseException) -> str:
    if isinstance(exc, _EXPECTED):
        return f"{type(exc).__name__}: {exc}"
    return "".join(traceback.format_exception(exc))


@app.errorhandler(Exception)
async def _on_exception(exc: Exception) -> quart.Response:
    """Toute exception → tar `error.txt`. Si la vue a déclaré un rendu local
    (`on_error`), c'est lui qui produit la réponse : il connaît ses artefacts."""
    render = getattr(quart.g, "on_error", None)
    if render is not None:
        return render(exc)
    return _resp_error(_describe(exc),
                       status=200 if isinstance(exc, _EXPECTED) else 500)


@app.errorhandler(HTTPException)
async def _on_http_exception(exc: HTTPException) -> quart.Response:
    """404 route inconnue, 413 upload trop gros, 405… : quart les détourne avant
    la recherche par `__mro__`, donc `_on_exception` ne les voit jamais."""
    return _resp_error(f"{exc.code} {exc.name}: {exc.description}",
                       status=exc.code or 500)


@app.post("/visit")
async def visit():
    _touch()

    members = read_req_tar(await quart.request.get_data())
    visit_url = tar_member_text(members, "url", strip=True)
    if not visit_url:
        return _resp_error("no url provided")

    tab = await _tab()

    await tab.send(cdp.page.navigate(visit_url))

    return _resp_ok()


@app.post("/query")
async def query():
    _touch()

    members = read_req_tar(await quart.request.get_data())
    selectors = load_selectors(members)
    max_raw = tar_member_text(members, "max", strip=True) or "0"

    if not selectors:
        return _resp_error("bad selectors")
    if not max_raw.isdigit():
        return _resp_error(f"bad max: {max_raw!r}")
    given_budget = int(max_raw)
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
            # TODO: bbox

        if budget <= 0:
            break

    return _resp_ok(files)


@app.post("/tap")
async def tap():
    _touch()

    # Tar plat mono-sélecteur : le CLI écrit toujours `0.json`.
    members = read_req_tar(await quart.request.get_data())
    sel = load_selector(members, "0")
    if sel is None:
        return _resp_error("bad selector")

    # Page top.
    tab = await _tab()

    # Click fiable (toutes techniques Playwright A-F activees en dur). `tries` est
    # rempli par reliable_tap tentative par tentative, y compris en cas d'echec :
    # la trace part donc avec l'erreur, via le rendu local ci-dessous.
    tries: list = []

    def _tries_files() -> dict[str, bytes]:
        return {f"tries/{i + 1:04d}.json": json.dumps(t).encode("utf-8")
                for i, t in enumerate(tries)}

    @on_error
    def _(exc):                                  # ferme sur `tries`
        return _resp_error(_describe(exc), _tries_files())

    # Peut lever (_NoMatch, _TapTimeout, ou une erreur CDP brute) : voulu, c'est
    # `_on_exception` qui rend la réponse en appelant le rendu ci-dessus.
    await reliable_tap(tab, sel, tries=tries)

    return _resp_ok(_tries_files())


@app.post("/input")
async def input():
    _touch()

    members = read_req_tar(await quart.request.get_data())
    sel = load_selector(members, "0")
    text = tar_member_text(members, "text")
    select_value = tar_member_text(members, "select-value")
    files = tar_filter_dir(members, "files/")

    if sel is None:
        return _resp_error("bad selector")

    tab = await _tab()

    # Éxécute la recherche (les uploads sous `files/` ne sont pas des .json à la
    # racine => load_selectors les ignore, pas besoin de les retirer).
    hits = await _search_selector(tab, sel, 1,
                              mode="attached" if files else "visible")
    if not hits:
        return _resp_error("no match")
    h = hits[0]

    if files:
        # <input type="file">
        # D'abord injecte le fichier en mémoire navigateur comme Playwright (pour les navigateurs distants).
        # Puis émet des events synthétique mais qui sont `isTrusted:false`. Donc pas besoin de scroll ni focus
        # TODO: isTrusted:false
        payload = [{
            "name": name,
            "type": mimetypes.guess_type(name)[0] or "application/octet-stream",
            "b64": base64.b64encode(data).decode("ascii"),
        } for name, data in sorted(files.items())]
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
            desc = exc.exception.description if exc.exception else exc.text
            return _resp_error(f"set files failed: {desc}")
        return _resp_ok()

    if text is not None:
        # Focus et insère le texte.
        # NOTE: insert_text() émule ni le clavier ni le presse-papier, mais produit `isTrusted:true`
        # C'est sûrement detect par stripe et tt

        await _send(tab, cdp.dom.scroll_into_view_if_needed(
            backend_node_id=h.backend_node_id), h.frame_sid)
        await _send(tab, cdp.dom.focus(
            backend_node_id=h.backend_node_id), h.frame_sid)

        await _send(tab, cdp.input_.insert_text(text), h.frame_sid)

        return _resp_ok()

    if select_value is not None:
        # Focus et émet des events synthétique.
        # TODO: `isTrusted:false`

        await _send(tab, cdp.dom.scroll_into_view_if_needed(
            backend_node_id=h.backend_node_id), h.frame_sid)
        await _send(tab, cdp.dom.focus(
            backend_node_id=h.backend_node_id), h.frame_sid)

        remote = await _send(tab, cdp.dom.resolve_node(
            backend_node_id=h.backend_node_id), h.frame_sid)
        result, exc = await _send(tab, cdp.runtime.call_function_on(
            function_declaration="""function(value) {
                for (const opt of this.options) {
                    // if (opt.innerText === text) {
                    if (opt.value === value) {
                        this.value = opt.value;
                        this.dispatchEvent(new Event('input', {bubbles: true}));
                        this.dispatchEvent(new Event('change', {bubbles: true}));
                        return true;
                    }
                }
                return false;
            }""",
            object_id=remote.object_id,
            arguments=[
                cdp.runtime.CallArgument(value=select_value)
            ],
            return_by_value=True,
        ), h.frame_sid)
        if exc is not None:
            desc = exc.exception.description if exc.exception else exc.text
            return _resp_error(f"select failed: {desc}")

        if not result.value:
            return _resp_error("option not found")
        else:
            return _resp_ok()

    return _resp_error("no input provided")


@app.post("/js")
async def js():
    _touch()

    members = read_req_tar(await quart.request.get_data())
    # `frame.json` (optionnel) : sélecteur d'iframe (`--frame`) qui choisit la
    # FRAME où évaluer. On résout la frame par son URL, puis on éval dedans.
    frame_sel = load_selector(members, "frame")

    script = tar_member_text(members, "script.js")
    args_raw = tar_member_text(members, "args.json")
    if script is None or args_raw is None:
        return _resp_error("missing member: script.js and/or args.json")
    try:
        args = json.loads(args_raw)
    except json.JSONDecodeError as e:
        return _resp_error(f"bad args.json: {e}")
    if not isinstance(args, list):
        return _resp_error("bad args.json: expected a JSON array")

    arguments = [cdp.runtime.CallArgument(value=v) for v in args]
    want_value = True

    tab = await _tab()

    # `this` = globalThis. Sans `rel`, c'est le top frame. Avec `rel`, c'est le
    # globalThis de la frame portant l'élément matché (OOPIF ou in-process) :
    # callFunctionOn s'exécute dans le contexte qui possède l'objectId, donc
    # récupérer `window` via un node de la frame suffit à router l'éval là-bas.
    frame_sid = None
    if frame_sel is not None:
        frame = await find_frame(tab, frame_sel)
        if frame is None:
            return _resp_error("frame: no match")
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
        function_declaration=script,
        object_id=glob.object_id,
        arguments=arguments,
        return_by_value=True,
        await_promise=True,
    ), frame_sid)
    if exc is not None:
        desc = exc.exception.description if exc.exception else exc.text
        return _resp_error(desc)

    # `ok.txt` = l'output DÉJÀ en texte brut, comme un `jq -r` : une string sort
    # nue, le reste en JSON. Sans `-j`, returnByValue est off donc `value` est
    # None — on renvoie du vide, pas `null`.
    text = result.value if isinstance(result.value, str) else json.dumps(result.value)
    return _resp_ok(ok=text.encode("utf-8"))


@app.post("/snap")
async def snap():
    _touch()

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

    return _resp_ok(files)


@app.post("/net")
async def net():
    """Arme l'interception Fetch (ephemere) et attend la PROCHAINE requete dont
    l'url matche le glob `url` (wildcards `*`/`?`), jusqu'a `timeout` secondes.
    Relache la requete, desactive Fetch, et renvoie `entry.har` = une entree HAR
    {request, response} ou `request` est reconstruit a la main. Si rien ne matche
    avant T : `ok.txt` SANS `entry.har` (deadline ecoulee = pas une erreur).
    `url`/`timeout`/`stade` toujours fournis par le client (fichiers du tar de
    requete `url` / `timeout` / `stade`).

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

    members = read_req_tar(await quart.request.get_data())
    url_glob = tar_member_text(members, "url", strip=True)
    timeout_raw = tar_member_text(members, "timeout", strip=True) or "60"
    stade = tar_member_text(members, "stade", strip=True) or "response"
    if not url_glob:
        return _resp_error("no url provided")
    try:
        timeout = float(timeout_raw)
    except ValueError:
        return _resp_error(f"bad timeout: {timeout_raw!r}")
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
        # Deadline ecoulee : succes SANS `entry.har`, pas une erreur.
        return _resp_ok()

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

    return _resp_ok({"entry.har": json.dumps(har_entry).encode("utf-8")})


# ── Profil : cookies ──────────────────────────────────────────────────────────
# Toute la mécanique CDP (jar global, wipe par origine, round-trip CookieParam)
# vit dans cyborg_profile.py, layout du tar inclus. Ici : uniquement le passage
# tar ↔ mémoire. Le DOM storage est HORS PÉRIMÈTRE, voir cyborg_profile.py pour
# les raisons de fond (il exige un frame vivant, donc une navigation par origine).


@app.post("/profile-save")
async def profile_save():
    """Exporte le jar de cookies complet (sans URL, sans navigation).
    Tar `{cookies.json}`."""
    _touch()

    tab = await _tab()
    profile = await cyborg_profile.export_profile(tab)

    return _resp_ok(cyborg_profile.to_tar_files(profile))


@app.post("/profile-restore")
async def profile_restore():
    """Restaure un profil depuis le tar produit par /profile-save (WIPE, jamais
    un merge)."""
    _touch()

    members = read_req_tar(await quart.request.get_data())
    profile = cyborg_profile.from_tar_members(members)

    tab = await _tab()
    await cyborg_profile.restore_profile(tab, profile)

    return _resp_ok()


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
