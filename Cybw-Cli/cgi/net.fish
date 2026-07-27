#!/usr/bin/env fish
# attend la prochaine requête dont l'url matche --url (glob) ; émet une entrée HAR
# {request, response}. stdout VIDE si rien avant -T (= rejected, allSettled).
#
# --stade request|response (défaut response) : à quel stade l'interception Fetch
#   relâche. `request` -> `response` à null (on ne voit que la requête sortante).
#   `response` -> on attend la réponse et `response` est rempli au format HAR.
#
# Le `request` inclut les cookies du store (injectés côté serveur via
# getCookies), y compris les PARTITIONNÉS (CHIPS, ex. `cf_clearance` Cloudflare)
# que l'interception Fetch ne voit pas -> rejouable tel quel (Cookie + UA dans
# `headers`, et tableau `cookies`).

set -lx log_registry CybNet
source ./lib/transport.fish
__cyb_op_init; or exit 1

argparse "u/url=" "T/timeout=" "s/stade=" -- $argv; or exit (llerr -e2 "bad usage")

set -q _flag_url
or exit (llerr -e2 "bad usage")

set -q _flag_T
or set _flag_T 60

set -q _flag_stade
or set _flag_stade response
contains -- "$_flag_stade" request response
or exit (llerr -e2 "bad usage: --stade doit être request ou response")

echo $_flag_u >$_CYBW_REQ/url
echo $_flag_T >$_CYBW_REQ/timeout
echo $_flag_stade >$_CYBW_REQ/stade

_cyb_op net 2>$_CYBW_ERR
or exit (llerr -e1 "op failed: $_flag_url $(llcode (cat $_CYBW_ERR))")

set -l entry_file $_CYBW_RESP/entry.har

# Ni erreur ni résultat => deadline elapsed
test -s $entry_file
or exit (llwar -e1 "deadline elapsed")

cat $entry_file
set -q CYBW_TRACE; and llinf "captured entry ($_flag_stade) for $(llcode $_flag_url)"
exit 0
