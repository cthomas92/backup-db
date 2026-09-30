# shellcheck shell=bash
# Fungsi kecil yang dipakai oleh semua script backup.

set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
unset CDPATH BASH_ENV ENV

log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$ENGINE" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Command tidak ditemukan: $1"; }
required() { [[ -n ${!1:-} ]] || die "Isi $1 di file config"; }

secure_file() {
    local file=$1 mode
    [[ $file == /* && -f $file && ! -L $file ]] || die "File harus regular, bukan symlink, dan memakai absolute path: $file"
    [[ -O $file ]] || die "File harus dimiliki user yang menjalankan backup: $file"
    mode=$(stat -c '%a' -- "$file")
    (( (8#$mode & 077) == 0 )) || die "Jalankan chmod 600 pada: $file"
}

load_config() {
    local expected_engine=$ENGINE
    [[ $# == 1 ]] || die "Cara pakai: $0 /absolute/path/config.conf"
    secure_file "$1"
    unset GCS_URI BACKUP_NAME BACKUP_DIR BACKUP_TIMEOUT_SECONDS UPLOAD_TIMEOUT_SECONDS
    local key
    for key in "${ENGINE_CONFIG_KEYS[@]}"; do unset "$key"; done
    # File config adalah file Bash tepercaya milik administrator.
    # shellcheck disable=SC1090
    source "$1"
    ENGINE=$expected_engine

    required GCS_URI
    required BACKUP_NAME
    : "${BACKUP_DIR:=/var/lib/db-backup}"
    : "${BACKUP_TIMEOUT_SECONDS:=21600}"
    : "${UPLOAD_TIMEOUT_SECONDS:=7200}"

    [[ $GCS_URI =~ ^gs://[a-z0-9][a-z0-9._-]+(/[a-zA-Z0-9._/-]+)?$ ]] || die "GCS_URI tidak valid"
    [[ $BACKUP_NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || die "BACKUP_NAME tidak valid"
    [[ $BACKUP_DIR == /* ]] || die "BACKUP_DIR harus absolute path"
    [[ $BACKUP_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || die "BACKUP_TIMEOUT_SECONDS tidak valid"
    [[ $UPLOAD_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || die "UPLOAD_TIMEOUT_SECONDS tidak valid"

    for command in flock mktemp sha256sum stat timeout openssl base64 gcloud; do need "$command"; done
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n ${RUN_DIR:-} && -d $RUN_DIR ]]; then
        if (( rc == 0 )); then
            rm -rf -- "$RUN_DIR"
        else
            log "Backup gagal; file sementara disimpan di $RUN_DIR"
        fi
    fi
    exit "$rc"
}

begin_backup() {
    mkdir -p -- "$BACKUP_DIR"
    [[ -d $BACKUP_DIR && ! -L $BACKUP_DIR && -O $BACKUP_DIR ]] || die "BACKUP_DIR harus private dan dimiliki user backup"
    local mode
    mode=$(stat -c '%a' -- "$BACKUP_DIR")
    (( (8#$mode & 077) == 0 )) || die "Jalankan chmod 700 pada $BACKUP_DIR"

    exec 9>"$BACKUP_DIR/.${ENGINE}-${BACKUP_NAME}.lock"
    flock -n 9 || die "Backup yang sama masih berjalan"

    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    RUN_DIR=$(mktemp -d "$BACKUP_DIR/.${ENGINE}-${BACKUP_NAME}-${STAMP}.XXXXXX")
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    log "Mulai backup $BACKUP_NAME"
}

run_backup() {
    timeout --signal=TERM --kill-after=30s "${BACKUP_TIMEOUT_SECONDS}s" "$@"
}

upload_backup() {
    local artifact=$1 filename checksum remote
    [[ -s $artifact ]] || die "Hasil backup kosong"
    filename=${artifact##*/}
    checksum="$artifact.sha256"
    (cd "$RUN_DIR" && sha256sum "$filename" >"$filename.sha256")
    remote="${GCS_URI%/}/$ENGINE/$BACKUP_NAME"

    export CLOUDSDK_CORE_DISABLE_PROMPTS=1
    export CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=False
    log "Upload $filename ke $remote/"
    upload_one "$artifact" "$remote/$filename"
    upload_one "$checksum" "$remote/$filename.sha256"

    log "SUCCESS: $remote/$filename"
}

upload_one() {
    local file=$1 uri=$2 size md5 metadata remote_size remote_md5
    size=$(stat -c %s -- "$file")
    md5=$(openssl dgst -md5 -binary "$file" | base64)
    timeout --signal=TERM --kill-after=30s "${UPLOAD_TIMEOUT_SECONDS}s" \
        gcloud storage cp "$file" "$uri" --if-generation-match=0 \
        --content-md5="$md5" --quiet
    metadata=$(timeout --signal=TERM --kill-after=30s "${UPLOAD_TIMEOUT_SECONDS}s" \
        gcloud storage objects describe "$uri" --raw \
        --format='value(size,md5Hash)')
    IFS=$'\t' read -r remote_size remote_md5 <<<"$metadata"
    remote_md5=${remote_md5%$'\r'}
    [[ $remote_size == "$size" && $remote_md5 == "$md5" ]] \
        || die "Verifikasi object GCS gagal: $uri"
}
