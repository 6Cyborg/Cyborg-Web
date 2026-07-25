#!/usr/bin/env fish

set -gx CYBW_HOME (status filename | path resolve | path dirname)
fish_add_path -ga $CYBW_HOME/bin
set -a fish_complete_path $CYBW_HOME/completions
