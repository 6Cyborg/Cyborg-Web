#!/usr/bin/env fish
ls (status filename | path resolve | path dirname)/../dat-fp/*/*.json | shuf -n1
