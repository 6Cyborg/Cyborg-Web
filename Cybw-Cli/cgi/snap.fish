#!/usr/bin/env fish
# capture page+frames+screenshot+har dans $CYB_DIR/snaps/<NNNN>. POST /snap.
set -lx log_registry CybSnap
__cyb_op_init; or exit 1

argparse v/verbose -- $argv; or exit (llerr -e2 "bad usage")


_cyb_op snap 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $(llcode (cat $_CYB_ERR))")

# NNNN alloué atomiquement (mkdir échoue si déjà pris → pas de race entre snaps //)
mkdir -p $CYB_DIR/snaps
set -l n (math (ls $CYB_DIR/snaps/ | count) + 1)
set -l snap_dir
while true
    set snap_dir $CYB_DIR/snaps/(string pad -c0 -w4 -- $n)
    mkdir $snap_dir 2>/dev/null; and break
    set n (math $n + 1)
end
mv $_CYB_RESP/* $snap_dir/

set -q _flag_verbose; and echo $snap_dir
set -q CYBTRACE; and llinf "snappé $(llcode $snap_dir)"
exit 0
