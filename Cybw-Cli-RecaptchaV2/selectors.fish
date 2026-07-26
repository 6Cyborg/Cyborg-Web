#!/usr/bin/env fish
# Sélecteurs cybw du solveur reCAPTCHA v2. Sourcé par invisible/normal/recaptcha.fish.

set -g rc_loaded        -e 'iframe[src*="api2/anchor"]'
set -g rc_checkbox      -e '#recaptcha-anchor[aria-checked="false"]' --pierce --frame 'iframe[url*="api2/anchor"]'
set -g rc_success       -e '#recaptcha-anchor[aria-checked="true"]' --pierce --frame 'iframe[url*="api2/anchor"]'
set -g rc_nav_audio     -e '#recaptcha-audio-button' --pierce --frame 'iframe[url*="api2/bframe"]'
set -g rc_audio_link    -e '.rc-audiochallenge-tdownload > a[href]' --pierce --frame 'iframe[url*="api2/bframe"]'
set -g rc_audio_refusal -e '.rc-doscaptcha-header-text' --pierce --frame 'iframe[url*="recaptcha/api2/bframe"], iframe[url*="recaptcha/enterprise/bframe"]'
set -g rc_audio_input   -e '#audio-response' --pierce --frame 'iframe[url*="api2/bframe"]'
set -g rc_audio_bad     -e '.rc-audiochallenge-error-message:not([style*="display:none"])' --pierce --frame 'iframe[url*="api2/bframe"]'
set -g rc_reload        -e 'button#recaptcha-reload-button' --pierce --frame 'iframe[url*="api2/bframe"]'
set -g rc_submit        -e '#recaptcha-verify-button' --pierce --frame 'iframe[url*="api2/bframe"]'
