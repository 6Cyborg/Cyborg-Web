#!/usr/bin/env fish
# clique le 1er élément matché par <targ_dir>/*.toml. POST /tap.
# Réponse TOUJOURS en tar : dossier tries/ (une tentative par fichier) + error.txt
# si échec. error.txt présent => échec ; la trace complète reste sous $CYB_CALL.
set -lx log_registry CybTap
__cyb_op_init; or exit 1

argparse -N1 -X1 -- $argv; or exit (llerr -e2 "bad usage")

cp -r $argv[1] $_CYB_REQ/

_cyb_op tap 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_ERR)) — trace: $(llcode $CYB_CALL)")

# Réponse en tar : error.txt présent => l'opération a échoué (le clic n'a pas abouti).
if test -e $_CYB_RESP/error.txt
    exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_RESP/error.txt)) — trace: $(llcode $CYB_CALL)")
end

set -q CYBTRACE; and llinf "tapped $(llcode $argv[1])"
exit 0
