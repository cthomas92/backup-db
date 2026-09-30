#!/usr/bin/env bash

ENGINE=mariadb-physical

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"


config_file=${1:-"$SCRIPT_DIR/.env"}

[[ $# -le 1 ]] \
    || die "Cara pakai: $0 [/absolute/path/.env]"


load_config "$config_file"


#
# Physical backup selalu mencakup seluruh
# instance MariaDB, bukan satu database.
#
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


#
# Validasi config.
#
[[ $MARIADB_PHYSICAL_SOCKET == /* ]] \
    || die "MARIADB_PHYSICAL_SOCKET harus absolute path"


[[ $MARIABACKUP_PARALLEL =~ ^[1-9][0-9]*$ \
   && $MARIABACKUP_PARALLEL -le 64 ]] \
    || die "MARIABACKUP_PARALLEL harus 1-64"


[[ $ZSTD_LEVEL =~ ^([1-9]|1[0-9])$ ]] \
    || die "ZSTD_LEVEL harus 1-19"


[[ $ZSTD_THREADS =~ ^[1-9][0-9]*$ \
   && $ZSTD_THREADS -le 64 ]] \
    || die "ZSTD_THREADS harus 1-64"


need zstd
need tee


#
# Cari binary MariaDB Backup.
#
if command -v mariadb-backup >/dev/null 2>&1; then

    backup_bin=mariadb-backup

elif command -v mariabackup >/dev/null 2>&1; then

    backup_bin=mariabackup

else

    die "Command mariadb-backup/mariabackup tidak ditemukan"
fi


begin_backup


#
# Credential sementara.
#
defaults_file="$RUN_DIR/mariadb-backup.cnf"

TEMP_CREDENTIAL_FILE=$defaults_file


{
    printf '[mariadb-backup]\n'

    printf 'user="%s"\n' \
        "$(escape_quoted_value "$MARIADB_PHYSICAL_USER")"

    printf 'password="%s"\n' \
        "$(escape_quoted_value "$MARIADB_PHYSICAL_PASSWORD")"

    printf 'socket="%s"\n' \
        "$(escape_quoted_value "$MARIADB_PHYSICAL_SOCKET")"

} >"$defaults_file"


chmod 600 "$defaults_file"


#
# File hasil.
#
artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.xbstream.zst"


#
# Log khusus mariadb-backup.
#
backup_log="$LOG_DIR/mariadb-physical-${STAMP}.log"

: >"$backup_log"

chmod 600 "$backup_log"


log "Full physical backup seluruh instance MariaDB"

log "Stream: mariadb-backup -> zstd -> $artifact"


#
# PENTING:
#
# stdout mariadb-backup = binary xbstream
#
# stdout tersebut HANYA diarahkan ke zstd.
#
# stderr mariadb-backup = log text
# diarahkan ke log + terminal.
#
set +e


run_backup \
    "$backup_bin" \
    --defaults-extra-file="$defaults_file" \
    --backup \
    --stream=xbstream \
    --parallel="$MARIABACKUP_PARALLEL" \
    2> >(
        tee -a "$backup_log" >&2
    ) |
    zstd \
        --quiet \
        "-T${ZSTD_THREADS}" \
        "-${ZSTD_LEVEL}" \
        >"$artifact"


pipe_rc=(
    "${PIPESTATUS[@]}"
)


set -e


backup_rc=${pipe_rc[0]:-1}

zstd_rc=${pipe_rc[1]:-1}


#
# Validasi mariadb-backup.
#
if (( backup_rc != 0 )); then

    die "MariaDB physical backup gagal (rc=$backup_rc). Lihat log: $backup_log"
fi


#
# Validasi compression.
#
if (( zstd_rc != 0 )); then

    die "zstd gagal melakukan compression (rc=$zstd_rc). Lihat log: $backup_log"
fi


#
# File tidak boleh kosong.
#
[[ -s $artifact ]] \
    || die "Hasil MariaDB physical backup kosong"


log "Validasi file Zstandard"


if ! zstd \
    --test \
    --quiet \
    "$artifact"
then

    die "Validasi file physical backup gagal: $artifact"
fi


#
# Catat ukuran local sebelum upload.
#
artifact_size=$(stat -c %s -- "$artifact")

log "Physical backup selesai: $(human_bytes "$artifact_size")"


#
# Upload + checksum + verifikasi GCS.
#
upload_backup "$artifact"