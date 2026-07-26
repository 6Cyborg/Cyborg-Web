#!/usr/bin/env fish
# clique le 1er élément matché par le sélecteur. POST /tap.
#   cybw tap -e '<css>' [--pierce] [--frame '<iframe>'] [--nth N] [--text-eq T]
# Réponse TOUJOURS en tar : tries/ (une tentative par fichier) + error.txt si échec.
set -lx log_registry CybTap

source ./lib/transport.fish
source ./lib/serialize_selector.fish

set -l selector (serialize_selector $argv)
and test (count $selector) -eq 1
or exit (llerr -e2 "expected one selector")

__cyb_op_init; or exit 1
echo $selector >$_CYBW_REQ/0.json

_cyb_op tap >$_CYBW_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR)) — trace: $(llcode $CYBW_CALL)")

# Réponse en tar : error.txt présent => le clic n'a pas abouti.
if test -e $_CYBW_RESP/error.txt
    exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_RESP/error.txt)) — trace: $(llcode $CYBW_CALL)")
end

set -q CYBW_TRACE; and llinf "tapped $(llcode $argv)"
exit 0
