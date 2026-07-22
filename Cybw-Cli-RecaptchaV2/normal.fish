#!/usr/bin/env fish
# Tape sur le bouton officiel Recaptcha puis le traite jusqu'au succès.

set -lx log_registry CybRecapV2

set -l CYB_RV2_HOME (status filename | path resolve | path dirname)
set -l ct $CYB_RV2_HOME/res-cyb

# ENTRÉE : coche la checkbox officielle (cybw tap n'attend pas -> `all` d'abord).
cybw all $ct/checkbox; or exit 1
cybw tap $ct/checkbox

# MILIEU + SORTIE : traite le popup éventuel ; sortie = coche verte (+ outcomes
# site optionnels).
$CYB_RV2_HOME/recaptcha.fish $ct/success
