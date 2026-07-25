#!/usr/bin/env fish
# attend que TOUS les sélecteurs matchent au moins un élément.
#   cybw all [-s] [-T N] -- -e 'a' -- -e 'b'
# Délègue à `cybw query` (sous-process) ; pas de staging direct ici.
set -lx log_registry CybAll
source ./lib/retry.fish

argparse 's/silent' 'T/timeout=' -- $argv
or exit (llerr -e2 "bad usage")

set -q _flag_timeout; and set -g cyb_retry_T $_flag_timeout; or set -g cyb_retry_T 60
set -q _flag_silent; and set -g cyb_retry_s 1

# nombre de sélecteurs attendus = (# de `--` restants) + 1.
set -l seps 0
for a in $argv
    test "$a" = --; and set seps (math $seps + 1)
end
set -l want (math $seps + 1)

set -l rh (__cyb_retry_reset $argv); or exit 2
while true
    __cyb_retry_tick $rh; or exit 1

    set -l qq_dir (cybw query -o root -- $argv); or exit $status

    # succès quand chaque index 0..want-1 a un sous-dossier (≥1 hit).
    set -l got $qq_dir/*
    if test (count $got) -eq $want
        set -q CYBW_TRACE; and llinf "found all : $(llcode $argv)"
        exit 0
    end
end
