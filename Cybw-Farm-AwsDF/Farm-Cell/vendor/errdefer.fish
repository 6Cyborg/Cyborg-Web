#!/usr/bin/env fish
#
# # Example:
# set instance_id (aws ec2 start-instance)
#
# # errdefer: evaluated on exit
# errdefer "aws ec2 stop-instance --instance-id $instance_id"
#
# curl payload.icu
# or exit 1
# 
# # noerr: previous and further `errdefer` are no-op
# noerr

set -g __errdefer
set -g __errdefer_noop 0

# Fonctions utilisateurs:
function errdefer -a shell_cmd -d "enregistre une commande à éxécuter à fish_exit"
    set -ga __errdefer $shell_cmd
end
function noerr -d "les commandes enregistées ne seront pas éxécutées."
    set -g __errdefer_noop 1
end

function errdefer_eval
    test $__errdefer_noop -eq 1 ; and return 0
    test (count $__errdefer) -eq 0 ; and return 0

    echo " *** Cleaning-up $(count $__errdefer) actions..." >&2
    for idx in (seq (count $__errdefer) -1 1)
        printf '\tCleaning N°%d\t%s\n' $idx $__errdefer[$idx] >&2

        eval $__errdefer[$idx]
        and printf '\tDone Cleaning N°%d\t%s\n' $idx $__errdefer[$idx] >&2
        or  printf '\tFail Cleaning N°%d\t%s\n' $idx $__errdefer[$idx] >&2
    end
    set -g __errdefer
end

function errdefer_on_exit --on-event fish_exit
    errdefer_eval
end
function errdefer_on_sigint --on-signal SIGINT
    exit 130
end
function errdefer_on_sigterm --on-signal SIGTERM
    exit 143
end

