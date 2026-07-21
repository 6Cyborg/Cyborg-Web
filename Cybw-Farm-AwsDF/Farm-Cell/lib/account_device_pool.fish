#!/usr/bin/env fish

# Résout (lazy) le device-pool STATIQUE qui épingle UN téléphone précis, et le
# mémorise dans l'account file.
#
#   account_device_pool.fish <account_file> <device_name> <device_os>  →  <pool_arn>
#
# Désignation par (name, os) : seule clé unique sur AWS DF — `name` seul ne l'est
# pas (certains modèles existent en plusieurs versions d'OS, ex. Pixel 7 en 13 et
# 14). Device introuvable ⇒ ERREUR DURE, jamais de fallback sur un autre tél : on
# respecte exactement la demande de l'utilisateur.
#
# Cache : `account_file.static_pools[<deviceArn>] = <poolArn>` (les pools sont
# liés au projet DF du compte). Miss ⇒ create-device-pool + réécriture du fichier.
#
# Pré-requis env : creds AWS + CYB_PROJECT (déjà exportés par cyb-awsdf-launch).
# CWD « compatible » : ./vendor/log.fish doit résoudre.

source ./vendor/log.fish
set -lx log_registry AccountDevicePool

set -l account_file $argv[1]
set -l device_name $argv[2]
set -l device_os $argv[3]

test -n "$account_file" -a -f "$account_file"
and test -n "$device_name" -a -n "$device_os"
or exit (llerr -e2 "usage: account_device_pool.fish <account_file> <name> <os>")

# (name, os) → deviceArn. Erreur dure si introuvable.
set -l device_arn (aws devicefarm list-devices | jq -re \
    --arg n "$device_name" --arg o "$device_os" \
    'first(.devices[] | select(.platform=="ANDROID" and .name==$n and .os==$o) | .arn) // empty')
or exit (llerr -e1 "device introuvable : $(llcode "$device_name / Android $device_os")")

# Cache hit ?
set -l cached (jq -re --arg a "$device_arn" '.static_pools[$a] // empty' <$account_file)
if test -n "$cached"
    echo $cached
    exit 0
end

# Miss → pool statique (1 device, règle ARN IN). Pas de --max-devices : AWS le
# refuse sur un pool statique (ArgumentException), c'est réservé aux dynamiques.
llwait "création du pool statique pour $(llcode "$device_name / Android $device_os")"
set -l rules (jq -nc --arg a "$device_arn" '[{attribute:"ARN", operator:"IN", value:([$a] | tojson)}]')
set -l pool_arn (aws devicefarm create-device-pool \
    --project-arn $CYB_PROJECT \
    --name "cyb-static-$device_os-"(string sub -s -8 -- $device_arn) \
    --rules $rules | jq -re '.devicePool.arn')
or exit (llerr -e1 "create-device-pool échoué [$status]")

# Réécriture atomique de l'account file.
set -l tmp (mktemp)
jq --arg a "$device_arn" --arg p "$pool_arn" '.static_pools[$a] = $p' <$account_file >$tmp
and mv $tmp $account_file
or exit (llerr -e1 "réécriture account file échouée [$status]")

llinf "pool statique: $(llcode $pool_arn)"

echo $pool_arn
