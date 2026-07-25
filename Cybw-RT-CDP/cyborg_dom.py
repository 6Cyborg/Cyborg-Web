#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["nodriver"]
# ///
"""Cyborg DOM/search/frame layer — primitives partagees (data-plane).

Ce module porte TOUT ce qui ne depend NI de Quart (`app`) NI des handlers HTTP :
les dataclasses de locator/hit/frame, le routage CDP `_send`, la decouverte de
frames/shadow-roots, la recherche `_search_selector`, les helpers tar, et le global
`BROWSER`/`_tab()`. cyborg_server.py et cyborg_tap.py importent d'ici.

Sens d'import acyclique : cyborg_visibility (feuille) <- cyborg_dom <-
cyborg_tap <- cyborg_server. `import _fix_nodriver` DOIT preceder `import nodriver` pour que ce
module soit sur d'etre importe en premier (il installe le meta_path finder).

Propriete du global BROWSER : ce module est l'UNIQUE proprietaire de `BROWSER`.
cyborg_server.main() doit faire `import cyborg_dom; cyborg_dom.BROWSER = <browser>`
(et NON un global server-local), pour que `_tab()` resolve la meme instance
depuis cyborg_server ET cyborg_tap.
"""

import _fix_nodriver   # noqa: F401 — MUST precede `import nodriver`. # type: ignore

import io
import json
import re
import sys
import tarfile
from dataclasses import dataclass, field
from typing import Any, Optional

import nodriver
from nodriver import cdp
from nodriver.core.connection import ProtocolException  # noqa: F401 — re-exporte

from cyborg_visibility import (  # noqa: F401 — err_is_* ré-exportés pour cyborg_tap
    Visibility, check_visibility, err_is_no_layout_object, err_is_node_notfound)


# ── Global browser + tab + touch ──────────────────────────────────────────────
#
# BROWSER est assigne par cyborg_server.main() via `cyborg_dom.BROWSER = ...`.
# Tout le reste (handlers serveur, reliable_tap) passe par `_tab()`.
BROWSER: nodriver.Browser = None  # set by cyborg_server.main() as cyborg_dom.BROWSER


async def _tab():
    """First page target. Raises if Chrome has no page (caught by callers)."""
    await BROWSER.update_targets()
    tabs = BROWSER.tabs
    if not tabs:
        raise RuntimeError("no page target present")
    return tabs[0]


async def _send(tab, cmd, session_id=None):
    """Send a CDP command, optionally routed to a sub-session."""
    if session_id is None:
        return await tab.send(cmd)
    return await tab.send(cmd, sessionId=session_id)


# err_is_node_notfound / err_is_no_layout_object vivent dans cyborg_visibility
# (importés ci-dessus, ré-exportés ici pour cyborg_tap).


# ── Sélecteur JSON → CssSelector ──────────────────────────────────────────────

@dataclass
class CssSelector:
    """Sélecteur compilé depuis les paramètres CLI (le `.json` de requête).
    `iframe_filters` : OR d'entrées, chaque entrée = AND de prédicats
    `(op, valeur)` sur l'URL de frame (cf. `_parse_frame_selector`).
    `nth` : index 0-based façon Playwright (aucun garde de taille).
    `mode` : attached | visible | hidden."""
    target: str
    iframe_filters: list[list[tuple[str, str]]] = field(default_factory=list)
    nth: Optional[int] = None
    exact_text: Optional[str] = None
    pierce: bool = False
    mode: str = "attached"


_FRAME_PRED_RE = re.compile(
    r'\[\s*url\s*(\*=|\^=|\$=|~=|=)\s*"((?:[^"\\]|\\.)*)"\s*\]')


def _split_top_commas(s: str) -> list[str]:
    """Découpe sur les virgules de profondeur 0 (hors `[...]` et hors
    guillemets) — la virgule d'une regex `~="a{2,4}"` reste protégée."""
    parts: list[str] = []
    buf: list[str] = []
    depth = 0
    in_q = esc = False
    for ch in s:
        if esc:
            buf.append(ch)
            esc = False
        elif ch == "\\":
            buf.append(ch)
            esc = True
        elif in_q:
            buf.append(ch)
            if ch == '"':
                in_q = False
        elif ch == '"':
            buf.append(ch)
            in_q = True
        elif ch == "[":
            depth += 1
            buf.append(ch)
        elif ch == "]":
            depth -= 1
            buf.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        parts.append("".join(buf))
    return parts


def _parse_frame_selector(raw: Optional[str]) -> list[list[tuple[str, str]]]:
    """Compile la mini-syntaxe `--frame` (élément `iframe` + attribut `url`
    uniquement, jamais envoyée à querySelector). Virgule = OR entre entrées ;
    `[url…]` accolés = AND intra-entrée. Opérateurs : `=` exact, `*=`
    sous-chaîne, `^=` préfixe, `$=` suffixe, `~=` regex (re.search)."""
    if not raw:
        return []
    filters: list[list[tuple[str, str]]] = []
    for entry in _split_top_commas(raw):
        preds = [(op, re.sub(r"\\(.)", r"\1", val))
                 for op, val in _FRAME_PRED_RE.findall(entry)]
        if preds:
            filters.append(preds)
    return filters


def _parse_locator_file(raw: bytes) -> Optional[CssSelector]:
    """Parse un sélecteur CLI (.json) en CssSelector. JSON invalide ou sans
    `element` → None (skip silencieux)."""
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(doc, dict) or not doc.get("element"):
        return None

    mode = doc.get("mode") or "attached"
    if mode not in ("attached", "visible", "hidden"):
        mode = "attached"

    nth = doc.get("nth")
    if nth is not None:
        nth = int(nth)

    return CssSelector(
        target=doc["element"],
        iframe_filters=_parse_frame_selector(doc.get("iframe")),
        nth=nth,
        exact_text=doc.get("text_eq"),
        pierce=bool(doc.get("pierce", False)),
        mode=mode,
    )


# ── tar (de)serialisation ─────────────────────────────────────────────────────

def download_req_tar(body: bytes) -> tarfile.TarFile:
    return tarfile.open(fileobj=io.BytesIO(body), mode="r:*")


def _normalize_tar_path(p: str) -> str:
    """`./foo/bar` ou `foo/bar` → `foo/bar`. Racine → ``."""
    if p.startswith("./"):
        p = p[2:]
    return p.strip("/")


def load_selector(req_tar: tarfile.TarFile, name: str) -> Optional[CssSelector]:
    """Charge le sélecteur `<name>.json` (à la racine du tar). Utilisé par /js
    pour la frame d'évaluation (`frame.json`)."""
    target = _normalize_tar_path(name) + ".json"
    for ent in req_tar.getmembers():
        if ent.isfile() and _normalize_tar_path(ent.name) == target:
            with req_tar.extractfile(ent) as f:
                return _parse_locator_file(f.read())
    return None


def load_selectors(req_tar: tarfile.TarFile,
                   dir: str = "/") -> dict[str, CssSelector]:
    """Chaque `<name>.json` directement sous `dir` → {name (sans .json):
    CssSelector}. Le CLI nomme les fichiers par index (0, 1, …), donc les clés
    sont uniques et ordonnables. Remplace load_targ/load_targs."""
    prefix = _normalize_tar_path(dir)
    prefix = prefix + "/" if prefix else ""
    out: dict[str, CssSelector] = {}
    for ent in req_tar.getmembers():
        if not ent.isfile():
            continue
        name = _normalize_tar_path(ent.name)
        if prefix and not name.startswith(prefix):
            continue
        rel = name[len(prefix):]
        if "/" in rel or not rel.endswith(".json"):
            continue
        with req_tar.extractfile(ent) as f:
            sel = _parse_locator_file(f.read())
        if sel is not None:
            out[rel[:-len(".json")]] = sel
    return out


def read_tar_dir(req_tar: tarfile.TarFile) -> dict[str, bytes]:
    """Inverse de `build_tar` : chaque fichier régulier du tar →
    `{chemin_normalisé: bytes}`. Le suffixe `_dir` rappelle qu'on ne garde que
    les `.isfile()` (dirs/symlinks/… ignorés, voulu)."""
    out: dict[str, bytes] = {}
    for ent in req_tar.getmembers():
        if ent.isfile():
            with req_tar.extractfile(ent) as f:
                out[_normalize_tar_path(ent.name)] = f.read()
    return out


def build_tar(files: dict) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for path, contents in files.items():
            info = tarfile.TarInfo(name=path)
            info.size = len(contents)
            tf.addfile(info, io.BytesIO(contents))
    return buf.getvalue()


# ── Frames + shadow walk (CDP-only) ───────────────────────────────────────────

@dataclass
class Frame:
    """Top frame ou OOPIF. `frame_sid`=None pour le top, sessionId multiplexé
    pour OOPIFs. `frame_offset_x/y` = position de l'iframe element en viewport top
    (0,0 pour le top). `frame_tid` = identifiant Chrome stable (per-browser),
    sert à nommer `<frame_tid>.html` dans le snap ; None pour le top."""
    frame_sid: Optional[Any]
    frame_doc: Any
    frame_url: str
    frame_is_top: bool
    frame_offset_x: float
    frame_offset_y: float
    frame_tid: Optional[str] = None
    # frame_needs_push : frames SAME-ORIGIN / IN-PROCESS uniquement (même
    # sessionId que le parent). Leurs nœuds ne sont pas poussés (nodeId=0) => à
    # matérialiser via pushNodesByBackendIdsToFrontend avant querySelectorAll.
    frame_needs_push: bool = False
    # backendNodeId de l'iframe HÔTE (dans le doc PARENT/top ; None pour le top).
    # Permet au filtre de visibilité (dans _search_locator_css, UN SEUL endroit)
    # de tester la visibilité de l'hôte — getComputedStyle est per-document et ne
    # remonte pas la chaîne de frames.
    frame_owner_bnid: Any = None


@dataclass
class Hit:
    """A matched element, contenu déjà extrait. `frame_sid` +
    `backend_node_id` valides ensemble. On ne garde que le backendNodeId
    (stable tant que le node existe) — jamais de nodeId, invalidé à chaque
    re-push de l'arbre DOM (p.ex. un `get_document`). `frame_offset_x/y` recopiés
    de la frame portant ce node, pour la translation des coords de click."""
    frame_sid: Optional[Any]
    backend_node_id: Any
    frame_offset_x: float
    frame_offset_y: float
    inner_text: str
    outer_html: str


async def list_frame_ids(tab) -> list[Optional[str]]:
    """
    Ids des frames présentes: `None` pour la page courante, `target_id`
    pour chaque iframe OOPIF.
    """
    ids: list[Optional[str]] = [None]
    for ti in (await tab.send(cdp.target.get_targets())):
        if getattr(ti, "type_", "") == "iframe":
            ids.append(str(ti.target_id))
    return ids


async def get_frame_by_id(tab, target_id: Optional[str]) -> Optional[Frame]:
    """
    Snapshot d'une frame. `None` => page courante, sinon l'iframe OOPIF
    portant ce `target_id`. Retourne `None` si l'iframe est invisible
    ou a disparu.
    """
    if target_id is None:
        doc = await tab.send(cdp.dom.get_document(depth=-1, pierce=True))
        url = getattr(doc, "document_url", None) or ""
        return Frame(None, doc, url, True, 0.0, 0.0)

    # `"Could not compute box model" -32000` indique une iframe invisible => skippé
    try:
        bnid, _ = await tab.send(cdp.dom.get_frame_owner(
            frame_id=cdp.page.FrameId(target_id)))
        box = await tab.send(cdp.dom.get_box_model(backend_node_id=bnid))
    except Exception as e:
        # Les iframes invisible produisent: "Could not compute box model" -32000
        print(f"[cyborg] skip iframe target {target_id} (no box): {e}",
              file=sys.stderr, flush=True)
        return None

    # Connexion à l'iframe.
    session = await tab.send(cdp.target.attach_to_target(
        target_id=cdp.target.TargetID(target_id), flatten=True))
    await _send(tab, cdp.dom.enable(), session)

    doc = await _send(tab, cdp.dom.get_document(depth=-1, pierce=True), session)
    url = getattr(doc, "document_url", None) or ""

    # frame_owner_bnid = l'owner (l'élément <iframe> dans le doc parent) ; le
    # filtre de visibilité (_search_locator_css) s'en sert pour tester l'hôte.
    return Frame(session, doc, url, False,
                 box.content[0], box.content[1], target_id,
                 frame_owner_bnid=bnid)


async def get_inprocess_frame(tab, frame_id: str, url: str) -> Optional[Frame]:
    """Résout une frame same-origin/in-process (découverte via getFrameTree) en
    `Frame`, SANS le `get_document(pierce)` complet de la page (le bottleneck) et
    SANS attach (même process => même sessionId que le parent, ici None=top).

    Scoped : `getFrameOwner(frameId)` -> nœud IFRAME ; `describeNode(pierce)` sur
    lui seul inline son `content_document` (sous-arbre de l'iframe, petit). Ces
    nœuds ne sont pas poussés (=> `needs_push`). Coords lues via la session top =
    root-relatives (modèle Playwright) => offset 0,0."""
    try:
        owner_bnid, _ = await tab.send(cdp.dom.get_frame_owner(
            frame_id=cdp.page.FrameId(frame_id)))
    except Exception as e:
        print(f"[cyborg] skip in-process frame {frame_id} (no owner): {e}",
              file=sys.stderr, flush=True)
        return None

    owner = await tab.send(cdp.dom.describe_node(
        backend_node_id=owner_bnid, depth=-1, pierce=True))
    cdoc = getattr(owner, "content_document", None)
    if cdoc is None:
        # pas encore chargée / about:blank pré-commit => reprise au retry
        return None

    return Frame(None, cdoc, url, False, 0.0, 0.0,
                 frame_tid=str(frame_id), frame_needs_push=True,
                 frame_owner_bnid=owner_bnid)


async def collect_frames_oopif(tab) -> list[Frame]:
    """top + OOPIF cross-origin (`getTargets`, chacun sa session propre)."""
    frames: list[Frame] = []
    for fid in (await list_frame_ids(tab)):
        f = await get_frame_by_id(tab, fid)
        if f is not None:
            frames.append(f)
    return frames


async def collect_frames_intra(tab) -> list[Frame]:
    """iframes in-process same-origin = enfants directs du top dans getFrameTree
    (il s'arrête aux frontières OOPIF). Résolues scoped, sans walk de la page.
    Pas de récursivité : une in-process imbriquée dans une autre n'est pas gérée
    (idem same-origin sous OOPIF) => WARN."""
    try:
        ft = await tab.send(cdp.page.get_frame_tree())
    except Exception as e:
        print(f"[cyborg] get_frame_tree failed: {e}", file=sys.stderr, flush=True)
        return []

    frames: list[Frame] = []
    for child in (ft.child_frames or []):
        fr = child.frame
        if child.child_frames:
            print(f"[cyborg] WARN in-process frame {fr.id_} a des sous-frames "
                  f"imbriquées non gérées", file=sys.stderr, flush=True)
        f = await get_inprocess_frame(tab, str(fr.id_), getattr(fr, "url", None) or "")
        if f is not None:
            frames.append(f)
    return frames


async def collect_frames(tab) -> list[Frame]:
    """Toutes les frames searchables, à plat : OOPIF + in-process (disjointes)."""
    return (await collect_frames_oopif(tab)) + (await collect_frames_intra(tab))


def walk_document_roots(doc, pierce: bool) -> list:
    """
    Liste les shadowroots open/closed et lui-même.
    Pour ensuite itéré sur toutes les racines où éxécuté `querySelector`.
    """

    # fast-path si ça perce pas les shadow-roots.
    # le slow-path prend 10 secondes pour un document de 2 Mo !
    if not pierce:
        return [doc]

    roots = [doc]
    stack = list(doc.children or [])
    while stack:
        n = stack.pop()
        if n.node_name == "IFRAME":
            continue
        for sr in (n.shadow_roots or []):
            roots.append(sr)
            stack.append(sr)
        if n.children:
            stack.extend(n.children)
    return roots


def _match_url_pred(op: str, val: str, url: str) -> bool:
    """Évalue un prédicat `[url<op>"val"]` du filtre `--frame` contre l'URL."""
    if op == "=":
        return url == val
    if op == "*=":
        return val in url
    if op == "^=":
        return url.startswith(val)
    if op == "$=":
        return url.endswith(val)
    if op == "~=":
        try:
            return re.search(val, url) is not None
        except re.error:
            return False
    return False


def guard_frame(frame: Frame, sel: CssSelector) -> bool:
    # Sans filtre => que la page courante
    if not sel.iframe_filters:
        return frame.frame_is_top

    # Avec filtre => que les `iframe`
    if frame.frame_is_top:
        return False
    return any(
        all(_match_url_pred(op, val, frame.frame_url) for op, val in entry)
        for entry in sel.iframe_filters
    )


async def _js_inner_text(tab, backend_node_id, session_id) -> str:
    """
    Obtient `innerText` de l'élément donné. En injectant du JS quelque part.
    """

    remote = await _send(tab, cdp.dom.resolve_node(
        backend_node_id=backend_node_id), session_id)

    result, exc = await _send(tab, cdp.runtime.call_function_on(
        function_declaration="function() { return this.innerText; }",
        object_id=remote.object_id,
        return_by_value=True,
    ), session_id)

    if exc is not None:
        raise RuntimeError(f"innerText callFunctionOn failed: {exc}")
    return result.value or ""


async def _search_locator_css(tab, sel: CssSelector, limit: int,
                              mode: str = "attached") -> list[Hit]:
    """
    Éxécute `CssSelector` sur les frames présentes.

    Ordre:
    1. `target` (querySelector)
    2. `nth` sur tout les éléments applati.
    3. `exact_text` exactement innerText (comparé après strip des deux côtés).

    Aucun nodeId ne survit à cette fonction : chaque hit retenu est
    immédiatement résolu en backendNodeId et son contenu (innerText,
    outerHTML) extrait sur place.
    """

    # 1. Éxécute `querySelectorAll` sur les frames assujetti.
    raw: list[tuple[Frame, Any]] = []
    for frame in (await collect_frames(tab)):
        if not guard_frame(frame, sel):
            print(f"filtered-out frame for search {sel.target} in {frame.frame_tid}")
            continue

        print(f"matched frame for search {sel.target} in {frame.frame_tid}")

        for root in walk_document_roots(frame.frame_doc, sel.pierce):
            # In-process : nodeId non poussé (=0) => on le matérialise. Top/OOPIF
            # (get_document) : nodeId déjà valide, utilisé tel quel.
            if frame.frame_needs_push:
                pushed = await _send(tab, cdp.dom.push_nodes_by_backend_ids_to_frontend(
                    backend_node_ids=[root.backend_node_id]), frame.frame_sid)
                if not pushed:
                    continue
                root_node_id = pushed[0]
            else:
                root_node_id = root.node_id

            # Racine remplacée (navigation/re-render) => nodeId mort. Skip.
            try:
                ids = await _send(tab, cdp.dom.query_selector_all(
                    node_id=root_node_id, selector=sel.target),
                    frame.frame_sid)
            except ProtocolException as e:
                if not err_is_node_notfound(e):
                    raise
                print(f"stale root for search {sel.target} in {frame.frame_tid}")
                continue
            for nid in (ids or []):
                raw.append((frame, nid))

    print(f"found {len(raw)} elements using {sel.target}")

    # 2. Applique `nth` (index 0-based, sémantique Playwright — aucun garde de
    # taille) pour ne garder qu'un élément du `querySelectorAll`.
    if sel.nth is not None:
        if 0 <= sel.nth < len(raw):
            candidates = [(sel.nth, raw[sel.nth])]
        else:
            return []
    else:
        candidates = list(enumerate(raw))

    # Extraction immédiate : nodeId → backendNodeId + innerText + outerHTML.
    out: list[Hit] = []
    host_vis: dict = {}  # visibilité de l'iframe hôte, mémoïsée par frame (mode!=attached)
    for idx, (frame, nid) in candidates:
        if len(out) >= limit:
            break

        # Node disparu entre le `querySelectorAll` et l'extraction => skip.
        try:
            node = await _send(tab, cdp.dom.describe_node(node_id=nid),
                               frame.frame_sid)
            bnid = node.backend_node_id
            inner_text = await _js_inner_text(tab, bnid, frame.frame_sid)
        except ProtocolException as e:
            if not err_is_node_notfound(e):
                raise
            print(f"stale node for search {sel.target} in {frame.frame_tid}")
            continue

        # 3. Applique `exact_text` qui cherche exactement innerText
        if (sel.exact_text is not None
                and inner_text.strip() != sel.exact_text.strip()):
            continue

        # 4. mode "visible"/"hidden" — filtre de visibilité en UN SEUL endroit :
        # l'élément dans SA frame ET l'iframe HÔTE (frame_owner_bnid, dans le
        # parent => session None) doivent être visibles. "attached" = aucun filtre.
        # La visibilité de l'hôte est mémoïsée par frame (host_vis).
        if mode != "attached":
            fkey = id(frame)
            if fkey not in host_vis:
                if frame.frame_owner_bnid is None:
                    host_vis[fkey] = Visibility.VISIBLE  # top : pas d'hôte
                else:
                    host_vis[fkey] = await check_visibility(
                        tab, None, frame.frame_tid, frame.frame_owner_bnid)
            if host_vis[fkey] is not Visibility.VISIBLE:
                vis = host_vis[fkey]  # hôte caché/détaché => élément idem
            else:
                vis = await check_visibility(
                    tab, frame.frame_sid, frame.frame_tid, bnid)
            if mode == "visible" and vis is not Visibility.VISIBLE:
                continue
            if mode == "hidden" and vis is Visibility.VISIBLE:
                continue

        outer_html = await _send(tab, cdp.dom.get_outer_html(
            backend_node_id=bnid), frame.frame_sid)

        out.append(Hit(frame.frame_sid, bnid,
                       frame.frame_offset_x, frame.frame_offset_y,
                       inner_text, outer_html))

    return out


async def _search_selector(tab, sel: CssSelector, limit: int,
                           mode: str = "attached") -> list[Hit]:
    """Recherche un unique CssSelector (plus de fallback multi-locator)."""
    return await _search_locator_css(tab, sel, limit, mode)


async def find_frame(tab, sel: CssSelector) -> Optional[Frame]:
    """Première frame non-top satisfaisant le filtre `--frame` de `sel`
    (utilisé par /js pour choisir la frame d'évaluation)."""
    for frame in (await collect_frames(tab)):
        if not frame.frame_is_top and guard_frame(frame, sel):
            return frame
    return None
