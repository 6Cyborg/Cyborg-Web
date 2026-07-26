#!/usr/bin/env fish
# Tape sur le bouton qui déclenche reCAPTCHA v2 invisible puis le traite.
#   invisible.fish <btn-selector> -- <outcome1> -- <outcome2> ...
# Sortie = celle de recaptcha.fish (index 0-based de l'outcome gagnant + hits).

set -lx log_registry CybRecapV2

set -l CYB_RV2_HOME (status filename | path resolve | path dirname)
source $CYB_RV2_HOME/selectors.fish

# Sépare le bouton (avant le 1er `--`) des outcomes (après, `--`-délimités).
set -l btn
set -l outcomes
set -l after 0
for a in $argv
    if test $after -eq 1
        set -a outcomes $a
    else if test "$a" = --
        set after 1
    else
        set -a btn $a
    end
end
test -n "$btn"; and test -n "$outcomes"
or exit (llerr -e2 "usage: invisible.fish <btn> -- <outcome>...")

# reCAPTCHA lazy-loadé à la 1re interaction (fill/checkbox par l'appelant AVANT) :
# on attend l'iframe api2/anchor = widget chargé, execute() prêt.
cybw all -- $rc_loaded; or exit 1
# ENTRÉE : déclenche l'évaluation (pass silencieux OU popup challenge).
cybw tap $btn

# MILIEU + SORTIE : traite le popup éventuel et race les outcomes du site.
$CYB_RV2_HOME/recaptcha.fish $outcomes
