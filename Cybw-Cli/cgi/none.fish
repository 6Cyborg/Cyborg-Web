#!/usr/bin/env fish
# attend que tous les sélecteurs ne matchent plus rien
#   cybw tap targs/close
#   cybw none targs/close
set -lx log_registry CybNone
__cyb_op_init; or exit 1

argparse -N1 "s/silent" "T/timeout=" "V/visible" -- $argv; or exit (llerr -e2 "bad usage")

set -l vflag  # -V propagé à chaque `cyb query`
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

    set -l qq (cyb query $vflag -o items $argv); or exit $status

    if test -z "$qq"
        set -q CYBTRACE; and llinf "found neither : $(llcode $argv)"
        exit 0
    end
end
