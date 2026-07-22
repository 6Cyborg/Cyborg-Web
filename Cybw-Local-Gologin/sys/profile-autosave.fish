#!/usr/bin/env fish
# Fonction périodique pour `cybw export-profile`

set -lx log_registry CybGologinSaver

argparse -N1 -X1 "i/interval="  -- $argv; or exit 2
set -l dest $argv[1]

set -q _flag_i
or set _flag_i 60

while true
    sleep $_flag_i

    set -l destdir (path dirname -- $dest)
    set -l tmp (mktemp --tmpdir=$destdir .state.XXXXXX)

    if cybw export-profile $tmp >/dev/null 2>&1
        mv -f $tmp $dest
        llinf "autosaved"
    else
        rm -f $tmp
        llwar "export profil échoué [$status]"
    end
end
