#!/usr/bin/env fish
#
# gologin-profile-gen.fish <accesstoken> [os]
#
# Créer puis sauvegarde un nouveau profile rapide.

which jq curl; or exit 2

set -g log_registry cyb-gen

set -l token $argv[1]
set -l os lin

set -l script_dir (status filename | path resolve | path dirname)
set -l output_dir $script_dir/dat-fp/(uuidgen -7)
mkdir -p $output_dir

echo $token >$output_dir/arg_token
echo $os >$output_dir/arg_os
llwait "création puis sauvegarde d'un nouveau fingerprint dans $(llcode $output_dir)"

# --- 1) Nouveau profile
# llwait "création d'un profile"
# 
# curl "https://api.gologin.com/browser/quick" \
#     -o $output_dir/api_quick_profile \
#     --json (jq -nc --arg os "$os" '{$os, osSpec:"", name:"api-generated"}') \
#     -H "Authorization: Bearer $token" \
#     -H "User-Agent: gologin-api" -s --fail-with-body
# or exit (llerr -e1 "profile rapide pas créer")
# 
# set -l id (jq -re '.id' <$output_dir/api_quick_profile)
# or exit (llerr -e1 "profile rapide créer mais sans ID")
# 
# llinf "profil créé : $(llcode $id)"
# FIXME : /browser/quick créer la dernière version sauf qu'elle a besoin de license. 

set -l id 6a4cf939552fd0a1a75c5d81

# --- 2) info-for-run (GET, fidèle gologin.py:416) ----------------------------
llwait "téléchargement du fingerprint"

curl "https://api.gologin.com/browser/features/$id/info-for-run" \
    -o $output_dir/$id.json \
    -H "Authorization: Bearer $token" \
    -H "User-Agent: Selenium-API" -s --fail-with-body
or exit (llerr -e1 "fingerprint pas obtenu")

llinf "fingerprint obtenu !"

# Le token de licence Orbita (3 min) n'est PAS récupéré ici : il expire trop
# vite. C'est launch qui en émet un frais à chaque démarrage, via l'access
# token longue durée conservé dans arg_token.

# --- 3) Sanity check
if not set -l data (./parse-profile.fish $output_dir/$id.json)
    exit (llerr -e1 "fingerprint non désérialisable")
end

echo $data | jq >&2

