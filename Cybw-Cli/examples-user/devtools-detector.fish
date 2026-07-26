#!/usr/bin/env fish
# Quick demo:
# 1. open devtools-detector demo
# 2. snap
# 3. click crash checkbox 10 times with growing back-off
# 4. snap

set -lx log_registry DevtoolsDetector

# L'ancien targ avait 2 locators ordonnés (input[type=checkbox]#crash puis #crash) ;
# sans fallback ordonné dans la nouvelle API, on les regroupe en OR CSS (virgule).
set -l crash_checkbox -e 'input[type="checkbox"]#crash, #crash'

function _last_snap --on-event fish_exit
    test -n "$CYB_URL"; and cybw snap
end

cybw visit "https://blog.aepkill.com/demos/devtools-detector/"
llinf "navigated"

cybw all -- $crash_checkbox; or exit 5
cybw snap
llinf "snap n°1"

for act in (seq 10)
    cybw tap $crash_checkbox
    llinf "checked checkbox - $act"
    sleep $act
end

cybw snap
llinf "snap n°2"
