# Cyborg Web

Automate Google Chrome from CLI. Supports [Gologin](https://gologin.net) and [AWS DeviceFarm](https://docs.aws.amazon.com/general/latest/gr/devicefarm.html).

```bash
# lance un nouveau profile
mkdir ~/cybw-profile
source ./Cybw-Local-Gologin/launch.fish ~/cybw-profile

# résout cloudflare turnstile
cybw visit https://nopecha.com/demo/turnstile
cybw all ./cybt/turnstile_input
cybw tap ./cybt/turnstile_input
cybw none ./cybt/turnstile_input
```

## Projets

* Cybw-Cli - outil de ligne de commande
* Cybw-Cli-RecaptchaV2 - résout Recaptcha V2 via Groq Whispers
* Cybw-Farm-AwsDF - démarre Cyborg via Aws DeviceFarm
* Cybw-Local-Gologin - démarre Cyborg via Gologin
* Cybw-RT-CDP - serveur Cyborg avec Chrome Devtools
* Cybw-Importer-acreed - génère un profile Cyborg depuis un log acreed

