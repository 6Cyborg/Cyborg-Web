#!/usr/bin/env fish
# Fonction périodique pour `cybw profile-save`

set -lx log_registry GologinAutosave

argparse -X0 "i/interval=" -- $argv; or exit 2

set -q _flag_i
or set _flag_i 60

while true
    sleep $_flag_i

    if cybw profile-save >/dev/null 2>&1
        llinf "autosaved"
    else
        llwar "export profil échoué [$status]"
    end
end
