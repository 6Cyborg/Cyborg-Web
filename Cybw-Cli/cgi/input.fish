#!/usr/bin/env fish
# Définit la valeur d'un input, textarea ou select.
# * Supporte les fichiers.
# * Humanisation sans configuration
#
#   cybw input --text "vendeur de glaces" 'input<css>'
#   cybw input --file a --file b 'input[type="file"]<css>'
#   cybw input --opt-value "1" 'select<css>'

set -lx log_registry CybSet

source ./lib/transport.fish
source ./lib/serialize_selector.fish

argparse -x t,f,select-value 't/text=' 'f/file=+' 'select-value='  -- $argv
and test -n "$_flag_text$_flag_file$_flag_select_value"
or exit (llerr -e2 "bad usage")

set -l selector (serialize_selector $argv)
and test (count $selector) -eq 1
or exit (llerr -e2 "expected one selector")

__cyb_op_init; or exit 1

echo $selector >$_CYBW_REQ/0.json

if set -q _flag_file
    mkdir $_CYBW_REQ/files
    for src in $_flag_file
        set -l dest $_CYBW_REQ/files/(path basename -- $src)

        if test -f $dest
            exit (llerr -e2 "duplicate basename: $(path basename -- $src)")
        end

        cp -- $src $dest; or exit (llerr -e2 "unreadable file: $src")

        if test (stat -c %s -- $dest) -gt (math '1024 * 1024 * 10')
            llwar "$(llcode $src) exceeds 10 MiB (server cap: 16 MiB total)"
        end
    end
else if set -q _flag_text
    echo -n -- $_flag_text >$_CYBW_REQ/text
else if set -q _flag_select_value
    echo -n -- $_flag_select_value >$_CYBW_REQ/select-value
end

_cyb_op input >$_CYBW_ERR
or exit (llerr -e1 "error: $(llcode (cat $_CYBW_ERR))")

set -q CYBW_TRACE; and llinf "input $(llcode $_flag_text $_flag_file)"
exit 0
