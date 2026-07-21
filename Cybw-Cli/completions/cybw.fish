# Complétion de l'entrypoint cyb. Déclare aussi `cyb` comme commande connue
# (fish-lsp s'en sert pour ne plus signaler « cybw n'existe pas »).
complete -c cybw -f
set -l __cyb_cmds net visit js query tap select input snap cookie css all none race auto export-profile set-profile
complete -c cybw -n __fish_use_subcommand -a "$__cyb_cmds"
