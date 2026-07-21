#!/usr/bin/env fish
# matche un/plusieurs targ dirs ; émet les paths des hits. POST /query.
# -V/--visible : ne matche que les éléments VISIBLES (défaut : attached = présent
# dans le DOM). Le daemon exige toujours un fichier `mode`.
set -lx log_registry CybQuery
__cyb_op_init; or exit 1

argparse -N1 "m/max=" "o/output=" "V/visible" -- $argv; or exit (llerr -e2 "bad usage")

set -q _flag_max
or set _flag_max 0

set -q _flag_output
or set _flag_output items

cp -r $argv $_CYB_REQ/
echo $_flag_max >$_CYB_REQ/max
if set -q _flag_visible
    echo visible >$_CYB_REQ/mode
else
    echo attached >$_CYB_REQ/mode
end

_cyb_op query 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_ERR))")

set -l save $_CYB_RESP

switch $_flag_output
    case items
        path resolve -- $save/*/*
    case root
        path resolve -- $save
    case '*'
        exit (llerr -e1 "unknown output : $(llcode $_flag_output)")
end

set -q CYBTRACE; and llinf "queried $(llcode $argv)"
exit 0
