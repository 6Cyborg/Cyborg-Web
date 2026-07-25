#!/usr/bin/env fish

# ─── Sélecteurs CLI → JSON (nouvelle API : un sélecteur = un `.json`) ──────────
# `argparse_selectors <segments>` : découpe $argv sur `--` (chaque `argparse`
# s'arrête au `--` suivant) et émet UN objet JSON compact par sélecteur sur
# stdout. Flags par sélecteur : -e/--element (requis), --frame, --nth, --text-eq,
# --pierce, -V/--visible | -h/--hidden. Clés JSON : element/iframe/text_eq/nth/
# mode/pierce (le serveur compile `iframe`/`--frame` en filtres).

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

function argparse_selectors
    set -l argv_rest $argv
    set -l count 0

    while set -q argv_rest[1]
        # Nettoyage explicite : argparse ne réinitialise PAS les flags absents ;
        # sans ça --nth/--pierce/… « baveraient » d'un sélecteur au suivant.
        set -e _flag_e _flag_element _flag_f _flag_frame _flag_nth \
            _flag_text_eq _flag_pierce _flag_V _flag_visible _flag_h _flag_hidden

        argparse --exclusive V,h 'e/element=' 'f/frame=' 'nth=' 'text-eq=' \
            pierce 'V/visible' 'h/hidden' -- $argv_rest
        and set -q _flag_e
        or exit (llerr -e2 "bad usage")

        set -l mode attached
        set -q _flag_V; and set mode visible
        set -q _flag_h; and set mode hidden

        set -l pierce false
        set -q _flag_pierce; and set pierce true

        jq -c -n '{ $element, $iframe, $text_eq, $nth, $mode, $pierce }' \
            --arg     element "$_flag_e" \
            --argjson iframe  "$(__cyb_json_str "$_flag_f")" \
            --argjson text_eq "$(__cyb_json_str "$_flag_text_eq")" \
            --argjson nth     "$(__cyb_json_int "$_flag_nth")" \
            --arg     mode    "$mode" \
            --argjson pierce  "$pierce"

        # argparse a muté $argv (bloc-local) au reliquat ; on le propage.
        set argv_rest $argv
        set count (math $count + 1)
    end
end
