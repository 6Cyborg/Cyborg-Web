#!/usr/bin/env fish
# Quick demo to check ranking on a Google query (URL-based, no input).

set -lx log_registry GoogleSerpNoinput

set -l here (status dirname)

function _last_snap --on-event fish_exit
    test -n "$CYB_URL"; and cybw snap
end

cybw visit "https://google.com/search?q=johnny+dang"
time cybw race $here/google-serp-noinput/serp_list_item
