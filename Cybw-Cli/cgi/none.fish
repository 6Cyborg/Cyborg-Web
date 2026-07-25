#!/usr/bin/env fish
# attend qu'AUCUN sélecteur ne matche plus rien.
#   cybw none [-s] [-T N] -- -e 'a' -- -e 'b'
set -lx log_registry CybNone
source ./lib/retry.fish

argparse 's/silent' 'T/timeout=' -- $argv
or exit (llerr -e2 "bad usage")

set -q _flag_timeout; and set -g cyb_retry_T $_flag_timeout; or set -g cyb_retry_T 60
set -q _flag_silent; and set -g cyb_retry_s 1

set -l rh (__cyb_retry_reset $argv); or exit 2
while true
    __cyb_retry_tick $rh; or exit 1

    set -l qq (cybw query -o items -- $argv); or exit $status

    if test -z "$qq"
        set -q CYBW_TRACE; and llinf "found neither : $(llcode $argv)"
        exit 0
    end
end
