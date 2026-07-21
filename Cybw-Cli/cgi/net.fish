#!/usr/bin/env fish
# attend la prochaine requête dont l'url matche --url (glob) ; émet le path d'un
# .har (objet request). stdout VIDE si rien avant -T (= rejected, allSettled).
#
# Le request.har inclut les cookies du store (injectés côté serveur via
# getCookies), y compris les PARTITIONNÉS (CHIPS, ex. `cf_clearance` Cloudflare)
# que l'interception Fetch ne voit pas -> rejouable tel quel (Cookie + UA dans
# `headers`, et tableau `cookies`).

set -lx log_registry CybNet
__cyb_op_init; or exit 1

argparse "u/url=" "T/timeout=" -- $argv; or exit (llerr -e2 "bad usage")

set -q _flag_url
or exit (llerr -e2 "bad usage")

set -q _flag_T
or set _flag_T 60

echo $_flag_u >$_CYB_REQ/url
echo $_flag_T >$_CYB_REQ/timeout

_cyb_op net 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $_flag_url $(llcode (cat $_CYB_ERR))")

set -l req_file $_CYB_RESP/request.har

# Ni erreur ni résultat => deadline elapsed
test -s $req_file
or exit (llwar -e1 "deadline elapsed")

cat $req_file
set -q CYBTRACE; and llinf "captured request for $(llcode $_flag_url)"
exit 0
