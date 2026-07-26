#!/usr/bin/env fish
# Tape sur la checkbox officielle reCAPTCHA puis le traite jusqu'au succès.
#   normal.fish ['<outcome-supplémentaire>' …]
# L'outcome par défaut est la coche verte (success).

set -lx log_registry CybRecapV2

set -l CYB_RV2_HOME (status filename | path resolve | path dirname)
source $CYB_RV2_HOME/selectors.fish

# ENTRÉE : coche la checkbox officielle (cybw tap n'attend pas -> `all` d'abord).
cybw all $rc_checkbox; or exit 1
cybw tap $rc_checkbox

# MILIEU + SORTIE : traite le popup éventuel ; sortie = coche verte (outcome 0).
$CYB_RV2_HOME/recaptcha.fish $rc_success $argv
