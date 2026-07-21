#!/usr/bin/env fish

source ./vendor/log.fish
set -lx log_registry "DfWaitJob"

argparse "T/max-time=" "f/run-arn=" -- $argv
and test -n $_flag_run_arn
or exit (llerr -e2 "bad usage")

test -z "$_flag_max_time"; and set -l _flag_max_time 30

set -l deadline (math (date +%s) + $_flag_max_time)
set -l attempt 0
while set (math $attempt + 1)
    if test (date +%s) -gt $deadline
        exit 11
    end
    
    if test (math $attempt % 3) -gt 1
        llwait "still waiting for job"
    end
       
    if aws devicefarm list-jobs --arn $aws_run_arn | jq -er '.jobs[0].arn' 2>/dev/null
        break
    end
end
