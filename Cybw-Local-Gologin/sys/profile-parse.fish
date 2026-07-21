#!/usr/bin/env fish
# parse-profile.fish FILE
# Se charge de lire un fingerprint officiel Gologin.

which jq >/dev/null; or exit 2

set -g log_registry parse-profile

argparse -N1 -X1 -- $argv; or return 2
set -l fpfile $argv[1]

# Version majeure du navigateur Orbita (fidèle à gologin.py:763-768)
set -l ver (jq -r '.navigator.userAgent' <$fpfile | string match -rg 'Chrome/([0-9]+)')
or exit (llerr -e1 "profile incompatible : version pas trouvée")

# ID GoLogin
set -l id (jq -re '.id' <$fpfile)
or exit (llerr -e2 "profile malformé : sans ID")

# Le profil ne sert qu'au fingerprint : un proxy défini est seulement signalé.
if jq -r '.proxy.mode=="" or .proxy.mode=="none"' <$fpfile >/dev/null
    llwar "Le fingerprint ne doit pas contenir le proxy $(llcode (jq '.proxy' -c <$fpfile)). Il a été ignoré."
end

# Seule dérivation autorisée (vient du .py amont).
set -l browser_release_url "https://orbita-browser-linux.gologin.com/orbita-browser-latest-$ver.tar.gz"

jq -n \
    --arg fpfile $fpfile \
    --arg id $id \
    --arg version $ver \
    --arg resolution (jq -r '.navigator.resolution // "1920x1080"' <$fpfile) \
    --arg language (jq -r '.navigator.language // "en-US"' <$fpfile) \
    --arg browser_release_url $browser_release_url \
    '{$fpfile, $id, $version, $resolution, $language, $browser_release_url}'
