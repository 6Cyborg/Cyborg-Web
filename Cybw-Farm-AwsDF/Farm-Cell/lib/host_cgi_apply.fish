#!/usr/bin/env fish

# Envoie la config à appliqué à l'appareil et vérifie que cyborg soit prêt.

source ./vendor/log.fish
set -lx log_registry HostCgiApply

function host_cgi_apply -a config_json
    set response (curl -s --max-time 120 \
	    --json $config_json \
	    "$host_endpoint/host-android/apply-provision")

    if not echo $response | jq -e '.ok' >/dev/null
        llwar "config endpoint unsucceed and replied: $(llcode $response)"
        exit 1
    end
end

function probe_cyborg
    # Attend que la data plane cyborg ait une page prête (status 200 + page:true)
    set -l deadline (math (date +%s) + 30)
    while true
        if curl -s --max-time 10 "$host_endpoint/cyborg/status" | jq -e '.page == true' >/dev/null
            break
        end

        if test (date +%s) -ge $deadline
            return 1
        end

        sleep 0.5
    end
end

llwait "submitting provision"
host_cgi_apply $argv[1]; or exit (llerr -e1 "apply config cgi failed")

llwait "probing cyborg"
probe_cyborg; or exit (llerr -e1 "cyborg not reacheable before deadline")
