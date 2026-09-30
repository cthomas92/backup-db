#!/usr/bin/env bash

ENGINE=mariadb-physical

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"


config_file=${1:-"$SCRIPT_DIR/.env"}

[[ $# -le 1 ]] \
    || die "Cara pakai: $0 [/absolute/path/.env]"


load_config "$config_file"


# ============================================================
# CONFIG
# ============================================================

# Physical backup selalu mencakup seluruh instance MariaDB.
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
need mkfifo


# ============================================================
# MARIADB BACKUP BINARY
# ============================================================

if command -v mariadb-backup >/dev/null 2>&1; then

    backup_bin=mariadb-backup

elif command -v mariabackup >/dev/null 2>&1; then

    backup_bin=mariabackup

else

    die "Command mariadb-backup/mariabackup tidak ditemukan"
fi


begin_backup


# ============================================================
# CREDENTIAL
# ============================================================

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


# ============================================================
# FILES
# ============================================================

artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.xbstream.zst"

backup_log="$LOG_DIR/mariadb-physical-${STAMP}.log"

stream_fifo="$RUN_DIR/mariadb-backup.xbstream.fifo"


: >"$backup_log"

chmod 600 "$backup_log"


mkfifo -m 600 \
    "$stream_fifo"


log "Full physical backup seluruh instance MariaDB"

log "Streaming MariaDB physical backup ke Zstandard"


# ============================================================
# STREAM
# ============================================================
#
# mariadb-backup STDOUT
#
#      binary xbstream
#             |
#             v
#            FIFO
#             |
#             v
#            zstd
#             |
#             v
#     *.xbstream.zst
#
#
# mariadb-backup STDERR
#
#             |
#             v
# mariadb-physical-*.log
#
# Binary tidak diarahkan ke terminal.
# ============================================================

set +e


# Jalankan zstd terlebih dahulu.
zstd \
    --quiet \
    "-T${ZSTD_THREADS}" \
    "-${ZSTD_LEVEL}" \
    -c \
    <"$stream_fifo" \
    >"$artifact" \
    2>>"$backup_log" &


zstd_pid=$!


# Jalankan mariadb-backup.
#
# stdout -> FIFO
# stderr -> log
#
run_backup \
    "$backup_bin" \
    --defaults-extra-file="$defaults_file" \
    --backup \
    --stream=xbstream \
    --parallel="$MARIABACKUP_PARALLEL" \
    >"$stream_fifo" \
    2>>"$backup_log"


backup_rc=$?


# Tunggu compressor selesai.
wait "$zstd_pid"

zstd_rc=$?


set -e


rm -f -- \
    "$stream_fifo"


# ============================================================
# VALIDATE BACKUP
# ============================================================

if (( backup_rc != 0 )); then

    die "MariaDB physical backup gagal (rc=$backup_rc). Lihat log: $backup_log"
fi


if (( zstd_rc != 0 )); then

    die "zstd gagal melakukan compression (rc=$zstd_rc). Lihat log: $backup_log"
fi


[[ -s $artifact ]] \
    || die "Hasil MariaDB physical backup kosong"


log "Validasi file Zstandard"


zstd \
    --test \
    --quiet \
    "$artifact" \
    || die "Validasi file physical backup gagal: $artifact"


artifact_size=$(
    stat -c %s -- \
        "$artifact"
)


log "Physical backup selesai: $(human_bytes "$artifact_size")"


# Kalau semuanya sukses,
# log detail mariadb-backup boleh dibuang.
rm -f -- \
    "$backup_log"


# ============================================================
# GCS
# ============================================================

upload_backup "$artifact"