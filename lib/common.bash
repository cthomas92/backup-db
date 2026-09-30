# shellcheck shell=bash
# Fungsi bersama untuk semua script backup.

set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
unset CDPATH BASH_ENV ENV TEMP_CREDENTIAL_FILE

log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$ENGINE" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Command tidak ditemukan: $1"; }
required() { [[ -n ${!1:-} ]] || die "Isi $1 di .env"; }

escape_quoted_value() {
    local value=$1
    [[ ! $value =~ [[:cntrl:]] ]] || die "Credential tidak boleh mengandung control character"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

escape_pgpass_value() {
    local value=$1
    [[ ! $value =~ [[:cntrl:]] ]] || die "Credential tidak boleh mengandung control character"
    value=${value//\\/\\\\}
    value=${value//:/\\:}
    printf '%s' "$value"
}

secure_file() {
    local file=$1 mode
    [[ $file == /* && -f $file && ! -L $file ]] \
        || die "File harus regular, bukan symlink, dan memakai absolute path: $file"
    [[ -O $file ]] || die "File harus dimiliki user yang menjalankan backup: $file"
    mode=$(stat -c '%a' -- "$file")
    (( (8#$mode & 077) == 0 )) || die "Jalankan chmod 600 pada: $file"
}

load_config() {
    [[ $# == 1 ]] || die "Cara pakai: $0 [/absolute/path/.env]"
    secure_file "$1"

    # .env adalah file Bash tepercaya milik administrator.
    # shellcheck disable=SC1090
    source "$1"

    required GCS_URI
    : "${BACKUP_DIR:=$SCRIPT_DIR/backups}"
    : "${BACKUP_TIMEOUT_SECONDS:=21600}"
    : "${UPLOAD_TIMEOUT_SECONDS:=7200}"

    [[ $GCS_URI =~ ^gs://[a-z0-9][a-z0-9._-]+(/[a-zA-Z0-9._/-]+)?$ ]] \
        || die "GCS_URI tidak valid: $GCS_URI"
    [[ $BACKUP_DIR == /* ]] || die "BACKUP_DIR harus absolute path"
    [[ $BACKUP_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || die "BACKUP_TIMEOUT_SECONDS tidak valid"
    [[ $UPLOAD_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || die "UPLOAD_TIMEOUT_SECONDS tidak valid"

    for command in flock mktemp sha256sum stat timeout openssl base64 gcloud; do
        need "$command"
    done
}

set_backup_name() {
    local name=$1
    [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$ ]] \
        || die "Nama backup tidak valid: $name"
    BACKUP_NAME=$name
}

cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z ${TEMP_CREDENTIAL_FILE:-} ]] || rm -f -- "$TEMP_CREDENTIAL_FILE"
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
    required BACKUP_NAME
    mkdir -p -- "$BACKUP_DIR"
    [[ -d $BACKUP_DIR && ! -L $BACKUP_DIR && -O $BACKUP_DIR ]] \
        || die "BACKUP_DIR harus private dan dimiliki user backup"
    local mode
    mode=$(stat -c '%a' -- "$BACKUP_DIR")
    (( (8#$mode & 077) == 0 )) || die "Jalankan chmod 700 pada $BACKUP_DIR"

    if [[ -n ${GCP_SERVICE_ACCOUNT_FILE:-} ]]; then
        secure_file "$GCP_SERVICE_ACCOUNT_FILE"
        CLOUDSDK_CONFIG="$BACKUP_DIR/.gcloud"
        export CLOUDSDK_CONFIG
        mkdir -p -- "$CLOUDSDK_CONFIG"
        chmod 700 "$CLOUDSDK_CONFIG"
        [[ -d $CLOUDSDK_CONFIG && ! -L $CLOUDSDK_CONFIG && -O $CLOUDSDK_CONFIG ]] \
            || die "Folder konfigurasi gcloud tidak aman: $CLOUDSDK_CONFIG"
        log "Aktifkan service account GCS"
        timeout --signal=TERM --kill-after=30s "${UPLOAD_TIMEOUT_SECONDS}s" \
            gcloud auth activate-service-account \
            --key-file="$GCP_SERVICE_ACCOUNT_FILE" --quiet >/dev/null
    fi

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
    md5=$(openssl dgst -md5 -binary "$file" | base64 | tr -d '\n')

    timeout --signal=TERM --kill-after=30s "${UPLOAD_TIMEOUT_SECONDS}s" \
        gcloud storage cp "$file" "$uri" \
        --if-generation-match=0 --content-md5="$md5" --quiet

    metadata=$(timeout --signal=TERM --kill-after=30s "${UPLOAD_TIMEOUT_SECONDS}s" \
        gcloud storage objects describe "$uri" --raw \
        --format='value(size,md5Hash)')
    IFS=$'\t' read -r remote_size remote_md5 <<<"$metadata"
    remote_md5=${remote_md5%$'\r'}
    [[ $remote_size == "$size" && $remote_md5 == "$md5" ]] \
        || die "Verifikasi object GCS gagal: $uri"
}
