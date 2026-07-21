#!/usr/bin/env fish
# exporte tout le profil (cookies + localStorage/sessionStorage) vers
# <dest>.tar.xz. POST /export-profile.
set -lx log_registry CybExportProfile
__cyb_op_init; or exit 1

argparse -N1 -X1 -- $argv; or exit (llerr -e2 "usage: cybw export-profile <dest.tar.xz>")
set -l dest $argv[1]


_cyb_op export-profile 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_ERR))")

# $_CYB_RESP contient cookies.json + storage/<origin>.json → archive .tar.xz.
tar -cJf $dest -C $_CYB_RESP .
or exit (llerr -e1 "archive $(llcode $dest) échouée [$status]")

set -q CYBTRACE; and llinf "profil exporté vers $(llcode $dest)"
exit 0
