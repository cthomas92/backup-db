#!/usr/bin/env bash
ENGINE=postgresql
ENGINE_CONFIG_KEYS=(PGHOST PGPORT PGUSER PGDATABASE PGPASSFILE PGSSLMODE PGSSLROOTCERT PGCONNECT_TIMEOUT)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"
load_config "$@"

for command in pg_dump pg_restore; do need "$command"; done
required PGHOST
required PGUSER
required PGDATABASE
: "${PGPORT:=5432}"
: "${PGCONNECT_TIMEOUT:=15}"
unset PGPASSWORD PGSERVICE PGSERVICEFILE PGOPTIONS PGHOSTADDR

if [[ -n ${PGPASSFILE:-} ]]; then
    secure_file "$PGPASSFILE"
    export PGPASSFILE
else
    PGPASSFILE=/dev/null
    export PGPASSFILE
fi
if [[ $PGHOST != /* && ${PGSSLMODE:-} != verify-full ]]; then
    die "Koneksi PostgreSQL melalui TCP wajib memakai PGSSLMODE=verify-full"
fi
export PGHOST PGPORT PGUSER PGDATABASE PGCONNECT_TIMEOUT
export PGSSLMODE="${PGSSLMODE:-prefer}"
[[ -z ${PGSSLROOTCERT:-} ]] || export PGSSLROOTCERT

begin_backup
artifact="$RUN_DIR/${BACKUP_NAME}-${STAMP}.dump"
run_backup pg_dump --no-password --format=custom --compress=6 \
    --no-owner --no-acl --file="$artifact"
pg_restore --list "$artifact" >/dev/null
run_backup pg_restore --file=/dev/null "$artifact"
upload_backup "$artifact"
