#!/usr/bin/env fish
# Quick demo to check ranking on a Google query.

set -lx log_registry GoogleSerp

set -l here (status dirname)

function _last_snap --on-event fish_exit
    test -n "$CYB_URL"; and cybw snap
end

cybw visit "https://google.com"
cybw all $here/google-serp/index_searchbox
cybw snap
llinf "index ready"

cybw input -t "vendeur de glaces" $here/google-serp/index_searchbox
# TODO: pas d'API cybw keys → submit via Enter impossible pour l'instant.
# cybw keys Enter
llinf "query filled (submit pending cybw keys API)"

cybw all $here/google-serp/serp_list_item
cybw snap
llinf "serp ready"
