#!/usr/bin/env fish
#
# Traite si besoin le popup RecaptchaV2. invisible.fish/normal.fish l'appellent.
#
# Args : les OUTCOMES du site (états de succès/échec attendus), une chaîne-
# sélecteur par argument. Sortie stdout : ligne 1 = index 0-based de l'outcome
# gagnant ; lignes suivantes = ses hits. Sort 1 si rien.

# FIXME:
llwar "merci de résoudre manuellement le captcha"
cybw race -T90 $argv
exit 0

set -l CYB_RV2_HOME (status filename | path resolve | path dirname)
source $CYB_RV2_HOME/selectors.fish

set -l outcomes $argv
test -n "$outcomes"; or exit 2

set -l tmp_mp3 (mktemp -t cyb-recaptchav2-audio.XXXXXXXXX.mp3)

function cleanup --on-event fish_exit
    rm -f $tmp_mp3
end

function _transcribe -a url
    set -q GROQ_API_KEY
    or set GROQ_API_KEY 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

    # TODO : _transcribe doit connaître language

    set -l text (curl -s https://api.groq.com/openai/v1/audio/transcriptions \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -F url=$url \
        -F model=whisper-large-v3 -F response_format=text | string trim)

    # Si c'est du json, c'est une erreur :
    if set -l transcribe_err (echo $text | jq -cCe 2>/dev/null)
        llwar "transcription pas fait: $(llcode $transcribe_err)"
        return 1
    end

    echo $text
    return 0
end

# nav_audio (index 0) vs outcomes (index 1..N) : popup ouvert, ou succès direct ?
set -l start_race (cybw race $rc_nav_audio $outcomes)
switch $start_race[1]
    case 0
        llinf "Recaptcha V2 popup ouvert"

    case ''
        exit 1

    case '*'
        # Pas de popup ouvert : un outcome a gagné.
        llinf "Recaptcha V2 réussi sans popup <3"
        math $start_race[1] - 1
        printf '%s\n' $start_race[2..-1]
        exit 0
end

llwait "Sélection du mode audio"
cybw tap $rc_nav_audio
set -l audio_race (cybw race $rc_audio_link $rc_audio_refusal)
switch $audio_race[1]
    case 0
        llinf "Mode audio autorisé"

    case '*'
        # C'est à cause de l'IP
        exit (llerr -e1 "Mode audio refusé par RecaptchaV2.")
end

for attempt in (seq 15)
    if test $attempt -ne 1
       and test (math $attempt % 10) -eq 0
        cybw tap $rc_reload
        cybw none $rc_audio_bad
        lwar "reloaded audio"
    end

    sleep 3

    set -l audio_btn (cybw query $rc_audio_link)
    or exit (llerr -e1 "bouton URL vers l'audio introuvable")

    set -l audio_url (pup '[href]' 'attr{href}' <$audio_btn/html |
        string replace -a '&amp;' '&')

    llwait "Tentative #$attempt sur $(llcode $audio_url)"

    if not set -l audio_size (curl -sI $audio_url | rg -m1 -i 'content-length' | rg -o '\d+')
       or test $audio_size -eq 0
        llwar "Audio vide."
        continue
    end

    if not set audio_text (_transcribe $audio_url)
        llwar "Transcription impossible"
        continue
    end

    cybw input --text "$audio_text" $rc_audio_input
    cybw tap $rc_submit

    # audio_bad (index 0) vs outcomes (index 1..N)
    set -l end_race (cybw race $rc_audio_bad $outcomes)
    switch $end_race[1]
        case 0
            llwar "Transcription mauvaise : $(llcode (cat $end_race[2]/text))"
            continue

        case ''
            continue

        case '*'
            math $end_race[1] - 1
            printf '%s\n' $end_race[2..-1]
            exit 0
    end
end

exit 1
