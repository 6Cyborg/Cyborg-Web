#!/usr/bin/env fish
# navigue vers <url>. POST /visit.
set -lx log_registry CybVisit
source ./lib/transport.fish
__cyb_op_init; or exit 1

argparse -N1 -X1 -- $argv; or exit (llerr -e2 "bad usage")

echo $argv[1] >$_CYBW_REQ/url

if not _cyb_op visit
    exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR)) — trace: $(llcode $CYBW_CALL)")
end

set -q CYBW_TRACE; and llinf "visited $(llcode $argv[1])"
exit 0
