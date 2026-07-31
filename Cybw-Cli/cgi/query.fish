#!/usr/bin/env fish
# multi-querySelectorAll basique. 
# cybw query [-m N] [-o items|root] -- ...
set -lx log_registry CybQuery
source ./lib/transport.fish
source ./lib/serialize_selector.fish

argparse 'm/max=' 'o/output=' -- $argv; or exit (llerr -e2 "bad usage")
set -q argv[1]; or exit (llerr -e2 "no selector")

set -q _flag_max; or set _flag_max 0
set -q _flag_output; or set _flag_output items

__cyb_op_init; or exit 1

echo $_flag_max >$_CYBW_REQ/max

set -l idx 0
for contents in (serialize_selector $argv)
    echo $contents > $_CYBW_REQ/$idx.json
    set idx (math $idx + 1)
end

if not _cyb_op query
    exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR)) — trace: $(llcode $CYBW_CALL)")
end

switch $_flag_output
    case items
        path filter -- $_CYBW_RESP/*/*
    case root
        path filter -- $_CYBW_RESP
    case '*'
        exit (llerr -e1 "unknown output : $(llcode $_flag_output)")
end

set -q CYBW_TRACE; and llinf "queried $idx selector(s)"
exit 0
