#!/usr/bin/env fish

# ─── helpers d'attente (partagés par all / none / race) ───────────────────────
# État global = OK : chaque waiter est son propre process. `cyb_retry_T` (timeout
# en s) et `cyb_retry_s` (silencieux) sont posés par l'appelant avant reset.

function __cyb_retry_reset -d "ouvre une session d'attente ; renvoie un handle aléatoire."
    set -q cyb_retry_T
    or return (llerr -e2 "no timeout defined")

    set -q cyb_retry_s
    and set -g __cyb_retry_silent 1

    set -g __cyb_retry_deadline (math (date +%s) + $cyb_retry_T)
    set -g __cyb_retry_attempt 1

    set -g __cyb_retry_title "$argv"
    set -g __cyb_retry_handle (random 100000000 999999999)

    echo $__cyb_retry_handle
end

function __cyb_retry_tick -d "fin de tour d'attente : échoue à T-0, sinon log périodique + sleep 0.2."
    set -l rh $argv[1]

    test "$rh" = "$__cyb_retry_handle"
    or return (llerr -e1 "retry handle incohérent : $rh != $__cyb_retry_handle")

    set -l countdown (math $__cyb_retry_deadline - (date +%s))

    # timed-out :
    if test $countdown -lt 1
        return (llerr -e1 "T-0 for $(llcode $__cyb_retry_title)")
    end

    # scheduled logs (sauf en mode silencieux) :
    if test (math $__cyb_retry_attempt % 10) -eq 0
        and not set -q __cyb_retry_silent
        llwait "T-$countdown for $(llcode $__cyb_retry_title) #$__cyb_retry_attempt"
    end

    # attempt démarre à 1
    if test $__cyb_retry_attempt -ne 1
        sleep 0.2
    end

    set -g __cyb_retry_attempt (math $__cyb_retry_attempt + 1)
end
