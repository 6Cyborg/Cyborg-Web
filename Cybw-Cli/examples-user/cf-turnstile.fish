#!/usr/bin/env fish
set -lx log_registry CfTurnstile

set -l here (status dirname)

cybw visit "https://nopecha.com/demo/turnstile"
cybw snap; llinf "navigated"
cybw all $here/cf-turnstile/turnstile_input
cybw snap; llinf "found turnstile"
cybw tap $here/cf-turnstile/turnstile_input
cybw snap; llinf "clicked turnstile checkbox"
cybw all $here/cf-turnstile/turnstile_success
cybw snap; llinf "bypassed turnstile"
