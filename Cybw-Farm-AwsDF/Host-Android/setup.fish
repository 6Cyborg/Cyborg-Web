#!/usr/bin/env fish

# Cold-start : orchestre tout le boot du testspec — appium, caddy (reverse-proxy
# de `/host-android/apply-provision` vers busybox httpd et de `/cyborg/*` vers
# le serveur data-plane Python), gost binding adb, cloudflared.
#
# Long-duration : chaque daemon est backgroundé avec `&` ici (direct child de
# setup.fish), `wait` à la fin tient le process vivant jusqu'à SIGTERM d'AWS DF.
#
# NOTE : ni Chrome ni le serveur cyborg ne sont up à ce stade. C'est le premier
# `POST /host-android/apply-provision` (déclenché par cyb-awsdf-launch) qui
# orchestre gost + locale + `pm clear chrome` + first-run + `adb forward` puis
# spawn le `.py` cyborg (Cybw-Runtime-CDP, à la racine du zip). Tant
# qu'apply-provision n'a pas tourné, `/cyborg/*` renvoie 502.
#
# Invariant client : `endpoint_url=<URL>` apparu dans TESTSPEC_OUTPUT ⇒
# cold-start a terminé ⇒ device prêt à recevoir `POST /host-android/apply-provision`.


set -lx log_registry HostAndroidSetup

# AWS ne cleanup pas bien et les runs peuvent s'entre-mêler. J'ai justement
# déjà eu "Address already in use" pour gost.
set -gx GOST_PORT (random 49152 51152)
set -gx CDP_PORT (random 52152 54152)

./3rd/appium_spawn.fish &
./3rd/caddy_spawn.fish &
./3rd/busybox_spawn.fish &
./3rd/cloudflared_spawn.fish &

llinf "setting-up phone proxy through adb"
adb reverse tcp:$GOST_PORT tcp:$GOST_PORT
and adb shell settings put global http_proxy 127.0.0.1:$GOST_PORT
or exit (llerr 1 "adb setup failed [$status]")

llinf "get-current-user: $(llcode (adb shell am get-current-user))"
llinf "chrome pkgs: $(adb shell pm list packages com.android.chrome))"
for apk in (adb shell pm path com.android.chrome | string replace -r '^package:' '' | string trim)
    set -l bytes (adb shell stat -c %s "$apk" | string trim)
    llinf "chrome apk $apk : $(numfmt --to=iec $bytes)"
end

# Le côté client se charge de probe
echo "endpoint_url=https://$CF_TUNNEL_HOSTNAME"

wait
