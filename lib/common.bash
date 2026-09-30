# shellcheck shell=bash
# Fungsi bersama untuk semua script backup.

set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
unset CDPATH BASH_ENV ENV TEMP_CREDENTIAL_FILE

log() {
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$ENGINE" "$*" >&2
}

die() {
    BACKUP_LAST_ERROR="$*"
    log "ERROR: $*"
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "Command tidak ditemukan: $1"
}

required() {
    [[ -n ${!1:-} ]] || die "Isi $1 di .env"
}

bool_value() {
    case "${1:-false}" in
        true|TRUE|1|yes|YES) return 0 ;;
        false|FALSE|0|no|NO|'') return 1 ;;
        *) return 2 ;;
    esac
}

escape_quoted_value() {
    local value=$1

    [[ ! $value =~ [[:cntrl:]] ]] \
        || die "Credential tidak boleh mengandung control character"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}

    printf '%s' "$value"
}

escape_pgpass_value() {
    local value=$1

    [[ ! $value =~ [[:cntrl:]] ]] \
        || die "Credential tidak boleh mengandung control character"

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

html_escape() {
    printf '%s' "$1" |
        sed \
            -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g'
}

secure_file() {
    local file=$1
    local mode

    [[ $file == /* && -f $file && ! -L $file ]] \
        || die "File harus regular, bukan symlink, dan memakai absolute path: $file"

    [[ -O $file ]] \
        || die "File harus dimiliki user yang menjalankan backup: $file"

    mode=$(stat -c '%a' -- "$file")

    (( (8#$mode & 077) == 0 )) \
        || die "Jalankan chmod 600 pada: $file"
}

secure_dir() {
    local dir=$1
    local mode

    mkdir -p -- "$dir"

    [[ -d $dir && ! -L $dir && -O $dir ]] \
        || die "Folder harus private dan dimiliki user backup: $dir"

    mode=$(stat -c '%a' -- "$dir")

    (( (8#$mode & 077) == 0 )) \
        || die "Jalankan chmod 700 pada: $dir"
}

init_logging() {
    : "${LOG_DIR:=$SCRIPT_DIR/logs}"

    [[ $LOG_DIR == /* ]] \
        || die "LOG_DIR harus absolute path"

    secure_dir "$LOG_DIR"
    need tee

    if [[ ${BACKUP_LOG_ACTIVE:-0} != 1 ]]; then
        LOG_FILE="$LOG_DIR/${ENGINE}-$(date -u +%Y%m%d).log"

        export LOG_FILE
        export BACKUP_LOG_ACTIVE=1

        exec 3>&2
        exec > >(tee -a "$LOG_FILE" >&3) 2>&1
    fi
}

validate_notification_config() {
    local name
    local value
    local rc

    for name in \
        NOTIFY_ON_SUCCESS \
        NOTIFY_ON_WARNING \
        NOTIFY_ON_FAILURE \
        NOTIFY_DISCORD \
        NOTIFY_TELEGRAM
    do
        value=${!name:-false}

        if bool_value "$value"; then
            :
        else
            rc=$?

            (( rc == 1 )) \
                || die "$name harus true/false"
        fi
    done

    if bool_value "${NOTIFY_DISCORD:-false}"; then
        required DISCORD_WEBHOOK_URL

        [[ $DISCORD_WEBHOOK_URL == https://* ]] \
            || die "DISCORD_WEBHOOK_URL harus HTTPS"
    fi

    if bool_value "${NOTIFY_TELEGRAM:-false}"; then
        required TELEGRAM_BOT_TOKEN
        required TELEGRAM_CHAT_ID
    fi
}

load_config() {
    [[ $# == 1 ]] \
        || die "Cara pakai: $0 [/absolute/path/.env]"

    secure_file "$1"

    # shellcheck disable=SC1090
    source "$1"

    required GCS_URI

    : "${BACKUP_DIR:=$SCRIPT_DIR/backups}"
    : "${LOG_DIR:=$SCRIPT_DIR/logs}"

    : "${BACKUP_TIMEOUT_SECONDS:=21600}"
    : "${UPLOAD_TIMEOUT_SECONDS:=7200}"
    : "${UPLOAD_RETRIES:=3}"
    : "${UPLOAD_RETRY_DELAY_SECONDS:=10}"

    : "${BACKUP_HOST_NAME:=}"
    : "${NOTIFY_TIMEZONE:=Asia/Makassar}"

    : "${NOTIFY_ON_SUCCESS:=true}"
    : "${NOTIFY_ON_WARNING:=true}"
    : "${NOTIFY_ON_FAILURE:=true}"

    : "${NOTIFY_DISCORD:=false}"
    : "${NOTIFY_TELEGRAM:=false}"

    [[ $GCS_URI =~ ^gs://[a-z0-9][a-z0-9._-]+(/[a-zA-Z0-9._/-]+)?$ ]] \
        || die "GCS_URI tidak valid: $GCS_URI"

    [[ $BACKUP_DIR == /* ]] \
        || die "BACKUP_DIR harus absolute path"

    [[ $LOG_DIR == /* ]] \
        || die "LOG_DIR harus absolute path"

    [[ $BACKUP_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] \
        || die "BACKUP_TIMEOUT_SECONDS tidak valid"

    [[ $UPLOAD_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] \
        || die "UPLOAD_TIMEOUT_SECONDS tidak valid"

    [[ $UPLOAD_RETRIES =~ ^[1-9][0-9]*$ \
       && $UPLOAD_RETRIES -le 10 ]] \
        || die "UPLOAD_RETRIES harus 1-10"

    [[ $UPLOAD_RETRY_DELAY_SECONDS =~ ^[1-9][0-9]*$ \
       && $UPLOAD_RETRY_DELAY_SECONDS -le 600 ]] \
        || die "UPLOAD_RETRY_DELAY_SECONDS harus 1-600"

    for command in \
        flock \
        mktemp \
        sha256sum \
        stat \
        timeout \
        openssl \
        base64 \
        gcloud \
        curl \
        hostname \
        awk \
        sed
    do
        need "$command"
    done

    init_logging
    validate_notification_config

    BACKUP_STARTED_EPOCH=$(date +%s)

    BACKUP_WARNING_COUNT=0
    BACKUP_FIRST_WARNING=''
    BACKUP_LAST_ERROR=''

    BACKUP_REMOTE_URI=''
    BACKUP_ARTIFACT_SIZE=''
    BACKUP_SKIPPED_OBJECTS=''

    export BACKUP_STARTED_EPOCH
    export BACKUP_WARNING_COUNT
    export BACKUP_FIRST_WARNING
    export BACKUP_LAST_ERROR

    trap finalize_backup_script EXIT
}

set_backup_name() {
    local name=$1

    [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$ ]] \
        || die "Nama backup tidak valid: $name"

    BACKUP_NAME=$name
}

mark_warning() {
    local msg=$*

    BACKUP_WARNING_COUNT=$(( ${BACKUP_WARNING_COUNT:-0} + 1 ))

    if [[ -z ${BACKUP_FIRST_WARNING:-} ]]; then
        BACKUP_FIRST_WARNING=$msg
    fi

    log "WARNING: $msg"

    if [[ -n ${BACKUP_STATUS_FILE:-} ]]; then
        printf 'WARNING\t%s\n' \
            "$msg" \
            >>"$BACKUP_STATUS_FILE"
    fi
}

mark_skipped_object() {
    local object=$1

    object=${object//$'\n'/ }
    object=${object//$'\r'/ }

    [[ -n $object ]] || return 0

    if [[ $'\n'"${BACKUP_SKIPPED_OBJECTS:-}"$'\n' \
          == *$'\n'"$object"$'\n'* ]]
    then
        return 0
    fi

    if [[ -n ${BACKUP_SKIPPED_OBJECTS:-} ]]; then
        BACKUP_SKIPPED_OBJECTS+=$'\n'
    fi

    BACKUP_SKIPPED_OBJECTS+="$object"

    if [[ -n ${BACKUP_STATUS_FILE:-} ]]; then
        printf 'SKIPPED\t%s\n' \
            "$object" \
            >>"$BACKUP_STATUS_FILE"
    fi
}

cleanup_resources() {
    local rc=$1

    if [[ -n ${TEMP_CREDENTIAL_FILE:-} ]]; then
        rm -f -- "$TEMP_CREDENTIAL_FILE"
    fi

    if [[ -n ${RUN_DIR:-} && -d $RUN_DIR ]]; then
        if (( rc == 0 )); then
            rm -rf -- "$RUN_DIR"
        else
            log "Backup gagal; file sementara disimpan di $RUN_DIR"
        fi
    fi
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

        timeout \
            --signal=TERM \
            --kill-after=30s \
            "${UPLOAD_TIMEOUT_SECONDS}s" \
            gcloud auth activate-service-account \
            --key-file="$GCP_SERVICE_ACCOUNT_FILE" \
            --quiet \
            >/dev/null
    fi

    exec 9>"$BACKUP_DIR/.${ENGINE}-${BACKUP_NAME}.lock"

    flock -n 9 \
        || die "Backup yang sama masih berjalan"

    STAMP=$(date -u +%Y%m%dT%H%M%SZ)

    RUN_DIR=$(
        mktemp -d \
            "$BACKUP_DIR/.${ENGINE}-${BACKUP_NAME}-${STAMP}.XXXXXX"
    )

    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    log "Mulai backup $BACKUP_NAME"
}

run_backup() {
    timeout \
        --signal=TERM \
        --kill-after=30s \
        "${BACKUP_TIMEOUT_SECONDS}s" \
        "$@"
}

retry_cmd() {
    local attempts=$1
    local delay=$2
    local label=$3

    shift 3

    local n=1
    local rc=0

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

_upload_cp() {
    local file=$1
    local uri=$2
    local md5=$3

    timeout \
        --signal=TERM \
        --kill-after=30s \
        "${UPLOAD_TIMEOUT_SECONDS}s" \
        gcloud storage cp \
        "$file" \
        "$uri" \
        --if-generation-match=0 \
        --content-md5="$md5" \
        --quiet
}

_upload_describe() {
    local uri=$1

    timeout \
        --signal=TERM \
        --kill-after=30s \
        "${UPLOAD_TIMEOUT_SECONDS}s" \
        gcloud storage objects describe \
        "$uri" \
        --raw \
        --format='value(size,md5Hash)'
}

upload_one() {
    local file=$1
    local uri=$2

    local size
    local md5

    local metadata
    local remote_size
    local remote_md5

    size=$(stat -c %s -- "$file")

    md5=$(
        openssl dgst -md5 -binary "$file" |
            base64 |
            tr -d '\n'
    )

    retry_cmd \
        "$UPLOAD_RETRIES" \
        "$UPLOAD_RETRY_DELAY_SECONDS" \
        "Upload GCS $uri" \
        _upload_cp \
        "$file" \
        "$uri" \
        "$md5" \
        || die "Upload GCS gagal setelah $UPLOAD_RETRIES percobaan: $uri"

    metadata=$(
        retry_cmd \
            "$UPLOAD_RETRIES" \
            "$UPLOAD_RETRY_DELAY_SECONDS" \
            "Verifikasi GCS $uri" \
            _upload_describe \
            "$uri"
    ) || die "Tidak dapat membaca metadata object GCS: $uri"

    IFS=$'\t' read -r \
        remote_size \
        remote_md5 \
        <<<"$metadata"

    remote_md5=${remote_md5%$'\r'}

    [[ $remote_size == "$size" \
       && $remote_md5 == "$md5" ]] \
        || die "Verifikasi object GCS gagal: $uri"
}

upload_backup() {
    local artifact=$1

    local filename
    local checksum
    local remote

    [[ -s $artifact ]] \
        || die "Hasil backup kosong"

    filename=${artifact##*/}

    checksum="$artifact.sha256"

    (
        cd "$RUN_DIR"

        sha256sum "$filename" \
            >"$filename.sha256"
    )

    remote="${GCS_URI%/}/$ENGINE/$BACKUP_NAME"

    export CLOUDSDK_CORE_DISABLE_PROMPTS=1
    export CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=False

    log "Upload $filename ke $remote/"

    upload_one \
        "$artifact" \
        "$remote/$filename"

    upload_one \
        "$checksum" \
        "$remote/$filename.sha256"

    BACKUP_REMOTE_URI="$remote/$filename"

    BACKUP_ARTIFACT_SIZE=$(
        stat -c %s -- "$artifact"
    )

    log "SUCCESS: $BACKUP_REMOTE_URI"
}

_curl_secret_url() {
    local url=$1

    shift

    local cfg
    local rc
    local escaped

    cfg=$(mktemp)

    chmod 600 "$cfg"

    # Supaya webhook/token tidak tampil di process list.
    escaped=${url//\\/\\\\}
    escaped=${escaped//\"/\\\"}

    printf 'url = "%s"\n' \
        "$escaped" \
        >"$cfg"

    if curl \
        --config "$cfg" \
        "$@"
    then
        rc=0
    else
        rc=$?
    fi

    rm -f -- "$cfg"

    return "$rc"
}

backup_display_host() {
    if [[ -n ${BACKUP_HOST_NAME:-} ]]; then
        printf '%s' \
            "$BACKUP_HOST_NAME"
    else
        hostname -f 2>/dev/null \
            || hostname
    fi
}

backup_display_label() {
    case "${ENGINE:-backup}" in

        mongodb)
            printf 'MongoDB'
            ;;

        mariadb)
            printf 'MariaDB Logical'
            ;;

        mariadb-physical)
            printf 'MariaDB Physical'
            ;;

        postgresql)
            printf 'PostgreSQL'
            ;;

        backup-all)
            printf 'All Databases'
            ;;

        *)
            printf '%s' \
                "${ENGINE:-backup}"
            ;;
    esac
}

notification_title() {
    case "$1" in

        SUCCESS)
            printf '✅ DATABASE BACKUP SUCCESS'
            ;;

        WARNING)
            printf '⚠️ DATABASE BACKUP WARNING'
            ;;

        FAILED)
            printf '❌ DATABASE BACKUP FAILED'
            ;;

        *)
            printf 'DATABASE BACKUP'
            ;;
    esac
}

notification_color() {
    case "$1" in

        SUCCESS)
            printf '5763719'
            ;;

        WARNING)
            printf '16705372'
            ;;

        FAILED)
            printf '15548997'
            ;;

        *)
            printf '9807270'
            ;;
    esac
}

notification_time() {
    TZ="${NOTIFY_TIMEZONE:-Asia/Makassar}" \
        date '+%d %b %Y %H:%M %Z'
}

format_duration() {
    local total=${1:-0}

    local h
    local m
    local s

    (( total < 0 )) \
        && total=0

    h=$(( total / 3600 ))

    m=$(( (total % 3600) / 60 ))

    s=$(( total % 60 ))

    if (( h > 0 )); then

        printf '%dh %dm %ds' \
            "$h" \
            "$m" \
            "$s"

    elif (( m > 0 )); then

        printf '%dm %ds' \
            "$m" \
            "$s"

    else

        printf '%ds' \
            "$s"
    fi
}

human_bytes() {
    local bytes=${1:-0}

    awk \
        -v b="$bytes" \
        '
        BEGIN {

            split(
                "B KB MB GB TB",
                u,
                " "
            )

            i=1

            while (
                b >= 1024 &&
                i < 5
            ) {

                b /= 1024

                i++
            }

            if (i == 1)
                printf "%.0f %s", b, u[i]
            else
                printf "%.2f %s", b, u[i]
        }
        '
}

build_standalone_notification() {
    local status=$1
    local rc=$2

    local host
    local label
    local duration
    local finished

    local message
    local size
    local object

    host=$(
        backup_display_host
    )

    label=$(
        backup_display_label
    )

    duration=$(
        format_duration \
            "$(( $(date +%s) - ${BACKUP_STARTED_EPOCH:-$(date +%s)} ))"
    )

    finished=$(
        notification_time
    )

    message="🖥 Host
$host

🗄 Backup
$label"

    if [[ -n ${BACKUP_REMOTE_URI:-} ]]; then

        message+=$'\n\n'"☁️ GCS
✅ Uploaded & verified

$BACKUP_REMOTE_URI"

    elif [[ $status == FAILED ]]; then

        message+=$'\n\n'"☁️ GCS
❌ Not uploaded"

    else

        message+=$'\n\n'"☁️ GCS
$GCS_URI"
    fi

    if [[ -n ${BACKUP_ARTIFACT_SIZE:-} ]]; then

        size=$(
            human_bytes \
                "$BACKUP_ARTIFACT_SIZE"
        )

        message+=$'\n\n'"📦 Size
$size"
    fi

    message+=$'\n\n'"⏱ Duration
$duration"

    message+=$'\n\n'"🕒 Finished
$finished"

    if [[ $status == WARNING ]]; then

        message+=$'\n\n'"⚠️ Issues
${BACKUP_WARNING_COUNT:-1} warning(s)"

        if [[ -n ${BACKUP_SKIPPED_OBJECTS:-} ]]; then

            message+=$'\n\n'"Skipped objects:"

            while IFS= read -r object; do

                [[ -n $object ]] \
                    || continue

                message+=$'\n'"• $object"

            done <<<"$BACKUP_SKIPPED_OBJECTS"
        fi

        if [[ -n ${BACKUP_FIRST_WARNING:-} ]]; then

            message+=$'\n\n'"ℹ️ Detail
$BACKUP_FIRST_WARNING"
        fi

        message+=$'\n\n'"🔎 Log
${LOG_FILE:-$LOG_DIR}"
    fi

    if [[ $status == FAILED ]]; then

        message+=$'\n\n'"❌ Error"

        if [[ -n ${BACKUP_LAST_ERROR:-} ]]; then

            message+=$'\n'"$BACKUP_LAST_ERROR"

        else

            message+=$'\n'"Backup command failed. Check log."
        fi

        message+=$'\n\n'"Exit code
$rc"

        if [[ -n ${RUN_DIR:-} \
              && -d ${RUN_DIR:-} ]]
        then

            message+=$'\n\n'"📁 Local staging
$RUN_DIR"
        fi

        message+=$'\n\n'"🔎 Log
${LOG_FILE:-$LOG_DIR}"
    fi

    printf '%s' \
        "$message"
}

_notify_discord_once() {
    local payload=$1

    _curl_secret_url \
        "$DISCORD_WEBHOOK_URL" \
        -fsS \
        --connect-timeout 10 \
        --max-time 60 \
        -H 'Content-Type: application/json' \
        --data-binary "$payload" \
        >/dev/null
}

notify_discord() {
    local status=$1
    local message=$2

    local title
    local color
    local payload
    local timestamp

    [[ -n ${DISCORD_WEBHOOK_URL:-} ]] \
        || return 0

    title=$(
        notification_title \
            "$status"
    )

    color=$(
        notification_color \
            "$status"
    )

    timestamp=$(
        date -u +%FT%TZ
    )

    payload=$(
        printf \
            '{"username":"DB Backup Monitor","allowed_mentions":{"parse":[]},"embeds":[{"title":"%s","description":"%s","color":%s,"timestamp":"%s","footer":{"text":"Database Backup Monitoring"}}]}' \
            "$(json_escape "$title")" \
            "$(json_escape "$message")" \
            "$color" \
            "$timestamp"
    )

    retry_cmd \
        3 \
        3 \
        "Notifikasi Discord" \
        _notify_discord_once \
        "$payload"
}

_notify_telegram_once() {
    local url=$1
    local telegram_text=$2

    # Server ini stabil ke Telegram memakai TLS 1.2 + HTTP/1.1.
    _curl_secret_url \
        "$url" \
        --tls-max 1.2 \
        --http1.1 \
        -fsS \
        --connect-timeout 10 \
        --max-time 60 \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode 'parse_mode=HTML' \
        --data-urlencode "text=$telegram_text" \
        --data 'disable_web_page_preview=true' \
        >/dev/null
}

notify_telegram() {
    local status=$1
    local message=$2

    local url
    local title
    local telegram_text

    [[ -n ${TELEGRAM_BOT_TOKEN:-} \
       && -n ${TELEGRAM_CHAT_ID:-} ]] \
        || return 0

    url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

    title=$(
        notification_title \
            "$status"
    )

    telegram_text="<b>$(html_escape "$title")</b>

$(html_escape "$message")"

    retry_cmd \
        3 \
        3 \
        "Notifikasi Telegram" \
        _notify_telegram_once \
        "$url" \
        "$telegram_text"
}

send_notifications() {
    local status=$1
    local message=$2

    local should_send=false

    case "$status" in

        SUCCESS)

            bool_value "${NOTIFY_ON_SUCCESS:-true}" \
                && should_send=true \
                || true
            ;;

        WARNING)

            bool_value "${NOTIFY_ON_WARNING:-true}" \
                && should_send=true \
                || true
            ;;

        FAILED)

            bool_value "${NOTIFY_ON_FAILURE:-true}" \
                && should_send=true \
                || true
            ;;

        *)

            return 0
            ;;
    esac

    [[ $should_send == true ]] \
        || return 0

    if bool_value "${NOTIFY_DISCORD:-false}"; then

        if notify_discord \
            "$status" \
            "$message"
        then

            log "Notifikasi Discord terkirim"

        else

            log "WARNING: Notifikasi Discord gagal dikirim"
        fi
    fi

    if bool_value "${NOTIFY_TELEGRAM:-false}"; then

        if notify_telegram \
            "$status" \
            "$message"
        then

            log "Notifikasi Telegram terkirim"

        else

            log "WARNING: Notifikasi Telegram gagal dikirim"
        fi
    fi
}

finalize_backup_script() {
    local rc=$?

    local status
    local message

    trap - EXIT

    # Notification tidak boleh mengubah exit code asli backup.
    set +e

    if (( rc != 0 )); then

        status='FAILED'

    elif (( ${BACKUP_WARNING_COUNT:-0} > 0 )); then

        status='WARNING'

    else

        status='SUCCESS'
    fi

    # Berlaku untuk MongoDB, MariaDB, MariaDB physical, PostgreSQL.
    # Kalau dipanggil lewat backup-all.sh, notif individual dimatikan.
    if [[ ${BACKUP_SUPPRESS_STANDALONE_NOTIFY:-0} != 1 ]]; then

        message=$(
            build_standalone_notification \
                "$status" \
                "$rc"
        )

        send_notifications \
            "$status" \
            "$message" \
            || true
    fi

    cleanup_resources "$rc"

    exit "$rc"
}