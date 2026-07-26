#!/usr/bin/env fish
# choisit l'option <--text> d'un <select> matché par le sélecteur. POST /select.
#   cybw select -t '<option innerText>' -e '<css>'
set -lx log_registry CybSelect

source ./lib/transport.fish
source ./lib/serialize_selector.fish

# -i : capte -t/--text, laisse passer les flags de sélecteur.
argparse -i 't/text=' -- $argv
and set -q _flag_text
or exit (llerr -e2 "bad usage")

set -l selector (serialize_selector $argv)
and test (count $selector) -eq 1
or exit (llerr -e2 "expected one selector")

__cyb_op_init; or exit 1
echo $selector >$_CYBW_REQ/0.json
echo $_flag_text >$_CYBW_REQ/text

_cyb_op select >$_CYBW_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR))")

set -q CYBW_TRACE; and llinf "selected $(llcode $_flag_text)"
exit 0
