#!/usr/bin/env fish

function __cyb_op_init -d "vérifie les pré-requis et (re)génère les buffers du process courant"
    which curl tar >/dev/null
    and set -q CYB_DIR
    and set -q CYB_URL
    or return 2

    # pour le parallélisme, il faut séparé le dossier de travail de chaque tâche :
    # FIXME : CYBW_CALL conflicts with pid re-use
    set -gx CYBW_CALL $CYB_DIR/call-$fish_pid

    set -gx _CYBW_REQ $CYBW_CALL/.req
    set -gx _CYBW_RESP $CYBW_CALL/.resp
    set -gx _CYBW_ERR $CYBW_CALL/.err

    rm -rf $CYBW_CALL
    mkdir -p $_CYBW_REQ
end

function _cyb_op -a name
    set -l req_pack $CYBW_CALL/.pack-req.tar
    set -l resp_pack $CYBW_CALL/.pack-resp.tar

    tar -c -C $_CYBW_REQ -f $req_pack .

    set -l http_code (curl -s -X POST \
        -H "Content-Type: application/x-tar" --data-binary @- \
        -H "Accept: application/x-tar" -o $resp_pack \
        -w "%{http_code}" \
        "$CYB_URL/$name" <$req_pack)
    or return (llerr -e1 "execute request failed [$status]")

    if not string match -qr '^2' $http_code
        jq -Rs <$resp_pack
        return 1
    end

    rm -rf $_CYBW_RESP
    mkdir -p $_CYBW_RESP
    tar -xf $resp_pack -C $_CYBW_RESP
    or return (llerr -e1 "bad response payload [$http_code] at $resp_pack")
end