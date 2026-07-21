#!/usr/bin/env fish

set -l proxy $argv[1]

set -q GOST_PORT; or set -lx GOST_PORT 8889

set -l gost_args -L "http://:$GOST_PORT"
if test -n "$proxy"
    set -a gost_args -F $proxy
end

# pkill -x = match exact du nom du binaire (pas de match sur cmdline).
pkill -x -KILL gost 2>/dev/null

echo "[gost] starting with $gost_args" >&2
gost $gost_args </dev/null 2>/dev/null
