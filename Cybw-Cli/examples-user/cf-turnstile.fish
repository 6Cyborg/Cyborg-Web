#!/usr/bin/env fish
set -lx log_registry CfTurnstile

# Sélecteurs inline (nouvelle API). L'iframe Turnstile est matchée par son sitekey.
set -l _frame --frame 'iframe[url*="3x00000000000000000000FF"]' --pierce
set -l turnstile_input $_frame -e 'input[type="checkbox"]'
set -l turnstile_success $_frame -e '[role="alert"][style*="grid"] svg[style*="block"] > path[d="m13,26l9.37,9l17.63,-18"]'

cybw visit "https://nopecha.com/demo/turnstile"
cybw snap; llinf "navigated"
cybw all -- $turnstile_input
cybw snap; llinf "found turnstile"
cybw tap $turnstile_input
cybw snap; llinf "clicked turnstile checkbox"
cybw all -- $turnstile_success
cybw snap; llinf "bypassed turnstile"
