#!/usr/bin/env fish
# remplit l'<input> matché par <targ_dir>/*.toml avec <--text>, ou y pose des
# fichiers (<-f>, répétable) via DOM.setFileInputFiles — le nom vu par la page
# est le basename du chemin local. Le locator doit matcher l'<input type=file>
# LUI-MÊME (display:none accepté : ni scroll ni focus dans ce mode), jamais le
# bouton stylé par-dessus — CDP refuse tout autre nœud. Taille cumulée < 16 Mio
# strict : MAX_CONTENT_LENGTH Quart côté serveur, moins l'overhead tar
# (~512 o/entrée + padding + le targ). POST /fill.

# Met un nombre ou du texte :
# `cyb input --text "" <targ>`
#
# Upload un ou plusieurs fichiers :
# `cyb input --file a --file b <targ>`

set -lx log_registry CybSet
__cyb_op_init; or exit 1

argparse -N1 -X1 "t/text=" "f/file=+" -- $argv
or exit (llerr -e2 "bad usage")

set -q _flag_text; or set -q _flag_file
or exit (llerr -e2 "no input value provided")

set -q _flag_text; and set -q _flag_file
and exit (llerr -e2 "text and file flags are mutually exclusive")

cp -r $argv[1] $_CYB_REQ/targ

if set -q _flag_file
    mkdir $_CYB_REQ/files
    for src in $_flag_file
        set -l dest $_CYB_REQ/files/(path basename -- $src)
        if test -f $dest
            exit (llerr -e2 "duplicate basename: $(path basename -- $src)")
        end

        cp -- $src $dest; or exit (llerr -e2 "unreadable file: $src")

        if test (stat -c %s -- $dest) -gt 10485760
            llwar "$(llcode $src) exceeds 10 MiB (server cap: 16 MiB total)"
        end
    end
else if set -q _flag_text
    echo $_flag_text >$_CYB_REQ/text
end

_cyb_op fill 2>$_CYB_ERR
or exit (llerr -e1 "op failed: $argv $(llcode (cat $_CYB_ERR))")

set -q CYBTRACE; and llinf "input $(llcode $_flag_text $_flag_file) on $(llcode $argv[1])"
exit 0
