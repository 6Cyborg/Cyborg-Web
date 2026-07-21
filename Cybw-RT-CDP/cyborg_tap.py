#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["nodriver"]
# ///
"""Cyborg `/tap` — clic gauche FIABLE (toutes techniques Playwright A-F en dur).

TOUT EST TOUJOURS ACTIVE : aucun toggle, aucun flag, un seul chemin de code par
fonction. Chaque tentative re-resout le Hit a frais nouveaux (aucune coord
cachee) puis, dans l'ordre :
  A. scroll D'ABORD (alignement cycle par tentative pour defaire les sticky bars),
  B. attente de stabilite geometrique (deux getContentQuads egaux ~16ms) qui
     RETOURNE la vue stable,
  C. enabled-check (disabled / aria-disabled),
  D. point cliquable (logique pure sur la vue stable de B) = centroide du 1er
     quad VISIBLE clippe au layout viewport,
     en coords top-viewport absolues (frame_offset_x/frame_offset_y + centre local), arrondi,
  E1. hit-test pre-dispatch via DOM.getNodeForLocation (cible ou descendant ;
      pour OOPIF : session de la frame + coords FRAME-LOCALES),
  E3. confirmation post-dispatch TOUJOURS ON (ecouteur capture-phase one-shot,
      verifie isTrusted, puis retire).

Verdict E3, decide DANS la tentative, pendant que l'ecouteur est arme :
  - event click recu par l'element vise -> SUCCES ;
  - events envoyes et element SUPPRIME pendant l'ecoute -> SUCCES (le clic a
    atterri et a fait disparaitre sa cible : navigation, re-render,
    fermeture). Detecte par : readback impossible (contexte/node mort) OU
    readback ok mais isConnected=false (node detache encore reference) ;
  - events envoyes, rien recu, element toujours attache -> le clic est parti
    AILLEURS (overlay/interception) : WARN + retry complet (re-resolution).

Le dispatch souris se fait au TOP tab (sessionId=None) : le compositor route vers
l'OOPIF avec isTrusted:true. Boucle bornee par un deadline global avec backoff
[0,20,100,100,500]ms saturant a 500. Les VRAIES erreurs CDP ne sont jamais
avalees ; seules les conditions transitoires lèvent _Retry.

Sens d'import acyclique : cyborg_dom <- cyborg_tap <- cyborg_server.
"""

import _fix_nodriver   # noqa: F401 — MUST precede `import nodriver`. # type: ignore

import asyncio
import sys

import nodriver  # noqa: F401 — installe/active le package cdp.
from nodriver import cdp
from nodriver.core.connection import ProtocolException

from cyborg_dom import (  # noqa: F401 — Hit pour typing
    Hit, _search_targ, _send, err_is_node_notfound,
)


# ── Exceptions de controle de flux ────────────────────────────────────────────
# Elles pilotent UNIQUEMENT la mecanique interne de reliable_tap ; elles ne
# doivent JAMAIS masquer une vraie erreur CDP (ProtocolException &c. remontent
# telles quelles) et NE doivent PAS heriter de ProtocolException.
class _Retry(Exception):
    """Echec transitoire d'une tentative (geometrie instable, hit rate,
    confirmation E3 negative, point hors viewport, node stale, disabled, ...).
    Entierement consommee par la boucle de reliable_tap : ne fuit JAMAIS."""


class _TapTimeout(Exception):
    """Deadline global atteint : l'element a ete resolu au moins une fois mais
    le clic n'a jamais aboutir. Mappe en HTTP 409 par le handler."""


class _NoMatch(Exception):
    """Aucun element ne correspond au Targ (apres deadline). Mappe en 404."""


# ── Constantes du module ──────────────────────────────────────────────────────

# Stabilite geometrique : deux echantillons egaux a cette tolerance (px), avec
# ~un frame d'affichage entre chaque lecture.
_QUAD_EPS = 0.01
_FRAME_S = 0.016


def _is_stale(e: ProtocolException) -> bool:
    """Vrai si l'erreur CDP traduit un node disparu/contexte mort (transitoire).
    Toute AUTRE ProtocolException est une vraie erreur et ne doit pas etre avalee."""
    return err_is_node_notfound(e) or "context" in str(e).lower()


async def _content_quads(tab, h, where) -> list:
    """get_content_quads dans la session de la frame du hit, avec classification
    transitoire (appele par _wait_stable a chaque lecture) :
      - node disparu (ProtocolException 'could not find node') -> _Retry('stale'),
      - liste vide (invisible / display:none / aire nulle) -> _Retry('notvisible'),
      - autre ProtocolException -> relancee telle quelle (vraie erreur CDP).
    Chaque Quad est 8 floats [x0,y0,x1,y1,x2,y2,x3,y3] sens horaire (top-left).
    """
    try:
        quads = await _send(tab, cdp.dom.get_content_quads(
            backend_node_id=h.backend_node_id), h.frame_sid)
    except ProtocolException as e:
        if not err_is_node_notfound(e):
            raise
        raise _Retry(f"{where}/quads: node stale (could not find node)")
    if not quads:
        raise _Retry(f"{where}/quads: empty (invisible / display:none / 0-area)")
    return quads


async def search_element(tab, targ) -> Hit:
    """Trouve le 1er match de `targ` avec `_search_targ`."""
    hits = await _search_targ(tab, targ, 1, mode="visible")
    if not hits:
        raise _Retry("search_element: no element matches the targ yet")
    return hits[0]


async def _scroll_into_view(tab, h):
    """Fait defiler l'element dans la vue, dans la session de la frame."""
    try:
        await _send(tab, cdp.dom.scroll_into_view_if_needed(
            backend_node_id=h.backend_node_id), h.frame_sid)
    except ProtocolException as e:
        if not _is_stale(e):
            raise
        raise _Retry(f"scroll_into_view_if_needed failed: {e}")
    return


async def _wait_stable(tab, h, deadline) -> list:
    """Attend que TOUS les quads soient constants entre deux lectures espacees
    d'~un frame (tolerance _QUAD_EPS), puis retourne cette vue stable — c'est
    elle que _clickable_point interprete ensuite (statique, aucune re-mesure)."""
    loop = asyncio.get_running_loop()
    prev = None  # lecture precedente (liste de quads)
    while True:
        if deadline - loop.time() <= 0:
            raise _Retry("")  # vide => ne pollue pas la raison memorisee

        quads = await _content_quads(tab, h, "wait_stable")

        if prev is not None and len(prev) == len(quads) and all(
            abs(a - b) <= _QUAD_EPS
            for qp, qc in zip(prev, quads) for a, b in zip(qp, qc)
        ):
            return quads

        prev = quads
        await asyncio.sleep(_FRAME_S)


def _quad_clip_centroid(quad, off_x, off_y, w, hgt):
    """Translate un quad frame-local en coords top-viewport (+off), clippe ses 4
    sommets au layout viewport top [0,w]x[0,hgt], et renvoie (area, cx, cy) :
    aire du polygone clippe et son CENTROIDE pondere par l'aire (shoelace).

    Le centroide pondere (et NON la moyenne des sommets) est correct meme quand
    une sticky bar coupe le quad en un polygone non-parallelogramme. cx/cy sont
    deja en coords top-viewport absolues. Si area == 0, cx/cy non significatifs.
    """
    pts = [
        (min(max(off_x + quad[i], 0.0), w),
         min(max(off_y + quad[i + 1], 0.0), hgt))
        for i in range(0, 8, 2)
    ]
    cross_sum = 0.0
    cxa = 0.0
    cya = 0.0
    for i in range(4):
        x_i, y_i = pts[i]
        x_j, y_j = pts[(i + 1) % 4]
        cross = x_i * y_j - x_j * y_i
        cross_sum += cross
        cxa += (x_i + x_j) * cross
        cya += (y_i + y_j) * cross
    area = abs(cross_sum) / 2.0
    if area == 0.0:
        return (0.0, 0.0, 0.0)
    cx = cxa / (3.0 * cross_sum)
    cy = cya / (3.0 * cross_sum)
    return (area, cx, cy)


async def _layout_viewport(tab):
    """Dimensions CSS px (w, h) du layout viewport TOP : index 3 du 6-tuple de
    get_layout_metrics (0..2 = deprecie device-px)."""
    metrics = await _send(tab, cdp.page.get_layout_metrics())
    vp = metrics[3]
    return float(vp.client_width), float(vp.client_height)


def _clickable_point(h, quads, w, hgt):
    """Choisit le point de clic : logique metier PURE (synchrone, aucun I/O)
    sur la vue stable retournee par _wait_stable.

    Traduit chaque sommet en top-viewport via h.frame_offset_x/h.frame_offset_y AVANT le
    clip au layout viewport top [0,w]x[0,hgt]. Le PREMIER quad d'aire clippee
    > 0.99 gagne ; centroide pondere par l'aire, arrondi a 2 decimales.
    Resultat deja absolu (on ne re-ajoute pas l'offset).

    Aucun quad visible dans le viewport -> _Retry('notinviewport').
    """
    best_area = 0.0
    for quad in quads:
        area, cx, cy = _quad_clip_centroid(quad, h.frame_offset_x, h.frame_offset_y, w, hgt)
        best_area = max(best_area, area)
        if area > 0.99:
            return (round(cx, 2), round(cy, 2))

    raise _Retry(
        f"clickable_point: no quad intersects the layout viewport "
        f"(viewport w={w:.0f} h={hgt:.0f}, {len(quads)} quad(s), "
        f"best clipped area={best_area:.2f}, frame offset="
        f"({h.frame_offset_x:.0f},{h.frame_offset_y:.0f}))")


async def _dispatch_click(tab, h, x, y):
    """Dispatch un clic souris au TOP-FRAME aux coords absolues (x, y) — deja
    traduites — puis rend le verdict E3 (TOUJOURS ON).

    1. resolve backend_node_id -> objet JS (this) dans la session de la frame ;
    2. ecouteur capture-phase one-shot ELEMENT-LOCAL sur `self` (pas de
       dependance a composedPath, robuste shadow root ferme) ;
    3. dispatch souris au TOP tab (sessionId=None ; compositor -> isTrusted) ;
    4. relecture {clicked, connected} ET retrait de l'ecouteur dans le MEME
       appel.

    Verdict :
      - clicked -> SUCCES : return ;
      - readback impossible (node/contexte mort) OU !connected -> SUCCES :
        events envoyes et element supprime PENDANT l'ecoute (navigation /
        re-render / fermeture) : le clic a atterri et a detache sa cible ;
      - !clicked mais connected -> le clic est parti AILLEURS (overlay,
        interception) : WARN + _Retry (l'appelant re-resout).
    Node stale AVANT le dispatch -> _Retry ordinaire (rien n'a ete envoye).
    """
    # backend_node_id -> objet JS (this) dans la session de la frame du hit.
    try:
        remote = await _send(tab, cdp.dom.resolve_node(
            backend_node_id=h.backend_node_id), h.frame_sid)
    except ProtocolException as e:
        if _is_stale(e):
            raise _Retry("dispatch/arm: node stale before click")
        raise
    object_id = remote.object_id

    # Ecouteur element-local one-shot : un click isTrusted qui atteint `self`
    # (cible ou bubbling depuis un descendant) leve le drapeau.
    arm = (
        "function() {"
        "  var self = this;"
        "  self.__cyb_clicked = false;"
        "  self.__cyb_handler = function(e) {"
        "    if (e.isTrusted) { self.__cyb_clicked = true; }"
        "  };"
        "  self.addEventListener('click', self.__cyb_handler,"
        "    {capture: true, once: true});"
        "}"
    )
    try:
        _, exc = await _send(tab, cdp.runtime.call_function_on(
            function_declaration=arm,
            object_id=object_id,
        ), h.frame_sid)
    except ProtocolException as e:
        if _is_stale(e):
            raise _Retry("dispatch/arm: node stale while installing listener")
        raise
    if exc is not None:
        raise RuntimeError(f"E3 arm callFunctionOn failed: {exc}")

    # Dispatch souris au TOP tab (compositor route vers l'OOPIF, isTrusted:true).
    await tab.send(cdp.input_.dispatch_mouse_event(
        type_="mouseMoved", x=x, y=y))
    await tab.send(cdp.input_.dispatch_mouse_event(
        type_="mousePressed", x=x, y=y,
        button=cdp.input_.MouseButton.LEFT, click_count=1))
    await tab.send(cdp.input_.dispatch_mouse_event(
        type_="mouseReleased", x=x, y=y,
        button=cdp.input_.MouseButton.LEFT, click_count=1))

    # Relecture {clicked, connected} + nettoyage en un seul appel : connected
    # est lu pendant la fenetre d'ecoute (avant tout re-resolve), c'est lui
    # qui distingue "supprime pendant l'ecoute" de "clic parti ailleurs".
    readback = (
        "function() {"
        "  if (this.__cyb_handler) {"
        "    this.removeEventListener('click', this.__cyb_handler,"
        "      {capture: true});"
        "  }"
        "  var clicked = !!this.__cyb_clicked;"
        "  delete this.__cyb_handler;"
        "  delete this.__cyb_clicked;"
        "  return {clicked: clicked, connected: this.isConnected};"
        "}"
    )
    try:
        result, exc = await _send(tab, cdp.runtime.call_function_on(
            function_declaration=readback,
            object_id=object_id,
            return_by_value=True,
        ), h.frame_sid)
    except ProtocolException as e:
        if _is_stale(e):
            # Le nœud a disparu APRES un dispatch souris reussi : le clic a atterri
            # et a detache sa cible (navigation / soumission / fermeture). C'est un
            # SUCCES, pas un transitoire — sinon on re-resout un element disparu et
            # on timeout a tort (bug login-submit 42 : clic OK a la tentative 5,
            # puis ~25s de _NoMatch jusqu'au deadline). Confirme par tries/.
            print("[cyborg/tap] click landed (node detached after dispatch — "
                  "navigation/removal likely); treating as success",
                  file=sys.stderr, flush=True)
            return
        raise
    if exc is not None:
        raise RuntimeError(f"E3 readback callFunctionOn failed: {exc}")

    verdict = result.value or {}
    if verdict.get("clicked"):
        return

    if not verdict.get("connected", True):
        # Events envoyes + element DETACHE pendant l'ecoute (re-render /
        # retrait du DOM, objet JS encore reference) : le clic a atterri et
        # a fait disparaitre sa cible -> SUCCES.
        print("[cyborg/tap] click landed (target detached during the listen "
              "window); treating as success", file=sys.stderr, flush=True)
        return

    # Events envoyes, rien recu, element toujours attache : le clic est parti
    # AILLEURS (overlay au-dessus du point, interception en capture, ...).
    print(f"[cyborg/tap] WARN: click sent at ({x},{y}) landed ELSEWHERE "
          f"(target still attached, no event received)",
          file=sys.stderr, flush=True)
    raise _Retry("dispatch: click landed elsewhere (events sent, target still "
                 "attached, no event received)")


async def reliable_tap(tab, targ, *, timeout_s: float = 30.0, tries: list | None = None) -> None:
    """Clic gauche fiable (toutes techniques Playwright A-F activees en dur).

    Boucle bornee par un deadline global (loop.time()). Chaque tentative
    re-resout le Hit a neuf (aucune coord cachee), puis scroll D'ABORD ->
    stabilite -> enabled -> point cliquable -> E1 hit-test -> dispatch + E3.

    Conditions transitoires -> _Retry (rattrapee, backoff, re-tentative).
    Verdict du clic rendu par _dispatch_click, pendant la fenetre d'ecoute
    (voir son docstring) : recu -> succes ; cible supprimee pendant l'ecoute
    -> succes ; parti ailleurs -> WARN + retry. Les VRAIES erreurs CDP
    remontent (non avalees).
    A l'expiration :
      - jamais resolu un Hit -> _NoMatch (404),
      - au moins un Hit resolu mais clic jamais aboutir -> _TapTimeout (409).
    """
    if tries is None:   # defaut mutable sinon : partage entre TOUS les appels.
        tries = []
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout_s
    attempt = 0

    ever_found = False
    msg = "deadline atteinte avant la premiere tentative"

    while True:
        attempt += 1

        if deadline - loop.time() <= 0:
            if ever_found:
                raise _TapTimeout(msg)
            else:
                raise _NoMatch(msg)

        try:
            # Cherche l'élément.
            h = await search_element(tab, targ)
            ever_found = True

            # Affiche l'élément à l'écran (scroll).
            await _scroll_into_view(tab, h)

            # Attend qu'il soit immobile et capture la vue stable.
            quads = await _wait_stable(tab, h, deadline)

            # Choisi l'endroit où tapé (logique métier pure sur la vue stable).
            w, hgt = await _layout_viewport(tab)
            x, y = _clickable_point(h, quads, w, hgt)

            # Dispatch souris (top tab, isTrusted) + verdict E3.
            await _dispatch_click(tab, h, x, y)

            elapsed = timeout_s - (deadline - loop.time())
            tries.append({"attempt": attempt, "ok": True,
                            "x": x, "y": y, "elapsed_s": round(elapsed, 3)})
            print(f"[cyborg/tap] OK attempt={attempt} at ({x},{y}) "
                  f"after {elapsed:.2f}s",
                  file=sys.stderr, flush=True)
            return

        except _Retry as e:
            # Transitoire : memorise la raison, temporise (borne par le temps
            # restant) puis re-tente. attempt n'augmente QUE sur _Retry.
            msg = str(e) or msg
            elapsed = timeout_s - (deadline - loop.time())
            tries.append({"attempt": attempt, "ok": False,
                            "reason": msg, "elapsed_s": round(elapsed, 3)})
            print(f"[cyborg/tap] attempt={attempt} retry "
                  f"@{elapsed:.2f}s: {msg}",
                  file=sys.stderr, flush=True)
            await asyncio.sleep(0.2)

        # Les exceptions non-_Retry (vraies erreurs CDP) ne sont PAS attrapees
        # ici : elles remontent telles quelles.
