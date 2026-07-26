#!/usr/bin/env fish

# ─── Sélecteur CLI → JSON (un ARGUMENT = un sélecteur, chaîne unique) ──────────
# `serialize_selector <sel>...` : prend UNE OU PLUSIEURS chaînes-sélecteur (une
# par argument) et émet un objet JSON compact par sélecteur sur stdout.
# Chaque chaîne : '<element>' [--pierce] [--nth N] [--text-eq T] [--frame '<ifr>']
# [-V|-h]. On re-tokenise avec `xargs -n1` (respecte les guillemets, sans `eval`),
# puis `argparse` : l'élément est le POSITIONNEL, le reste des flags.
# Clés JSON : element / iframe / text_eq / nth / mode / pierce.
#
# ⚠ Quoting au RUNTIME : une valeur mal quotée (guillemet non appairé) échoue ici
# (xargs), pas au parse fish. Wrapper chaque valeur avec le guillemet absent de
# son contenu (CSS avec `"` → `'…'` ; texte avec `'` → `"…"`).

function __cyb_json_str -a str
    test -n "$str"
    and echo $str | jq -R
    or echo null
end

function __cyb_json_int -a str
    test -n "$str"
    and echo $str | jq -r
    or echo null
end

function serialize_selector
    for sel in $argv
        # argparse ne réinitialise PAS les flags absents → nettoyage explicite.
        set -e _flag_pierce _flag_nth _flag_text_eq _flag_frame _flag_V _flag_h

        # -N1 -X1 : exactement 1 positionnel = l'élément. Le reste = flags.
        argparse -N1 -X1 --exclusive V,h 'pierce' 'nth=' 'text-eq=' 'frame=' \
            'V/visible' 'h/hidden' -- (printf '%s' $sel | xargs -n1)
        or exit (llerr -e2 "bad selector: $(llcode $sel)")

        set -l element $argv[1]

        set -l mode attached
        set -q _flag_V; and set mode visible
        set -q _flag_h; and set mode hidden

        set -l pierce false
        set -q _flag_pierce; and set pierce true

        jq -c -n '{ $element, $iframe, $text_eq, $nth, $mode, $pierce }' \
            --arg     element "$element" \
            --argjson iframe  "$(__cyb_json_str "$_flag_frame")" \
            --argjson text_eq "$(__cyb_json_str "$_flag_text_eq")" \
            --argjson nth     "$(__cyb_json_int "$_flag_nth")" \
            --arg     mode    "$mode" \
            --argjson pierce  "$pierce"
    end
end
