#!/usr/bin/env fish

# Boucle de sauvegarde périodique de l'état Chrome persistant (cookies +
# localStorage) vers <dest_state> (.tar.xz), via le client `cyb` (Cybw-Client).
# Piloté depuis le home du client car ses cgi sourcent `vendor/…` relatif au CWD ;
# hérite CYB_URL / CYB_DIR (-gx) du process appelant. Export atomique (tmp dans le
# dossier du profil + mv, même système de fichiers ⇒ rename atomique) ⇒ jamais de
# .tar.xz tronqué si tué en plein tar.
#
# C'est un .fish DÉDIÉ (et non une fonction) car backgrounder une fonction fish ne
# donne pas de `$last_pid` fiable pour la tuer proprement au fish_exit ; un
# exécutable externe forke un vrai process.
#
#   profile_saver.fish <client_home> <dest_state> [interval_secs=60]
#
# Lancé détaché par cyb-awsdf-launch.fish (`profile_saver.fish … &`, $last_pid
# tué au fish_exit). Le bootstrap fait la sauvegarde FINALE lui-même (même bloc).

source (status dirname)/../vendor/log.fish
set -lx log_registry CybProfileSaver

argparse -N2 -X3 -- $argv; or exit 2
set -l client_home $argv[1]
set -l dest $argv[2]
set -l interval $argv[3]
test -n "$interval"; or set interval 60

cd $client_home; or exit (llerr -e1 "client home introuvable: $(llcode $client_home)")

# Save immédiat (avant le 1er sleep) : garantit un state.tar.xz valide tôt, même si
# la session meurt avant l'intervalle.
while true
    set -l tmp (mktemp (path dirname -- $dest)/.state.XXXXXX)
    if bin/cyb export-profile $tmp >/dev/null 2>&1
        mv -f $tmp $dest
    else
        rm -f $tmp
        llwar "export profil échoué [$status]"
    end
    sleep $interval
end
