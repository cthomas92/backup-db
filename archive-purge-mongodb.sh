#!/usr/bin/env bash

# Archive data MongoDB lama ke GCS per rentang waktu. Mode --delete tetap
# menghapus hanya setelah backup terverifikasi; --delete-only adalah aksi
# terpisah dengan konfirmasi dan daftar tahun terlindungi tersendiri.
# Optimized v2: aggregation boundary; index-aware batched purge; guarded delete.
# Fail-closed if dump, verification, or GCS upload fails.
# Tidak menyentuh lib/common.bash dan format archive/GCS existing.

ENGINE=mongodb-archive
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"

mode=''
config_file="$SCRIPT_DIR/.env"

usage() {
    printf 'Cara pakai:\n'
    printf '  %s --check-years [/.env]\n' "$0"
    printf '  %s --backup [/.env]\n' "$0"
    printf '  %s --delete [/.env]\n' "$0"
    printf '  %s --delete-only [/.env]\n' "$0"
    printf '\nTahun selalu dibaca dari MONGO_ARCHIVE_YEARS di .env.\n'
    printf 'Khusus --delete-only: gunakan daftar tahun atau all; auto ditolak.\n'
}

case $# in
    1|2)
        case $1 in
            --check-years)
                mode=check-years
                ;;
            --backup)
                mode=backup
                ;;
            --delete)
                mode=delete
                ;;
            --delete-only)
                mode=delete-only
                ;;
            --help|-h)
                (( $# == 1 )) || { usage >&2; exit 2; }
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
        if (( $# == 2 )); then
            config_file=$2
        fi
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if [[ $mode == check-years || $mode == delete-only ]]; then
    export BACKUP_SUPPRESS_STANDALONE_NOTIFY=1
fi

load_config "$config_file"

# Action ditentukan command; tahun tetap dibaca dari MONGO_ARCHIVE_YEARS di .env.
case $mode in
    check-years|backup)
        MONGO_ARCHIVE_DELETE_AFTER_UPLOAD=false
        ;;
    delete)
        MONGO_ARCHIVE_DELETE_AFTER_UPLOAD=true
        ;;
    delete-only)
        MONGO_ARCHIVE_DELETE_AFTER_UPLOAD=false
        ;;
esac

if [[ $mode == check-years || $mode == delete-only ]]; then
    # Pemeriksaan tahun dan delete-only tidak mengakses GCS.
    GCP_SERVICE_ACCOUNT_FILE=''
fi

for command in mongosh grep awk sort date; do
    need "$command"
done

if [[ $mode == backup || $mode == delete ]]; then
    for command in mongodump mongorestore gzip df wc; do
        need "$command"
    done
fi

required MONGO_USER
required MONGO_PASSWORD
required MONGO_ARCHIVE_DATABASE
if [[ $mode != check-years ]]; then
    required MONGO_ARCHIVE_YEARS
fi

: "${MONGO_HOST:=127.0.0.1}"
: "${MONGO_PORT:=27017}"
: "${MONGO_AUTH_DB:=admin}"
: "${MONGO_REPLICA_SET:=}"
: "${MONGO_TLS:=false}"
: "${MONGO_ARCHIVE_TIMEZONE:=UTC}"
: "${MONGO_ARCHIVE_CHUNK:=month}"
: "${MONGO_ARCHIVE_MIN_FREE_GB:=5}"
: "${MONGO_ARCHIVE_DELETE_BATCH_SIZE:=10000}"
: "${MONGO_ARCHIVE_OLD_DATA_IMMUTABLE:=false}"
: "${MONGO_ARCHIVE_WRITES_PAUSED:=false}"
# Notifikasi progres per periode (mulai backup, upload, hapus) + ringkasan akhir.
: "${MONGO_ARCHIVE_NOTIFY_PROGRESS:=true}"
# Jeda minimum antar notifikasi (detik) agar tidak kena rate limit Telegram/Discord.
: "${MONGO_ARCHIVE_NOTIFY_MIN_INTERVAL:=3}"
# Buat index {field_tanggal: 1} otomatis jika collection belum punya index
# yang bisa dipakai untuk field archive (hanya pada --backup/--delete).
# --delete-only tidak pernah membuat index atau perubahan lain selain delete.
: "${MONGO_ARCHIVE_AUTO_CREATE_INDEX:=true}"

validate_bool_setting() {
    local name=$1
    local rc

    if bool_value "${!name:-}"; then
        return 0
    else
        rc=$?
    fi

    (( rc == 1 )) || die "$name harus true/false"
    return 0
}

for name in \
    MONGO_TLS \
    MONGO_ARCHIVE_OLD_DATA_IMMUTABLE \
    MONGO_ARCHIVE_WRITES_PAUSED \
    MONGO_ARCHIVE_NOTIFY_PROGRESS \
    MONGO_ARCHIVE_AUTO_CREATE_INDEX
do
    validate_bool_setting "$name"
done

[[ $MONGO_PORT =~ ^[1-9][0-9]*$ && $MONGO_PORT -le 65535 ]] \
    || die "MONGO_PORT tidak valid"
[[ $MONGO_ARCHIVE_DATABASE =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] \
    || die "MONGO_ARCHIVE_DATABASE tidak valid"
[[ $MONGO_ARCHIVE_TIMEZONE =~ ^[a-zA-Z0-9_+.-]+(/[a-zA-Z0-9_+.-]+)*$ \
   && $MONGO_ARCHIVE_TIMEZONE != *..* \
   && -e /usr/share/zoneinfo/$MONGO_ARCHIVE_TIMEZONE ]] \
    || die "MONGO_ARCHIVE_TIMEZONE tidak valid"
[[ $MONGO_ARCHIVE_CHUNK == year \
   || $MONGO_ARCHIVE_CHUNK == month \
   || $MONGO_ARCHIVE_CHUNK == day ]] \
    || die "MONGO_ARCHIVE_CHUNK harus year, month, atau day"
[[ $MONGO_ARCHIVE_MIN_FREE_GB =~ ^[1-9][0-9]*$ ]] \
    || die "MONGO_ARCHIVE_MIN_FREE_GB tidak valid"
[[ $MONGO_ARCHIVE_DELETE_BATCH_SIZE =~ ^[1-9][0-9]*$ \
   && $MONGO_ARCHIVE_DELETE_BATCH_SIZE -le 100000 ]] \
    || die "MONGO_ARCHIVE_DELETE_BATCH_SIZE harus 1-100000"
[[ $MONGO_ARCHIVE_NOTIFY_MIN_INTERVAL =~ ^[0-9]+$ \
   && $MONGO_ARCHIVE_NOTIFY_MIN_INTERVAL -le 60 ]] \
    || die "MONGO_ARCHIVE_NOTIFY_MIN_INTERVAL harus 0-60"

# Validasi target GCS sebelum membuat atau menghapus backup apa pun.
if [[ $mode == backup || $mode == delete ]]; then
    required GCS_URI
    [[ $GCS_URI == gs://*/*/ && $GCS_URI != *' '* ]] \
        || die "GCS_URI harus berbentuk gs://nama-bucket/path/ dan diakhiri /"
fi

if [[ $mode == backup || $mode == delete ]]; then
    # Tampung dulu output --help: "cmd | grep -q" + pipefail bisa gagal acak
    # karena SIGPIPE saat grep berhenti lebih awal.
    restore_help=$(mongorestore --help 2>&1 || true)
    grep -q -- '--dryRun' <<<"$restore_help" \
        || die "mongorestore harus mendukung --dryRun untuk validasi archive"
fi

collections=()
date_fields=()
collection_specs=()

if declare -p MONGO_ARCHIVE_COLLECTIONS >/dev/null 2>&1; then
    collection_declaration=$(declare -p MONGO_ARCHIVE_COLLECTIONS)
    [[ $collection_declaration == 'declare -a '* ]] \
        || die "MONGO_ARCHIVE_COLLECTIONS harus Bash indexed array"
    (( ${#MONGO_ARCHIVE_COLLECTIONS[@]} > 0 )) \
        || die "MONGO_ARCHIVE_COLLECTIONS tidak boleh kosong"
    collection_specs=("${MONGO_ARCHIVE_COLLECTIONS[@]}")
else
    # Kompatibilitas sementara dengan format lama.
    required MONGO_ARCHIVE_COLLECTION_1
    required MONGO_ARCHIVE_DATE_FIELD_1
    collection_specs+=("${MONGO_ARCHIVE_COLLECTION_1}:${MONGO_ARCHIVE_DATE_FIELD_1}")

    if [[ -n ${MONGO_ARCHIVE_COLLECTION_2:-} \
       || -n ${MONGO_ARCHIVE_DATE_FIELD_2:-} ]]; then
        required MONGO_ARCHIVE_COLLECTION_2
        required MONGO_ARCHIVE_DATE_FIELD_2
        collection_specs+=("${MONGO_ARCHIVE_COLLECTION_2}:${MONGO_ARCHIVE_DATE_FIELD_2}")
    fi
fi

for collection_spec in "${collection_specs[@]}"; do
    [[ $collection_spec == *:* ]] \
        || die "Format collection harus NAMA_COLLECTION:FIELD_TANGGAL"

    collection_name=${collection_spec%%:*}
    date_field_name=${collection_spec#*:}

    [[ $collection_name =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] \
        || die "Nama collection tidak valid: $collection_name"
    [[ $date_field_name =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]] \
        || die "Field tanggal tidak valid untuk $collection_name: $date_field_name"

    for existing_collection in "${collections[@]}"; do
        [[ $existing_collection != "$collection_name" ]] \
            || die "Collection tercantum lebih dari sekali: $collection_name"
    done

    collections+=("$collection_name")
    date_fields+=("$date_field_name")
done

current_year=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date +%Y)

delete_only_protected_years=()

year_is_delete_only_protected() {
    local candidate=$1
    local protected_year

    for protected_year in "${delete_only_protected_years[@]}"; do
        [[ $candidate != "$protected_year" ]] || return 0
    done
    return 1
}

parse_delete_only_protected_years() {
    local raw=$1
    local token
    local start_year
    local end_year
    local year
    local -a tokens=()

    IFS=',' read -r -a tokens <<<"$raw"
    for token in "${tokens[@]}"; do
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"

        if [[ $token == current ]]; then
            start_year=$current_year
            end_year=$current_year
        elif [[ $token =~ ^([0-9]{4})-(current|[0-9]{4})$ ]]; then
            start_year=${BASH_REMATCH[1]}
            if [[ ${BASH_REMATCH[2]} == current ]]; then
                end_year=$current_year
            else
                end_year=${BASH_REMATCH[2]}
            fi
        elif [[ $token =~ ^[0-9]{4}$ ]]; then
            start_year=$token
            end_year=$token
        else
            die "Format MONGO_ARCHIVE_DELETE_ONLY_PROTECTED_YEARS tidak valid: $token"
        fi

        (( 10#$start_year <= 10#$end_year )) \
            || die "Rentang tahun terlindungi terbalik: $token"
        (( 10#$end_year - 10#$start_year <= 200 )) \
            || die "Rentang tahun terlindungi terlalu lebar: $token"

        for (( year = 10#$start_year; year <= 10#$end_year; year++ )); do
            delete_only_protected_years+=("$year")
        done
    done

    mapfile -t delete_only_protected_years < <(
        printf '%s\n' "${delete_only_protected_years[@]}" | sort -nu
    )
    (( ${#delete_only_protected_years[@]} > 0 )) \
        || die "MONGO_ARCHIVE_DELETE_ONLY_PROTECTED_YEARS tidak boleh kosong"
}

if [[ $mode == delete || $mode == delete-only ]]; then
    required MONGO_ARCHIVE_DELETE_USER
    required MONGO_ARCHIVE_DELETE_PASSWORD

    confirmation_targets=()
    for collection_name in "${collections[@]}"; do
        confirmation_targets+=("${MONGO_ARCHIVE_DATABASE}.${collection_name}")
    done

    if ! bool_value "$MONGO_ARCHIVE_OLD_DATA_IMMUTABLE" \
       && ! bool_value "$MONGO_ARCHIVE_WRITES_PAUSED"; then
        die "Untuk menghapus, set MONGO_ARCHIVE_OLD_DATA_IMMUTABLE=true atau hentikan write lalu set MONGO_ARCHIVE_WRITES_PAUSED=true"
    fi

    if [[ $mode == delete ]]; then
        required MONGO_ARCHIVE_DELETE_CONFIRM
        expected_confirmation="DELETE $(IFS=,; printf '%s' "${confirmation_targets[*]}")"
        [[ $MONGO_ARCHIVE_DELETE_CONFIRM == "$expected_confirmation" ]] \
            || die "MONGO_ARCHIVE_DELETE_CONFIRM harus persis: $expected_confirmation"
    else
        required MONGO_ARCHIVE_DELETE_ONLY_PROTECTED_YEARS
        parse_delete_only_protected_years "$MONGO_ARCHIVE_DELETE_ONLY_PROTECTED_YEARS"
    fi
elif [[ $mode == backup ]]; then
    log "Mode --backup: data MongoDB tidak akan dihapus"
fi

# Akun untuk createIndex: MONGO_ARCHIVE_INDEX_* -> akun delete -> akun utama.
if [[ -n ${MONGO_ARCHIVE_INDEX_USER:-} ]]; then
    required MONGO_ARCHIVE_INDEX_PASSWORD
    index_user=$MONGO_ARCHIVE_INDEX_USER
    index_password=$MONGO_ARCHIVE_INDEX_PASSWORD
    index_auth_db=${MONGO_ARCHIVE_INDEX_AUTH_DB:-$MONGO_AUTH_DB}
elif [[ -n ${MONGO_ARCHIVE_DELETE_USER:-} && -n ${MONGO_ARCHIVE_DELETE_PASSWORD:-} ]]; then
    index_user=$MONGO_ARCHIVE_DELETE_USER
    index_password=$MONGO_ARCHIVE_DELETE_PASSWORD
    index_auth_db=${MONGO_ARCHIVE_DELETE_AUTH_DB:-$MONGO_AUTH_DB}
else
    index_user=$MONGO_USER
    index_password=$MONGO_PASSWORD
    index_auth_db=$MONGO_AUTH_DB
fi

safe_db=${MONGO_ARCHIVE_DATABASE//[^a-zA-Z0-9_.-]/_}
set_backup_name "mongodb-archive-${safe_db}"

# ---------------------------------------------------------------------------
# Notifikasi progres archive
# ---------------------------------------------------------------------------

# Statistik sesi, dihitung hanya untuk rentang yang benar-benar diproses.
archive_run_started=$SECONDS
archive_started_at=''
archive_ranges_checked=0
archive_ranges_empty=0
archive_ranges_backed_up=0
archive_ranges_deleted=0
archive_documents_backed_up=0
archive_documents_deleted=0
archive_bytes_uploaded=0
archive_period_details=()
archive_collection_status=()
archive_collections_skipped=0
archive_indexes_created=0
archive_warnings=()
archive_current_period=''
archive_current_step=''
archive_notify_last_epoch=0

archive_now() {
    TZ="${NOTIFY_TIMEZONE:-Asia/Makassar}" date '+%d-%m-%Y %H:%M:%S %Z'
}

# 1234567 -> 1.234.567
archive_format_count() {
    local number=$1
    local grouped=''

    while (( ${#number} > 3 )); do
        grouped=".${number: -3}${grouped}"
        number=${number:0:${#number}-3}
    done
    printf '%s%s' "$number" "$grouped"
}

# 2023 -> Tahun 2023 | 2023-01 -> Januari 2023 | 2023-01-05 -> 5 Januari 2023
archive_period_text() {
    local label=$1
    local -a months=(Januari Februari Maret April Mei Juni Juli Agustus September Oktober November Desember)

    case ${#label} in
        4)
            printf 'Tahun %s' "$label"
            ;;
        7)
            printf '%s %s' "${months[10#${label:5:2} - 1]}" "${label:0:4}"
            ;;
        10)
            printf '%d %s %s' "$((10#${label:8:2}))" "${months[10#${label:5:2} - 1]}" "${label:0:4}"
            ;;
        *)
            printf '%s' "$label"
            ;;
    esac
}

archive_mode_text() {
    case $mode in
        delete)
            printf -- '--delete (backup, upload, lalu hapus)'
            ;;
        delete-only)
            printf -- '--delete-only (hapus tanpa backup)'
            ;;
        *)
            printf -- '--backup (tanpa hapus data)'
            ;;
    esac
}

# Kirim satu pesan ke Discord/Telegram dengan judul bebas.
# Tidak pernah menggagalkan proses archive.
archive_notify() {
    local title=$1
    local color=$2
    local message=$3
    local payload
    local now
    local wait_seconds

    bool_value "${NOTIFY_DISCORD:-false}" \
        || bool_value "${NOTIFY_TELEGRAM:-false}" \
        || return 0

    # Telegram/Discord menolak pesan > 4096 karakter. Dengan LC_ALL=C panjang
    # dihitung dalam byte (>= jumlah karakter), lalu dipotong di akhir baris
    # supaya karakter UTF-8/emoji tidak terbelah.
    if (( ${#message} > 3500 )); then
        message=${message:0:3500}
        message=${message%$'\n'*}
        message+=$'\n\n'"… (pesan dipotong; detail lengkap di log ${LOG_FILE:-$LOG_DIR})"
    fi

    now=$(date +%s)
    wait_seconds=$((archive_notify_last_epoch + MONGO_ARCHIVE_NOTIFY_MIN_INTERVAL - now))
    if (( wait_seconds > 0 )); then
        sleep "$wait_seconds"
    fi

    if bool_value "${NOTIFY_DISCORD:-false}" && [[ -n ${DISCORD_WEBHOOK_URL:-} ]]; then
        payload=$(
            printf '{"username":"DB Backup Monitor","allowed_mentions":{"parse":[]},"embeds":[{"title":"%s","description":"%s","color":%s,"timestamp":"%s","footer":{"text":"MongoDB Archive Monitoring"}}]}' \
                "$(json_escape "$title")" \
                "$(json_escape "$message")" \
                "$color" \
                "$(date -u +%FT%TZ)"
        )
        if retry_cmd 3 3 "Notifikasi Discord" _notify_discord_once "$payload"; then
            :
        else
            log "WARNING: Notifikasi Discord gagal dikirim: $title"
        fi
    fi

    if bool_value "${NOTIFY_TELEGRAM:-false}" \
       && [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]]; then
        if retry_cmd 3 3 "Notifikasi Telegram" _notify_telegram_once \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            "<b>$(html_escape "$title")</b>

$(html_escape "$message")"; then
            :
        else
            log "WARNING: Notifikasi Telegram gagal dikirim: $title"
        fi
    fi

    archive_notify_last_epoch=$(date +%s)
    return 0
}

# Notifikasi progres per periode; bisa dimatikan lewat MONGO_ARCHIVE_NOTIFY_PROGRESS=false.
archive_progress_notify() {
    bool_value "$MONGO_ARCHIVE_NOTIFY_PROGRESS" || return 0
    archive_notify "$@" || true
}

archive_send_summary() {
    local rc=$1
    local title
    local color
    local message
    local line
    local details=''
    local shown=0
    local hidden=0
    local error

    if (( rc == 0 && ${#archive_warnings[@]} > 0 )); then
        bool_value "${NOTIFY_ON_WARNING:-true}" || return 0
        title='⚠️ MONGODB ARCHIVE SELESAI DENGAN PERINGATAN — RINGKASAN'
        color=16705372
    elif (( rc == 0 )); then
        bool_value "${NOTIFY_ON_SUCCESS:-true}" || return 0
        if [[ $mode == delete ]]; then
            title='✅ MONGODB ARCHIVE SELESAI — RINGKASAN'
        elif [[ $mode == delete-only ]]; then
            title='✅ MONGODB DELETE-ONLY SELESAI — RINGKASAN'
        else
            title='✅ MONGODB BACKUP ARCHIVE SELESAI — RINGKASAN'
        fi
        color=5763719
    else
        bool_value "${NOTIFY_ON_FAILURE:-true}" || return 0
        title='❌ MONGODB ARCHIVE GAGAL — RINGKASAN'
        color=15548997
    fi

    message="🖥 Host
$(backup_display_host)

🗄 Database
$MONGO_ARCHIVE_DATABASE

🔧 Mode
$(archive_mode_text)"

    # Saat gagal, error ditaruh paling atas agar tidak ikut terpotong.
    if (( rc != 0 )); then
        error=${BACKUP_LAST_ERROR:-}
        [[ -n $error ]] || error="Proses berhenti (exit code $rc)"
        message+=$'\n\n'"❌ Error
$error"
        if [[ -n $archive_current_period ]]; then
            message+=$'\n\n'"📍 Berhenti pada
$archive_current_period (tahap ${archive_current_step:-?})"
        fi
        message+=$'\n\n'"Exit code: $rc"
    fi

    if (( ${#archive_collection_status[@]} > 0 )); then
        message+=$'\n\n'"📚 Status collection"
        for line in "${archive_collection_status[@]}"; do
            message+=$'\n'"$line"
        done
    fi

    message+=$'\n\n'"📊 Hasil
Collection dilewati: $(archive_format_count "$archive_collections_skipped")
Index dibuat       : $(archive_format_count "$archive_indexes_created")
Periode dicek      : $(archive_format_count "$archive_ranges_checked")
Periode kosong     : $(archive_format_count "$archive_ranges_empty")
Periode di-backup  : $(archive_format_count "$archive_ranges_backed_up")
Periode dihapus    : $(archive_format_count "$archive_ranges_deleted")
Dokumen di-backup  : $(archive_format_count "$archive_documents_backed_up")
Dokumen dihapus    : $(archive_format_count "$archive_documents_deleted")"
    if [[ $mode != delete-only ]]; then
        message+=$'\n'"Total ukuran upload: $(human_bytes "$archive_bytes_uploaded")"
    fi

    # Batasi panjang rincian agar muat di Telegram/Discord (maks ~4096 karakter).
    for line in "${archive_period_details[@]}"; do
        if (( ${#details} + ${#line} > 1000 )); then
            hidden=$((hidden + 1))
            continue
        fi
        details+=$'\n'"• $line"
        shown=$((shown + 1))
    done
    if (( shown > 0 )); then
        message+=$'\n\n'"🧾 Rincian per periode${details}"
        if (( hidden > 0 )); then
            message+=$'\n'"… dan $hidden periode lain (lihat log)"
        fi
    fi

    if [[ $mode == delete-only ]]; then
        message+=$'\n\n'"⚠️ Backup
Tidak dibuat; mode delete-only"
    else
        message+=$'\n\n'"☁️ GCS
${GCS_URI}mongodb/archive/${safe_db}/"
    fi

    message+=$'\n\n'"⏱ Durasi
$(format_duration "$((SECONDS - archive_run_started))")

🕒 Mulai
${archive_started_at:-?}

🕒 Selesai
$(archive_now)"

    if (( ${#archive_warnings[@]} > 0 )); then
        message+=$'\n\n'"⚠️ Peringatan (${#archive_warnings[@]})"
        shown=0
        for line in "${archive_warnings[@]}"; do
            if (( shown == 5 )); then
                message+=$'\n'"… dan $(( ${#archive_warnings[@]} - 5 )) peringatan lain (lihat log)"
                break
            fi
            message+=$'\n'"• $line"
            shown=$((shown + 1))
        done
    fi

    if (( rc != 0 )); then
        if [[ -n ${RUN_DIR:-} && -d ${RUN_DIR:-} ]]; then
            message+=$'\n\n'"📁 Local staging
$RUN_DIR"
        fi
        message+=$'\n\n'"🔎 Log
${LOG_FILE:-$LOG_DIR}"
    fi

    archive_notify "$title" "$color" "$message" || true
}

# Kirim ringkasan archive sebagai notifikasi akhir, lalu serahkan ke handler
# bawaan lib/common.bash (cleanup + exit code asli) tanpa notifikasi ganda.
archive_finalize() {
    local rc=$?

    trap - EXIT
    set +e
    archive_send_summary "$rc"
    BACKUP_SUPPRESS_STANDALONE_NOTIFY=1
    archive_return_status "$rc"
    finalize_backup_script
}

archive_return_status() {
    return "$1"
}

if [[ $mode == check-years || $mode == delete-only ]]; then
    secure_dir "$BACKUP_DIR"
    exec 9>"$BACKUP_DIR/.${ENGINE}-${BACKUP_NAME}.lock"
    flock -n 9 || die "Archive atau pemeriksaan tahun masih berjalan"
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    RUN_DIR=$(mktemp -d "$BACKUP_DIR/.${ENGINE}-${BACKUP_NAME}-${STAMP}.XXXXXX")
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ $mode == check-years ]]; then
        log "Pemeriksaan tahun MongoDB (read-only)"
    else
        BACKUP_FILE_SERVER=$(backup_file_server_name)
        archive_started_at=$(archive_now)
        trap archive_finalize EXIT
        log "DELETE-ONLY: hapus data MongoDB tanpa membuat backup atau mengakses GCS"
    fi
else
    begin_backup
    archive_started_at=$(archive_now)
    trap archive_finalize EXIT
fi

# Tampilkan sasaran yang benar-benar dibaca dari .env (tanpa kredensial).
collection_summary=$(IFS=,; printf '%s' "${collection_specs[*]}")
log "CONFIG: mode=--$mode | db=$MONGO_ARCHIVE_DATABASE | collections=$collection_summary | years=${MONGO_ARCHIVE_YEARS:-auto} | chunk=$MONGO_ARCHIVE_CHUNK | timezone=$MONGO_ARCHIVE_TIMEZONE"
if [[ $mode == backup || $mode == delete ]]; then
    log "CONFIG: GCS=${GCS_URI}mongodb/archive/${MONGO_ARCHIVE_DATABASE}/... | batch=$MONGO_ARCHIVE_DELETE_BATCH_SIZE"
fi
if [[ $mode == delete ]]; then
    log "DELETE_GUARD: immutable=$MONGO_ARCHIVE_OLD_DATA_IMMUTABLE | writes_paused=$MONGO_ARCHIVE_WRITES_PAUSED | target=$MONGO_ARCHIVE_DELETE_CONFIRM"
elif [[ $mode == delete-only ]]; then
    log "DELETE_ONLY_GUARD: immutable=$MONGO_ARCHIVE_OLD_DATA_IMMUTABLE | writes_paused=$MONGO_ARCHIVE_WRITES_PAUSED | protected=$MONGO_ARCHIVE_DELETE_ONLY_PROTECTED_YEARS"
fi

host_arg="$MONGO_HOST:$MONGO_PORT"
if [[ -n $MONGO_REPLICA_SET ]]; then
    host_arg="$MONGO_REPLICA_SET/$host_arg"
fi

shell_connection=(--quiet --norc --host "$host_arg")
dump_connection=()
restore_connection=()

if [[ $mode == backup || $mode == delete ]]; then
    mongo_config="$RUN_DIR/mongodb.yml"
    TEMP_CREDENTIAL_FILE=$mongo_config
    printf 'password: "%s"\n' "$(escape_quoted_value "$MONGO_PASSWORD")" >"$mongo_config"
    chmod 600 "$mongo_config"

    dump_connection=(
        --config="$mongo_config"
        --host="$host_arg"
        --username="$MONGO_USER"
        --authenticationDatabase="$MONGO_AUTH_DB"
    )
    restore_connection=("${dump_connection[@]}")
fi

if bool_value "$MONGO_TLS"; then
    dump_connection+=(--ssl)
    restore_connection+=(--ssl)
    shell_connection+=(--tls)
fi

if [[ -n ${MONGO_TLS_CA_FILE:-} ]]; then
    [[ $MONGO_TLS_CA_FILE == /* && -f $MONGO_TLS_CA_FILE && ! -L $MONGO_TLS_CA_FILE ]] \
        || die "MONGO_TLS_CA_FILE tidak valid"
    dump_connection+=(--sslCAFile="$MONGO_TLS_CA_FILE")
    restore_connection+=(--sslCAFile="$MONGO_TLS_CA_FILE")
    shell_connection+=(--tlsCAFile="$MONGO_TLS_CA_FILE")
fi

list_years_js="$RUN_DIR/list-years.js"
boundary_js="$RUN_DIR/boundary.js"
count_js="$RUN_DIR/count.js"
delete_js="$RUN_DIR/delete.js"

cat >"$list_years_js" <<'JS'
const e = process.env;
const auth = db.getSiblingDB(e.ARCHIVE_AUTH_DB);
try { auth.auth({user: e.ARCHIVE_USER, pwd: e.ARCHIVE_PASSWORD}); }
catch (error) { console.error(error.message); quit(18); }
const target = db.getSiblingDB(e.ARCHIVE_DATABASE);
const field = e.ARCHIVE_DATE_FIELD;
target.getCollection(e.ARCHIVE_COLLECTION).aggregate([
  {$match: {[field]: {$type: "date"}}},
  {$group: {_id: {$year: {date: "$" + field, timezone: e.ARCHIVE_TIMEZONE}}}},
  {$sort: {_id: 1}}
], {allowDiskUse: true}).forEach(row => print("ARCHIVE_YEAR\t" + row._id));
JS

cat >"$boundary_js" <<'JS'
// Satu traversal untuk menghitung dokumen, memeriksa tipe _id dan max ObjectId.
// Tidak melakukan sort({_id:-1}) yang dapat memaksa scan besar.
const e = process.env;
const auth = db.getSiblingDB(e.ARCHIVE_AUTH_DB);
try { auth.auth({user: e.ARCHIVE_USER, pwd: e.ARCHIVE_PASSWORD}); }
catch (error) { console.error(error.message); quit(18); }
const coll = db.getSiblingDB(e.ARCHIVE_DATABASE).getCollection(e.ARCHIVE_COLLECTION);
const field = e.ARCHIVE_DATE_FIELD;
const dateFilter = {[field]: {$gte: new Date(e.ARCHIVE_START), $lt: new Date(e.ARCHIVE_END)}};

// Pilih hanya index satu-field yang persis sesuai filter; hindari hint palsu.
// Jika tidak ada atau metadata index tak dapat dibaca, biarkan query planner memilih.
// Index yang diawali field archive (single atau compound, semua key 1/-1).
// Utamakan index dengan jumlah key paling sedikit.
function usableDateIndex() {
  const list = coll.getIndexes().filter(item => {
    const fields = Object.keys(item.key || {});
    return fields.length >= 1 && fields[0] === field &&
           fields.every(name => item.key[name] === 1 || item.key[name] === -1) &&
           item.hidden !== true && !item.partialFilterExpression && item.sparse !== true;
  });
  list.sort((a, b) => Object.keys(a.key).length - Object.keys(b.key).length);
  return list.length ? list[0] : null;
}
function dateIndexHint() {
  try {
    const index = usableDateIndex();
    return index ? {hint: index.name} : {};
  } catch (error) {
    console.error("WARN_INDEX_HINT\t" + error.message);
    return {};
  }
}
const started = Date.now();
const pipeline = [
  {$match: dateFilter},
  {$group: {
    _id: null,
    total: {$sum: 1},
    maxId: {$max: "$_id"},
    invalidIds: {$sum: {$cond: [{$eq: [{$type: "$_id"}, "objectId"]}, 0, 1]}}
  }}
];
const rows = coll.aggregate(pipeline, Object.assign({allowDiskUse: true}, dateIndexHint())).toArray();
if (rows.length === 0) {
  print("EMPTY");
  quit(0);
}
if (rows.length !== 1) {
  console.error("BOUNDARY_UNEXPECTED_GROUPS\t" + rows.length);
  quit(45);
}
const row = rows[0];
const total = Number(row.total);
const invalid = Number(row.invalidIds);
if (!Number.isSafeInteger(total) || total < 1 || !Number.isSafeInteger(invalid) || invalid < 0) {
  console.error("BOUNDARY_INVALID_COUNT");
  quit(46);
}
if (invalid !== 0) {
  console.error("NON_OBJECT_ID\t" + invalid);
  quit(42);
}
if (!row.maxId || typeof row.maxId.toHexString !== "function") {
  console.error("BOUNDARY_INVALID_MAX_ID");
  quit(47);
}
const maxId = row.maxId.toHexString();
if (!/^[0-9a-fA-F]{24}$/.test(maxId)) {
  console.error("BOUNDARY_INVALID_MAX_ID");
  quit(47);
}
console.error("BOUNDARY_PROFILE\tdocuments=" + total +
              "\tduration_ms=" + (Date.now() - started));
print("BOUNDARY\t" + maxId + "\t" + total);
JS

cat >"$count_js" <<'JS'
const e = process.env;
const auth = db.getSiblingDB(e.ARCHIVE_AUTH_DB);
try { auth.auth({user: e.ARCHIVE_USER, pwd: e.ARCHIVE_PASSWORD}); }
catch (error) { console.error(error.message); quit(18); }
const coll = db.getSiblingDB(e.ARCHIVE_DATABASE).getCollection(e.ARCHIVE_COLLECTION);
const field = e.ARCHIVE_DATE_FIELD;
const filter = {$and: [
  {[field]: {$gte: new Date(e.ARCHIVE_START), $lt: new Date(e.ARCHIVE_END)}},
  {_id: {$lte: ObjectId.createFromHexString(e.ARCHIVE_MAX_ID)}}
]};
print("ARCHIVE_COUNT\t" + coll.countDocuments(filter));
JS

cat >"$delete_js" <<'JS'
const e = process.env;
const auth = db.getSiblingDB(e.ARCHIVE_AUTH_DB);
try { auth.auth({user: e.ARCHIVE_USER, pwd: e.ARCHIVE_PASSWORD}); }
catch (error) { console.error(error.message); quit(18); }
const coll = db.getSiblingDB(e.ARCHIVE_DATABASE).getCollection(e.ARCHIVE_COLLECTION);
const field = e.ARCHIVE_DATE_FIELD;
const maxId = ObjectId.createFromHexString(e.ARCHIVE_MAX_ID);
const batchSize = Number(e.ARCHIVE_DELETE_BATCH_SIZE);
if (!Number.isSafeInteger(batchSize) || batchSize < 1 || batchSize > 100000) {
  console.error("INVALID_DELETE_BATCH_SIZE");
  quit(49);
}
const dateFilter = {[field]: {$gte: new Date(e.ARCHIVE_START), $lt: new Date(e.ARCHIVE_END)}};
const filter = {$and: [dateFilter, {_id: {$lte: maxId}}]};
// Index yang diawali field archive (single atau compound, semua key 1/-1).
// Utamakan index dengan jumlah key paling sedikit.
function usableDateIndex() {
  const list = coll.getIndexes().filter(item => {
    const fields = Object.keys(item.key || {});
    return fields.length >= 1 && fields[0] === field &&
           fields.every(name => item.key[name] === 1 || item.key[name] === -1) &&
           item.hidden !== true && !item.partialFilterExpression && item.sparse !== true;
  });
  list.sort((a, b) => Object.keys(a.key).length - Object.keys(b.key).length);
  return list.length ? list[0] : null;
}
function dateIndexHint() {
  try {
    const index = usableDateIndex();
    return index ? index.name : null;
  } catch (error) {
    console.error("WARN_INDEX_HINT\t" + error.message);
    return null;
  }
}
const hint = dateIndexHint();
let total = 0;
let batches = 0;
const started = Date.now();
while (true) {
  // Tidak butuh urutan _id. Gunakan index tanggal jika ada.
  let cursor = coll.find(filter, {_id: 1});
  if (hint) cursor = cursor.hint(hint);
  const ids = cursor.limit(batchSize).toArray().map(row => row._id);
  if (ids.length === 0) break;

  // Defense-in-depth: validasi ulang tanggal dan maxId SAAT delete, bukan
  // hanya pada saat mencari ID. Jika berubah, hentikan proses.
  const guardedFilter = {$and: [dateFilter, {_id: {$lte: maxId}}, {_id: {$in: ids}}]};
  const result = coll.deleteMany(guardedFilter, {writeConcern: {w: "majority", wtimeout: 60000}});
  total += result.deletedCount;
  batches += 1;
  // Collection ber-TTL: MongoDB boleh menghapus dokumen yang sama lebih dulu
  // (selisih hanya boleh berkurang, tidak pernah bertambah).
  if (result.deletedCount !== ids.length &&
      !(e.ARCHIVE_ALLOW_SHRINK === "1" && result.deletedCount < ids.length)) {
    console.error("DELETE_BATCH_MISMATCH\t" + ids.length + "\t" + result.deletedCount);
    quit(43);
  }
  if (batches % 10 === 0) {
    const duration = Math.max(1, Math.floor((Date.now() - started) / 1000));
    console.error("DELETE_PROGRESS\tbatches=" + batches +
                  "\tdeleted=" + total + "\tseconds=" + duration +
                  "\tavg_docs_per_sec=" + Math.floor(total / duration));
  }
}
const remaining = coll.countDocuments(filter);
console.error("DELETE_PROFILE\tbatches=" + batches +
              "\tduration_ms=" + (Date.now() - started));
print("DELETED\t" + total + "\t" + remaining);
if (remaining !== 0) quit(44);
JS

inspect_js="$RUN_DIR/inspect.js"
create_index_js="$RUN_DIR/create-index.js"
oldest_js="$RUN_DIR/oldest.js"
year_check_js="$RUN_DIR/year-check.js"

# Header bersama: autentikasi + pemilihan index field archive.
archive_js_header=$(cat <<'JS'
const e = process.env;
const auth = db.getSiblingDB(e.ARCHIVE_AUTH_DB);
try { auth.auth({user: e.ARCHIVE_USER, pwd: e.ARCHIVE_PASSWORD}); }
catch (error) { console.error(error.message); quit(18); }
const target = db.getSiblingDB(e.ARCHIVE_DATABASE);
const coll = target.getCollection(e.ARCHIVE_COLLECTION);
const field = e.ARCHIVE_DATE_FIELD;
function clean(text) { return String(text).replace(/[\t\r\n]+/g, " "); }
function usableDateIndex(indexes) {
  const list = indexes.filter(item => {
    const fields = Object.keys(item.key || {});
    return fields.length >= 1 && fields[0] === field &&
           fields.every(name => item.key[name] === 1 || item.key[name] === -1) &&
           item.hidden !== true && !item.partialFilterExpression && item.sparse !== true;
  });
  list.sort((a, b) => Object.keys(a.key).length - Object.keys(b.key).length);
  return list.length ? list[0] : null;
}
function dateIndexName() {
  try { const index = usableDateIndex(coll.getIndexes()); return index ? index.name : null; }
  catch (error) { console.error("WARN_INDEX_HINT\t" + clean(error.message)); return null; }
}
JS
)

# INSPECT  MISSING | NOT_COLLECTION <type> | OK <estimasi> <index|-> <ttl|->
{ printf '%s\n' "$archive_js_header"; cat <<'JS'; } >"$inspect_js"
const infos = target.getCollectionInfos({name: e.ARCHIVE_COLLECTION});
if (infos.length === 0) { print("INSPECT\tMISSING"); quit(0); }
const type = infos[0].type || "collection";
if (type !== "collection") { print("INSPECT\tNOT_COLLECTION\t" + clean(type)); quit(0); }
const estimated = coll.estimatedDocumentCount();
let indexes = [];
try { indexes = coll.getIndexes(); }
catch (error) { console.error("WARN_INDEX_LIST\t" + clean(error.message)); }
const index = usableDateIndex(indexes);
const ttl = indexes.filter(item => item.expireAfterSeconds !== undefined)
  .map(item => item.name + "=" + item.expireAfterSeconds + "s");
print("INSPECT\tOK\t" + estimated + "\t" + (index ? index.name : "-") + "\t" + (ttl.join(",") || "-"));
JS

# INDEX_CREATED <nama> | INDEX_FAILED <pesan>
{ printf '%s\n' "$archive_js_header"; cat <<'JS'; } >"$create_index_js"
try {
  const name = coll.createIndex({[field]: 1});
  print("INDEX_CREATED\t" + clean(name));
} catch (error) {
  const text = clean((error.codeName ? error.codeName + ": " : "") + error.message);
  print("INDEX_FAILED\t" + text.replace(/ to execute command .*/, "").slice(0, 200));
}
JS

# OLDEST <ISO> | OLDEST NONE  (dokumen BSON Date paling tua)
{ printf '%s\n' "$archive_js_header"; cat <<'JS'; } >"$oldest_js"
const hint = dateIndexName();
let cursor = coll.find({[field]: {$type: "date"}}, {[field]: 1}).sort({[field]: 1}).limit(1);
if (hint) cursor = cursor.hint(hint);
const doc = cursor.toArray()[0];
if (!doc) { print("OLDEST\tNONE"); quit(0); }
const value = field.split(".").reduce((obj, key) => (obj == null ? undefined : obj[key]), doc);
if (!(value instanceof Date)) { console.error("OLDEST_NOT_DATE"); quit(48); }
print("OLDEST\t" + value.toISOString());
JS

# YEAR_DATA <tahun> <1|0> untuk setiap "tahun|awal|akhir" di ARCHIVE_YEAR_RANGES.
{ printf '%s\n' "$archive_js_header"; cat <<'JS'; } >"$year_check_js"
const hint = dateIndexName();
for (const part of e.ARCHIVE_YEAR_RANGES.split(";")) {
  const [year, start, end] = part.split("|");
  let cursor = coll.find({[field]: {$gte: new Date(start), $lt: new Date(end)}}, {_id: 1}).limit(1);
  if (hint) cursor = cursor.hint(hint);
  print("YEAR_DATA\t" + year + "\t" + (cursor.hasNext() ? 1 : 0));
}
JS

chmod 600 "$list_years_js" "$boundary_js" "$count_js" "$delete_js" \
    "$inspect_js" "$create_index_js" "$oldest_js" "$year_check_js"

run_mongosh_script() {
    local user=$1
    local password=$2
    local auth_db=$3
    local script=$4

    (
        export ARCHIVE_USER=$user
        export ARCHIVE_PASSWORD=$password
        export ARCHIVE_AUTH_DB=$auth_db
        export ARCHIVE_DATABASE=$MONGO_ARCHIVE_DATABASE
        export ARCHIVE_TIMEZONE=$MONGO_ARCHIVE_TIMEZONE
        export ARCHIVE_DELETE_BATCH_SIZE=$MONGO_ARCHIVE_DELETE_BATCH_SIZE
        run_backup mongosh "${shell_connection[@]}" --file="$script"
    )
}

# Jalankan query mongosh sambil memberi heartbeat setiap 30 detik.
# Output stdout tetap dipisahkan dari log supaya parsing BOUNDARY/COUNT aman.
run_mongosh_with_progress() {
    local step_label=$1
    shift
    local output_file watcher_pid rc
    local started=$SECONDS

    output_file=$(mktemp "$RUN_DIR/.mongosh-result.XXXXXXXX") || return 1
    chmod 600 "$output_file"

    (
        # Jangan warisi file lock (fd 9): proses sleep yang tersisa setelah
        # timer dihentikan tidak boleh menahan lock run berikutnya.
        exec 9>&-
        while sleep 30; do
            log "WAIT: $step_label masih berjalan ($((SECONDS - started)) detik); menunggu respons MongoDB..." >&2
        done
    ) >/dev/null &
    watcher_pid=$!

    # Query MongoDB tetap berjalan sinkron; yang background hanya timer log.
    if run_mongosh_script "$@" >"$output_file"; then
        rc=0
    else
        rc=$?
    fi

    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
    if (( rc == 0 )); then
        cat "$output_file"
    fi
    rm -f -- "$output_file"
    return "$rc"
}

# Hasil inspect_collection (global, berlaku untuk collection yang sedang diproses).
collection_state=''       # OK | MISSING | NOT_COLLECTION
collection_type=''
collection_estimated=0
collection_index='-'
collection_ttl='-'

inspect_collection() {
    local collection=$1
    local date_field=$2
    local output
    local line

    export ARCHIVE_COLLECTION=$collection
    export ARCHIVE_DATE_FIELD=$date_field

    output=$(run_mongosh_with_progress "inspect $collection" \
        "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$inspect_js") \
        || die "Gagal memeriksa collection $collection"
    line=$(awk -F '\t' '$1 == "INSPECT" {print; exit}' <<<"$output")
    [[ -n $line ]] || die "Hasil pemeriksaan collection $collection tidak valid"

    collection_type=''
    collection_estimated=0
    collection_index='-'
    collection_ttl='-'
    IFS=$'\t' read -r _ collection_state <<<"$line"
    collection_state=${collection_state%%$'\t'*}
    case $collection_state in
        MISSING)
            ;;
        NOT_COLLECTION)
            IFS=$'\t' read -r _ _ collection_type <<<"$line"
            ;;
        OK)
            IFS=$'\t' read -r _ _ collection_estimated collection_index collection_ttl <<<"$line"
            [[ $collection_estimated =~ ^[0-9]+$ ]] \
                || die "Estimasi jumlah dokumen $collection tidak valid"
            ;;
        *)
            die "Status collection $collection tidak dikenal: $collection_state"
            ;;
    esac
}

archive_warn() {
    archive_warnings+=("$1")
    mark_warning "$1"
}

skip_collection() {
    local collection=$1
    local reason=$2

    archive_collections_skipped=$((archive_collections_skipped + 1))
    archive_collection_status+=("⏭ $collection: dilewati — $reason")
    log "SKIP COLLECTION: $collection — $reason"
    archive_progress_notify '⏭ MONGODB ARCHIVE — COLLECTION DILEWATI' 9807270 "🗄 Collection
${MONGO_ARCHIVE_DATABASE}.${collection}

ℹ️ Alasan
$reason

🕒 Waktu
$(archive_now)"
}

# Pastikan field archive punya index; buat {field: 1} jika belum ada.
# Gagal membuat index = peringatan (proses tetap jalan, hanya lebih lambat).
ensure_date_index() {
    local collection=$1
    local date_field=$2
    local output
    local status
    local detail
    local started=$SECONDS
    local target_text="${MONGO_ARCHIVE_DATABASE}.${collection}"

    if [[ $collection_index != - ]]; then
        log "INDEX: $collection memakai index $collection_index untuk $date_field"
        return 0
    fi

    if ! bool_value "$MONGO_ARCHIVE_AUTO_CREATE_INDEX"; then
        archive_warn "$collection: tidak ada index untuk $date_field (MONGO_ARCHIVE_AUTO_CREATE_INDEX=false); proses bisa sangat lambat"
        return 0
    fi

    archive_current_step=INDEX
    log "INDEX: membuat index {$date_field: 1} pada $collection (±$collection_estimated dokumen)"
    archive_progress_notify '🛠 MONGODB ARCHIVE — MEMBUAT INDEX' 3447003 "🗄 Collection
$target_text

🔑 Index
{ $date_field: 1 }

📊 Perkiraan data
$(archive_format_count "$collection_estimated") dokumen

ℹ️ Keterangan
Index belum ada; dibuat dulu sebelum backup/hapus.

🕒 Mulai
$(archive_now)"

    export ARCHIVE_COLLECTION=$collection
    export ARCHIVE_DATE_FIELD=$date_field
    if output=$(run_mongosh_with_progress "create index $collection.$date_field" \
        "$index_user" "$index_password" "$index_auth_db" "$create_index_js"); then
        IFS=$'\t' read -r status detail \
            <<<"$(awk -F '\t' '$1 ~ /^INDEX_/ {print; exit}' <<<"$output")"
    else
        status=INDEX_FAILED
        detail="mongosh gagal (cek hak akses createIndex untuk user $index_user)"
    fi

    if [[ $status == INDEX_CREATED && -n $detail ]]; then
        collection_index=$detail
        archive_indexes_created=$((archive_indexes_created + 1))
        log "INDEX: selesai $detail pada $collection ($((SECONDS - started)) detik)"
        archive_progress_notify '✅ MONGODB ARCHIVE — INDEX BERHASIL DIBUAT' 5763719 "🗄 Collection
$target_text

🔑 Index
$detail

⏱ Durasi
$(format_duration "$((SECONDS - started))")

🕒 Selesai
$(archive_now)"
    else
        archive_warn "$collection: index {$date_field: 1} gagal dibuat: ${detail:-tanpa keterangan}; proses tetap jalan tanpa index"
        archive_progress_notify '⚠️ MONGODB ARCHIVE — INDEX GAGAL DIBUAT' 16705372 "🗄 Collection
$target_text

❌ Error
${detail:-tanpa keterangan}

ℹ️ Keterangan
Proses tetap dilanjutkan tanpa index (lebih lambat)."
    fi
}

# Bangun "tahun|awal|akhir;..." sesuai MONGO_ARCHIVE_TIMEZONE.
build_year_ranges() {
    local year
    local ranges=''
    local start
    local end

    for year in "$@"; do
        start=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date --iso-8601=seconds -d "$year-01-01 00:00:00")
        end=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date --iso-8601=seconds -d "$((10#$year + 1))-01-01 00:00:00")
        ranges+="${ranges:+;}$year|$start|$end"
    done
    printf '%s' "$ranges"
}

# Isi array years_with_data dengan kandidat tahun yang benar-benar berisi data.
filter_years_with_data() {
    local collection=$1
    local date_field=$2
    shift 2
    local output

    years_with_data=()
    (( $# > 0 )) || return 0

    export ARCHIVE_COLLECTION=$collection
    export ARCHIVE_DATE_FIELD=$date_field
    ARCHIVE_YEAR_RANGES=$(build_year_ranges "$@")
    export ARCHIVE_YEAR_RANGES

    output=$(run_mongosh_with_progress "cek data per tahun $collection" \
        "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$year_check_js") \
        || die "Gagal memeriksa data per tahun pada $collection"
    mapfile -t years_with_data < <(
        awk -F '\t' '$1 == "YEAR_DATA" && $2 ~ /^[0-9]{4}$/ && $3 == "1" {print $2}' \
            <<<"$output" | sort -nu
    )
}

# Isi all_collection_years dengan seluruh tahun BSON Date yang ditemukan.
# Dipakai hanya untuk permintaan delete-only yang eksplisit memakai "all".
find_all_collection_years() {
    local collection=$1
    local date_field=$2
    local output

    export ARCHIVE_COLLECTION=$collection
    export ARCHIVE_DATE_FIELD=$date_field
    output=$(run_mongosh_with_progress "daftar seluruh tahun $collection" \
        "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$list_years_js") \
        || die "Gagal membaca seluruh tahun pada $collection"

    mapfile -t all_collection_years < <(
        awk -F '\t' '$1 == "ARCHIVE_YEAR" && $2 ~ /^[0-9]{4}$/ {print $2}' \
            <<<"$output" | sort -nu
    )
}

# Tahun paling tua (zona MONGO_ARCHIVE_TIMEZONE) yang punya BSON Date; kosong jika tidak ada.
oldest_year() {
    local collection=$1
    local date_field=$2
    local output
    local oldest

    export ARCHIVE_COLLECTION=$collection
    export ARCHIVE_DATE_FIELD=$date_field
    output=$(run_mongosh_with_progress "cari data tertua $collection" \
        "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$oldest_js") \
        || die "Gagal mencari data tertua pada $collection"
    oldest=$(awk -F '\t' '$1 == "OLDEST" {print $2; exit}' <<<"$output")
    [[ -n $oldest && $oldest != NONE ]] || return 0
    # toISOString: YYYY-MM-DDTHH:MM:SS.sssZ; tahun < 1900 / format lain
    # (mis. tanggal sampah) dimulai dari 1900 agar daftar tahun tetap wajar.
    if [[ $oldest =~ ^(19|20)[0-9]{2}- ]]; then
        TZ="$MONGO_ARCHIVE_TIMEZONE" date -d "$oldest" +%Y
    else
        log "WARNING: $collection punya tanggal tidak wajar ($oldest); pencarian tahun dimulai dari 1900"
        printf '1900'
    fi
}

report_available_years() {
    local index
    local collection
    local date_field
    local output
    local year
    local oldest
    local overall_oldest=''
    local all_list
    local backup_list
    local delete_list
    local -a found_years=()
    local -a backup_years=()
    local -a delete_years=()

    printf 'Database: %s\n' "$MONGO_ARCHIVE_DATABASE"
    printf 'Timezone: %s\n' "$MONGO_ARCHIVE_TIMEZONE"
    printf 'Tahun berjalan: %s (boleh backup, tidak boleh delete)\n\n' "$current_year"

    for index in "${!collections[@]}"; do
        collection=${collections[$index]}
        date_field=${date_fields[$index]}
        inspect_collection "$collection" "$date_field"
        case $collection_state in
            MISSING)
                printf '%s (%s): collection TIDAK ADA, akan dilewati\n\n' "$collection" "$date_field"
                continue
                ;;
            NOT_COLLECTION)
                printf '%s (%s): bukan collection biasa (%s), akan dilewati\n\n' "$collection" "$date_field" "$collection_type"
                continue
                ;;
        esac
        if (( collection_estimated == 0 )); then
            printf '%s (%s): collection kosong, akan dilewati\n\n' "$collection" "$date_field"
            continue
        fi
        printf '%s (%s): ±%s dokumen | index: %s | TTL: %s\n' \
            "$collection" "$date_field" "$(archive_format_count "$collection_estimated")" \
            "$([[ $collection_index == - ]] && printf 'BELUM ADA (dibuat otomatis saat --backup/--delete)' || printf '%s' "$collection_index")" \
            "$collection_ttl"

        export ARCHIVE_COLLECTION=$collection
        export ARCHIVE_DATE_FIELD=$date_field

        log "CHECK: mencari tahun untuk $collection (field: $date_field)"
        found_years=()
        if [[ $collection_index != - ]]; then
            # Cepat via index: data tertua, lalu satu query per tahun.
            first_year=$(oldest_year "$collection" "$date_field") \
                || die "Gagal mencari data tertua pada $collection"
            if [[ -n $first_year ]]; then
                candidate_years=()
                for (( year = 10#$first_year; year <= 10#$current_year; year++ )); do
                    candidate_years+=("$year")
                done
                filter_years_with_data "$collection" "$date_field" "${candidate_years[@]}"
                found_years=("${years_with_data[@]}")
            fi
        else
            # Tanpa index: satu kali scan penuh lebih murah daripada banyak query.
            output=$(run_mongosh_with_progress "daftar tahun $collection" \
                "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$list_years_js") \
                || die "Gagal memeriksa tahun pada $collection"
            mapfile -t found_years < <(
                awk -F '\t' '$1 == "ARCHIVE_YEAR" && $2 ~ /^[0-9]{4}$/ {print $2}' \
                    <<<"$output" | sort -nu
            )
        fi

        if (( ${#found_years[@]} == 0 )); then
            printf '%s (%s): tidak ada BSON Date\n\n' "$collection" "$date_field"
            continue
        fi

        oldest=${found_years[0]}
        if [[ -z $overall_oldest ]] || (( 10#$oldest < 10#$overall_oldest )); then
            overall_oldest=$oldest
        fi

        backup_years=()
        delete_years=()
        for year in "${found_years[@]}"; do
            if (( 10#$year <= 10#$current_year )); then
                backup_years+=("$year")
            fi
            if (( 10#$year < 10#$current_year )); then
                delete_years+=("$year")
            fi
        done

        all_list=$(IFS=,; printf '%s' "${found_years[*]}")
        if (( ${#backup_years[@]} > 0 )); then
            backup_list=$(IFS=,; printf '%s' "${backup_years[*]}")
        else
            backup_list='tidak ada'
        fi
        if (( ${#delete_years[@]} > 0 )); then
            delete_list=$(IFS=,; printf '%s' "${delete_years[*]}")
        else
            delete_list='tidak ada'
        fi

        printf '%s (%s):\n' "$collection" "$date_field"
        printf '  Tahun paling tua : %s\n' "$oldest"
        printf '  Tahun tersedia   : %s\n' "$all_list"
        printf '  Boleh di-backup  : %s\n' "$backup_list"
        printf '  Boleh di-delete  : %s\n\n' "$delete_list"
    done

    if [[ -n $overall_oldest ]]; then
        printf 'Tahun paling tua dari semua collection: %s\n' "$overall_oldest"
    else
        printf 'Tidak ditemukan data BSON Date pada collection yang dikonfigurasi.\n'
    fi
}

if [[ $mode == check-years ]]; then
    report_available_years
    exit 0
fi

check_free_space() {
    local available_kb
    local required_kb=$((MONGO_ARCHIVE_MIN_FREE_GB * 1024 * 1024))

    available_kb=$(df -Pk "$BACKUP_DIR" | awk 'NR == 2 {print $4}')
    [[ $available_kb =~ ^[0-9]+$ ]] || die "Tidak dapat membaca free space BACKUP_DIR"
    (( available_kb >= required_kb )) \
        || die "Free space kurang dari ${MONGO_ARCHIVE_MIN_FREE_GB} GB; kecilkan MONGO_ARCHIVE_CHUNK"
}

delete_range_only() {
    local collection=$1
    local date_field=$2
    local year=$3
    local range_start_local=$4
    local range_end_local=$5
    local range_label=$6
    local start_iso
    local end_iso
    local boundary_output
    local boundary_line
    local max_id
    local expected_count
    local count_output
    local current_count
    local delete_output
    local deleted_count
    local remaining_count
    local range_started=$SECONDS
    local step_started
    local period_text
    local target_text
    local allow_shrink=0

    period_text=$(archive_period_text "$range_label")
    target_text="${MONGO_ARCHIVE_DATABASE}.${collection}"
    archive_current_period="$target_text | $period_text"
    archive_current_step=BOUNDARY
    archive_ranges_checked=$((archive_ranges_checked + 1))

    log "CHECK DELETE-ONLY: $collection periode $range_label | field=$date_field | rentang=$range_start_local s.d. $range_end_local (akhir eksklusif) | zona=$MONGO_ARCHIVE_TIMEZONE"
    start_iso=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date --iso-8601=seconds -d "$range_start_local 00:00:00")
    end_iso=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date --iso-8601=seconds -d "$range_end_local 00:00:00")

    export ARCHIVE_COLLECTION=$collection
    export ARCHIVE_DATE_FIELD=$date_field
    export ARCHIVE_START=$start_iso
    export ARCHIVE_END=$end_iso

    step_started=$SECONDS
    boundary_output=$(run_mongosh_with_progress "boundary delete-only $collection $range_label" \
        "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$boundary_js") \
        || die "Gagal menentukan boundary delete-only $collection $range_label"

    if grep -qx 'EMPTY' <<<"$boundary_output"; then
        archive_ranges_empty=$((archive_ranges_empty + 1))
        log "SKIP DELETE-ONLY: $collection periode $range_label kosong"
        archive_current_period=''
        archive_current_step=''
        return 0
    fi

    boundary_line=$(awk -F '\t' '$1 == "BOUNDARY" {print; exit}' <<<"$boundary_output")
    [[ -n $boundary_line ]] || die "Boundary delete-only tidak valid untuk $collection $range_label"
    IFS=$'\t' read -r _ max_id expected_count <<<"$boundary_line"
    [[ $max_id =~ ^[0-9a-fA-F]{24}$ ]] || die "ObjectId boundary tidak valid"
    [[ $expected_count =~ ^[1-9][0-9]*$ ]] || die "Jumlah dokumen boundary tidak valid"
    export ARCHIVE_MAX_ID=$max_id

    archive_current_step=RECOUNT
    count_output=$(run_mongosh_with_progress "recount delete-only $collection $range_label" \
        "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$count_js") \
        || die "Gagal memeriksa ulang jumlah dokumen $collection $range_label"
    current_count=$(awk -F '\t' '$1 == "ARCHIVE_COUNT" {print $2; exit}' <<<"$count_output")
    [[ $current_count =~ ^[0-9]+$ ]] || die "Hasil recount delete-only tidak valid"

    if [[ $current_count == "$expected_count" ]]; then
        :
    elif [[ $collection_ttl != - ]] && (( current_count < expected_count )); then
        allow_shrink=1
        log "RECOUNT DELETE-ONLY: berkurang $expected_count -> $current_count karena TTL; lanjut hapus sisa"
    else
        die "Jumlah dokumen berubah sebelum delete-only ($expected_count menjadi $current_count); tidak ada data yang dihapus"
    fi
    export ARCHIVE_ALLOW_SHRINK=$allow_shrink

    archive_progress_notify '🗑 MONGODB DELETE-ONLY — PROSES PENGHAPUSAN' 16705372 "🗄 Collection
$target_text

📅 Periode
$period_text

🗑 Akan dihapus
$(archive_format_count "$current_count") dokumen

⚠️ Backup
Tidak dibuat (delete-only)

🕒 Mulai
$(archive_now)"

    log "DELETE-ONLY: mulai $collection periode $range_label | $current_count dokumen | tanpa backup"
    archive_current_step=DELETE_ONLY
    step_started=$SECONDS
    delete_output=$(run_mongosh_with_progress "delete-only $collection $range_label" \
        "$MONGO_ARCHIVE_DELETE_USER" \
        "$MONGO_ARCHIVE_DELETE_PASSWORD" \
        "${MONGO_ARCHIVE_DELETE_AUTH_DB:-$MONGO_AUTH_DB}" \
        "$delete_js") || die "Delete-only gagal untuk $collection $range_label"

    IFS=$'\t' read -r _ deleted_count remaining_count \
        <<<"$(awk -F '\t' '$1 == "DELETED" {print; exit}' <<<"$delete_output")"
    [[ $deleted_count =~ ^[0-9]+$ && $remaining_count == 0 ]] \
        || die "Verifikasi delete-only gagal untuk $collection $range_label"
    if (( allow_shrink == 1 )); then
        (( deleted_count <= current_count )) \
            || die "Jumlah delete-only tidak valid untuk $collection $range_label"
    else
        [[ $deleted_count == "$expected_count" ]] \
            || die "Jumlah delete-only tidak sesuai untuk $collection $range_label"
    fi

    archive_ranges_deleted=$((archive_ranges_deleted + 1))
    archive_documents_deleted=$((archive_documents_deleted + deleted_count))
    archive_period_details+=("$collection | $period_text: $(archive_format_count "$deleted_count") dok dihapus TANPA backup")
    log "DELETE-ONLY: sukses $collection periode $range_label | $deleted_count dokumen dihapus | sisa=$remaining_count | durasi=$((SECONDS - step_started)) detik"

    archive_progress_notify '✅ MONGODB DELETE-ONLY — PENGHAPUSAN BERHASIL' 5763719 "🗄 Collection
$target_text

📅 Periode
$period_text

🗑 Dokumen dihapus
$(archive_format_count "$deleted_count") dokumen (sisa $remaining_count)

⚠️ Backup
Tidak dibuat (delete-only)

⏱ Total periode
$(format_duration "$((SECONDS - range_started))")

🕒 Selesai
$(archive_now)"

    archive_current_period=''
    archive_current_step=''
}

process_range() {
    local collection=$1
    local date_field=$2
    local year=$3
    local range_start_local=$4
    local range_end_local=$5
    local range_label=$6
    local start_iso
    local end_iso
    local boundary_output
    local boundary_line
    local max_id
    local expected_count
    local count_output
    local current_count
    local delete_output
    local deleted_count
    local remaining_count
    local query_file
    local artifact_name
    local artifact
    local range_started=$SECONDS
    local step_started
    local artifact_bytes
    local period_text
    local target_text
    local prepare_seconds
    local delete_started_at
    local delete_finished_at
    local detail
    local allow_shrink=0

    period_text=$(archive_period_text "$range_label")
    target_text="${MONGO_ARCHIVE_DATABASE}.${collection}"
    archive_current_period="$target_text | $period_text"
    archive_current_step=BOUNDARY

    archive_ranges_checked=$((archive_ranges_checked + 1))
    log "CHECK: $collection periode $range_label | field=$date_field | rentang=$range_start_local s.d. $range_end_local (akhir eksklusif) | zona=$MONGO_ARCHIVE_TIMEZONE"

    start_iso=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date --iso-8601=seconds -d "$range_start_local 00:00:00")
    end_iso=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date --iso-8601=seconds -d "$range_end_local 00:00:00")

    export ARCHIVE_COLLECTION=$collection
    export ARCHIVE_DATE_FIELD=$date_field
    export ARCHIVE_START=$start_iso
    export ARCHIVE_END=$end_iso

    step_started=$SECONDS
    boundary_output=$(run_mongosh_with_progress "boundary $collection $range_label" \
        "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$boundary_js") \
        || die "Gagal menentukan boundary $collection $range_label"

    if grep -qx 'EMPTY' <<<"$boundary_output"; then
        archive_ranges_empty=$((archive_ranges_empty + 1))
        log "SKIP: $collection periode $range_label kosong (cek $((SECONDS - step_started)) detik; total $((SECONDS - range_started)) detik)"
        archive_current_period=''
        archive_current_step=''
        return 0
    fi

    boundary_line=$(awk -F '\t' '$1 == "BOUNDARY" {print; exit}' <<<"$boundary_output")
    [[ -n $boundary_line ]] || die "Boundary tidak valid untuk $collection $range_label"
    IFS=$'\t' read -r _ max_id expected_count <<<"$boundary_line"
    [[ $max_id =~ ^[0-9a-fA-F]{24}$ ]] || die "ObjectId boundary tidak valid"
    [[ $expected_count =~ ^[1-9][0-9]*$ ]] || die "Jumlah dokumen boundary tidak valid"
    log "FOUND: $collection periode $range_label | $expected_count dokumen (cek $((SECONDS - step_started)) detik)"

    archive_progress_notify '📦 MONGODB ARCHIVE — MULAI BACKUP' 3447003 "🗄 Collection
$target_text

📅 Periode
$period_text

📊 Total data
$(archive_format_count "$expected_count") dokumen

🔧 Mode
$(archive_mode_text)

🕒 Mulai
$(archive_now)"

    archive_current_step=DUMP
    check_free_space

    query_file="$RUN_DIR/query-${collection}-${range_label}.json"
    printf '{"$and":[{"%s":{"$gte":{"$date":"%s"},"$lt":{"$date":"%s"}}},{"_id":{"$lte":{"$oid":"%s"}}}]}\n' \
        "$date_field" "$start_iso" "$end_iso" "$max_id" >"$query_file"
    chmod 600 "$query_file"

    artifact_name="${BACKUP_FILE_SERVER}-${safe_db}-${collection}-period-${range_label}-backup-${STAMP}.archive.gz"
    (( ${#artifact_name} <= 240 )) \
        || die "Nama file backup terlalu panjang: $artifact_name"
    artifact="$RUN_DIR/$artifact_name"

    log "DUMP: mulai $collection periode $range_label ($expected_count dokumen) -> $artifact_name"
    step_started=$SECONDS
    run_backup mongodump \
        "${dump_connection[@]}" \
        --db="$MONGO_ARCHIVE_DATABASE" \
        --collection="$collection" \
        --queryFile="$query_file" \
        --gzip \
        --archive="$artifact" \
        || die "DUMP gagal: $collection periode $range_label; data tidak dihapus"
    [[ -s $artifact ]] \
        || die "DUMP kosong/tidak ada: $artifact_name; data tidak dihapus"
    artifact_bytes=$(wc -c < "$artifact")
    log "DUMP: selesai $collection periode $range_label | ukuran=${artifact_bytes} byte | durasi=$((SECONDS - step_started)) detik"

    log "VERIFY: mulai gzip test + mongorestore dry-run untuk $artifact_name"
    archive_current_step=VERIFY
    step_started=$SECONDS
    gzip -t "$artifact" \
        || die "VERIFY gzip gagal: $artifact_name; data tidak dihapus"
    run_backup mongorestore \
        "${restore_connection[@]}" \
        --archive="$artifact" \
        --gzip \
        --dryRun \
        --verbose \
        --nsInclude="${MONGO_ARCHIVE_DATABASE}.${collection}" \
        >/dev/null \
        || die "VERIFY dry-run gagal: $artifact_name; data tidak dihapus"
    log "VERIFY: selesai $collection periode $range_label ($((SECONDS - step_started)) detik)"

    GCS_BACKUP_PATH="mongodb/archive/${safe_db}/${collection}/${year}"
    prepare_seconds=$((SECONDS - range_started))
    archive_progress_notify '☁️ MONGODB ARCHIVE — PROSES UPLOAD' 3447003 "🗄 Collection
$target_text

📅 Periode
$period_text

📊 Total data
$(archive_format_count "$expected_count") dokumen

📦 File
$artifact_name
($(human_bytes "$artifact_bytes"), dump + verifikasi $(format_duration "$prepare_seconds"))

☁️ Tujuan
$GCS_URI$GCS_BACKUP_PATH/

🕒 Mulai upload
$(archive_now)"

    log "UPLOAD: mulai $artifact_name ke $GCS_URI$GCS_BACKUP_PATH/"
    archive_current_step=UPLOAD
    step_started=$SECONDS
    upload_backup "$artifact" \
        || die "UPLOAD atau verifikasi GCS gagal: $artifact_name; data tidak dihapus"
    log "UPLOAD: selesai $collection periode $range_label ($((SECONDS - step_started)) detik)"
    archive_bytes_uploaded=$((archive_bytes_uploaded + artifact_bytes))

    if bool_value "$MONGO_ARCHIVE_DELETE_AFTER_UPLOAD"; then
        detail='data dihapus setelah ini'
    else
        detail='data MongoDB TIDAK dihapus (mode --backup)'
    fi
    archive_progress_notify '✅ MONGODB ARCHIVE — UPLOAD BERHASIL' 5763719 "🗄 Collection
$target_text

📅 Periode
$period_text

📊 Total data
$(archive_format_count "$expected_count") dokumen

☁️ GCS (uploaded & verified)
$BACKUP_REMOTE_URI

📦 Ukuran
$(human_bytes "$artifact_bytes")

⏱ Durasi upload
$(format_duration "$((SECONDS - step_started))")

🕒 Selesai
$(archive_now)

ℹ️ Keterangan
$detail"

    if bool_value "$MONGO_ARCHIVE_DELETE_AFTER_UPLOAD"; then
        export ARCHIVE_MAX_ID=$max_id
        log "RECOUNT: cek ulang jumlah dokumen sebelum delete $collection periode $range_label"
        archive_current_step=RECOUNT
        step_started=$SECONDS
        count_output=$(run_mongosh_with_progress "recount $collection $range_label" \
            "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$count_js") \
            || die "Gagal memeriksa ulang jumlah dokumen $collection $range_label"
        current_count=$(awk -F '\t' '$1 == "ARCHIVE_COUNT" {print $2; exit}' <<<"$count_output")
        [[ $current_count =~ ^[0-9]+$ ]] || die "Hasil recount tidak valid"
        allow_shrink=0
        if [[ $current_count == "$expected_count" ]]; then
            log "RECOUNT: sesuai ($current_count dokumen; $((SECONDS - step_started)) detik)"
        elif [[ $collection_ttl != - ]] && (( current_count < expected_count )); then
            # TTL MongoDB sudah menghapus sebagian dokumen yang ada di backup.
            # Sisanya tetap bagian dari backup, jadi aman dihapus.
            allow_shrink=1
            log "RECOUNT: berkurang $expected_count -> $current_count karena TTL ($collection_ttl); lanjut hapus sisa"
        else
            die "Jumlah dokumen berubah setelah backup ($expected_count menjadi $current_count); data tidak dihapus"
        fi
        export ARCHIVE_ALLOW_SHRINK=$allow_shrink

        delete_started_at=$(archive_now)
        archive_progress_notify '🗑 MONGODB ARCHIVE — PROSES PENGHAPUSAN' 16705372 "🗄 Collection
$target_text

📅 Periode
$period_text

📊 Total yang akan dihapus
$(archive_format_count "$current_count") dokumen $(if (( allow_shrink == 1 )); then printf '(backup %s; selisih sudah dihapus TTL MongoDB)' "$(archive_format_count "$expected_count")"; else printf '(sudah di-recount, sesuai backup)'; fi)

☁️ Backup GCS
$BACKUP_REMOTE_URI

⚙️ Batch
$(archive_format_count "$MONGO_ARCHIVE_DELETE_BATCH_SIZE") dokumen per batch

🕒 Mulai hapus
$delete_started_at"

        log "DELETE: mulai $collection periode $range_label (batch $MONGO_ARCHIVE_DELETE_BATCH_SIZE)"
        archive_current_step=DELETE
        step_started=$SECONDS
        delete_output=$(run_mongosh_with_progress "delete $collection $range_label" \
            "$MONGO_ARCHIVE_DELETE_USER" \
            "$MONGO_ARCHIVE_DELETE_PASSWORD" \
            "${MONGO_ARCHIVE_DELETE_AUTH_DB:-$MONGO_AUTH_DB}" \
            "$delete_js") || die "Penghapusan gagal untuk $collection $range_label; backup GCS tetap aman"

        IFS=$'\t' read -r _ deleted_count remaining_count \
            <<<"$(awk -F '\t' '$1 == "DELETED" {print; exit}' <<<"$delete_output")"
        [[ $deleted_count =~ ^[0-9]+$ && $remaining_count == 0 ]] \
            || die "Verifikasi penghapusan gagal untuk $collection $range_label"
        if (( allow_shrink == 1 )); then
            (( deleted_count <= current_count )) \
                || die "Verifikasi penghapusan gagal untuk $collection $range_label"
        else
            [[ $deleted_count == "$expected_count" ]] \
                || die "Verifikasi penghapusan gagal untuk $collection $range_label"
        fi

        archive_documents_deleted=$((archive_documents_deleted + deleted_count))
        archive_ranges_deleted=$((archive_ranges_deleted + 1))
        delete_finished_at=$(archive_now)
        log "DELETE: sukses $collection periode $range_label | $deleted_count dokumen dihapus | sisa=$remaining_count | durasi=$((SECONDS - step_started)) detik"

        archive_progress_notify '✅ MONGODB ARCHIVE — PENGHAPUSAN BERHASIL' 5763719 "🗄 Collection
$target_text

📅 Periode
$period_text

🗑 Dokumen dihapus
$(archive_format_count "$deleted_count") dokumen (sisa $remaining_count)

🕒 Waktu penghapusan
Mulai  : $delete_started_at
Selesai: $delete_finished_at
Durasi : $(format_duration "$((SECONDS - step_started))")

☁️ Backup GCS
$BACKUP_REMOTE_URI"

        detail="$collection | $period_text: $(archive_format_count "$expected_count") dok, $(human_bytes "$artifact_bytes"), dihapus $delete_finished_at"
    else
        log "DELETE: nonaktif (--backup); data MongoDB tidak dihapus untuk $collection periode $range_label"
        detail="$collection | $period_text: $(archive_format_count "$expected_count") dok, $(human_bytes "$artifact_bytes"), tidak dihapus"
    fi

    archive_ranges_backed_up=$((archive_ranges_backed_up + 1))
    archive_documents_backed_up=$((archive_documents_backed_up + expected_count))
    archive_period_details+=("$detail")
    rm -f -- "$artifact" "$artifact.sha256" "$query_file"
    log "DONE: $collection periode $range_label | $expected_count dokumen | $((SECONDS - range_started)) detik total"
    archive_current_period=''
    archive_current_step=''
}

process_selected_range() {
    if [[ $mode == delete-only ]]; then
        delete_range_only "$@"
    else
        process_range "$@"
    fi
}

process_year() {
    local collection=$1
    local date_field=$2
    local year=$3
    local next_year=$((year + 1))
    local month
    local start_local
    local end_local
    local cursor
    local next_day

    case "$MONGO_ARCHIVE_CHUNK" in
        year)
            process_selected_range "$collection" "$date_field" "$year" \
                "$year-01-01" "$next_year-01-01" "$year"
            ;;

        month)
            for month in {01..12}; do
                start_local="$year-$month-01"
                end_local=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date -d "$start_local +1 month" +%F)
                process_selected_range "$collection" "$date_field" "$year" \
                    "$start_local" "$end_local" "$year-$month"
            done
            ;;

        day)
            cursor="$year-01-01"
            while [[ $cursor < "$next_year-01-01" ]]; do
                next_day=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date -d "$cursor +1 day" +%F)
                process_selected_range "$collection" "$date_field" "$year" \
                    "$cursor" "$next_day" "$cursor"
                cursor=$next_day
            done
            ;;
    esac
}

explicit_years=()
if [[ $mode == delete-only && $MONGO_ARCHIVE_YEARS == auto ]]; then
    die "--delete-only tidak menerima MONGO_ARCHIVE_YEARS=auto; gunakan daftar tahun eksplisit atau all"
fi
if [[ $MONGO_ARCHIVE_YEARS == all ]]; then
    [[ $mode == delete-only ]] \
        || die "MONGO_ARCHIVE_YEARS=all hanya boleh dipakai dengan --delete-only"
elif [[ $MONGO_ARCHIVE_YEARS != auto ]]; then
    IFS=',' read -r -a requested_years <<<"$MONGO_ARCHIVE_YEARS"
    for year in "${requested_years[@]}"; do
        year="${year#"${year%%[![:space:]]*}"}"
        year="${year%"${year##*[![:space:]]}"}"
        [[ $year =~ ^[0-9]{4}$ ]] || die "Tahun archive tidak valid: $year"
        if [[ $mode == delete-only ]]; then
            year_is_delete_only_protected "$year" \
                && die "Tahun $year dilindungi oleh MONGO_ARCHIVE_DELETE_ONLY_PROTECTED_YEARS"
        else
            (( 10#$year <= 10#$current_year )) \
                || die "Tahun mendatang $year tidak boleh diproses"
            if [[ $mode == delete ]] && (( 10#$year == 10#$current_year )); then
                die "Tahun berjalan $year boleh di-backup tetapi tidak boleh di-delete"
            fi
        fi
        explicit_years+=("$year")
    done
    mapfile -t explicit_years < <(printf '%s\n' "${explicit_years[@]}" | sort -nu)
    (( ${#explicit_years[@]} > 0 )) || die "MONGO_ARCHIVE_YEARS kosong"
fi

if [[ $mode == delete-only ]]; then
    required MONGO_ARCHIVE_DELETE_ONLY_CONFIRM
    delete_only_targets=$(IFS=,; printf '%s' "${confirmation_targets[*]}")
    delete_only_protected=$(IFS=,; printf '%s' "${delete_only_protected_years[*]}")
    if [[ $MONGO_ARCHIVE_YEARS == all ]]; then
        delete_only_scope='ALL UNPROTECTED YEARS'
    else
        delete_only_scope="YEARS $(IFS=,; printf '%s' "${explicit_years[*]}")"
    fi
    expected_delete_only_confirmation="DELETE WITHOUT BACKUP $delete_only_scope FROM $delete_only_targets; PROTECTED $MONGO_ARCHIVE_DELETE_ONLY_PROTECTED_YEARS"
    [[ $MONGO_ARCHIVE_DELETE_ONLY_CONFIRM == "$expected_delete_only_confirmation" ]] \
        || die "MONGO_ARCHIVE_DELETE_ONLY_CONFIRM harus persis: $expected_delete_only_confirmation"
    log "DELETE-ONLY CONFIRMED: scope=$delete_only_scope | protected=$delete_only_protected"
fi

if [[ $mode == delete ]]; then
    last_allowed_year=$((10#$current_year - 1))
else
    last_allowed_year=$((10#$current_year))
fi

for index in "${!collections[@]}"; do
    collection=${collections[$index]}
    date_field=${date_fields[$index]}
    archive_current_period="${MONGO_ARCHIVE_DATABASE}.${collection} | pemeriksaan awal"
    archive_current_step=INSPECT

    # 1. Collection ada dan berisi data?
    log "CHECK: memeriksa collection $collection (field: $date_field)"
    inspect_collection "$collection" "$date_field"
    case $collection_state in
        MISSING)
            skip_collection "$collection" "collection tidak ada di database $MONGO_ARCHIVE_DATABASE"
            continue
            ;;
        NOT_COLLECTION)
            skip_collection "$collection" "bukan collection biasa ($collection_type)"
            continue
            ;;
    esac
    if (( collection_estimated == 0 )); then
        skip_collection "$collection" "collection kosong"
        continue
    fi
    log "CHECK: $collection ±$collection_estimated dokumen | index=$collection_index | ttl=$collection_ttl"

    # 2. Delete-only tidak boleh membuat index/perubahan tambahan pada DB.
    if [[ $mode == delete-only ]]; then
        [[ $collection_index != - ]] \
            || die "Delete-only memerlukan index yang diawali field $date_field pada $collection; script tidak membuat index otomatis"
        log "INDEX: delete-only memakai index $collection_index untuk $date_field"
    else
        ensure_date_index "$collection" "$date_field"
    fi

    # 3. Tahun kandidat, lalu saring hanya yang benar-benar berisi data.
    archive_current_step=YEAR_CHECK
    candidate_years=()
    if [[ $MONGO_ARCHIVE_YEARS == all ]]; then
        find_all_collection_years "$collection" "$date_field"
        for year in "${all_collection_years[@]}"; do
            if year_is_delete_only_protected "$year"; then
                log "PROTECTED: $collection tahun $year tidak akan dihapus"
            else
                candidate_years+=("$year")
            fi
        done
    elif [[ $MONGO_ARCHIVE_YEARS == auto ]]; then
        first_year=$(oldest_year "$collection" "$date_field") \
            || die "Gagal mencari data tertua pada $collection"
        if [[ -z $first_year ]]; then
            skip_collection "$collection" "tidak ada data BSON Date pada field $date_field"
            continue
        fi
        for (( year = 10#$first_year; year <= last_allowed_year; year++ )); do
            candidate_years+=("$year")
        done
    else
        candidate_years=("${explicit_years[@]}")
    fi

    if (( ${#candidate_years[@]} == 0 )); then
        skip_collection "$collection" "tidak ada tahun yang boleh diproses; seluruh tahun yang ditemukan terlindungi atau kosong"
        continue
    fi

    filter_years_with_data "$collection" "$date_field" "${candidate_years[@]}"
    if (( ${#years_with_data[@]} == 0 )); then
        skip_collection "$collection" "tidak ada data di tahun $(IFS=,; printf '%s' "${candidate_years[*]}") (field $date_field)"
        continue
    fi
    years=("${years_with_data[@]}")
    log "CHECK: $collection berisi data di tahun $(IFS=,; printf '%s' "${years[*]}")"

    collection_docs_before=$archive_documents_backed_up
    collection_deleted_before=$archive_documents_deleted
    collection_ranges_before=$archive_ranges_backed_up
    collection_deleted_ranges_before=$archive_ranges_deleted

    for year in "${years[@]}"; do
        log "YEAR: mulai $collection tahun $year | chunk=$MONGO_ARCHIVE_CHUNK"
        year_started=$SECONDS
        process_year "$collection" "$date_field" "$year"
        log "YEAR: selesai $collection tahun $year | durasi=$((SECONDS - year_started)) detik"
    done

    if [[ $mode == delete-only ]]; then
        collection_line="✅ $collection ($(IFS=,; printf '%s' "${years[*]}")): $((archive_ranges_deleted - collection_deleted_ranges_before)) periode, $(archive_format_count "$((archive_documents_deleted - collection_deleted_before))") dok dihapus TANPA backup"
    else
        collection_line="✅ $collection ($(IFS=,; printf '%s' "${years[*]}")): $((archive_ranges_backed_up - collection_ranges_before)) periode, $(archive_format_count "$((archive_documents_backed_up - collection_docs_before))") dok di-backup"
    fi
    if [[ $mode == delete ]]; then
        collection_line+=", $(archive_format_count "$((archive_documents_deleted - collection_deleted_before))") dok dihapus"
    fi
    archive_collection_status+=("$collection_line")
done
archive_current_period=''
archive_current_step=''

log "SUMMARY: mode=--$mode | periode dicek=$archive_ranges_checked | kosong=$archive_ranges_empty | di-backup=$archive_ranges_backed_up | periode dihapus=$archive_ranges_deleted | dokumen di-backup=$archive_documents_backed_up | dokumen dihapus=$archive_documents_deleted | durasi=$((SECONDS - archive_run_started)) detik"
if [[ $mode == delete ]]; then
    log "Archive dan delete selesai; tahun $current_year tetap dilindungi"
elif [[ $mode == delete-only ]]; then
    log "Delete-only selesai TANPA backup; tahun terlindungi: $(IFS=,; printf '%s' "${delete_only_protected_years[*]}")"
else
    log "Backup archive selesai; tidak ada data MongoDB yang dihapus"
fi
