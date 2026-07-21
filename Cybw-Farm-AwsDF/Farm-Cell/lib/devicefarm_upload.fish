#!/usr/bin/env fish

# Créé un upload DeviceFarm (multipart), pousse le contenu lu sur STDIN, et
# attend que le tracking passe SUCCEEDED.
#
#   devicefarm_upload.fish --project-arn ARN --name NAME --type TYPE \
#       --content-type CT <contenu
#
# Stdout : <upload_arn> sur succès.

source ./vendor/log.fish
set -lx log_registry "DfUpload"

argparse --name=devicefarm_upload \
	'project-arn=' \
	'name=' \
	'type=' \
	'content-type=' \
	-- $argv
or exit 2

# Créer l'upload multipart
set -l handle (aws devicefarm create-upload \
	--project-arn $_flag_project_arn \
	--name $_flag_name \
	--type $_flag_type \
	--content-type $_flag_content_type)
and set -l upload_arn (echo $handle | jq -re '.upload.arn')
and set -l upload_url (echo $handle | jq -re '.upload.url')
or exit (llerr -e $status "create upload failed")

# Upload en une seule partie (lit le contenu sur stdin)
curl -sf $upload_url -o/dev/stderr \
	-X PUT -H "Content-Type: $_flag_content_type" --data-binary @-
or exit (llerr -e $status "upload file failed")

set -l post_deadline (math (date +%s) + 10)
while true
	# nsm l'handle deviens orphelin
	test (date +%s) -gt $post_deadline
	and exit (llerr -e 1 "deadline elapsed")

	sleep 1

	set -l upload_tracking (aws devicefarm get-upload --arn $upload_arn)
	and set -l upload_status (echo $upload_tracking | jq -re .upload.status)
	or llwar -e1 "track upload failed [$status]"
	or continue

	switch $upload_status
		case SUCCEEDED
			echo $upload_arn
			exit 0
		case FAILED
		 llerr "upload ended with failure: $(echo $upload_tracking | jq -Cc)"
			exit 1
		case '*'
		 llwait "upload not yet finished: $upload_status"
			continue
	end
end
