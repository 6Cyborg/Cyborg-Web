#!/usr/bin/env fish

# Génère (ou met à jour) un dossier profil AWS Device Farm persistant, INDÉPENDANT
# du compte AWS. Le profil est l'IDENTITÉ (proxy, état Chrome, géo attendue) — même
# contrat que Cybw-Local-Gologin, partagé avec cyb-awsdf-launch.fish :
#
#   proxy                  http://user:pass@host:port — SOURCE DE VÉRITÉ du proxy
#   app_country.txt        géo attendue (sanity non bloquant au launch)
#   app_city.txt
#   run-history/<ISO>.json une trace par run (écrite par le launch, provider awsdf)
#                          — mémoire des appareils déjà utilisés par ce profil
#   state.tar.xz           état Chrome persistant (cookies + localStorage) — écrit
#                          par cyb-awsdf-launch.fish toutes les ~60s et à la fermeture
#
# country / language NE sont PAS stockés : ils sont DÉRIVÉS au launch de la géoloc
# de l'IP de sortie (geo.myip.link à travers le proxy). L'APPAREIL n'est pas non
# plus épinglé ici : le launch prend le dernier device de run-history, sinon un
# pool dynamique (AWS choisit) ; forcer un device précis se fait au launch via -d.
#
# Usage :
#   cyb-awsdf-profile.fish <destdir> [--proxy URL] [--country XX] [--city Ville]
#
# Ex :
#   cyb-awsdf-profile.fish ./profiles/floppy-us-1 \
#       --proxy 'http://user:pass@geo.floppydata.com:10080' \
#       --country US --city 'New York'
#
# Puis, à chaque session (state.tar.xz restauré au boot s'il existe) :
#   ./cyb-awsdf-launch.fish pool-accounts/AKIA….json ./profiles/floppy-us-1
#
# Re-run : proxy / app_country.txt / app_city.txt ne sont (ré)écrits que si leur
# flag est passé (sinon fichier existant préservé, comme state.tar.xz et
# run-history/). Pour SUPPRIMER un proxy ou une attente géo, effacer le fichier
# correspondant à la main. Rotation des creds proxy : re-run avec le nouveau --proxy.

set -lx log_registry CybAwsdfProfile

argparse -N1 -X1 'proxy=' 'country=' 'city=' -- $argv
or exit (llerr -e2 "usage: cyb-awsdf-profile.fish <destdir> [--proxy URL] [--country XX] [--city Ville]")

set -l destdir $argv[1]

mkdir -p $destdir/run-history
or exit (llerr -e1 "création $(llcode $destdir) échouée [$status]")

# proxy / app_country.txt / app_city.txt : écrits seulement si le flag est passé
# (sinon fichier existant préservé). Pour les SUPPRIMER, effacer le fichier à la main.
if set -q _flag_proxy
    echo $_flag_proxy >$destdir/proxy
end
if set -q _flag_country
    echo $_flag_country >$destdir/app_country.txt
end
if set -q _flag_city
    echo $_flag_city >$destdir/app_city.txt
end

llinf "profil écrit → $(llcode (path resolve -- $destdir))"
for f in proxy app_country.txt app_city.txt state.tar.xz
    test -f $destdir/$f
    and llinf "  $f = $(llcode (test $f = state.tar.xz; and echo '<état persistant>'; or string trim <$destdir/$f))"
end
