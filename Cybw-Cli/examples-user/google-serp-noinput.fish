#!/usr/bin/env fish
# Quick demo to check ranking on a Google query (URL-based, no input).

set -lx log_registry GoogleSerpNoinput

set -l serp_list_item -e '#rso[data-async-context^="query:"] > div > div'

function _last_snap --on-event fish_exit
    test -n "$CYB_URL"; and cybw snap
end

cybw visit "https://google.com/search?q=johnny+dang"
time cybw race -- $serp_list_item
