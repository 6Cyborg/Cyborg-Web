#!/usr/bin/env fish

function __cyb_op_init -d "vérifie les pré-requis et (re)génère les buffers du process courant"
    which curl tar file >/dev/null
    and set -q CYB_DIR
    and set -q CYB_URL
    or return 2

    # pour le parallélisme, il faut séparé le dossier de travail de chaque tâche :
    # FIXME : CYBW_CALL conflicts with pid re-use
    set -gx CYBW_CALL $CYB_DIR/.cybw-calls/$(date -In)

    set -gx _CYBW_REQ $CYBW_CALL/req
    set -gx _CYBW_RESP $CYBW_CALL/resp
    
    set -gx _CYBW_OK $_CYBW_RESP/ok.txt
    set -gx _CYBW_ERR $_CYBW_RESP/error.txt

    mkdir -p $_CYBW_REQ
end

function _cyb_op -a name
    set -l req_pack $CYBW_CALL/pack-req.tar
    set -l resp_pack $CYBW_CALL/pack-resp.tar

    rm -rf $_CYBW_RESP
    mkdir -p $_CYBW_RESP

    tar -c -C $_CYBW_REQ -f $req_pack .

    curl -s -X POST "$CYB_URL/$name" \
        -H "Content-Type: application/x-tar" --data-binary "@$req_pack" \
        -H "Accept: application/x-tar" -o "$resp_pack"
    or return (llerr -e1 "curl request failed [$status]")

    if test (file --mime-type -b $resp_pack) = application/x-tar
        tar -xf $resp_pack -C $_CYBW_RESP
    else
        llwar "non-tar response received!"
        head -c 400 $resp_pack >$_CYBW_ERR
    end
    
    if test -f $_CYBW_OK
        return 0
    else if test -f $_CYBW_ERR
        return 1
    else
        llerr "Response is neither ok nor error"
        return 1
    end
end
