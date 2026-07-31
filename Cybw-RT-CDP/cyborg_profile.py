#!/usr/bin/env -S uv run
"""Cyborg profile layer — export/restore des cookies (data-plane).

Ce module porte TOUTE la logique CDP de `/profile-save` et `/profile-restore` et
la (dé)sérialisation du tar. cyborg_server.py ne fait que parser la requête HTTP
en mémoire (`read_req_tar`) et emballer la réponse (`_resp_ok`).

Le profil = LE JAR DE COOKIES, rien d'autre. `Storage.getCookies`/`setCookies`
opèrent sur un jar GLOBAL au navigateur indexé par domaine/path : aucune
navigation, aucun document vivant requis, et l'aller-retour préserve ce qu'aucun
JS ne pourrait écrire (HttpOnly, SameSite, partition key CHIPS).

POURQUOI PAS DE localStorage / sessionStorage — supprimé délibérément, ne pas
réintroduire sans lire ceci. Contrairement aux cookies, le DOM storage est
attaché à une ORIGINE et n'existe qu'à travers un document, ce qui le rend
incompatible avec un data-plane sans navigation :
  * `DOMStorage.getDOMStorageItems` exige un FRAME VIVANT pour l'origine visée,
    sinon « Frame not found for the given storage id ». L'export ne pouvait donc
    couvrir que la page courante et ses iframes, jamais les origines du jar.
  * `DOMStorage.setDOMStorageItem` a la même contrainte, donc restaurer imposait
    `Page.addScriptToEvaluateOnNewDocument` + un `navigate` vers CHAQUE origine —
    une page chargée par origine, séquentiellement, dans la réponse HTTP.
  * Le raccourci « iframe cachée pour créer un frame vivant » ne marche pas : sous
    partitionnement du storage tiers, une iframe cross-site n'est même pas
    adressable par `security_origin` (mesuré sur Chrome 150).
  * Un script externe ou un ServiceWorker n'ouvrent aucune porte : un
    `<script src>` cross-origin s'exécute dans l'origine du DOCUMENT hôte (jamais
    la sienne), et `localStorage` est `undefined` dans tout scope worker.

Sens d'import acyclique : cyborg_profile est une FEUILLE (ne dépend que de
`nodriver`/`cdp`, jamais de cyborg_dom ni de Quart). Elle reçoit le `tab` en
paramètre. cyborg_server.py importe d'ici.

Surface publique :
  * export_profile(tab) -> Profile        — lecture CDP pure.
  * restore_profile(tab, profile) -> None — WIPE puis écriture CDP pure.
  * to_tar_files(profile) -> dict         — Profile → membres de tar.
  * from_tar_members(members) -> Profile  — membres de tar → Profile.
"""

import _fix_nodriver   # noqa: F401 — MUST precede `import nodriver`. # type: ignore

import json
import sys
from dataclasses import dataclass, field

import nodriver  # noqa: F401 — installe/active le package cdp.
from nodriver import cdp


# ── Contrat de tar ────────────────────────────────────────────────────────────
# UNE seule définition du layout, partagée par les deux sens, pour qu'un préfixe
# écrit et relu ne puissent pas diverger. Les clients
# `cgi/profile-{save,restore}.fish` copient littéralement cette entrée.
PART_COOKIES = "cookies.json"


@dataclass
class Profile:
    """État de navigation transportable. `cookies` porte des `network.Cookie`
    (jamais du JSON brut) des deux côtés, pour que le round-trip soit
    symétrique."""
    cookies: list = field(default_factory=list)


def to_tar_files(profile: Profile) -> dict[str, bytes]:
    return {PART_COOKIES: json.dumps(
        [c.to_json() for c in profile.cookies]).encode("utf-8")}


def from_tar_members(members: dict[str, bytes]) -> Profile:
    cookies = ([cdp.network.Cookie.from_json(c)
                for c in json.loads(members[PART_COOKIES].decode("utf-8"))]
               if PART_COOKIES in members else [])
    return Profile(cookies=cookies)


# ── Helpers CDP ───────────────────────────────────────────────────────────────

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


async def _set_cookies(tab, cookies) -> None:
    """Pose les cookies, sans navigation. Chrome rejette TOUT le batch (« Invalid
    cookie fields ») dès qu'un seul cookie est malformé → on retombe en pose
    1-à-1 pour isoler et logger le(s) fautif(s), poser le reste, et ne pas faire
    échouer le restore entier."""
    if not cookies:
        return

    params = [_cookie_to_param(c) for c in cookies]
    try:
        await tab.send(cdp.storage.set_cookies(params))
        return
    except Exception as batch_err:
        print(f"[cyborg] profile-restore: batch set_cookies KO ({batch_err!r}) → pose 1-à-1",
              file=sys.stderr, flush=True)

    ok = skipped = 0
    for p in params:
        try:
            await tab.send(cdp.storage.set_cookies([p]))
            ok += 1
        except Exception as e:
            skipped += 1
            print(f"[cyborg] profile-restore: cookie REJETÉ ({e!r}) :: {json.dumps(p.to_json())}",
                  file=sys.stderr, flush=True)
    print(f"[cyborg] profile-restore: {ok} posés, {skipped} ignorés",
          file=sys.stderr, flush=True)


# ── Surface publique ──────────────────────────────────────────────────────────

async def export_profile(tab) -> Profile:
    """Exporte le jar de cookies COMPLET. Lecture pure, aucune navigation."""
    cookies = await tab.send(cdp.storage.get_cookies()) or []
    return Profile(cookies=cookies)


async def restore_profile(tab, profile: Profile) -> None:
    """Restaure un profil : WIPE puis pose des cookies (jamais un merge).

    ASYMÉTRIE ASSUMÉE du wipe : `storage_types="all"` efface par origine bien plus
    que les cookies (localStorage, IndexedDB, service workers) alors qu'on ne
    repose QUE les cookies. C'est le comportement d'origine, conservé tel quel :
    un profil restauré part d'un état propre plutôt que de mélanger les cookies
    entrants avec le storage résiduel d'une session précédente. Le prix est qu'une
    app dont la session vit en localStorage sera déconnectée par un restore.
    Passer `storage_types="cookies"` inverserait ce compromis."""
    origins = {_cookie_origin(c) for c in profile.cookies}

    await tab.send(cdp.storage.clear_cookies())
    for origin in origins:
        try:
            await tab.send(cdp.storage.clear_data_for_origin(origin=origin,
                                                             storage_types="all"))
        except Exception:
            pass

    await _set_cookies(tab, profile.cookies)
