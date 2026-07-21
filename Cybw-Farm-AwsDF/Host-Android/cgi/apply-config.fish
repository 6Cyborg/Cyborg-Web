#!/usr/bin/env fish

# POST /host-android/apply-provision
#
# Routé par Caddy puis busybox httpd. Reçoit `{country, language, proxy}` et :
#   1. stop le serveur Cyborg (`cyborg_server.py`) s'il tourne
#   2. restart gost avec le proxy demandé
#   3. broadcast la locale Android (lang/country)
#   4. wipe + first-run Chrome (chrome.py via uv)
#   5. ré-établit `adb forward tcp:9222 → chrome_devtools_remote`
#   6. respawn le serveur Cyborg (qui connecte au CDP fraîchement up et ouvre
#      une page blanche au boot)
#
# Le serveur cyborg ne gère NI le device, NI son propre lifecycle — c'est cet
# endpoint qui orchestre. Sa simple présence sur :9224 (via Caddy /cyborg/*)
# indique que le device est ready.

cd ..
source ./vendor/log.fish

set -lx log_registry HostAndroidProvision

function respond_error -a msg
    llerr "request failed due to: $msg"
    echo "Status: 500 Internal Server Error"
    echo "Content-Type: application/json"
    echo
    jq -nc --arg msg "$msg" '{"ok":false, $msg}'
    exit 0
end

function respond_success
    llinf "request successfully executed"
    echo "Status: 200 OK"
    echo "Content-Type: application/json"
    echo
    jq -nc '{"ok":true}'
    exit 0
end

read -l body
and set -l language (echo $body | jq -re '.language')
and set -l country (echo $body | jq -re '.country')
and set -l proxy (echo $body | jq -re '.proxy // empty')
or respond_error "malformed request body: $body [$status]"

llinf "applying provision: $(llcode $body)"

llwait "restarting gost"
./3rd/gost_spawn.fish $proxy >&2 &
sleep 0.5
pgrep -x gost >/dev/null
or respond_error "gost restart failed [$status]"

llwait "changing android locale"
adb shell am broadcast \
    -a io.appium.settings.locale \
    -n io.appium.settings/.receivers.LocaleSettingReceiver \
    --es lang $language \
    --es country $country >&2
or respond_error "adb set locale failed [$status]"

llwait "wiping google chrome"
adb shell pm clear com.android.chrome >&2
or respond_error "adb wipe chrome failed [$status]"

llwait "doing first-run google chrome"
uv run --script ./automation/chrome.py >&2
or respond_error "chrome first-run failed [$status]"

llwait "forwarding cdp"
adb forward tcp:$CDP_PORT localabstract:chrome_devtools_remote >&2
or respond_error "adb forward failed [$status]"

# `setsid` détache du process group (sinon SIGHUP en cascade quand le CGI exit).
# Stdio : stdin=/dev/null, stdout+stderr → fd2 du CGI ; ce fd2 est hérité du
# fork de busybox httpd, lui-même started en `&` par setup.fish ⇒ remonte au
# stderr de setup.fish, capté par AWS DF. Le fd est dup'd au fork donc cyborg
# continue d'écrire dedans après l'exit du CGI et même celui de busybox.
llwait "respawning cyborg data-plane server"
pkill -f cyborg_server.py 2>/dev/null
setsid uv run --script ./cyborg_server.py </dev/null >&2 &
disown 2>/dev/null

llinf "applied configuration"
respond_success
