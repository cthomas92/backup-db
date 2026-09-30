#!/usr/bin/env bash
ENGINE=mariadb
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"
config_file=${1:-"$SCRIPT_DIR/.env"}
[[ $# -le 1 ]] || die "Cara pakai: $0 [/absolute/path/.env]"
load_config "$config_file"

for command in mariadb mariadb-dump gzip; do need "$command"; done
required MARIADB_USER
required MARIADB_PASSWORD
required MARIADB_DATABASES
: "${MARIADB_HOST:=127.0.0.1}"
: "${MARIADB_PORT:=3306}"
: "${MARIADB_SOCKET:=}"
: "${MARIADB_BACKUP_NAME:=mariadb-logical}"
set_backup_name "$MARIADB_BACKUP_NAME"
unset MYSQL_PWD

[[ $MARIADB_PORT =~ ^[1-9][0-9]*$ && $MARIADB_PORT -le 65535 ]] \
    || die "MARIADB_PORT tidak valid"

IFS=',' read -r -a databases <<<"$MARIADB_DATABASES"
(( ${#databases[@]} > 0 )) || die "MARIADB_DATABASES tidak boleh kosong"
sql_list=''
for i in "${!databases[@]}"; do
    db=${databases[$i]}
    # Buang spasi di awal/akhir agar 'db1, db2' tetap valid.
    db="${db#"${db%%[![:space:]]*}"}"
    db="${db%"${db##*[![:space:]]}"}"
    [[ $db =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die "Nama database tidak didukung: $db"
    databases[$i]=$db
    sql_list+="'$db',"
done
sql_list=${sql_list%,}

begin_backup
defaults_file="$RUN_DIR/mariadb.cnf"
TEMP_CREDENTIAL_FILE=$defaults_file
{
    printf '[client]\n'
    printf 'user="%s"\n' "$(escape_quoted_value "$MARIADB_USER")"
    printf 'password="%s"\n' "$(escape_quoted_value "$MARIADB_PASSWORD")"
    if [[ -n $MARIADB_SOCKET ]]; then
        [[ $MARIADB_SOCKET == /* ]] || die "MARIADB_SOCKET harus absolute path"
        printf 'socket="%s"\n' "$(escape_quoted_value "$MARIADB_SOCKET")"
    else
        printf 'host="%s"\n' "$(escape_quoted_value "$MARIADB_HOST")"
        printf 'port=%s\nprotocol=TCP\n' "$MARIADB_PORT"
        if [[ -n ${MARIADB_SSL_CA:-} ]]; then
            [[ $MARIADB_SSL_CA == /* && -f $MARIADB_SSL_CA && ! -L $MARIADB_SSL_CA ]] \
                || die "MARIADB_SSL_CA tidak valid"
            printf 'ssl-ca="%s"\nssl=1\nssl-verify-server-cert=1\n' \
                "$(escape_quoted_value "$MARIADB_SSL_CA")"
        fi
    fi
} >"$defaults_file"
chmod 600 "$defaults_file"

conn=(--defaults-file="$defaults_file")
non_innodb=$(run_backup mariadb "${conn[@]}" --batch --skip-column-names \
    --execute="SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ($sql_list) AND TABLE_TYPE='BASE TABLE' AND ENGINE <> 'InnoDB'")
[[ $non_innodb == 0 ]] \
    || die "Ditemukan tabel non-InnoDB; --single-transaction tidak dapat menjamin konsistensi"

artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.sql.gz"
args=("${conn[@]}" --single-transaction --quick --skip-lock-tables --routines \
      --events --triggers --hex-blob --tz-utc --no-tablespaces)
log "Dump database: ${databases[*]}"
run_backup mariadb-dump "${args[@]}" --databases "${databases[@]}" | gzip -6 >"$artifact"
gzip -t "$artifact"
upload_backup "$artifact"
