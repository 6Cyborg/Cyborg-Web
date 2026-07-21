#!/usr/bin/env fish
# émet le cookie et l'User-Agent d'une <url>. POST /cookie.
set -lx log_registry CybCookie
__cyb_op_init; or exit 1

argparse -N1 -X1 -- $argv; or exit (llerr -e2 "bad usage")

echo $argv[1] >$_CYB_REQ/url

_cyb_op cookie 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_ERR))")

# cookie.txt n'a pas de \n final → `echo` sépare les 2 valeurs.
cat $_CYB_RESP/cookie.txt; echo
cat $_CYB_RESP/user-agent.txt

set -q CYBTRACE; and llinf "got cookie for $(llcode $argv[1])"
exit 0
