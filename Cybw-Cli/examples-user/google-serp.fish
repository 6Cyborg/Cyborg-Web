#!/usr/bin/env fish
# Quick demo to check ranking on a Google query.

set -lx log_registry GoogleSerp

set -l index_searchbox '\'form[action="/search"] textarea[name="q"]\''
set -l serp_list_item '\'#rso[data-async-context^="query:"] > div > div\''

function _last_snap --on-event fish_exit
    test -n "$CYB_URL"; and cybw snap
end

cybw visit "https://google.com"
cybw all $index_searchbox
cybw snap
llinf "index ready"

cybw input --text "vendeur de glaces" $index_searchbox
# TODO: pas d'API cybw keys → submit via Enter impossible pour l'instant.
# cybw keys Enter
llinf "query filled (submit pending cybw keys API)"

cybw all $serp_list_item
cybw snap
llinf "serp ready"
