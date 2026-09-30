#!/usr/bin/env bash
ENGINE=mongodb
ENGINE_CONFIG_KEYS=(MONGO_CONFIG_FILE MONGO_MODE MONGO_WRITES_PAUSED)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"
load_config "$@"

need mongodump
need gzip
required MONGO_CONFIG_FILE
secure_file "$MONGO_CONFIG_FILE"
: "${MONGO_MODE:=replica-set}"

args=(--config="$MONGO_CONFIG_FILE" --gzip)
case "$MONGO_MODE" in
    replica-set) args+=(--oplog) ;;
    standalone)
        [[ ${MONGO_WRITES_PAUSED:-false} == true ]] || die "Standalone wajib menghentikan semua write dan set MONGO_WRITES_PAUSED=true"
        ;;
    *) die "MONGO_MODE harus replica-set atau standalone" ;;
esac

begin_backup
artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.archive.gz"
args+=(--archive="$artifact")
run_backup mongodump "${args[@]}"
gzip -t "$artifact"
upload_backup "$artifact"
