#!/usr/bin/env fish
# Tape sur le bouton qui déclenche reCAPTCHA v2 invisible puis le traite.
#   invisible.fish '<btn>' '<outcome1>' '<outcome2>' …
# Sortie = celle de recaptcha.fish (index 0-based de l'outcome gagnant + hits).

set -lx log_registry CybRecapV2

set -l CYB_RV2_HOME (status filename | path resolve | path dirname)
source $CYB_RV2_HOME/selectors.fish

# Bouton = 1er positionnel, outcomes = le reste (validé par -N2).
argparse -N2 -- $argv; or exit (llerr -e2 "usage: invisible.fish <btn> <outcome>...")
set -l btn $argv[1]
set -l outcomes $argv[2..-1]

# reCAPTCHA lazy-loadé à la 1re interaction (fill/checkbox par l'appelant AVANT) :
# on attend l'iframe api2/anchor = widget chargé, execute() prêt.
cybw all $rc_loaded; or exit 1
# ENTRÉE : déclenche l'évaluation (pass silencieux OU popup challenge).
cybw tap $btn

# MILIEU + SORTIE : traite le popup éventuel et race les outcomes du site.
$CYB_RV2_HOME/recaptcha.fish $outcomes
