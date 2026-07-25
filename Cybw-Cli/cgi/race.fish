#!/usr/bin/env fish
# attend que le 1er sélecteur (par index) trouve au moins un élément.
# 1ère ligne = index gagnant (0, 1, …), puis ses hits. Permet :
#   set -l then (cybw race -- -e 'a' -- -e 'b')
#   switch $then[1]
#        case 0 ; for p in $then[2..-1]; cat $p; end
#        case 1 ; for p in $then[2..-1]; cat $p; end
#        case '' ; echo 'deadline has elapsed'
#   end
set -lx log_registry CybRace
source ./lib/retry.fish

argparse 's/silent' 'T/timeout=' -- $argv
or exit (llerr -e2 "bad usage")

set -q _flag_timeout; and set -g cyb_retry_T $_flag_timeout; or set -g cyb_retry_T 60
set -q _flag_silent; and set -g cyb_retry_s 1

# nombre de sélecteurs = (# de `--` restants) + 1.
set -l seps 0
for a in $argv
    test "$a" = --; and set seps (math $seps + 1)
end
set -l n (math $seps + 1)

set -l rh (__cyb_retry_reset $argv); or exit 2
while true
    __cyb_retry_tick $rh; or exit 1

    set -l qq_dir (cybw query -o root -- $argv); or exit $status

    # succès au 1er index (ordre passé) qui a un hit ; émet l'index puis ses hits.
    for i in (seq 0 (math $n - 1))
        set -l hits $qq_dir/$i/*
        test (count $hits) -gt 0; or continue

        echo $i
        path resolve -- $hits

        set -q CYBW_TRACE; and llinf "race winner : #$i"
        exit 0
    end
end
