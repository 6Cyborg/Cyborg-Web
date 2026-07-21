#!/usr/bin/env fish
# restaure un profil depuis <src>.tar.xz (WIPE puis set : cookies + localStorage
# seedé avant le JS de page → pas de redirect). POST /set-profile.
set -lx log_registry CybSetProfile
__cyb_op_init; or exit 1

argparse -N1 -X1 -- $argv; or exit (llerr -e2 "usage: cybw set-profile <src.tar.xz>")
set -l src $argv[1]
test -f $src; or exit (llerr -e2 "fichier introuvable: $(llcode $src)")

# Le contenu du profil (cookies.json + storage/) devient le tar de requête.
tar -xf $src -C $_CYB_REQ
or exit (llerr -e1 "extraction $(llcode $src) échouée [$status]")

_cyb_op set-profile 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_ERR))")

set -q CYBTRACE; and llinf "profil restauré depuis $(llcode $src)"
exit 0
