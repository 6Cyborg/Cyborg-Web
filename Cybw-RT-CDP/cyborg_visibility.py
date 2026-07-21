#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["nodriver"]
# ///
"""Cyborg visibility layer — décision visible / hidden / detached d'un élément,
en COMMANDES CDP UNIQUEMENT (aucun eval JS).

Pourquoi pas de JS : un antibot/malware peut hooker `getComputedStyle`,
`getBoundingClientRect`, `Element.checkVisibility`… dans la page. Les commandes
CDP (`CSS.getComputedStyleForNode`, `DOM.getBoxModel`) s'exécutent dans le
processus navigateur, hors de portée du JS de page — donc non falsifiables.

Réplique la sémantique Playwright `computeBox` / `isElementVisible`
(packages/injected/src/domUtils.ts) :
  - `visibility == 'visible'` (exclut hidden ET collapse ; HÉRITE => ancêtres),
  - bounding box non-vide (getBoundingClientRect ≡ AABB du quad `border`),
  - display:none (self OU ancêtre), content-visibility, <details> fermé => pas de
    layout object => caché,
  - opacity:0 et hors-écran restent VISIBLES.

Divergence unique et documentée : display:contents (voir check_visibility).

Feuille du graphe d'import : ne dépend d'AUCUN module projet (surtout pas
cyborg_dom). cyborg_dom / cyborg_tap importent d'ici (et ré-exportent les
classifieurs d'erreur).
"""

import enum

from nodriver import cdp
from nodriver.core.connection import ProtocolException


class Visibility(enum.Enum):
    """État de visibilité (les deux axes Playwright condensés en un enum).
    Dérivations : visible = VISIBLE ; hidden = {HIDDEN, DETACHED} ;
    attached = {VISIBLE, HIDDEN} ; detached = DETACHED."""
    VISIBLE = "visible"
    HIDDEN = "hidden"
    DETACHED = "detached"


# Sessions où `CSS.enable` a déjà été émis (CSS.getComputedStyleForNode l'exige).
_css_enabled_sessions: set = set()


async def _send(tab, cmd, session_id=None):
    """Route une commande CDP (session None = top)."""
    if session_id is None:
        return await tab.send(cmd)
    return await tab.send(cmd, sessionId=session_id)


def err_is_node_notfound(e) -> bool:
    """Node introuvable / point sans node : « could not find node »
    (nodeId/backendNodeId périmé, arbre re-pushé) ou « no node found at given
    location ». TRANSITOIRE (stale) ou détaché — jamais une vraie erreur."""
    m = str(e).lower()
    return ("could not find node" in m
            or "no node found at given location" in m)


def err_is_no_layout_object(e) -> bool:
    """Nœud ATTACHÉ mais NON RENDU (aucun layout object) : display:none sur
    l'élément OU un ancêtre, content-visibility, <details> fermé. Messages
    « does not have a layout object » (getContentQuads / scrollIntoView) ou
    « could not compute box model » (getBoxModel). DÉTERMINISTE (caché) — distinct
    de err_is_node_notfound (transitoire) : inutile de retenter."""
    m = str(e).lower()
    return ("does not have a layout object" in m
            or "could not compute box model" in m)


def _aabb_wh(quad):
    """(width, height) de l'AABB d'un quad CDP [x0,y0,x1,y1,x2,y2,x3,y3] —
    équivaut à getBoundingClientRect (border-box, post-transform)."""
    xs = quad[0::2]
    ys = quad[1::2]
    return (max(xs) - min(xs), max(ys) - min(ys))


async def check_visibility(tab, frame_sid, frame_tid, backend_node_id) -> Visibility:
    """Visibilité d'un élément par COMMANDES CDP, façon Playwright `computeBox`.

    `frame_sid` = session de la frame de l'élément (None = top) ; `frame_tid` =
    target id de la frame (logs). `backend_node_id` est stable => poussé en
    interne pour obtenir le nodeId requis par CSS.getComputedStyleForNode.

    Retourne VISIBLE / HIDDEN / DETACHED (cf. Visibility)."""
    # nodeId : backend_node_id est stable, mais CSS a besoin d'un nodeId.
    try:
        pushed = await _send(tab, cdp.dom.push_nodes_by_backend_ids_to_frontend(
            backend_node_ids=[backend_node_id]), frame_sid)
    except ProtocolException as e:
        if err_is_node_notfound(e):
            return Visibility.DETACHED
        raise
    if not pushed:
        return Visibility.DETACHED
    node_id = pushed[0]

    # Style calculé D'ABORD (comme computeBox : style avant géométrie).
    if frame_sid not in _css_enabled_sessions:
        await _send(tab, cdp.css.enable(), frame_sid)
        _css_enabled_sessions.add(frame_sid)
    try:
        props, _extra = await _send(
            tab, cdp.css.get_computed_style_for_node(node_id), frame_sid)
    except ProtocolException as e:
        if err_is_node_notfound(e):
            return Visibility.DETACHED
        raise
    style = {p.name: p.value for p in props}

    # display:contents : l'élément n'a pas de box propre. Playwright le considère
    # VISIBLE ssi un enfant (élément OU nœud-texte) est visible (récursion,
    # domUtils.ts:117-126). On NE réplique PAS cette récursion — marginal, et un
    # nœud-texte n'a pas d'équivalent CDP propre (Playwright mesure via un Range).
    # SEULE divergence assumée avec Playwright : on classe display:contents HIDDEN.
    if style.get("display") == "contents":
        return Visibility.HIDDEN

    # `visibility` HÉRITE => couvre aussi un ancêtre visibility:hidden ;
    # `== 'visible'` exclut hidden ET collapse.
    if style.get("visibility") != "visible":
        return Visibility.HIDDEN

    # content-visibility:hidden SUR l'élément : il garde un box mais est caché.
    # (Un ANCÊTRE content-visibility:hidden retire le layout => capté plus bas.)
    if style.get("content-visibility") == "hidden":
        return Visibility.HIDDEN

    # Géométrie : box non-vide. « no layout object » => display:none (self OU
    # ancêtre), content-visibility ancêtre, <details> fermé => HIDDEN. L'AABB du
    # quad `border` équivaut à getBoundingClientRect (border-box, post-transform).
    try:
        box = await _send(tab, cdp.dom.get_box_model(
            backend_node_id=backend_node_id), frame_sid)
    except ProtocolException as e:
        if err_is_no_layout_object(e):
            return Visibility.HIDDEN
        if err_is_node_notfound(e):
            return Visibility.DETACHED
        raise
    w, h = _aabb_wh(box.border)
    return Visibility.VISIBLE if (w > 0 and h > 0) else Visibility.HIDDEN
