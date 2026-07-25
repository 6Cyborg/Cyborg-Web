#!/usr/bin/env fish
# évalue du JS ; -j/--json renvoie la valeur décodée. Échoue si le JS throw. POST /js.
# -f/--frame '<iframe>' : évalue dans la FRAME iframe matchée par son `url` (au lieu
# du top frame). Interprété spécialement côté serveur, jamais via querySelector.
set -lx log_registry CybJs

source ./lib/transport.fish
source ./lib/argparse_selectors.fish

argparse -N1 'j/json' 'f/frame=' -- $argv; or exit (llerr -e2 "bad usage")

__cyb_op_init; or exit 1

echo $argv[1] >$_CYBW_REQ/script.js
jq -n --args -c '$ARGS.positional' -- $argv[2..-1] >$_CYBW_REQ/args.json

# Sélecteur d'iframe (choix de frame), compilé en frame.json. `element` factice :
# le serveur (find_frame) n'utilise que le filtre `iframe`, pas querySelector.
if set -q _flag_frame
    argparse_selectors -e iframe --frame "$_flag_frame" >$_CYBW_REQ/frame.json
    or exit (llerr -e2 "bad frame selector")
end

# le daemon ne returnByValue que si `output` == "json"
set -q _flag_json; and echo json >$_CYBW_REQ/output; or echo -n >$_CYBW_REQ/output

_cyb_op js >$_CYBW_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR))")

# le daemon renvoie un membre `error` (et pas `output`) si le JS a throw
test -s $_CYBW_RESP/error; and exit (llerr -e1 "js threw : $(llcode (cat $_CYBW_RESP/error))")

# `output` est encodé JSON (json.dumps) ; jq -r le décode
set -q _flag_json; and jq -r . <$_CYBW_RESP/output

set -q CYBW_TRACE; and llinf "evaluated js"
exit 0
