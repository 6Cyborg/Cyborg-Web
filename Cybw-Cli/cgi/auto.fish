#!/usr/bin/env fish
# Éxécute un script dès qu'un élément est trouvé dans le but de le faire disparaitre.
#
# - Exemple éxécute une seule fois
# cybw auto -d ./dismiss-cookies.fish -- -e 'a.cookie-accept'   
#
# - Exemple re-éxécute si réapparait :
# cybw auto -m0 -d ./close-chat.fish  -- -e '.chatbox'          

set -lx log_registry Cybw-Auto

argparse 'm/limit=' 'exec=' -- $argv
and set -q _flag_exec
or exit (llerr -e2 "bad usage")

set -q _flag_m
or set _flag_m 1

set -l done 0

while true
    cybw all -s -- $argv; or continue

    llwait "processing: $(llcode $argv)"
    $_flag_exec

    cybw none -s -T2 -- $argv
    or llwar "not processed: $(llcode $argv)"

    set done (math $done + 1)
    if test "$_flag_m" -gt 0
        and test "$done" -ge "$_flag_m"
        exit 0
    end
end
