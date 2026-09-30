#!/usr/bin/env bash
ENGINE=postgresql
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"
config_file=${1:-"$SCRIPT_DIR/.env"}
[[ $# -le 1 ]] || die "Cara pakai: $0 [/absolute/path/.env]"
load_config "$config_file"

for command in pg_dump pg_restore; do need "$command"; done
required POSTGRES_USER
required POSTGRES_PASSWORD
required POSTGRES_DATABASE
: "${POSTGRES_HOST:=/var/run/postgresql}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_CONNECT_TIMEOUT:=15}"
: "${POSTGRES_SSLMODE:=prefer}"
: "${POSTGRES_BACKUP_NAME:=postgresql-${POSTGRES_DATABASE}}"
set_backup_name "$POSTGRES_BACKUP_NAME"

[[ $POSTGRES_PORT =~ ^[1-9][0-9]*$ && $POSTGRES_PORT -le 65535 ]] \
    || die "POSTGRES_PORT tidak valid"
[[ $POSTGRES_CONNECT_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die "POSTGRES_CONNECT_TIMEOUT tidak valid"

pg_password=$POSTGRES_PASSWORD
unset PGPASSWORD PGSERVICE PGSERVICEFILE PGOPTIONS PGHOSTADDR PGPASSFILE
export PGHOST="$POSTGRES_HOST"
export PGPORT="$POSTGRES_PORT"
export PGUSER="$POSTGRES_USER"
export PGDATABASE="$POSTGRES_DATABASE"
export PGCONNECT_TIMEOUT="$POSTGRES_CONNECT_TIMEOUT"
export PGSSLMODE="$POSTGRES_SSLMODE"
if [[ -n ${POSTGRES_SSLROOTCERT:-} ]]; then
    [[ $POSTGRES_SSLROOTCERT == /* && -f $POSTGRES_SSLROOTCERT && ! -L $POSTGRES_SSLROOTCERT ]] \
        || die "POSTGRES_SSLROOTCERT tidak valid"
    export PGSSLROOTCERT="$POSTGRES_SSLROOTCERT"
fi

begin_backup
PGPASSFILE="$RUN_DIR/pgpass"
TEMP_CREDENTIAL_FILE=$PGPASSFILE
printf '*:%s:%s:%s:%s\n' \
    "$(escape_pgpass_value "$PGPORT")" \
    "$(escape_pgpass_value "$PGDATABASE")" \
    "$(escape_pgpass_value "$PGUSER")" \
    "$(escape_pgpass_value "$pg_password")" >"$PGPASSFILE"
chmod 600 "$PGPASSFILE"
export PGPASSFILE
unset pg_password

artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.dump"
log "Dump database: $POSTGRES_DATABASE"
run_backup pg_dump --no-password --format=custom --compress=6 \
    --no-owner --no-acl --file="$artifact"
pg_restore --list "$artifact" >/dev/null
# Ekspansi archive ke /dev/null memvalidasi bahwa archive dapat dibaca seluruhnya.
run_backup pg_restore --file=/dev/null "$artifact"
upload_backup "$artifact"
