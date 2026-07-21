#!/usr/bin/env fish

# Provisionne UN tunnel Cloudflare (locally-managed) + son DNS record CNAME.
# Le nom du sous-domaine est aléatoire (`abr-cell-<8alpha>.<zone>`), idempotence
# laissée à l'appelant (relancer = un slot de plus).
#
# Pure curl. Pas de `cloudflared tunnel login`, pas de `~/.cloudflared`.
#
# Args : (rien)
# Stdout (success) : payload JSON compact du slot (aussi écrit sur disque).
# Disk  : pool-tunnels/<hostname>.json (chmod 600).

source ./vendor/errdefer.fish
source ./vendor/log.fish
set -lx log_registry "ProvisionTunnel"

test -f cfg-tunnel.json
and set -lx CF_API_TOKEN (jq -re '.cf_api_token' <cfg-tunnel.json)
and set -lx CF_ACCOUNT_ID (jq -re '.cf_account_id' <cfg-tunnel.json)
and set -lx CF_ZONE_ID (jq -re '.cf_zone_id' <cfg-tunnel.json)
and set -lx CF_ZONE_NAME (jq -re '.cf_zone_name' <cfg-tunnel.json)
or exit (llerr -e1 "bad cfg-tunnel.json [$status]")

set -lx CF_API_ENDPOINT "https://api.cloudflare.com/client/v4"
set -lx H_CF_AUTH "Authorization: Bearer $CF_API_TOKEN"

function random_subdomain
	set -l seed (tr -dc '[:lower:]' </dev/urandom | head -c 8)
	echo "abr-cell-$seed"
end

# Required token permission: Account → Cloudflare One Connectors → Write
# Doc: https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/methods/create/
function cf_create_tunnel -a tunnel_name tunnel_secret
	set -l req_body (jq -nc \
		--arg name $tunnel_name \
		--arg tunnel_secret $tunnel_secret \
		'{ $name, $tunnel_secret, config_src: "local" }')
	curl -sf --max-time 15 -H $H_CF_AUTH --json "$req_body" \
		"$CF_API_ENDPOINT/accounts/$CF_ACCOUNT_ID/cfd_tunnel" |
		jq -re '.result.id'
end

# Required token permission: Account → Cloudflare One Connectors → Write
# Doc: https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/methods/delete/
function cf_delete_tunnel -a tunnel_uuid
	curl -sf --max-time 15 -X DELETE -H $H_CF_AUTH \
		"$CF_API_ENDPOINT/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_uuid" |
		jq -ce 'select(.success==true)' >/dev/null
end

# Required token permission: Zone → DNS → Write
# Doc: https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/create/
function cf_create_tunnel_dns_record -a tunnel_hostname tunnel_uuid
	set -l req_body (jq -nc \
		--arg name $tunnel_hostname \
		--arg content "$tunnel_uuid.cfargotunnel.com" \
		'{ $name, $content, type: "CNAME", proxied: true, ttl: 1 }')
	curl -sf --max-time 10 -H $H_CF_AUTH --json "$req_body" \
		"$CF_API_ENDPOINT/zones/$CF_ZONE_ID/dns_records" |
		jq -re '.result.id'
end

set -l tunnel_hostname "$(random_subdomain).$CF_ZONE_NAME"
llinf "reserving $tunnel_hostname in account $CF_ACCOUNT_ID and zone $CF_ZONE_ID"

# 32 bytes aléatoires encodés base64 (format attendu par Cloudflare).
set -l tunnel_secret (openssl rand -base64 32)
or exit (llerr -e 1 "openssl failed [$status]")
llinf "with tunnel secret: $tunnel_secret"

set -l tunnel_uuid (cf_create_tunnel $tunnel_hostname $tunnel_secret)
or exit (llerr -e 1 "cf create tunnel failed [$status]")
errdefer "cf_delete_tunnel $tunnel_uuid"
llinf "issued tunnel uuid: $tunnel_uuid"

set -l dns_record_id (cf_create_tunnel_dns_record $tunnel_hostname $tunnel_uuid)
or exit (llerr -e 1 "cf create tunnel dns record failed [$status]")
llinf "issued tunnel dns record: $dns_record_id"

set -l out_file pool-tunnels/$tunnel_hostname.json
mkdir -p (dirname $out_file)
jq -nc \
	--arg tunnel_hostname $tunnel_hostname \
	--arg tunnel_uuid $tunnel_uuid \
	--arg tunnel_secret $tunnel_secret \
	--arg dns_record_id $dns_record_id \
	--arg api_token $CF_API_TOKEN \
	--arg account_id $CF_ACCOUNT_ID \
	--arg zone_name $CF_ZONE_NAME \
	--arg zone_id $CF_ZONE_ID \
	'{ $tunnel_hostname, $tunnel_uuid, $tunnel_secret, $dns_record_id, $api_token,
	$account_id, $zone_name, $zone_id }' >$out_file
or exit (llerr -e 1 "failed to write tunnel file [$status]")
chmod 600 $out_file

cat $out_file
noerr
