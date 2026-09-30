#!/usr/bin/env bash

ENGINE=backup-all


SCRIPT_DIR=$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
    pwd
)


# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"


#
# Kalau menjalankan backup-all.sh:
#
# MongoDB / MariaDB / PostgreSQL / Physical
# tidak mengirim notif masing-masing.
#
# Hanya satu summary akhir.
#
export BACKUP_SUPPRESS_STANDALONE_NOTIFY=1


ENV_FILE=${1:-"$SCRIPT_DIR/.env"}


[[ $# -le 1 ]] \
    || die "Cara pakai: $0 [/absolute/path/.env]"


if [[ $ENV_FILE != /* ]]; then

    ENV_FILE="$PWD/$ENV_FILE"
fi


load_config "$ENV_FILE"


validate_bool_var() {

    local name=$1
    local value=${!1:-false}
    local rc


    if bool_value "$value"; then

        return 0

    else

        rc=$?


        (( rc == 1 )) \
            || die "$name harus true/false"
    fi
}


for name in \
    BACKUP_MONGODB \
    BACKUP_MARIADB \
    BACKUP_MARIADB_PHYSICAL \
    BACKUP_POSTGRESQL \
    NOTIFY_DISCORD \
    NOTIFY_TELEGRAM \
    NOTIFY_ON_SUCCESS \
    NOTIFY_ON_WARNING \
    NOTIFY_ON_FAILURE
do

    validate_bool_var "$name"
done


secure_dir "$BACKUP_DIR"


STATUS_DIR=$(
    mktemp -d \
        "$BACKUP_DIR/.backup-status.XXXXXX"
)


trap \
    'rm -rf -- "$STATUS_DIR"' \
    EXIT INT TERM HUP


overall='SUCCESS'

exit_rc=0


declare -a summary_lines=()

declare -a warning_lines=()

declare -a skipped_lines=()


run_one() {

    local enabled=$1
    local script=$2
    local label=$3

    local status_file

    local rc
    local status

    local warning_count
    local first_warning

    local record_type
    local record_value


    #
    # Disabled.
    #
    if ! bool_value "$enabled"; then

        summary_lines+=(
            "$label: SKIPPED"
        )

        return 0
    fi


    echo "===== $label =====" >&2


    status_file="$STATUS_DIR/${script}.status"


    : >"$status_file"


    chmod 600 "$status_file"


    export BACKUP_STATUS_FILE="$status_file"


    if "$SCRIPT_DIR/$script" "$ENV_FILE"; then

        rc=0

    else

        rc=$?
    fi


    unset BACKUP_STATUS_FILE


    #
    # Ambil object yang diskip child backup.
    #
    while IFS=$'\t' \
        read -r \
            record_type \
            record_value
    do

        [[ $record_type == SKIPPED ]] \
            || continue


        [[ -n $record_value ]] \
            || continue


        #
        # Batasi supaya Telegram / Discord
        # tidak terlalu panjang.
        #
        if (( ${#skipped_lines[@]} < 15 )); then

            skipped_lines+=(
                "$label: $record_value"
            )
        fi


    done <"$status_file"


    #
    # FAILED
    #
    if (( rc != 0 )); then

        status='FAILED'

        overall='FAILED'

        exit_rc=1


        summary_lines+=(
            "$label: FAILED"
        )


        echo "FAILED: $label" >&2


        return 0
    fi


    #
    # Hitung warning.
    #
    warning_count=$(
        grep -c '^WARNING' \
            "$status_file" \
            2>/dev/null \
            || true
    )


    #
    # WARNING
    #
    if (( warning_count > 0 )); then

        status='WARNING'


        if [[ $overall != FAILED ]]; then

            overall='WARNING'
        fi


        summary_lines+=(
            "$label: WARNING ($warning_count)"
        )


        first_warning=$(
            sed -n \
                's/^WARNING[[:space:]]*//p' \
                "$status_file" |
                head -n 1
        )


        if [[ -n $first_warning ]]; then

            warning_lines+=(
                "$label: $first_warning"
            )
        fi


    #
    # SUCCESS
    #
    else

        status='SUCCESS'


        summary_lines+=(
            "$label: SUCCESS"
        )
    fi


    echo "$status: $label" >&2
}


#
# MongoDB
#
run_one \
    "${BACKUP_MONGODB:-false}" \
    backup-mongodb.sh \
    "MongoDB"


#
# MariaDB Logical
#
run_one \
    "${BACKUP_MARIADB:-false}" \
    backup-mariadb.sh \
    "MariaDB Logical"


#
# MariaDB Physical
#
run_one \
    "${BACKUP_MARIADB_PHYSICAL:-false}" \
    backup-mariadb-physical.sh \
    "MariaDB Physical"


#
# PostgreSQL
#
run_one \
    "${BACKUP_POSTGRESQL:-false}" \
    backup-postgresql.sh \
    "PostgreSQL"


host_name=$(
    backup_display_host
)


finished=$(
    notification_time
)


duration=$(
    format_duration \
        "$(
            (
                $(date +%s) -
                ${BACKUP_STARTED_EPOCH:-$(date +%s)}
            )
        )"
)


message="🖥 Host
$host_name

☁️ Destination
$GCS_URI

📊 Backup Summary"


#
# Summary engine.
#
for line in "${summary_lines[@]}"; do

    case "$line" in

        *": SUCCESS")

            message+=$'\n'"✅ $line"
            ;;


        *": WARNING"* )

            message+=$'\n'"⚠️ $line"
            ;;


        *": FAILED")

            message+=$'\n'"❌ $line"
            ;;


        *": SKIPPED")

            message+=$'\n'"⏭️ $line"
            ;;


        *)

            message+=$'\n'"• $line"
            ;;
    esac
done


#
# Object yang dilewati.
#
if (( ${#skipped_lines[@]} > 0 )); then

    message+=$'\n\n'"⚠️ Skipped Objects"


    for line in "${skipped_lines[@]}"; do

        message+=$'\n'"• $line"
    done
fi


#
# Warning detail.
#
if (( ${#warning_lines[@]} > 0 )); then

    message+=$'\n\n'"ℹ️ Warning Details"


    for line in "${warning_lines[@]}"; do

        message+=$'\n'"• $line"
    done
fi


#
# Waktu.
#
message+=$'\n\n'"⏱ Duration
$duration

🕒 Finished
$finished"


#
# Log tidak perlu ditampilkan
# kalau semuanya benar-benar sukses.
#
if [[ $overall != SUCCESS ]]; then

    message+=$'\n\n'"🔎 Log
${LOG_FILE:-$LOG_DIR}"
fi


log "OVERALL: $overall"


for line in "${summary_lines[@]}"; do

    log "$line"
done


send_notifications \
    "$overall" \
    "$message"


exit "$exit_rc"