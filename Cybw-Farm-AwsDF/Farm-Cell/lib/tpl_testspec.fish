#!/usr/bin/env fish

# Rend le template testspec (stdin) avec les créneaux du tunnel_file (argv[1]).
#
#   tpl_testspec.fish <tunnel_file> <template.yml >rendered.yml

source ./vendor/log.fish
set -lx log_registry "TemplateTestspec"

set -l tunnel_file $argv[1]

test -n "$tunnel_file" -a -f "$tunnel_file"
and set -l cf_tunnel_hostname (jq -re .tunnel_hostname <$tunnel_file)
and set -l cf_tunnel_id (jq -re .tunnel_uuid <$tunnel_file)
and set -l cf_tunnel_secret (jq -re .tunnel_secret <$tunnel_file)
and set -l cf_account_id (jq -re .account_id <$tunnel_file)
or exit (llerr -e 2 "malformed tunnel file")

# NOTE: fish supprime les line feed! À utilisé avec précaution.
sed \
    -e "s|{{CF_TUNNEL_HOSTNAME}}|$cf_tunnel_hostname|g" \
    -e "s|{{CF_TUNNEL_ID}}|$cf_tunnel_id|g" \
    -e "s|{{CF_TUNNEL_SECRET}}|$cf_tunnel_secret|g" \
    -e "s|{{CF_ACCOUNT_ID}}|$cf_account_id|g" \
    -
