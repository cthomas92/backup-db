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

bool_value() {
    case "${1:-false}" in
        true|TRUE|1|yes|YES) return 0 ;;
        false|FALSE|0|no|NO|'') return 1 ;;
        *) return 2 ;;
    esac
}

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

json_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
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

secure_dir() {
    local dir=$1 mode
    mkdir -p -- "$dir"
    [[ -d $dir && ! -L $dir && -O $dir ]] \
        || die "Folder harus private dan dimiliki user backup: $dir"
    mode=$(stat -c '%a' -- "$dir")
    (( (8#$mode & 077) == 0 )) || die "Jalankan chmod 700 pada: $dir"
}

init_logging() {
    : "${LOG_DIR:=$SCRIPT_DIR/logs}"
    [[ $LOG_DIR == /* ]] || die "LOG_DIR harus absolute path"
    secure_dir "$LOG_DIR"
    need tee

    # Jika dipanggil dari backup-all.sh, semua child mewarisi logger parent.
    if [[ ${BACKUP_LOG_ACTIVE:-0} != 1 ]]; then
        LOG_FILE="$LOG_DIR/${ENGINE}-$(date -u +%Y%m%d).log"
        export LOG_FILE BACKUP_LOG_ACTIVE=1
        exec 3>&2
        exec > >(tee -a "$LOG_FILE" >&3) 2>&1
    fi
}

load_config() {
    [[ $# == 1 ]] || die "Cara pakai: $0 [/absolute/path/.env]"
    secure_file "$1"

    # .env adalah file Bash tepercaya milik administrator.
    # shellcheck disable=SC1090
    source "$1"

    required GCS_URI
    : "${BACKUP_DIR:=$SCRIPT_DIR/backups}"
    : "${LOG_DIR:=$SCRIPT_DIR/logs}"
    : "${BACKUP_TIMEOUT_SECONDS:=21600}"
    : "${UPLOAD_TIMEOUT_SECONDS:=7200}"
    : "${UPLOAD_RETRIES:=3}"
    : "${UPLOAD_RETRY_DELAY_SECONDS:=10}"

    [[ $GCS_URI =~ ^gs://[a-z0-9][a-z0-9._-]+(/[a-zA-Z0-9._/-]+)?$ ]] \
        || die "GCS_URI tidak valid: $GCS_URI"
    [[ $BACKUP_DIR == /* ]] || die "BACKUP_DIR harus absolute path"
    [[ $LOG_DIR == /* ]] || die "LOG_DIR harus absolute path"
    [[ $BACKUP_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || die "BACKUP_TIMEOUT_SECONDS tidak valid"
    [[ $UPLOAD_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || die "UPLOAD_TIMEOUT_SECONDS tidak valid"
    [[ $UPLOAD_RETRIES =~ ^[1-9][0-9]*$ && $UPLOAD_RETRIES -le 10 ]] || die "UPLOAD_RETRIES harus 1-10"
    [[ $UPLOAD_RETRY_DELAY_SECONDS =~ ^[1-9][0-9]*$ && $UPLOAD_RETRY_DELAY_SECONDS -le 600 ]] \
        || die "UPLOAD_RETRY_DELAY_SECONDS harus 1-600"

    for command in flock mktemp sha256sum stat timeout openssl base64 gcloud curl hostname; do
        need "$command"
    done
    init_logging
}

set_backup_name() {
    local name=$1
    [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$ ]] \
        || die "Nama backup tidak valid: $name"
    BACKUP_NAME=$name
}

mark_warning() {
    local msg=$*
    log "WARNING: $msg"
    if [[ -n ${BACKUP_STATUS_FILE:-} ]]; then
        printf 'WARNING\t%s\n' "$msg" >>"$BACKUP_STATUS_FILE"
    fi
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
    secure_dir "$BACKUP_DIR"

    if [[ -n ${GCP_SERVICE_ACCOUNT_FILE:-} ]]; then
        secure_file "$GCP_SERVICE_ACCOUNT_FILE"
        CLOUDSDK_CONFIG="$BACKUP_DIR/.gcloud"
        export CLOUDSDK_CONFIG
        secure_dir "$CLOUDSDK_CONFIG"
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

retry_cmd() {
    local attempts=$1 delay=$2 label=$3
    shift 3
    local n=1 rc=0
    while (( n <= attempts )); do
        if "$@"; then
            return 0
        else
            rc=$?
        fi
        if (( n == attempts )); then
            break
        fi
        log "WARNING: $label gagal (percobaan $n/$attempts), retry dalam ${delay}s"
        sleep "$delay"
        ((n++))
    done
    return "$rc"
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

_upload_cp() {
    local file=$1 uri=$2 md5=$3
    timeout --signal=TERM --kill-after=30s "${UPLOAD_TIMEOUT_SECONDS}s" \
        gcloud storage cp "$file" "$uri" \
        --if-generation-match=0 --content-md5="$md5" --quiet
}

_upload_describe() {
    local uri=$1
    timeout --signal=TERM --kill-after=30s "${UPLOAD_TIMEOUT_SECONDS}s" \
        gcloud storage objects describe "$uri" --raw \
        --format='value(size,md5Hash)'
}

upload_one() {
    local file=$1 uri=$2 size md5 metadata remote_size remote_md5
    size=$(stat -c %s -- "$file")
    md5=$(openssl dgst -md5 -binary "$file" | base64 | tr -d '\n')

    retry_cmd "$UPLOAD_RETRIES" "$UPLOAD_RETRY_DELAY_SECONDS" "Upload GCS $uri" \
        _upload_cp "$file" "$uri" "$md5" \
        || die "Upload GCS gagal setelah $UPLOAD_RETRIES percobaan: $uri"

    metadata=$(retry_cmd "$UPLOAD_RETRIES" "$UPLOAD_RETRY_DELAY_SECONDS" "Verifikasi GCS $uri" \
        _upload_describe "$uri") \
        || die "Tidak dapat membaca metadata object GCS: $uri"
    IFS=$'\t' read -r remote_size remote_md5 <<<"$metadata"
    remote_md5=${remote_md5%$'\r'}
    [[ $remote_size == "$size" && $remote_md5 == "$md5" ]] \
        || die "Verifikasi object GCS gagal: $uri"
}

_curl_secret_url() {
    local url=$1
    shift
    local cfg rc
    cfg=$(mktemp)
    chmod 600 "$cfg"
    # Curl config: escape backslash dan quote agar URL secret tidak muncul di process list.
    local escaped=${url//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    printf 'url = "%s"\n' "$escaped" >"$cfg"
    set +e
    curl --config "$cfg" "$@"
    rc=$?
    set -e
    rm -f -- "$cfg"
    return "$rc"
}

notify_discord() {
    local message=$1 payload
    [[ -n ${DISCORD_WEBHOOK_URL:-} ]] || return 0
    payload=$(printf '{"content":"%s"}' "$(json_escape "$message")")
    _curl_secret_url "$DISCORD_WEBHOOK_URL" \
        -fsS --connect-timeout 10 --max-time 30 \
        -H 'Content-Type: application/json' \
        --data-binary "$payload" >/dev/null
}

notify_telegram() {
    local message=$1 url
    [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]] || return 0
    url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    _curl_secret_url "$url" \
        -fsS --connect-timeout 10 --max-time 30 \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data 'disable_web_page_preview=true' >/dev/null
}

send_notifications() {
    local status=$1 message=$2 should_send=false

    case "$status" in
        SUCCESS) bool_value "${NOTIFY_ON_SUCCESS:-true}" && should_send=true || true ;;
        WARNING) bool_value "${NOTIFY_ON_WARNING:-true}" && should_send=true || true ;;
        FAILED)  bool_value "${NOTIFY_ON_FAILURE:-true}" && should_send=true || true ;;
        *) return 0 ;;
    esac
    [[ $should_send == true ]] || return 0

    if bool_value "${NOTIFY_DISCORD:-false}"; then
        if notify_discord "$message"; then
            log "Notifikasi Discord terkirim"
        else
            log "WARNING: Notifikasi Discord gagal dikirim"
        fi
    fi
    if bool_value "${NOTIFY_TELEGRAM:-false}"; then
        if notify_telegram "$message"; then
            log "Notifikasi Telegram terkirim"
        else
            log "WARNING: Notifikasi Telegram gagal dikirim"
        fi
    fi
}
