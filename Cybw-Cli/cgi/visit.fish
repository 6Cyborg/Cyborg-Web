#!/usr/bin/env fish
# navigue vers <url>. POST /visit.
set -lx log_registry CybVisit
__cyb_op_init; or exit 1

argparse -N1 -X1 -- $argv; or exit (llerr -e2 "bad usage")

echo $argv[1] >$_CYBW_REQ/url

_cyb_op visit 2>$_CYBW_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR))")

set -q CYBW_TRACE; and llinf "visited $(llcode $argv[1])"
exit 0
