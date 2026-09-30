#!/usr/bin/env bash
ENGINE=mariadb-physical
ENGINE_CONFIG_KEYS=(MARIABACKUP_DEFAULTS_FILE MARIABACKUP_PARALLEL ZSTD_LEVEL ZSTD_THREADS)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"
load_config "$@"

required MARIABACKUP_DEFAULTS_FILE
secure_file "$MARIABACKUP_DEFAULTS_FILE"
need zstd
if command -v mariabackup >/dev/null 2>&1; then
    backup_bin=mariabackup
elif command -v mariadb-backup >/dev/null 2>&1; then
    backup_bin=mariadb-backup
else
    die "Command mariabackup/mariadb-backup tidak ditemukan"
fi

: "${MARIABACKUP_PARALLEL:=1}"
: "${ZSTD_LEVEL:=3}"
: "${ZSTD_THREADS:=1}"
[[ $MARIABACKUP_PARALLEL =~ ^[1-9][0-9]*$ && $MARIABACKUP_PARALLEL -le 64 ]] \
    || die "MARIABACKUP_PARALLEL harus 1-64"
[[ $ZSTD_LEVEL =~ ^([1-9]|1[0-9])$ ]] || die "ZSTD_LEVEL harus 1-19"
[[ $ZSTD_THREADS =~ ^[1-9][0-9]*$ && $ZSTD_THREADS -le 64 ]] \
    || die "ZSTD_THREADS harus 1-64"

begin_backup
artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.xbstream.zst"
log "Full physical backup seluruh instance dengan xbstream + zstd"
(
    cd "$RUN_DIR"
    run_backup "$backup_bin" --defaults-extra-file="$MARIABACKUP_DEFAULTS_FILE" \
        --backup --stream=xbstream --parallel="$MARIABACKUP_PARALLEL"
) | zstd --quiet "-T$ZSTD_THREADS" "-$ZSTD_LEVEL" -o "$artifact" -
zstd --test --quiet "$artifact"
upload_backup "$artifact"
