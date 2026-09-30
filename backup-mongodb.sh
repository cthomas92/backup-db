#!/usr/bin/env bash
ENGINE=mongodb
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"
config_file=${1:-"$SCRIPT_DIR/.env"}
[[ $# -le 1 ]] || die "Cara pakai: $0 [/absolute/path/.env]"
load_config "$config_file"

need mongodump
need gzip
required MONGO_USER
required MONGO_PASSWORD
: "${MONGO_HOST:=127.0.0.1}"
: "${MONGO_PORT:=27017}"
: "${MONGO_AUTH_DB:=admin}"
: "${MONGO_DATABASE:=}"
: "${MONGO_COLLECTION:=}"
: "${MONGO_REPLICA_SET:=}"
: "${MONGO_TLS:=false}"
: "${MONGO_BACKUP_NAME:=mongodb}"

[[ $MONGO_PORT =~ ^[1-9][0-9]*$ && $MONGO_PORT -le 65535 ]] || die "MONGO_PORT tidak valid"
[[ $MONGO_TLS == true || $MONGO_TLS == false ]] || die "MONGO_TLS harus true atau false"
[[ -z $MONGO_COLLECTION || -n $MONGO_DATABASE ]] \
    || die "MONGO_COLLECTION memerlukan MONGO_DATABASE"
if [[ -n $MONGO_DATABASE ]]; then
    [[ $MONGO_DATABASE =~ ^[^/[:cntrl:]]+$ ]] || die "MONGO_DATABASE tidak valid"
fi
if [[ -n $MONGO_COLLECTION ]]; then
    [[ $MONGO_COLLECTION =~ ^[^[:cntrl:]]+$ ]] || die "MONGO_COLLECTION tidak valid"
fi

if [[ $MONGO_BACKUP_NAME == mongodb ]]; then
    if [[ -n $MONGO_DATABASE && -n $MONGO_COLLECTION ]]; then
        MONGO_BACKUP_NAME="mongodb-${MONGO_DATABASE}-${MONGO_COLLECTION}"
    elif [[ -n $MONGO_DATABASE ]]; then
        MONGO_BACKUP_NAME="mongodb-${MONGO_DATABASE}"
    else
        MONGO_BACKUP_NAME='mongodb-all'
    fi
    MONGO_BACKUP_NAME=${MONGO_BACKUP_NAME//[^a-zA-Z0-9_.-]/_}
fi
set_backup_name "$MONGO_BACKUP_NAME"

begin_backup
mongo_config="$RUN_DIR/mongodb.yml"
TEMP_CREDENTIAL_FILE=$mongo_config
printf 'password: "%s"\n' "$(escape_quoted_value "$MONGO_PASSWORD")" >"$mongo_config"
chmod 600 "$mongo_config"

host_arg="$MONGO_HOST:$MONGO_PORT"
if [[ -n $MONGO_REPLICA_SET ]]; then
    host_arg="$MONGO_REPLICA_SET/$host_arg"
fi
args=(--config="$mongo_config" --host="$host_arg" --username="$MONGO_USER" \
      --authenticationDatabase="$MONGO_AUTH_DB" --gzip)
[[ $MONGO_TLS == false ]] || args+=(--ssl)
if [[ -n ${MONGO_TLS_CA_FILE:-} ]]; then
    [[ $MONGO_TLS_CA_FILE == /* && -f $MONGO_TLS_CA_FILE && ! -L $MONGO_TLS_CA_FILE ]] \
        || die "MONGO_TLS_CA_FILE tidak valid"
    args+=(--sslCAFile="$MONGO_TLS_CA_FILE")
fi
if [[ -n $MONGO_DATABASE ]]; then
    args+=(--db="$MONGO_DATABASE")
fi
if [[ -n $MONGO_COLLECTION ]]; then
    args+=(--collection="$MONGO_COLLECTION")
fi
# --oplog hanya valid untuk full dump replica set; MongoDB menolak --oplog bersama --db/--collection.
if [[ -n $MONGO_REPLICA_SET && -z $MONGO_DATABASE && -z $MONGO_COLLECTION ]]; then
    args+=(--oplog)
    log "Replica set full dump: aktifkan oplog untuk snapshot point-in-time"
fi

artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.archive.gz"
args+=(--archive="$artifact")
if [[ -n $MONGO_COLLECTION ]]; then
    log "Dump collection: $MONGO_DATABASE.$MONGO_COLLECTION"
elif [[ -n $MONGO_DATABASE ]]; then
    log "Dump database: $MONGO_DATABASE"
else
    log "Dump seluruh database MongoDB (kecuali local)"
fi
run_backup mongodump "${args[@]}"
gzip -t "$artifact"
upload_backup "$artifact"
