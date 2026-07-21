#!/usr/bin/env fish
#
# Traite si besoin le popup RecaptchaV2.
#
# invisible.fish et normal.fish sont à utilisé plutôt car ils déclenchent recaptcha puis le traite.

set -l ct (status filename | path resolve | path dirname)/res-cyb

argparse -N1 -- $argv; or exit 2
set -l outcomes $argv

set -l tmp_mp3 (mktemp -t cyb-recaptchav2-audio.XXXXXXXXX.mp3)

function cleanup --on-event fish_exit
    rm -f $tmp_mp3
end

function _transcribe -a url
    # TODO : _transcribe doit connaître language

    # Psq j'oublie tt le temps de le définir
    set -q GROQ_API_KEY
    or set GROQ_API_KEY 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

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

set -l start_race (cyb race -V $ct/nav_audio $outcomes)
switch $start_race[1]
    case $ct/nav_audio
        llinf "Recaptcha V2 popup ouvert"

    case $outcomes
        # Pas de popup ouvert
        llinf "Recaptcha V2 réussi sans popup <3"
        printf '%s\n' $start_race[2]
        exit 1
end

llwait "Sélection du mode audio"
cybw tap $ct/nav_audio
set -l audio_race (cyb race $ct/audio_link $ct/audio_refusal)
switch $audio_race[1]
    case $ct/audio_link
        llinf "Mode audio autorisé"

    case $ct/audio_refusal
        # C'est à cause de l'IP
        exit (llerr -e1 "Mode audio refusé par RecaptchaV2.")
end

for attempt in (seq 15)
    if $attempt -ne 1
        cybw tap $ct/reload
        cybw none -V $ct/audio_bad
    end

    sleep 1

    set -l audio_btn (cyb query -V $ct/audio_link)
    set -l audio_url (pup '[href]' 'attr{href}' <$audio_btn/html | string replace -a '&amp;' '&')

    set -l audio_url ()
    llwait "Tentative #$attempt sur $(llcode $audio_url)"

    if not set -l audio_size (curl -sI $audio_url | rg -m1 -i 'content-length' | rg -o '\d+');
       or test $audio_size -eq 0
        llwar "Audio vide."
        continue
    end

    if not set audio_text (_transcribe $audio_url)
        llwar "Transcription impossible"
        continue
    end
 
    cybw input -t "$audio_text" $ct/audio_input
    cybw tap $ct/submit

    # TODO : erreur de traduction
    set -l end_race (cyb race -V $ct/audio_bad $outcomes)
    switch $end_race[1]
        case $ct/audio_bad
            llwar "Transcription mauvaise : $(llcode (cat $end_race[2]/text))"
            continue

        case $outcomes
            printf '%s\n' $end_race[1]
            exit 0
    end
end

exit 1

