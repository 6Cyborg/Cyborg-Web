#!/usr/bin/env fish

# Provisionne UN compte AWS DeviceFarm : crée le projet, le device-pool dynamique
# ANDROID, et écrit le slot pool-accounts/<key_id>.json consommé par
# cyb-awsdf-launch.fish.
#
# Usage : add-account.fish <aws_access_key_id> <aws_secret_access_key>

source ./vendor/errdefer.fish
source ./vendor/log.fish
set -lx log_registry "AddAccount"

test -n "$argv[1]" -a -n "$argv[2]"
or exit (llerr -e 2 "Bad Usage")

set -lx AWS_ACCESS_KEY_ID $argv[1]
set -lx AWS_SECRET_ACCESS_KEY $argv[2]
set -lx AWS_DEFAULT_REGION us-west-2
set -l project_name "AWS_Default"
set -l out_file pool-accounts/$AWS_ACCESS_KEY_ID.json

llwait "adding account to $out_file"

function df_create_device_pool_dynamic -a project platform name
	aws devicefarm create-device-pool \
		--project-arn $project \
		--name $name \
		--rules (jq -nc --arg platform "$platform" '[{ attribute: "PLATFORM", operator: "EQUALS", value: ($platform | tojson) }]') \
		--max-devices 1 |
		jq -re '.devicePool.arn'
end

# Créer le projet DeviceFarm.
set -l project (aws devicefarm create-project --name $project_name | jq -re '.project.arn')
or exit (llerr -e 1 "create project failed [$status]")
llinf "project: $project"
errdefer "aws devicefarm delete-project --arn $project | jq -c"

# ANDROID Dynamic Pool
set -l android_dyn_pool (df_create_device_pool_dynamic $project "ANDROID" "AWS_Default_Android")
or exit (llerr -e 1 "create android dyn pool failed [$status]")
llinf "android dyn pool made as $android_dyn_pool"

# ANDROID TestApp
set -l android_app "arn:aws:devicefarm:us-west-2::upload:100e31a8-12ac-11e9-ab14-d763b5a3a933"
llinf "android app is $android_app"

# NOTE: android_testpkg et android_testspec sont zip+upload à chaque bootstrap.

llwait "saving as $out_file"
mkdir -p (dirname $out_file)
jq -n \
	--arg key_id $AWS_ACCESS_KEY_ID --arg secret $AWS_SECRET_ACCESS_KEY \
	--arg project $project \
	--arg android_dyn_pool $android_dyn_pool \
	--arg android_app $android_app \
	'{ $key_id, $secret, $project, $android_dyn_pool, $android_app }' >$out_file

noerr
