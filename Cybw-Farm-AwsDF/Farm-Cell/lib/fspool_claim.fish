#!/usr/bin/env fish

# Claim atomique d'un slot dans pool-tunnels/ via mkdir. Pas de détection de
# stale lock : un slot tenu par un process mort reste claimed jusqu'à cleanup
# manuel (rm -rf <tunnel_file>.lock). Cas P99 assumé.
#
#   fspool_claim.fish POOL_DIR OWNER_PID
#
# Stdout : <tunnel_file> (path du slot .json claimé) sur succès.
# Exit   : 0 ok ; 1 pool exhausted ; 2 usage.

source ./vendor/log.fish
set -lx log_registry FsPoolClaim

set -l pool_dir $argv[1]
set -l owner_pid $argv[2]

if test -z "$pool_dir" -o -z "$owner_pid"
    exit (llerr -e 2 "usage: fspool_claim.fish POOL_DIR OWNER_PID")
else if not test -d $pool_dir
    exit (llerr -e 2 "pool dir not found: $pool_dir")
end

for tunnel_file in $pool_dir/*.json
    if mkdir $tunnel_file.lock 2>/dev/null
        echo $owner_pid >$tunnel_file.lock/pid
        echo $tunnel_file
        exit 0
    end
end

exit (llerr -e 1 "tunnel pool exhausted in $pool_dir")
