#!/usr/bin/env fish
set -lx log_registry CfTurnstile

# Sélecteurs inline (chaîne unique). L'iframe Turnstile est matchée par son sitekey.
set -l turnstile_input '\'input[type="checkbox"]\' --pierce --frame \'iframe[url*="3x00000000000000000000FF"]\''
set -l turnstile_success '\'[role="alert"][style*="grid"] svg[style*="block"] > path[d="m13,26l9.37,9l17.63,-18"]\' --pierce --frame \'iframe[url*="3x00000000000000000000FF"]\''

cybw visit "https://nopecha.com/demo/turnstile"
cybw snap; llinf "navigated"
cybw all $turnstile_input
cybw snap; llinf "found turnstile"
cybw tap $turnstile_input
cybw snap; llinf "clicked turnstile checkbox"
cybw all $turnstile_success
cybw snap; llinf "bypassed turnstile"
