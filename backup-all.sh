#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${1:-"$SCRIPT_DIR/.env"}
[[ $# -le 1 ]] || { echo "Cara pakai: $0 [/absolute/path/.env]" >&2; exit 2; }
[[ $ENV_FILE == /* ]] || ENV_FILE="$PWD/$ENV_FILE"
[[ -f $ENV_FILE && ! -L $ENV_FILE ]] || { echo "File .env tidak valid: $ENV_FILE" >&2; exit 2; }
[[ -O $ENV_FILE ]] || { echo "File .env harus dimiliki user yang menjalankan backup: $ENV_FILE" >&2; exit 2; }
mode=$(stat -c '%a' -- "$ENV_FILE")
(( (8#$mode & 077) == 0 )) || { echo "Jalankan chmod 600 pada: $ENV_FILE" >&2; exit 2; }

# .env adalah file konfigurasi Bash tepercaya milik administrator.
# shellcheck disable=SC1090
source "$ENV_FILE"

bool() {
    case "${1:-false}" in
        true|TRUE|1|yes|YES) return 0 ;;
        false|FALSE|0|no|NO|'') return 1 ;;
        *) echo "Nilai boolean tidak valid: $1" >&2; return 2 ;;
    esac
}

rc=0
run_one() {
    local enabled=$1 script=$2 label=$3
    if bool "$enabled"; then
        echo "===== $label =====" >&2
        if ! "$SCRIPT_DIR/$script" "$ENV_FILE"; then
            echo "FAILED: $label" >&2
            rc=1
        fi
    fi
}

run_one "${BACKUP_MONGODB:-false}" backup-mongodb.sh "MongoDB"
run_one "${BACKUP_MARIADB:-false}" backup-mariadb.sh "MariaDB logical"
run_one "${BACKUP_MARIADB_PHYSICAL:-false}" backup-mariadb-physical.sh "MariaDB physical"
run_one "${BACKUP_POSTGRESQL:-false}" backup-postgresql.sh "PostgreSQL"

exit "$rc"
