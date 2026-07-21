#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["gologin"]
# ///
"""Ouvre un profil GoLogin en HEADED via le SDK officiel (pygologin).

But : reproduire EXACTEMENT le flux de licence d'Orbita (le navigateur calcule
le même machineId qu'avec nos scripts) pour trancher : si la fenêtre s'ouvre,
ton machineId n'est pas blacklisté et le 500 vient de notre code ; si ça
échoue pareil (500 / license aborted), c'est côté compte/machine.

Usage :
    uv run open-gologin.py <access_token> [profile_id]
    ./open-gologin.py <access_token> [profile_id]

Sans profile_id, prend le plus récent dat-fp/*/*.json (nom de fichier = id).
Le SDK télécharge son propre Orbita dans ~/.gologin/browser (indépendant de
dat-browser/). Ctrl-C ou 300 s pour fermer.
"""
import glob
import os
import sys
import time

# --- Fedora : Orbita (build Debian) réclame libcurl-gnutls.so.4, absent ici.
# On expose libcurl.so.4 sous ce nom et on l'ajoute au LD_LIBRARY_PATH hérité
# par le navigateur que le SDK va lancer.
HERE = os.path.dirname(os.path.abspath(__file__))
USRLIB = os.path.join(HERE, "usrlib")
os.makedirs(USRLIB, exist_ok=True)
_link = os.path.join(USRLIB, "libcurl-gnutls.so.4")
if not os.path.exists(_link):
    for _cand in (
        "/lib64/libcurl.so.4",
        "/usr/lib64/libcurl.so.4",
        "/usr/lib/x86_64-linux-gnu/libcurl.so.4",
    ):
        if os.path.exists(_cand):
            os.symlink(_cand, _link)
            break
os.environ["LD_LIBRARY_PATH"] = USRLIB + ":" + os.environ.get("LD_LIBRARY_PATH", "")

from gologin import GoLogin  # noqa: E402  (après le fix LD_LIBRARY_PATH)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: open-gologin.py <access_token> [profile_id]", file=sys.stderr)
        return 2
    token = sys.argv[1]

    if len(sys.argv) >= 3:
        profile_id = sys.argv[2]
    else:
        cands = sorted(glob.glob(os.path.join(HERE, "dat-fp", "*", "*.json")))
        if not cands:
            print("aucun profile_id fourni et dat-fp/ vide", file=sys.stderr)
            return 2
        profile_id = os.path.splitext(os.path.basename(cands[-1]))[0]
        print(f"[i] profile_id = {profile_id} (auto depuis dat-fp)", file=sys.stderr)

    gl = GoLogin({"token": token, "profile_id": profile_id})

    print("[i] gl.start() — download Orbita si besoin + licence + lancement headed…",
          file=sys.stderr, flush=True)
    try:
        debugger = gl.start()
    except Exception as e:
        print(f"[!] start() a échoué : {e}", file=sys.stderr)
        return 1

    print(f"[OK] navigateur lancé — debugger = {debugger}", file=sys.stderr, flush=True)
    print("[i] Ctrl-C ou 300 s pour fermer.", file=sys.stderr, flush=True)
    try:
        time.sleep(300)
    except KeyboardInterrupt:
        pass
    finally:
        gl.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
