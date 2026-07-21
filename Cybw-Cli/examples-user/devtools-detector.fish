#!/usr/bin/env fish
# Quick demo:
# 1. open devtools-detector demo
# 2. snap
# 3. click crash checkbox 10 times with growing back-off
# 4. snap

set -lx log_registry DevtoolsDetector

set -l here (status dirname)

function _last_snap --on-event fish_exit
    test -n "$CYB_URL"; and cybw snap
end

cybw visit "https://blog.aepkill.com/demos/devtools-detector/"
llinf "navigated"

cybw all $here/devtools-detector/crash_checkbox; or exit 5
cybw snap
llinf "snap n°1"

for act in (seq 10)
    cybw tap $here/devtools-detector/crash_checkbox
    llinf "checked checkbox - $act"
    sleep $act
end

cybw snap
llinf "snap n°2"
