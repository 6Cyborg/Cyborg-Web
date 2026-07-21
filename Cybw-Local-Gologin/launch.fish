#!/usr/bin/env fish
# cyb-gologin-launch.fish [-f/--fingerprint FINGERPRINT] PROFILE
set -g log_registry cyb-launch

set -l script_dir (status filename | path resolve | path dirname)
set -l sys $script_dir/sys
set -l ddir $script_dir/dat-userdatadir/(uuidgen)

llwait "starting gologin in $(llcode $ddir)"

argparse -N1 -X1 "f/fingerprint="  -- $argv; or return 2

set -l profile_dir $argv[1]

# Structure FS profile :
set -l profile__geo_json $profile_dir/.geo.json
set -l profile__fp_json $profile_dir/.fp.json
set -l profile__proxy_json $profile_dir/.proxy.json
set -l profile_proxy_url $profile_dir/proxy
set -l profile_app_country $profile_dir/app_country.txt
set -l profile_app_city $profile_dir/app_city.txt
set -l profile_export $profile_dir/state.tar.xz
set -l profile_history_dir $profile_dir/run-history

mkdir -p $profile_history_dir

set -q _flag_f
and set -l fpfile $_flag_f
or set -l fpfile ($sys/profile-random.fish)

function get_free_port
    while set -l p (random 10000 35000)
        if test -z "$(ss -Htln "sport = :$p" 2>/dev/null)"
            echo $p
            return 0
        end
    end
end

function wait_ready -a pid url
    while sleep 1
        kill -0 $pid 2>/dev/null; or return 1
        curl -sf $url >/dev/null 2>&1; and break
    end
end

function check_app_field -a file actual
    test -n "$actual"; or return 2
    set -l label (path basename -- $file)

    if not test -s "$file"
        llwar "No Data $label"
        return 0
    end
    set -l expected (string collect <$file)

    test "$actual" = "$expected"
    and llinf "Good $label : $(llcode $actual) au lieu de $(llcode $expected)"
    or llwar "mismatch $label : $(llcode $actual) au lieu de $(llcode $expected)"
end

$sys/profile-parse.fish $fpfile >$profile__fp_json
and set -l fpfile (jq -re .fpfile <$profile__fp_json)
and set -l ver (jq -re .version <$profile__fp_json)
and set -l id (jq -re .id <$profile__fp_json)
and set -l res (jq -re .resolution <$profile__fp_json)
or return (llerr -e2 "profile incompatible")

set -l chrome $script_dir/dat-browser/$ver/release/chrome

if not test -x "$chrome"
    llerr "Version non téléchargé : $ver => ./cyb-gologin-install.fish $fpfile"
    return 2
end

set -l profile__geo_args -s --max-time 10

if not test -s $profile_proxy_url
    jq -nc \
        '{scheme:"none", user:"", pass:"", server}' >$profile__proxy_json
else if set -l proxy_parts (string match -rg '^http://([^:]+):([^@]+)@(.+)$' <$profile_proxy_url)
    set -a profile__geo_args --proxy (cat $profile_proxy_url)
    jq -nc \
        --arg user "$proxy_parts[1]" \
        --arg pass "$proxy_parts[2]" \
        --arg server "$proxy_parts[3]" \
        '{scheme:"http", $user, $pass, $server}' >$profile__proxy_json
else if set -l proxy_parts (string match -rg '^http://([^:]+:.+)$' <$profile_proxy_url)
    set -a profile__geo_args --proxy (cat $profile_proxy_url)
    jq -nc \
        --arg server "$proxy_parts[1]" \
        '{scheme:"http", user:"", pass:"", $server}' >$profile__proxy_json
else
    exit (llerr -e1 "Incompatible Proxy : $(llcode (string collect <$profile_proxy_url))")
end

curl https://geo.myip.link $profile__geo_args -o $profile__geo_json
or return (llerr -e1 "La géo-localisation a échoué")
set -l _geo_country (jq -re '.country // ""' <$profile__geo_json)
set -l _geo_city (jq -re '.city // ""' <$profile__geo_json)

# Antidetect Network
check_app_field $profile_app_country $_geo_country
check_app_field $profile_app_city $_geo_city
# pas retourné : check_app_field $profile_app_postal_code $_geo_postal_code

# User Data Dir vierge
mkdir -p $ddir/Default/Network
cp $sys/udd-preferences.json $ddir/Default/Preferences
cp $sys/udd-bookmarks.json $ddir/Default/Bookmarks
if set -l init_cookies_query (jq -re '.createCookiesTableQuery' <$fpfile)
    for db in $ddir/Default/Network/Cookies $ddir/Default/Cookies
        $sys/sqlite-query.py "$db" "$init_cookies_query"
    end
end

# Default/Preferences : base + bloc gologin (fingerprint + proxy) — udd-gologin.jq fusionne tout.
jq --argjson base (cat $ddir/Default/Preferences) \
    --argjson tz (cat $profile__geo_json) \
    --argjson proxy (cat $profile__proxy_json) \
    -c -f $sys/udd-gologin.jq <$fpfile >$ddir/Default/Preferences.tmp
and mv $ddir/Default/Preferences.tmp $ddir/Default/Preferences
or return (llerr -e1 "Non généré : Preferences.tmp")

# orbita.config : intl + gologin(SECURED_ORBITA_OPTS), calculé depuis la source (pas de round-trip).
jq -c --argjson tz (cat $profile__geo_json) -f $sys/udd-orbita.jq <$fpfile >$ddir/orbita.config
or return (llerr -e1 "Non généré : orbita.config")

set -l cdp_port (get_free_port)
or return (llerr -e1 "aucun port libre trouvé")

# Args Orbita (ordre exact gologin.py:199-209 == bélier). Pas de proxy : le
# profil ne sert qu'au fingerprint (proxy seulement signalé par parse-profile).
set -l args \
    --remote-debugging-port=$cdp_port \
    --password-store=basic \
    --gologin-profile=(path basename $fpfile | path change-extension '') \
    --lang=en-US \
    --webrtc-ip-handling-policy=default_public_interface_only \
    --disable-features=PrintCompositorLPAC \
    --window-size=(string replace x , $res) \
    --user-data-dir=$ddir

# Orbita dépend de libcurl-gnutls.so.4
# ./usrlib/ contient ceux que Fedora ne fournit pas.
set -l ld (path resolve $script_dir/usrlib)
set -q LD_LIBRARY_PATH; and set ld $ld:$LD_LIBRARY_PATH

# === Démarrage du navigateur internet
set -l ad_log $ddir/cyb-orbita.log
llwait "lancement d'Orbita $ver"

setpriv --pdeathsig TERM -- \
    env SENTRY_DSN= LD_LIBRARY_PATH=$ld \
    setsid $chrome $args >$ad_log 2>&1 &
set -gx GOLOGIN_PID $last_pid
disown

wait_ready $GOLOGIN_PID http://127.0.0.1:$cdp_port/json
or return (llerr -e1 "Gologin n'a pas été prêt")

# === Démarrage de Cyborg

set -l runtime $script_dir/../Cybw-Runtime-CDP/cyborg_server.py
set -l rt_log $ddir/cyb-runtime-cdp.log
set -l rt_url http://127.0.0.1:9224
llwait "lancement de Cyborg"

setpriv --pdeathsig TERM -- env CDP_PORT=$cdp_port uv run $runtime >$rt_log 2>&1 &
set -gx CYBRT_PID $last_pid
disown

wait_ready $CYBRT_PID $rt_url/status
or return (llerr -e1 "Cyborg n'a pas été prêt")

set -gx CYB_DIR $ddir
set -gx CYB_URL $rt_url

# === Profil persistant : appareil vu ? trace de run, restore, save périodique ===

path filter -- $profile_history_dir/*.json | jq --arg ID "$id" 'select(.device==$ID)' -e >/dev/null
and llinf "appareil connu : $(llcode $id)"
or llwar "nouvel : $(llcode $id)"

# Trace de run : <profile>/run-history/<ISO-8601>.json (ex 2026-07-10T20:54:55+02:00.json).
set -l now (date --iso-8601=seconds)
jq -n --arg ts $now --arg device $id --arg fpfile $fpfile --arg proxy "$proxy" \
    --arg country "$_geo_country" --arg language "$geo_lang" --arg resolution "$res" \
    --arg version "$ver" --argjson cdp_port $cdp_port \
    '{$ts, "gologin", $device, $fpfile, $proxy,
      $country, $language, $resolution,
      $version, $cdp_port}' >$profile_history_dir/$now.json

# Importe d'abord
if test -s $profile_export
    llwait "restauration du profile"
    cybw set-profile $profile_export
    or exit (llerr -e1 "Échec de set-profile")
else
    llwar "profile vierge"
end

# Démarre l'exportateur automatique
setpriv --pdeathsig TERM -- $sys/profile-autosave.fish (path resolve $profile_export) &
set -gx CYB_SAVER_PID $last_pid
disown

llinf "Prêt à l'emploi  |  browser:$GOLOGIN_PID  server:$CYBRT_PID saver:$CYB_SAVER_PID"
