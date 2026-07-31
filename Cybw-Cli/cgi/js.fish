#!/usr/bin/env fish
# évalue du JS ; -j/--json renvoie la valeur décodée. Échoue si le JS throw. POST /js.
# -f/--frame '<iframe>' : évalue dans la FRAME iframe matchée par son `url` (au lieu
# du top frame). Interprété spécialement côté serveur, jamais via querySelector.
set -lx log_registry CybJs

source ./lib/transport.fish
source ./lib/serialize_selector.fish

argparse -N1 'f/frame=' -- $argv; or exit (llerr -e2 "bad usage")

__cyb_op_init; or exit 1

echo $argv[1] >$_CYBW_REQ/script.js
jq -n --args -c '$ARGS.positional' -- $argv[2..-1] >$_CYBW_REQ/args.json

# Sélecteur d'iframe (choix de frame), compilé en frame.json. `-f` reçoit le
# filtre iframe brut ; on fabrique le sélecteur `iframe` + ce filtre. `element`
# factice : le serveur (find_frame) n'utilise que le filtre `iframe`.
if set -q _flag_frame
    serialize_selector "iframe --frame '$_flag_frame'" >$_CYBW_REQ/frame.json
    or exit (llerr -e2 "bad frame selector")
end

if not _cyb_op js
    exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR)) — trace: $(llcode $CYBW_CALL)")
end

# `ok.txt` porte déjà l'output en texte brut (le daemon a fait le `jq -r`) : vide
# sans -j, sinon la valeur nue pour une string, en JSON pour le reste.
cat $_CYBW_RESP/ok.txt

set -q CYBW_TRACE; and llinf "evaluated js"
exit 0
