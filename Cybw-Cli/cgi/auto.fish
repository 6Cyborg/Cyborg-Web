#!/usr/bin/env fish
# Détecte l'apparition IMPRÉVISIBLE d'un targ (bannière cookies, popup, chatbox
# qui s'ouvre seule) et lance un script d'interface qui le referme.
#
#   cybw auto targs/cookie-accept ./dismiss-cookies.fish   # traite une fois puis sort
#   cybw auto -m0 targs/chatbox    ./close-chat.fish       # persistant : ré-arme sans fin
#
# Boucle : attend la PRÉSENCE du targ (cybw all), lance $cgi (qui fait le/les
# clic(s)), puis attend sa DISPARITION (cybw none) — et recommence. Le cybw none
# avant de reboucler garantit qu'on ne re-traite pas tant que le targ n'a pas
# disparu puis réapparu. S'arrête après --limit traitements (défaut 1 ; 0 = illimité).
set -lx log_registry CybAuto
__cyb_op_init; or exit 1

set -l done 0

argparse -N2 -X2 "m/limit=" -- $argv
or exit (llerr -e2 "usage: cybw auto [-m/--limit N] <targ> <script>")

set -q _flag_limit
or set _flag_limit 1

set -l targ $argv[1]
set -l cgi $argv[2]

while true
    # -s : silence les logs d'attente périodiques de cybw all/none (on garde ceux de CybAuto).
    cybw all -s $targ
    or continue

    llwait "automatic process running $(llcode $targ)"
    exec $cgi

    cybw none -s -T2 $targ
    or exit (llwar -e1 "automatic process unsucceed $(llcode $targ)")

    set done (math $done + 1)
    if test "$_flag_limit" -gt 0;
       and test "$done" -ge "$_flag_limit"
        exit 0
    end
end
