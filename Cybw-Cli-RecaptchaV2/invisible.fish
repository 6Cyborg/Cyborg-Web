#!/usr/bin/env fish
# Tape sur le bouton qui cache Recaptcha V2 puis le traite jusqu'au succès.

set -lx log_registry CybRecapV2

set -l CYB_RV2_HOME (status filename | path resolve | path dirname)
set -l ct $CYB_RV2_HOME/res-cyb

argparse -N2 -- $argv; or exit (llerr -e2 "usage: invisible.fish <btn> <outcome>...")

set -l btn $argv[1]
set -l outcomes $argv[2..-1]

# reCAPTCHA lazy-loadé à la 1re interaction (fill/checkbox par l'appelant AVANT) :
# on attend l'iframe api2/anchor = widget chargé, execute() prêt, sinon le submit
# natif part sans token.
cybw all $ct/loaded; or exit 1
# ENTRÉE : déclenche l'évaluation (pass silencieux OU popup challenge).
cybw tap $btn

# MILIEU + SORTIE : traite le popup éventuel et race les outcomes du site.
$CYB_RV2_HOME/recaptcha.fish $outcomes
