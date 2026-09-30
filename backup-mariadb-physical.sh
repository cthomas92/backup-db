#!/usr/bin/env bash
ENGINE=mariadb-physical
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"
config_file=${1:-"$SCRIPT_DIR/.env"}
[[ $# -le 1 ]] || die "Cara pakai: $0 [/absolute/path/.env]"
load_config "$config_file"

# Physical backup selalu mencakup seluruh instance MariaDB, bukan satu database.
: "${MARIADB_PHYSICAL_USER:=${MARIADB_USER:-}}"
: "${MARIADB_PHYSICAL_PASSWORD:=${MARIADB_PASSWORD:-}}"
: "${MARIADB_PHYSICAL_SOCKET:=${MARIADB_SOCKET:-/run/mysqld/mysqld.sock}}"
: "${MARIADB_PHYSICAL_BACKUP_NAME:=mariadb-full}"
: "${MARIABACKUP_PARALLEL:=1}"
: "${ZSTD_LEVEL:=3}"
: "${ZSTD_THREADS:=1}"
required MARIADB_PHYSICAL_USER
required MARIADB_PHYSICAL_PASSWORD
set_backup_name "$MARIADB_PHYSICAL_BACKUP_NAME"

[[ $MARIADB_PHYSICAL_SOCKET == /* ]] || die "MARIADB_PHYSICAL_SOCKET harus absolute path"
[[ $MARIABACKUP_PARALLEL =~ ^[1-9][0-9]*$ && $MARIABACKUP_PARALLEL -le 64 ]] \
    || die "MARIABACKUP_PARALLEL harus 1-64"
[[ $ZSTD_LEVEL =~ ^([1-9]|1[0-9])$ ]] || die "ZSTD_LEVEL harus 1-19"
[[ $ZSTD_THREADS =~ ^[1-9][0-9]*$ && $ZSTD_THREADS -le 64 ]] \
    || die "ZSTD_THREADS harus 1-64"
need zstd
if command -v mariadb-backup >/dev/null 2>&1; then
    backup_bin=mariadb-backup
elif command -v mariabackup >/dev/null 2>&1; then
    backup_bin=mariabackup
else
    die "Command mariadb-backup/mariabackup tidak ditemukan"
fi

begin_backup
defaults_file="$RUN_DIR/mariadb-backup.cnf"
TEMP_CREDENTIAL_FILE=$defaults_file
{
    printf '[mariadb-backup]\n'
    printf 'user="%s"\n' "$(escape_quoted_value "$MARIADB_PHYSICAL_USER")"
    printf 'password="%s"\n' "$(escape_quoted_value "$MARIADB_PHYSICAL_PASSWORD")"
    printf 'socket="%s"\n' "$(escape_quoted_value "$MARIADB_PHYSICAL_SOCKET")"
} >"$defaults_file"
chmod 600 "$defaults_file"

artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.xbstream.zst"
log "Full physical backup seluruh instance MariaDB"
(
    cd "$RUN_DIR"
    run_backup "$backup_bin" --defaults-extra-file="$defaults_file" \
        --backup --stream=xbstream --parallel="$MARIABACKUP_PARALLEL"
) | zstd --quiet "-T$ZSTD_THREADS" "-$ZSTD_LEVEL" -o "$artifact" -
zstd --test --quiet "$artifact"
upload_backup "$artifact"
