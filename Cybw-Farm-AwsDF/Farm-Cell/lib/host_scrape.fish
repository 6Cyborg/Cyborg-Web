#!/usr/bin/env fish

source ./vendor/log.fish
set -lx log_registry ScrapeHost

set -g run_arn $argv[1]
test -n "$run_arn"; or exit 2

# Fenêtre d'attente : argv[2] (défaut 60s). cyb-awsdf-launch passe ~180s
# pour absorber le PENDING d'AWS (recherche de téléphone) quand les slots du
# compte sont pleins.
set -l max_secs $argv[2]
test -n "$max_secs"
or set max_secs 60

set -l deadline (math (date +%s) + $max_secs)
set -l attempt 0
set -g job_arn
set -g host_endpoint

function _get_job
    # pas skip pour vérifier le job result
    # test -n "$job_arn"; and return 0

    set -l job (aws devicefarm list-jobs --arn $run_arn | jq -erc '.jobs[0]' 2>/dev/null)
    or return (llwait -e1 "job not yet visible")
    
    set -l job_result (echo $job | jq -re '.result')
    and test $job_result = PENDING
    or return (llerr -e1 "job stopped: $(llcode $job)")
    
    set -g job_arn (echo $job | jq -re '.arn')
    or return (llerr -e1 "job has no arn: $(llcode $job)")
end

function _scrape
    test -n "$host_endpoint"; and return 0

    # Récupère l'URL de chaque logs
    set -l file_count 0
    for arn in $run_arn $job_arn
        set -l url (aws devicefarm list-artifacts --arn "$arn" --type FILE |
            jq -re '.artifacts[] | select(.type=="TESTSPEC_OUTPUT") | .url')
        or continue
        set file_count (math "$file_count + 1")

        set -g host_endpoint (curl -s $url | rg --text -m1 -or '$1' 'endpoint_url=(http[s]?://\S+)')
        and return 0
    end

    set -l files_plural s
    test $file_count -eq 1; and set files_plural ""

    return (llwait -e 1 "endpoint not yet found across $file_count file$files_plural")
end

function _probe
    curl -s $host_endpoint/host-android/probe-caddy | rg -q "Caddy has health"
    or return (llwait -e1 "host not yet healthy (caddy)")

    curl -s $host_endpoint/host-android/probe-busybox | rg -q "Busybox has health"
    or return (llwait -e1 "host not yet healthy (busybox)")

    # NOTE: L'endpoint cyborg sera probe à l'apply-config.
end

while set attempt (math $attempt + 1)
    if test (date +%s) -gt $deadline
        exit 11
    end

    sleep 0.2

    _get_job; or continue
    _scrape; or continue
    _probe; or continue

    echo $host_endpoint
    break
end
