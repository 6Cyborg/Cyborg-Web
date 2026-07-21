#!/usr/bin/env fish
# évalue du JS ; -j/--json renvoie la valeur décodée. Échoue si le JS throw. POST /js.
# --rel <targ_dir> : éval dans la FRAME portant l'élément matché par le Targ (au
# lieu du top frame). L'élément sert juste à choisir la frame, il n'est pas passé.
set -lx log_registry CybJs
__cyb_op_init; or exit 1

argparse -N1 j/json rel= -- $argv; or exit (llerr -e2 "bad usage")

echo $argv[1] >$_CYB_REQ/script.js
jq -n --args -c '$ARGS.positional' -- $argv[2..-1] >$_CYB_REQ/args.json
# Targ de sélection de frame, copié sous `rel/` (sous-dossier => Targ côté daemon)
set -q _flag_rel; and cp -r $_flag_rel $_CYB_REQ/rel
# le daemon ne returnByValue que si `output` == "json"
set -q _flag_json; and echo json >$_CYB_REQ/output; or echo -n >$_CYB_REQ/output

_cyb_op js 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_ERR))")

# le daemon renvoie un membre `error` (et pas `output`) si le JS a throw
test -s $_CYB_RESP/error; and exit (llerr -e1 "js threw : $(llcode (cat $_CYB_RESP/error))")

# `output` est encodé JSON (json.dumps) ; jq -r le décode
set -q _flag_json; and jq -r . <$_CYB_RESP/output

set -q CYBTRACE; and llinf "evaluated js"
exit 0
