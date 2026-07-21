#!/usr/bin/env fish
# attend que le 1er sélecteur trouve au moins un élément.
# 1ère ligne = path du targ gagnant, puis ses hits. Permet :
#   set -l then (cyb race elems/a elems/b)
#   switch $then[1]
#        case elems/a ; for p in $then[2..-1]; cat $p; end
#        case elems/b ; for p in $then[2..-1]; cat $p; end
#        case ''      ; echo 'deadline has elapsed'
#   end
set -lx log_registry CybRace
__cyb_op_init; or exit 1

argparse -N1 "s/silent" "T/timeout=" "V/visible" -- $argv; or exit (llerr -e2 "bad usage")

set -l vflag  # -V/--visible propagé à `cyb query` (ne race que les visibles)
if set -q _flag_visible
    set vflag -V
end

set -q _flag_T
and set -g cyb_retry_T $_flag_T
or set -g cyb_retry_T 60

set -q _flag_silent
and set -g cyb_retry_s 1

set -l rh (__cyb_retry_reset $argv); or exit 2

while true
    __cyb_retry_tick $rh; or exit 1

    set -l qq_dir (cyb query $vflag -o root $argv); or exit $status

    # succès au 1er targ (ordre passé) qui a un hit ; émet son path puis ses hits.
    for f in $argv
        set -l targ_qq_dir $qq_dir/(path basename -- $f)

        test -d $targ_qq_dir
        or continue

        echo $f
        path resolve -- $targ_qq_dir/*

        set -q CYBTRACE; and llinf "race winner : $(llcode $f)"
        exit 0
    end
end
