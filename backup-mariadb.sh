#!/usr/bin/env bash

ENGINE=mariadb

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"

config_file=${1:-"$SCRIPT_DIR/.env"}

[[ $# -le 1 ]] \
    || die "Cara pakai: $0 [/absolute/path/.env]"

load_config "$config_file"


for command in \
    mariadb \
    mariadb-dump \
    gzip \
    grep \
    sort \
    head
do
    need "$command"
done


required MARIADB_USER
required MARIADB_PASSWORD
required MARIADB_DATABASES


: "${MARIADB_HOST:=127.0.0.1}"
: "${MARIADB_PORT:=3306}"
: "${MARIADB_SOCKET:=}"

: "${MARIADB_BACKUP_NAME:=mariadb-logical}"

: "${MARIADB_SKIP_OBJECT_ERRORS:=true}"


set_backup_name "$MARIADB_BACKUP_NAME"

unset MYSQL_PWD


[[ $MARIADB_PORT =~ ^[1-9][0-9]*$ \
   && $MARIADB_PORT -le 65535 ]] \
    || die "MARIADB_PORT tidak valid"


bool_value "$MARIADB_SKIP_OBJECT_ERRORS" || {
    rc=$?

    (( rc == 1 )) \
        || die "MARIADB_SKIP_OBJECT_ERRORS harus true/false"
}


IFS=',' read -r -a databases \
    <<<"$MARIADB_DATABASES"


(( ${#databases[@]} > 0 )) \
    || die "MARIADB_DATABASES tidak boleh kosong"


sql_list=''


for i in "${!databases[@]}"; do

    db=${databases[$i]}

    # Buang spasi awal/akhir.
    db="${db#"${db%%[![:space:]]*}"}"
    db="${db%"${db##*[![:space:]]}"}"

    [[ $db =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] \
        || die "Nama database tidak didukung: $db"

    databases[$i]=$db

    sql_list+="'$db',"
done


sql_list=${sql_list%,}


begin_backup


# ============================================================
# MARIADB CREDENTIAL
# ============================================================

defaults_file="$RUN_DIR/mariadb.cnf"

TEMP_CREDENTIAL_FILE=$defaults_file


{
    printf '[client]\n'

    printf 'user="%s"\n' \
        "$(escape_quoted_value "$MARIADB_USER")"

    printf 'password="%s"\n' \
        "$(escape_quoted_value "$MARIADB_PASSWORD")"


    if [[ -n $MARIADB_SOCKET ]]; then

        [[ $MARIADB_SOCKET == /* ]] \
            || die "MARIADB_SOCKET harus absolute path"

        printf 'socket="%s"\n' \
            "$(escape_quoted_value "$MARIADB_SOCKET")"

    else

        printf 'host="%s"\n' \
            "$(escape_quoted_value "$MARIADB_HOST")"

        printf 'port=%s\nprotocol=TCP\n' \
            "$MARIADB_PORT"


        if [[ -n ${MARIADB_SSL_CA:-} ]]; then

            [[ $MARIADB_SSL_CA == /* \
               && -f $MARIADB_SSL_CA \
               && ! -L $MARIADB_SSL_CA ]] \
                || die "MARIADB_SSL_CA tidak valid"

            printf 'ssl-ca="%s"\nssl=1\nssl-verify-server-cert=1\n' \
                "$(escape_quoted_value "$MARIADB_SSL_CA")"
        fi
    fi

} >"$defaults_file"


chmod 600 "$defaults_file"


conn=(
    --defaults-file="$defaults_file"
)


# ============================================================
# PREFLIGHT CONNECTION
# ============================================================

run_backup \
    mariadb \
    "${conn[@]}" \
    --batch \
    --skip-column-names \
    --execute='SELECT 1' \
    >/dev/null


# ============================================================
# CHECK NON-INNODB
# ============================================================

non_innodb=$(
    run_backup \
        mariadb \
        "${conn[@]}" \
        --batch \
        --skip-column-names \
        --execute="SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ($sql_list) AND TABLE_TYPE='BASE TABLE' AND ENGINE <> 'InnoDB'"
)


if [[ $non_innodb != 0 ]]; then

    mark_warning \
        "Ditemukan $non_innodb tabel non-InnoDB. Backup tetap lanjut, tetapi --single-transaction tidak menjamin snapshot konsisten untuk tabel tersebut."
fi


# ============================================================
# OUTPUT
# ============================================================

artifact="$RUN_DIR/${BACKUP_FILE_SERVER}-${BACKUP_NAME}-${STAMP}.sql.gz"

dump_log="$LOG_DIR/mariadb-dump-${STAMP}.log"


: >"$dump_log"

chmod 600 "$dump_log"


args=(
    "${conn[@]}"

    --single-transaction
    --quick
    --skip-lock-tables

    --routines
    --events
    --triggers

    --hex-blob
    --tz-utc
    --no-tablespaces
)


if bool_value "$MARIADB_SKIP_OBJECT_ERRORS"; then

    # Kalau satu view/table bermasalah,
    # mariadb-dump tetap lanjut.
    args+=(--force)
fi


log "Dump database: ${databases[*]}"


# ============================================================
# BACKUP
# ============================================================

set +e


run_backup \
    mariadb-dump \
    "${args[@]}" \
    --databases \
    "${databases[@]}" \
    2> >(
        tee -a "$dump_log" >&2
    ) |
    gzip -6 \
        >"$artifact"


pipe_rc=(
    "${PIPESTATUS[@]}"
)


set -e


dump_rc=${pipe_rc[0]:-1}

gzip_rc=${pipe_rc[1]:-1}


(( gzip_rc == 0 )) \
    || die "gzip gagal saat membuat backup MariaDB (rc=$gzip_rc)"


gzip -t "$artifact"


# ============================================================
# FATAL ERROR CHECK
# ============================================================

fatal_regex='Access denied|Can.t connect|Could not connect|Lost connection|server has gone away|No space left|Disk full|write error|unknown option|when trying to connect|Connection refused|Connection timed out|TLS/SSL error'


if [[ -s $dump_log ]] \
   && grep -Eiq \
        "$fatal_regex" \
        "$dump_log"
then

    die "mariadb-dump mengalami error koneksi/auth/storage. Lihat log: $dump_log"
fi


# ============================================================
# DETECT SKIPPED / BROKEN OBJECTS
# ============================================================

skipped_count=0


if [[ -s $dump_log ]]; then

    skipped_count=$(
        grep -Ec \
            "^mariadb-dump: Couldn't execute|^mysqldump: Couldn't execute" \
            "$dump_log" \
            || true
    )
fi


if (( skipped_count > 0 )); then

    while IFS= read -r skipped_object; do

        [[ -n $skipped_object ]] \
            || continue

        mark_skipped_object \
            "$skipped_object"

    done < <(

        {
            # Object yang sedang didump.
            # Contoh:
            # SHOW FIELDS FROM `vw_ex_coal`
            grep -E \
                "^mariadb-dump: Couldn't execute|^mysqldump: Couldn't execute" \
                "$dump_log" |
                sed -n \
                    's/.*SHOW FIELDS FROM `\([^`]*\)`.*/\1/p'


            # View yang disebut sebagai sumber error.
            # Contoh:
            # View 'db_opr.vw_unit' references invalid...
            grep -E \
                "^mariadb-dump: Couldn't execute|^mysqldump: Couldn't execute" \
                "$dump_log" |
                sed -n \
                    "s/.*View '\([^']*\)'.*/\1/p"

        } |
            sort -u |
            head -n 20
    )
fi


# ============================================================
# RESULT HANDLING
# ============================================================

if (( dump_rc != 0 )); then

    # Timeout / terminated tetap dianggap fatal.
    if (( dump_rc == 124 \
          || dump_rc == 137 \
          || dump_rc == 143 ))
    then

        die "mariadb-dump timeout/terminated (rc=$dump_rc). Lihat log: $dump_log"
    fi


    # Broken object boleh diskip.
    if bool_value "$MARIADB_SKIP_OBJECT_ERRORS" \
       && (( skipped_count > 0 ))
    then

        mark_warning \
            "mariadb-dump selesai dengan rc=$dump_rc; $skipped_count object/table/view bermasalah dilewati. Detail: $dump_log"

    else

        die "mariadb-dump gagal (rc=$dump_rc). Lihat log: $dump_log"
    fi


elif (( skipped_count > 0 )); then

    mark_warning \
        "$skipped_count object/table/view bermasalah dilewati oleh mariadb-dump --force. Detail: $dump_log"


elif [[ -s $dump_log ]]; then

    # Warning client non-fatal tetap disimpan.
    mark_warning \
        "mariadb-dump menghasilkan warning. Detail: $dump_log"


else

    rm -f -- "$dump_log"
fi


# ============================================================
# GCS
# ============================================================

upload_backup "$artifact"