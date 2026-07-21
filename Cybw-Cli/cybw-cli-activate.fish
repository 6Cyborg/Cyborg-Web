#!/usr/bin/env fish

# Obtient le path vers le script en dur.
# `path resolve` va suivre les symlinks.
set -l activate_path (path resolve -- (status filename))

set -gx CYB_HOME (path dirname -- $activate_path)
set -a PATH $CYB_HOME/bin

# Complétions cybw (tab-complétion). fish-lsp se base sur le PATH, pas là-dessus.
set -a fish_complete_path $CYB_HOME/completions

# ──────────────────────────────────────────────────────────────────────────────
# Cyb Transport — lib commune des commandes `cyb <sub>`.
#
# Modèle façon curl : __cyb_op_init crée le handle (dans l'env → un seul handle
# par shell), on stage le contenu dans $_CYB_REQ, puis _cyb_op exécute.
#
# C'est le modèle « 1 commande = 1 process » qui rend `cyb_net … & ; wait`
# réellement concurrent : backgrounder une *fonction* fish se sérialise, seul un
# command externe forke. Conséquence : les buffers scratch sont keyés sur
# $fish_pid → chaque process a les siens → N commandes en // ne se clobberent pas.
#
# Contrat de sortie (= équivalent Promise.allSettled via `cyb_x … >fichier &`) :
#   succès ⇒ la VALEUR sur stdout ; échec ⇒ stdout VIDE (diagnostic sur stderr).
#
# Buffers fixes sous $CYB_CALL = $CYB_DIR/call-$fish_pid (privés au
# process, jamais GC'd → un résultat reste lisible via le path retourné sans
# recopie, y compris pour cyb_all/cyb_race qui appellent cyb_query en sous-main) :
#   .req/  .req.tar    staging + archive uploadée à curl.
#   .resp/ .resp.tar   archive de réponse + extraction.
#   .err               stderr du dernier _cyb_op (lu seulement si non-zero).
# Les résultats persistants (listen/, blobs/, snaps/, .locators/) restent sous
# $CYB_DIR avec des noms uniques.
#
# Sourcer ce fichier ne fait QUE définir des fonctions : les pré-requis
# ($CYB_DIR / $CYB_URL exportés par le launcher, ex. cyb-awsdf-launch.fish de
# Cybw-Farm-AwsDeviceFarm) ne sont vérifiés qu'à l'appel de __cyb_op_init.
# ──────────────────────────────────────────────────────────────────────────────

function __cyb_op_init -d "vérifie les pré-requis et (re)génère les buffers du process courant"
    which curl tar >/dev/null
    and set -q CYB_DIR
    and set -q CYB_URL
    or return 2

    # pour le parallélisme, il faut séparé le dossier de travail de chaque tâche :
    set -gx CYB_CALL $CYB_DIR/call-$fish_pid

    set -gx _CYB_REQ $CYB_CALL/.req
    set -gx _CYB_RESP $CYB_CALL/.resp
    set -gx _CYB_ERR $CYB_CALL/.err

    mkdir -p $_CYB_REQ
end

function _cyb_op -a name
    # Succès/échec décidé par le code HTTP, PAS par sniffing mime : `file` ne
    # sait pas reconnaître un tar VIDE (10240 octets de zéros, aucun en-tête de
    # membre — la réponse normale de visit/fill/select/set-profile), et une
    # erreur Quart générée (413/500) est du text/html. L'ancien switch mime
    # laissait ces deux cas tomber en fallthrough silencieux → return 0.
    # Erreur serveur ⇒ corps émis BRUT sur stderr : l'appelant le capture via
    # `2>$_CYB_ERR` et l'embarque dans son llerr `op failed: …`.
    set -l req_pack $_CYB_REQ".tar"
    set -l resp_pack $_CYB_RESP".tar"

    tar -c -C $_CYB_REQ -f $req_pack .

    set -l http_code (curl -s -X POST \
        -H "Content-Type: application/x-tar" --data-binary @- \
        -H "Accept: application/x-tar" -o $resp_pack \
        -w "%{http_code}" \
        "$CYB_URL/$name" <$req_pack)
    or return (llerr -e1 "execute request failed [$status]")

    if not string match -qr '^2' $http_code
        jq -Rs <$resp_pack >&2
        return 1
    end

    mkdir -p $_CYB_RESP
    tar -xf $resp_pack -C $_CYB_RESP
    or return (llerr -e1 "bad response payload [$http_code] at $resp_pack")
end

# ─── helpers d'attente (partagés par cyb_all / cyb_none / cyb_race) ───────────
# État global = OK : chaque waiter est son propre process (cf. test 5-vs-3).

function __cyb_retry_reset -d "ouvre une session d'attente ; renvoie un handle aléatoire."
    set -q cyb_retry_T
    or return (llerr -e2 "no timeout defined")

    set -q cyb_retry_s
    and set -g __cyb_retry_silent 1

    set -g __cyb_retry_deadline (math (date +%s) + $cyb_retry_T)
    set -g __cyb_retry_attempt 1

    set -g __cyb_retry_title "$argv"
    set -g __cyb_retry_handle (random 100000000 999999999)

    echo $__cyb_retry_handle
end

function __cyb_retry_tick -d "fin de tour d'attente : échoue à T-0, sinon log périodique + sleep 0.2."
    set -l rh $argv[1]

    test "$rh" = "$__cyb_retry_handle"
    or return (llerr -e1 "retry handle incohérent : $rh != $__cyb_retry_handle")

    set -l countdown (math $__cyb_retry_deadline - (date +%s))

    # timed-out :
    if test $countdown -lt 1
        return (llerr -e1 "T-0 for $(llcode $__cyb_retry_title)")
    end

    # scheduled logs (sauf en mode silencieux) :
    if test (math $__cyb_retry_attempt % 10) -eq 0;
       and not set -q __cyb_retry_silent
        llwait "T-$countdown for $(llcode $__cyb_retry_title) #$__cyb_retry_attempt"
    end

    # attempt démarre à 1
    if test $__cyb_retry_attempt -ne 1
        sleep 0.2
    end

    set -g __cyb_retry_attempt (math $__cyb_retry_attempt + 1)
end
