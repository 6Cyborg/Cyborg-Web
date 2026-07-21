#!/usr/bin/env fish
# cyb-gologin-install.fish FINGERPRINT
# Installe le navigateur Orbita correspondante

set -g log_registry GologinInstall

# --- Parsing du profil (sans argument : profil aléatoire de dat-fp/) --------
set -l info (./sys/profile-parse.fish $argv[1])
and set -l fpfile (echo $info | jq -re .fpfile)
and set -l ver (echo $info | jq -re .version)
and set -l url (echo $info | jq -re .browser_release_url)
or exit (llerr -e2 "profile parse error")

# Chemin d'install construit ici (parse expose la version, pas le chemin).
set -l browser_dir (path resolve dat-browser/$ver)

set -l archive "$browser_dir/release.tar.gz"
set -l dest "$browser_dir/release"
set -l chrome "$dest/chrome"

# --- Compat lib : Orbita (build Debian) réclame libcurl-gnutls.so.4, que
# Fedora ne fournit pas. On expose libcurl.so.4 sous ce nom dans usrlib/ ;
# launch l'ajoute à LD_LIBRARY_PATH. Fait aussi office de sanity check.
set -l libcurl (ldconfig -p | string match -rg 'libcurl\.so\.4.*=> (\S+)' | head -1)
test -e "$libcurl"; or exit (llerr -e9 "libcurl.so.4 introuvable — installe le paquet « libcurl »")
mkdir -p usrlib
ln -sf $libcurl usrlib/libcurl-gnutls.so.4
llinf "compat : usrlib/libcurl-gnutls.so.4 → $libcurl"

llinf "profil $(path basename $fpfile) → Orbita $ver → $browser_dir"

if test -x $chrome
    llinf "déjà installé : $chrome"
    exit 0
end

# --- Téléchargement dans le dossier de travail de la version ----------------
mkdir -p "$browser_dir"
llwait "téléchargement : $url"
if not curl -fSL --retry 3 --progress-bar -o "$archive" "$url"
    llerr "échec du téléchargement (version $ver peut-être indisponible)"
    rm -f "$archive"
    exit 6
end

# --- Extraction dans le sous-dossier release/ (racine aplatie) --------------
llwait "extraction dans $dest"
mkdir -p "$dest"
if not tar -xzf "$archive" -C "$dest" --strip-components=1
    llerr "échec de l'extraction"
    exit 7
end
if not test -f "$chrome"
    llerr "binaire « chrome » absent après extraction — archive inattendue"
    exit 8
end

# --- Permissions (bélier browser.rs:73 met 0o777 sur les deux) --------------
for f in chrome chrome_crashpad_handler
    chmod 0755 $dest/$f
end

# chrome-sandbox : setuid root (mode 4755). Sur certains Arch Linux c'est nécessaire. Sur Fedora non.
# set -l sandbox "$dest/chrome-sandbox"
# if test -f "$sandbox"
#     set -l owner (stat -c '%U' "$sandbox" 2>/dev/null)
#     if test "$owner" != root; or not test -u "$sandbox"
#         llwait "configuration de chrome-sandbox (setuid root, sudo requis)…"
#         if sudo chown root:root "$sandbox" 2>/dev/null; and sudo chmod 4755 "$sandbox" 2>/dev/null
#             llinf "chrome-sandbox configuré"
#         else
#             llwar "chrome-sandbox non configuré (sudo indisponible/refusé)."
#             llwar "si le lancement échoue : CYB_EXTRA_ARGS='--no-sandbox' au launch,"
#             llwar "ou : sudo chown root:root '$sandbox'; sudo chmod 4755 '$sandbox'"
#         end
#     end
# end

llinf "OK → $chrome"
exit 0
