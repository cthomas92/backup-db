#!/usr/bin/env bash
ENGINE=mariadb
ENGINE_CONFIG_KEYS=(MARIADB_DEFAULTS_FILE MARIADB_DATABASES)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"
load_config "$@"

required MARIADB_DEFAULTS_FILE
secure_file "$MARIADB_DEFAULTS_FILE"
need mariadb
need mariadb-dump
need gzip
unset MYSQL_PWD

declare -p MARIADB_DATABASES >/dev/null 2>&1 || die "Isi MARIADB_DATABASES=(...) di config"
[[ $(declare -p MARIADB_DATABASES) == "declare -a "* ]] \
    || die "MARIADB_DATABASES harus berupa array Bash: MARIADB_DATABASES=('db1' 'db2')"
(( ${#MARIADB_DATABASES[@]} > 0 )) || die "MARIADB_DATABASES tidak boleh kosong"
sql_list=''
for db in "${MARIADB_DATABASES[@]}"; do
    [[ $db =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die "Nama database tidak didukung: $db"
    sql_list+="'$db',"
done
sql_list=${sql_list%,}

begin_backup
conn=(--defaults-file="$MARIADB_DEFAULTS_FILE")
non_innodb=$(run_backup mariadb "${conn[@]}" --batch --skip-column-names \
    --execute="SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ($sql_list) AND TABLE_TYPE='BASE TABLE' AND ENGINE <> 'InnoDB'")
[[ $non_innodb == 0 ]] || die "Ditemukan tabel non-InnoDB; --single-transaction tidak dapat menjamin konsistensinya"

artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.sql.gz"
args=("${conn[@]}" --single-transaction --quick --skip-lock-tables --routines
      --events --triggers --hex-blob --tz-utc --no-tablespaces)
log "Dump satu transaksi; jangan jalankan migration/DDL selama backup"
run_backup mariadb-dump "${args[@]}" --databases "${MARIADB_DATABASES[@]}" | gzip -6 >"$artifact"
gzip -t "$artifact"
upload_backup "$artifact"
