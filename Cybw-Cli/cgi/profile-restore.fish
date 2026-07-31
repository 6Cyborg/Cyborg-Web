#!/usr/bin/env fish
# Restaure les données de navigateur

set -lx log_registry CybSetProfile

source ./lib/transport.fish
__cyb_op_init; or exit 1

argparse -X0 -- $argv; or exit (llerr -e2 "usage: cybw profile-restore")

cp -r $CYB_DIR/cookies.json $_CYBW_REQ

# Met en ligne les données à restauré
if not _cyb_op profile-restore
    exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR)) — trace: $(llcode $CYBW_CALL)")
end

set -q CYBW_TRACE; and llinf "profile restauré"
exit 0
