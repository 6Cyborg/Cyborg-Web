#!/usr/bin/env fish
# Sélecteurs cybw du solveur reCAPTCHA v2. Sourcé par invisible/normal/recaptcha.fish.

set -g rc_loaded        '\'iframe[src*="api2/anchor"]\''
set -g rc_checkbox      '\'#recaptcha-anchor[aria-checked="false"]\' --pierce --frame \'iframe[url*="api2/anchor"]\''
set -g rc_success       '\'#recaptcha-anchor[aria-checked="true"]\' --pierce --frame \'iframe[url*="api2/anchor"]\''
set -g rc_nav_audio     '\'#recaptcha-audio-button\' --pierce --frame \'iframe[url*="api2/bframe"]\' -V'
set -g rc_audio_link    '\'.rc-audiochallenge-tdownload > a[href]\' --pierce --frame \'iframe[url*="api2/bframe"]\' -V'
set -g rc_audio_refusal '\'.rc-doscaptcha-header-text\' --pierce --frame \'iframe[url*="recaptcha/api2/bframe"], iframe[url*="recaptcha/enterprise/bframe"]\' -V'
set -g rc_audio_input   '\'#audio-response\' --pierce --frame \'iframe[url*="api2/bframe"]\''
set -g rc_audio_bad     '\'.rc-audiochallenge-error-message:not([style*="display:none"])\' --pierce --frame \'iframe[url*="api2/bframe"]\' -V'
set -g rc_reload        '\'button#recaptcha-reload-button\' --pierce --frame \'iframe[url*="api2/bframe"]\''
set -g rc_submit        '\'#recaptcha-verify-button\' --pierce --frame \'iframe[url*="api2/bframe"]\''
