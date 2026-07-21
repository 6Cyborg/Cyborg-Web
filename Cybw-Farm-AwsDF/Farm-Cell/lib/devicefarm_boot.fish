#!/usr/bin/env fish

source ./vendor/log.fish

# jobTimeoutMinutes = plafond DUR du run = backstop si le client ne `stop-run`
# jamais (ex. OOM). Défaut 150 si non défini ; cyb-awsdf-launch le met bas
# (≈20) car pas de watchdog device-side.
# ⚠️ plafonne AUSSI la durée max d'une session légitime.
set -q CYB_JOB_TIMEOUT_MIN
or set -lx CYB_JOB_TIMEOUT_MIN 150

function choose_network_profile
    set -l desired_name "WiFi Good"

    set -l catalog (aws devicefarm list-network-profiles --arn $CYB_PROJECT)
    or return (llerr -e1 "network profile catalog unavailable")

    echo $catalog | jq -e -r \
        --arg desired_name $desired_name \
        '.networkProfiles[] | select(.name==$desired_name) | .arn'
    or return (llerr -e1 "network profile not found")
end

set -l network_profile_arn (choose_network_profile)

set -l test_script (jq -nc \
	--arg testPackageArn "$CYB_TESTPKG_ANDROID" \
	--arg testSpecArn "$CYB_TESTSPEC_ANDROID" \
	'{
		type: "APPIUM_NODE",
		$testPackageArn, $testSpecArn,
		parameters: { bluetooth: "true", gps: "true", nfc: "true", wifi: "true" }
	}')

set -l device_configuration (jq -nc \
	--arg networkProfileArn "$network_profile_arn" \
	'{
		$networkProfileArn,
		locale: "en_US",
		customerArtifactPaths: { deviceHostPaths: ["$WORKING_DIRECTORY"] },
		billingMethod: "METERED",
		radios: { bluetooth: true, gps: true, nfc: true, wifi: true }
	}')

set -l execution_configuration (jq -nc --argjson t $CYB_JOB_TIMEOUT_MIN \
    '{videoCapture:true, skipAppResign:false, jobTimeoutMinutes:$t}')

# Pool à utiliser : CYB_POOL_ANDROID si défini (pool statique épinglant un device
# précis, résolu par cyb-awsdf-launch via account_device_pool), sinon le pool
# dynamique du compte.
set -q CYB_POOL_ANDROID; or set -lx CYB_POOL_ANDROID $CYB_DYNPOOL_ANDROID

set -l run (aws devicefarm schedule-run \
	--project-arn $CYB_PROJECT \
	--app-arn $CYB_APP_ANDROID \
	--device-pool-arn $CYB_POOL_ANDROID \
	--name "AWS_Routine" \
	--test $test_script \
	--configuration $device_configuration \
	--execution-configuration $execution_configuration)
or exit (llerr -e1 "schedule-run error [$status]")

echo $run | jq -re '.run.arn'
or exit (llerr -e1 "schedule-run returned no error [$status]")
