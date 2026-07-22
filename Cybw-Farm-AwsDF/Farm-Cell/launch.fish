#!/usr/bin/env fish

# Launch Cyborg — entrypoint direct sur AWS Device Farm.
#
# Démarre soi-même un device DF (schedule-run → wait-job → scrape → probe),
# applique la provision, restaure l'état Chrome persistant, puis expose
# `<host>/cyborg` comme CYB_URL. Orchestrateur mince sur le layer Farm-Cell/lib/ ;
# cycle de vie source-once + fish_exit, backstop jobTimeout.
#
# **À sourcer** — le dernier argument est un DOSSIER PROFIL persistant (même
# contrat que Cybw-Local-Gologin ; générable via cyb-awsdf-profile.fish) :
#
#     source ./vendor/cyb-awsdf-launch.fish [-d 'Nom@OS'] \
#         pool-accounts/AKIA….json ./profiles/floppy-us-1
#
# CWD « compatible » requis : le seul source littéral-relatif (fish-lsp le suit)
# est `./vendor/log.fish` — l'appelant s'engage à ce qu'il résolve depuis son CWD
# (symlink vendor du projet ; les libs exécutées le sourcent). Les chemins
# compte/profil sont relatifs au CWD de l'appelant ; tout le reste (lib/ exécutés,
# Host-Android, pool-tunnels, run_archives) est résolu via $CYBAWSDF_HOME.
#
# Le profil est l'IDENTITÉ (proxy, état Chrome, géo attendue) — dossier de
# fichiers plats INDÉPENDANT du compte AWS, au contrat partagé avec
# cyb-gologin-launch.fish :
#
#   proxy                  http://user:pass@host:port — SOURCE DE VÉRITÉ du proxy
#   state.tar.xz           état Chrome persistant (cookies + localStorage)
#   run-history/<ISO>.json une trace par run (ici provider:"awsdf") — mémoire
#                          des appareils déjà utilisés par ce profil
#   app_country.txt        géo attendue (sanity non bloquant)
#   app_city.txt
#   .geo.json              tampon interne (régénéré à chaque run)
#
# L'appareil est un device DF ('Nom@OS'), pendant du fingerprint gologin. Choix :
#   1. forcé via -d/--device (pool statique) ;
#   2. sinon le dernier utilisé — .device de la trace run-history la plus
#      récente portant provider "awsdf" (pool statique) ;
#   3. sinon (profil jamais démarré avec awsdf) : pool DYNAMIQUE — AWS choisit ;
#      le device réellement attribué est relevé sur le job et mémorisé dans la
#      trace, si bien que le run suivant l'épinglera (cas 2).
#
# Aucune option proxy/country/language : le proxy vient UNIQUEMENT du profil, et
# country/language sont DÉRIVÉS de la géoloc de l'IP (geo.myip.link, routé à
# travers le proxy) — la locale du device suit donc l'IP de sortie réelle.
#
# state.tar.xz est restauré au boot s'il existe, puis ré-écrit toutes les ~60s
# (lib/profile_saver.fish) et à la fermeture (voir hook fish_exit).
#
# Effets :
#   - démarre un device AWS DF et attend qu'il soit prêt (≤ ~3 min de PENDING)
#   - exporte CYB_DIR, CYB_URL (= <host>/cyborg)
#   - la commande `cyb` (sur le PATH via cyb-activate.fish de Cybw-Client) parle
#     alors directement au device
#
# Lifecycle : le teardown « propre » se fait au fish_exit du shell qui a sourcé
# — sauvegarde finale du profil PUIS `stop-run` (arrêt immédiat, non facturé en
# limbo). Backstop si le client meurt sans release (OOM) : jobTimeoutMinutes court
# (CYB_JOB_TIMEOUT_MIN=20 ; le dernier state.tar.xz périodique est alors la reprise).
# (Pas de watchdog device-side : tuer les process laisse le run en result=PENDING
# → STOPPING facturé ~73 min ; seul stop-run est propre.)
#
# Utiliser `return` partout : `exit` tuerait ton terminal. (Sourcé sans wrapper ni
# pushd : un `return` d'erreur sort du fichier sans laisser d'état à restaurer.)

# Home Farm-Cell, résolu depuis CE script (`path resolve` suit le symlink vendor
# éventuel). -gx (pas -l) : le hook fish_exit et le saver détaché en ont besoin.
set -gx CYBAWSDF_HOME (status filename | path resolve | path dirname)

set -lx log_registry CybAwsdfLaunch

# ── Paramètres ─────────────────────────────────────────────────────────────────
argparse -N2 -X2 "d/device=" -- $argv
or return (llerr -e2 "usage: source …/cyb-awsdf-launch.fish [-d 'Nom@OS'] <account.json> <profile_dir>")

# Chemins de l'APPELANT, absolutisés contre SON CWD.
set -l account_file (path resolve -- $argv[1])

# Profil persistant. Exporté : le saver périodique et le hook fish_exit
# (sauvegarde finale) en ont besoin.
set -gx cyb_profile_dir (path resolve -- $argv[2])
test -d $cyb_profile_dir
or return (llerr -e2 "profil introuvable : $cyb_profile_dir (générer via cyb-awsdf-profile.fish)")

# Structure FS profil (contrat partagé avec cyb-gologin-launch.fish) :
set -l profile__geo_json $cyb_profile_dir/.geo.json
set -l profile_proxy_url $cyb_profile_dir/proxy
set -l profile_app_country $cyb_profile_dir/app_country.txt
set -l profile_app_city $cyb_profile_dir/app_city.txt
set -l profile_history_dir $cyb_profile_dir/run-history
set -gx cyb_profile_state $cyb_profile_dir/state.tar.xz

mkdir -p $profile_history_dir

function check_app_field -a file actual
    test -n "$actual"; or return 2
    set -l label (path basename -- $file)

    if not test -s "$file"
        llwar "No Data $label"
        return 0
    end
    set -l expected (string collect <$file)

    test "$actual" = "$expected"
    and llinf "Good $label : $(llcode $actual)"
    or llwar "mismatch $label : $(llcode $actual) au lieu de $(llcode $expected)"
end

# ── Compte AWS (exporté : le teardown au fish_exit en a besoin) ─────────────────
test -n "$account_file" -a -f "$account_file"
and set -gx AWS_DEFAULT_REGION us-west-2
and set -gx AWS_ACCESS_KEY_ID (jq -re .key_id <$account_file)
and set -gx AWS_SECRET_ACCESS_KEY (jq -re .secret <$account_file)
and set -gx CYB_PROJECT (jq -re .project <$account_file)
and set -gx CYB_APP_ANDROID (jq -re .android_app <$account_file)
and set -gx CYB_DYNPOOL_ANDROID (jq -re .android_dyn_pool <$account_file)
or return (llerr -e8 "compte malformé : $account_file [$status]")

set -q CYB_DIR; or set -gx CYB_DIR (mktemp -d -t cyb.XXXXXX)

# Pas de watchdog device-side (cf. (b)) : le jobTimeout court est le backstop
# OOM ; le client stop-run (fish_exit) gère le cas normal. ⚠️ plafonne la durée
# max d'une session.
set -gx CYB_JOB_TIMEOUT_MIN 20

# ── Proxy (uniquement depuis le profil) + géoloc de l'IP de sortie ───────────────
# country/language de la provision sont dérivés de geo.myip.link, requêté À
# TRAVERS le proxy du profil ⇒ ils reflètent l'IP réellement vue par les sites.
set -l proxy ""
set -l geo_args -s --max-time 10
if test -s $profile_proxy_url
    set proxy (string trim <$profile_proxy_url)
    set -a geo_args --proxy $proxy
end

curl https://geo.myip.link $geo_args -o $profile__geo_json
or return (llerr -e1 "la géo-localisation a échoué (proxy mort ?) [$status]")
set -l geo_country (jq -re '.country // empty' <$profile__geo_json)
or return (llerr -e1 "géo sans pays : $(llcode (string collect <$profile__geo_json))")
set -l geo_city (jq -r '.city // ""' <$profile__geo_json)
set -l geo_language (jq -r '.languages // "" | split(",")[0] | split("-")[0]' <$profile__geo_json)
test -n "$geo_language"; or set geo_language en

# Antidetect Network : la géo observée doit coller à celle attendue par le profil.
check_app_field $profile_app_country $geo_country
check_app_field $profile_app_city $geo_city

# Provision pour l'endpoint host apply-provision (attend {country, language,
# proxy}) ; proxy absent du profil ⇒ "" (pas de proxy).
set -l provision_json (jq -nc --arg c "$geo_country" --arg l "$geo_language" --arg p "$proxy" \
    '{country:$c, language:$l, proxy:$p}')

# ── Teardown au fish_exit : stop-run (arrêt propre) + backstop jobTimeout ───────
# Défini tôt : un échec en cours de launch nettoie quand même au fish_exit.
function _cybawsdf_launch_exit --on-event fish_exit
    set -l log_registry CybAwsdfLaunch

    # Kill le saver périodique, puis SAUVEGARDE FINALE du profil — on tourne
    # AVANT stop-run, donc le device est encore up et joignable. Même bloc
    # d'export atomique que profile_saver.fish. Best-effort : un échec
    # n'empêche pas le teardown AWS ci-dessous.
    test -n "$cyb_saver_pid"; and kill $cyb_saver_pid 2>/dev/null
    if test -n "$cyb_profile_state" -a -n "$CYB_URL"
        llwait "sauvegarde finale du profil"
        set -l tmp (mktemp (path dirname -- $cyb_profile_state)/.state.XXXXXX)
        if fish -c "cd $CYB_HOME; and bin/cyb export-profile $tmp" >/dev/null 2>&1
            mv -f $tmp $cyb_profile_state
            and llinf "profil sauvé → $(llcode $cyb_profile_state)"
        else
            rm -f $tmp
            llwar "sauvegarde finale du profil échouée [$status]"
        end
    end

    if test -n "$aws_run_arn"
        # Archive les logs du run. Chemin absolu via $CYBAWSDF_HOME car on tourne
        # au fish_exit (CWD = appelant).
        set -l dir $CYBAWSDF_HOME/run_archives/(uuidgen -7)
        mkdir -p $dir
        llwait "stopping run and archiving at $(llcode $dir)"
        echo -n $aws_run_arn >$dir/run_arn
        echo -n $aws_job_arn >$dir/job_arn
        set -l job_files (aws devicefarm list-artifacts --arn $aws_job_arn --type FILE | jq -e)
        curl -sLo $dir/testspec.log \
            (echo $job_files | jq '.artifacts[] | select(.type=="TESTSPEC_OUTPUT") | .url' -r)
        # NOTE: la vidéo est générée ~1 min après l'arrêt.

        aws devicefarm stop-run --arn $aws_run_arn >/dev/null
        and llinf "stopped $(llcode $aws_run_arn)"
        or llwar "stop-run failed [$status]"
    end
    test -n "$CYB_TESTSPEC_ANDROID"; and aws devicefarm delete-upload --arn $CYB_TESTSPEC_ANDROID >/dev/null 2>&1
    test -n "$CYB_TESTPKG_ANDROID"; and aws devicefarm delete-upload --arn $CYB_TESTPKG_ANDROID >/dev/null 2>&1
    test -n "$tunnel_file"; and rm -rf $tunnel_file.lock
end

# ── Choix du device ('Nom@OS') ───────────────────────────────────────────────────
# Pendant de la sélection du fingerprint gologin : forcé (-d) → dernier utilisé
# (trace run-history la plus récente, provider awsdf) → sinon pool dynamique.
# Avant tunnel/uploads : un device introuvable fail-fast sans rien allouer.
set -l traces (path filter -- $profile_history_dir/*.json | sort)
set -l awsdf_history '[]'
test (count $traces) -gt 0
and set awsdf_history (cat $traces | jq -cs 'map(select(.provider=="awsdf"))')

set -l device_slug $_flag_device
if test -z "$device_slug"
    set device_slug (echo $awsdf_history | jq -r 'last | .device // empty')
    test -n "$device_slug"
    and llinf "device du dernier run : $(llcode $device_slug)"
end

if test -n "$device_slug"
    # Résolution 'Nom@OS' → pool DF statique (split sur le DERNIER @ : le nom peut
    # contenir des espaces, jamais l'OS). Erreur dure si introuvable — on respecte
    # exactement l'appareil demandé, l'identité du profil en dépend.
    set -l parts (string split -r -m1 '@' -- $device_slug)
    test (count $parts) -eq 2 -a -n "$parts[1]" -a -n "$parts[2]"
    or return (llerr -e2 "device malformé (attendu 'Nom@OS') : $(llcode $device_slug)")
    set -gx CYB_POOL_ANDROID ($CYBAWSDF_HOME/lib/account_device_pool.fish $account_file $parts[1] $parts[2])
    or return (llerr -e1 "résolution device-pool échouée")
    llinf "device épinglé: $(llcode "$parts[1] / Android $parts[2]") → $(llcode $CYB_POOL_ANDROID)"
else
    # Profil jamais démarré avec awsdf → AWS choisit dans le pool dynamique ; le
    # device attribué sera relevé sur le job (après wait_job) et mémorisé dans la
    # trace, si bien que le prochain run l'épinglera.
    set -gx CYB_POOL_ANDROID $CYB_DYNPOOL_ANDROID
    llinf "profil sans historique awsdf → pool dynamique"
end

# ── Tunnel + uploads DeviceFarm ──────────────────────────────────────────────────
# pool-tunnels en chemin absolu ⇒ tunnel_file absolu ⇒ le hook fish_exit résout
# son .lock quel que soit le CWD.
set -gx tunnel_file ($CYBAWSDF_HOME/lib/fspool_claim.fish $CYBAWSDF_HOME/pool-tunnels $fish_pid)
or return (llerr -e4 "tunnel pool exhausted [$status]")
llinf "tunnel: $(llcode $tunnel_file)"

set -l host_dir $CYBAWSDF_HOME/../Host-Android

set -l testspec_name testspec-(tr -dc '[:lower:]' </dev/urandom | head -c 12).yaml
set -gx CYB_TESTSPEC_ANDROID ($CYBAWSDF_HOME/lib/tpl_testspec.fish $tunnel_file <$host_dir/testspec.yml | $CYBAWSDF_HOME/lib/devicefarm_upload.fish \
    --project-arn $CYB_PROJECT --name $testspec_name \
    --type APPIUM_NODE_TEST_SPEC --content-type application/x-yaml)
or return (llerr -e4 "upload testspec échoué [$status]")
llinf "testspec: $(llcode $CYB_TESTSPEC_ANDROID)"

# zip dans un sous-shell : ne bouge pas notre CWD ($host_dir est absolu).
# La runtime CDP (Cybw-RT-CDP, repo sibling) est ajoutée à la racine du
# zip (-j junk paths) : layout on-device inchangé, `./cyborg_server.py`.
fish -c "cd $host_dir; and zip -qr dist.zip * -x 'node_modules/*' dist.zip; and zip -qj dist.zip ../../Cybw-RT-CDP/*.py"
or return (llerr -e4 "zip testpkg échoué [$status]")
set -gx CYB_TESTPKG_ANDROID ($CYBAWSDF_HOME/lib/devicefarm_upload.fish --project-arn $CYB_PROJECT --name android-testpkg.zip \
    --type APPIUM_NODE_TEST_PACKAGE --content-type application/zip <$host_dir/dist.zip)
or return (llerr -e4 "upload testpkg échoué [$status]")
llinf "testpkg: $(llcode $CYB_TESTPKG_ANDROID)"

# ── Cold-start ────────────────────────────────────────────────────────────────────
# aws_run_arn exporté : wait_job le lit en global, et le teardown en a besoin.
set -gx aws_run_arn ($CYBAWSDF_HOME/lib/devicefarm_boot.fish)
or return (llerr -e1 "schedule-run échoué [$status]")
llinf "run: $(llcode $aws_run_arn)"

set -gx aws_job_arn ($CYBAWSDF_HOME/lib/devicefarm_wait_job.fish --run-arn $aws_run_arn -T180)
or return (llerr -e1 "wait job échoué [$status]")
llinf "job: $(llcode $aws_job_arn)"

# Device réellement attribué (pool dynamique) : relevé sur le job pour la trace
# run-history — c'est lui que le prochain run de ce profil épinglera.
if test -z "$device_slug"
    set device_slug (aws devicefarm get-job --arn $aws_job_arn | jq -re '.job.device | "\(.name)@\(.os)"')
    and llinf "device attribué par le pool dynamique : $(llcode $device_slug)"
    or llwar "device du job introuvable (get-job) — trace sans device [$status]"
end

# 180s : absorbe le PENDING d'AWS (recherche de téléphone) quand les slots du
# compte sont déjà pleins — c'est ici que se joue ton « max 3 min d'attente ».
set -gx host_endpoint ($CYBAWSDF_HOME/lib/host_scrape.fish $aws_run_arn 180)
or return (llerr -e1 "deadline avant un tunnel host (PENDING > 3 min ?) [$status]")
llinf "host serving at: $(llcode $host_endpoint) 🚓💨"

# ── Provision + exposition ────────────────────────────────────────────────────────
$CYBAWSDF_HOME/lib/host_cgi_apply.fish $provision_json
or return (llerr -e1 "apply-provision échoué")

set -gx CYB_URL $host_endpoint/cyborg

# ── Profil persistant : appareil vu ? trace de run, restore, save périodique ────

echo $awsdf_history | jq -e --arg ID "$device_slug" 'any(.[]; .device==$ID)' >/dev/null
and llinf "appareil connu : $(llcode $device_slug)"
or llwar "nouvel appareil : $(llcode $device_slug)"

# Trace de run : <profile>/run-history/<ISO-8601>.json — mémoire des appareils
# de ce profil ; .provider distingue les traces awsdf des autres providers.
set -l now (date --iso-8601=seconds)
jq -n --arg ts $now --arg device "$device_slug" --arg proxy "$proxy" \
    --arg country "$geo_country" --arg language "$geo_language" \
    --arg run_arn $aws_run_arn --arg job_arn $aws_job_arn \
    '{$ts, provider:"awsdf", $device, $proxy,
      $country, $language, $run_arn, $job_arn}' >$profile_history_dir/$now.json

# Restore piloté depuis le home du client (ses cgi sourcent `vendor/…` relatif au
# CWD) ; CYB_URL / CYB_DIR (-gx) sont hérités par le `fish -c` enfant.
if test -f $cyb_profile_state
    llwait "restauration du profil ($(llcode $cyb_profile_state))"
    fish -c "cd $CYB_HOME; and bin/cyb set-profile $cyb_profile_state" >/dev/null 2>&1
    and llinf "profil restauré"
    or llwar "restore profil échoué — session neuve [$status]"
else
    llinf "pas d'état persistant — session neuve (profil créé à la sortie)"
end

# Saver périodique (~60s) : lib/profile_saver.fish est un exécutable DÉDIÉ
# (backgroundé ⇒ $last_pid killable au fish_exit) qui hérite CYB_URL / CYB_DIR.
$CYBAWSDF_HOME/lib/profile_saver.fish $CYB_HOME $cyb_profile_state &
set -gx cyb_saver_pid $last_pid
disown 2>/dev/null

llinf "Cyborg prêt → CYB_URL=$(llcode $CYB_URL) CYB_DIR=$(llcode $CYB_DIR) profil=$(llcode $cyb_profile_dir)"

# ── Lien debug live : frontend DevTools (screencast + clic) sur le CDP brut du device ──
# Best-effort. On assemble l'URL à la main : le webSocketDebuggerUrl renvoyé par
# /cdp/json pointe sur 127.0.0.1 (injoignable via tunnel) ; la révision du frontend
# est calée sur le build Chrome du device (@hash de WebKit-Version).
set -l cdp_host (string replace -r '^https?://' '' -- $host_endpoint)
set -l cdp_page (curl -sf $host_endpoint/cdp/json/list | jq -re 'map(select(.type=="page"))[0].id')
set -l cdp_rev (curl -sf $host_endpoint/cdp/json/version | jq -re '."WebKit-Version"' | string match -rg '@([0-9a-fA-F]+)')
if test -n "$cdp_page" -a -n "$cdp_rev"
    llinf "debug live (écran + clic) → $(llcode "$host_endpoint/devtools/serve_file/@$cdp_rev/inspector.html?remoteFrontend=screencast&wss=$cdp_host/cdp/devtools/page/$cdp_page")"
else
    llwar "lien debug live indisponible (route /cdp muette)"
end
