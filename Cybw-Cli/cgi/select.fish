#!/usr/bin/env fish
# choisit l'option <--text> d'un <select> matché par <targ_dir>/*.toml. POST /select.
set -lx log_registry CybSelect
__cyb_op_init; or exit 1

argparse -N1 -X1 "t/text=" -- $argv; or exit (llerr -e2 "bad usage")

set -q _flag_text
or exit (llerr -e2 "no select option provided")

cp -r $argv[1] $_CYB_REQ/
echo $_flag_text >$_CYB_REQ/text

_cyb_op select 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_ERR))")

set -q CYBTRACE; and llinf "selected $(llcode $_flag_text) on $(llcode $argv[1])"
exit 0
