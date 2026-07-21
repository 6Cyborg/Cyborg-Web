#!/usr/bin/env fish

# cloudflared_spawn.fish
#
# Provisionne un temp dir handle (creds.json + config.yml depuis l'env),
# branche les followers tail -F qui republient stdout/stderr de cloudflared
# vers ceux de setup.fish (pour que AWS DF capture les logs), puis run
# cloudflared en foreground. setup.fish background ce script avec `&` ; quand
# cloudflared meurt, le script exit → le `wait` final de setup.fish sort.
#
# Env requis (seedés par testspec) : CF_TUNNEL_ID, CF_TUNNEL_SECRET,
# CF_ACCOUNT_ID, CF_TUNNEL_HOSTNAME.

set -l handle (mktemp -d)
chmod 700 $handle

for var in CF_TUNNEL_ID CF_TUNNEL_SECRET CF_ACCOUNT_ID CF_TUNNEL_HOSTNAME
    set -q $var; and test -n "$$var"
    or begin
        echo "missing env $var" >&2
        exit 1
    end
end

set -l creds $handle/creds.json
jq -nc \
    --arg AccountTag $CF_ACCOUNT_ID \
    --arg TunnelSecret $CF_TUNNEL_SECRET \
    --arg TunnelID $CF_TUNNEL_ID \
    '{$AccountTag, $TunnelSecret, $TunnelID}' >$creds
or exit 1
chmod 600 $creds

set -l config $handle/config.yml
echo "tunnel: $CF_TUNNEL_ID
credentials-file: $creds
ingress:
  - hostname: $CF_TUNNEL_HOSTNAME
    service: http://127.0.0.1:9223
  - service: http_status:404
" >$config

# Pré-créer AVANT tail -F : si le fichier n'existe pas, le poll initial peut
# manquer le fichier et ne jamais s'y rattacher.
touch $handle/stdout $handle/stderr

# Followers (orphans quand ce script exit ; SIGPIPE quand AWS DF coupe).
tail -F -n 0 $handle/stdout &
tail -F -n 0 $handle/stderr >&2 &

echo $fish_pid >$handle/pid
cloudflared tunnel --config $config --no-autoupdate run \
    --credentials-file $creds \
    </dev/null >$handle/stdout 2>$handle/stderr
