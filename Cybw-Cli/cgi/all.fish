#!/usr/bin/env fish
# attend que tous les sélecteurs matchent au moins un élément.
#   cybw all targs/monsite.fr_*
#   cybw tap targs/monsite.fr_bet
set -lx log_registry CybAll
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

    set -l qq_dir (cyb query $vflag -o root $argv); or exit $status

    # succès quand aucun targ n'est manquant (tous ont au moins un hit).
    set -l diff (comm -23 \
        (path basename -- $argv | sort | psub) \
        (path basename -- $qq_dir/* | sort | psub)
    )
    if test -z "$diff"
        set -q CYBTRACE; and llinf "found all : $(llcode $argv)"
        exit 0
    end
end
