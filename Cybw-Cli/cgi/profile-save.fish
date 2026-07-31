#!/usr/bin/env fish
# Sauvegarde les données de navigateur (universel).

set -lx log_registry CybwProfileSave

source ./lib/transport.fish
__cyb_op_init; or exit 1

argparse -X0 -- $argv; or exit (llerr -e2 "usage: cybw profile-save")

# Télécharge les données
if not _cyb_op profile-save
    exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYBW_ERR)) — trace: $(llcode $CYBW_CALL)")
end

cp -r $_CYBW_RESP/cookies.json $CYB_DIR

set -q CYBW_TRACE; and llinf "profile sauvegardé"
exit 0
