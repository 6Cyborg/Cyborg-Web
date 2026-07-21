#!/usr/bin/env fish

# Serveur CGI sur :9224b… non, :9225 (le data plane Python tient :9224). Caddy
# reverse-proxy `/host-android/apply-provision` (et `/host-android/probe-busybox`)
# → ici. Busybox httpd fork-exec les
# scripts `cgi/*.fish` (cf. httpd.conf : `*.fish:/tmp/bin/fish`).
#
# Bind localhost-only ; pas d'auth — Caddy est le seul reachable.

busybox httpd -f -p 127.0.0.1:9225 -h . -c httpd.conf </dev/null
