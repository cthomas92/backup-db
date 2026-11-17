#!/usr/bin/env bash

# Archive data MongoDB lama ke GCS per rentang waktu, lalu hapus hanya setelah
# backup, checksum, upload, dan verifikasi berhasil.

ENGINE=mongodb-archive
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.bash
source "$SCRIPT_DIR/lib/common.bash"

mode=archive
config_file="$SCRIPT_DIR/.env"

case $# in
    0)
        ;;
    1)
        if [[ $1 == --check-years ]]; then
            mode=check-years
        elif [[ $1 == --help || $1 == -h ]]; then
            printf 'Cara pakai:\n  %s [/.env]\n  %s --check-years [/.env]\n' "$0" "$0"
            exit 0
        else
            config_file=$1
        fi
        ;;
    2)
        [[ $1 == --check-years ]] \
            || die "Cara pakai: $0 [/.env] atau $0 --check-years [/.env]"
        mode=check-years
        config_file=$2
        ;;
    *)
        die "Cara pakai: $0 [/.env] atau $0 --check-years [/.env]"
        ;;
esac

if [[ $mode == check-years ]]; then
    export BACKUP_SUPPRESS_STANDALONE_NOTIFY=1
fi

load_config "$config_file"

if [[ $mode == check-years ]]; then
    # Pemeriksaan tahun tidak memerlukan aktivasi service account GCS.
    GCP_SERVICE_ACCOUNT_FILE=''
fi

for command in mongosh grep awk sort date; do
    need "$command"
done

if [[ $mode == archive ]]; then
    for command in mongodump mongorestore gzip df; do
        need "$command"
    done
fi

required MONGO_USER
required MONGO_PASSWORD
required MONGO_ARCHIVE_DATABASE
required MONGO_ARCHIVE_COLLECTION_1
required MONGO_ARCHIVE_DATE_FIELD_1
required MONGO_ARCHIVE_COLLECTION_2
required MONGO_ARCHIVE_DATE_FIELD_2
if [[ $mode == archive ]]; then
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
: "${MONGO_ARCHIVE_DELETE_AFTER_UPLOAD:=false}"
: "${MONGO_ARCHIVE_OLD_DATA_IMMUTABLE:=false}"
: "${MONGO_ARCHIVE_WRITES_PAUSED:=false}"

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
    MONGO_ARCHIVE_DELETE_AFTER_UPLOAD \
    MONGO_ARCHIVE_OLD_DATA_IMMUTABLE \
    MONGO_ARCHIVE_WRITES_PAUSED
do
    validate_bool_setting "$name"
done

[[ $MONGO_PORT =~ ^[1-9][0-9]*$ && $MONGO_PORT -le 65535 ]] \
    || die "MONGO_PORT tidak valid"
[[ $MONGO_ARCHIVE_DATABASE =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] \
    || die "MONGO_ARCHIVE_DATABASE tidak valid"
[[ $MONGO_ARCHIVE_COLLECTION_1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] \
    || die "MONGO_ARCHIVE_COLLECTION_1 tidak valid"
[[ $MONGO_ARCHIVE_COLLECTION_2 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] \
    || die "MONGO_ARCHIVE_COLLECTION_2 tidak valid"
[[ $MONGO_ARCHIVE_COLLECTION_1 != "$MONGO_ARCHIVE_COLLECTION_2" ]] \
    || die "Dua collection archive harus berbeda"
[[ $MONGO_ARCHIVE_DATE_FIELD_1 =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]] \
    || die "MONGO_ARCHIVE_DATE_FIELD_1 tidak valid"
[[ $MONGO_ARCHIVE_DATE_FIELD_2 =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]] \
    || die "MONGO_ARCHIVE_DATE_FIELD_2 tidak valid"
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

if [[ $mode == archive ]] \
   && ! mongorestore --help 2>&1 | grep -q -- '--dryRun'; then
    die "mongorestore harus mendukung --dryRun untuk validasi archive"
fi

collections=("$MONGO_ARCHIVE_COLLECTION_1" "$MONGO_ARCHIVE_COLLECTION_2")
date_fields=("$MONGO_ARCHIVE_DATE_FIELD_1" "$MONGO_ARCHIVE_DATE_FIELD_2")
current_year=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date +%Y)

if [[ $mode == archive ]] \
   && bool_value "$MONGO_ARCHIVE_DELETE_AFTER_UPLOAD"; then
    required MONGO_ARCHIVE_DELETE_USER
    required MONGO_ARCHIVE_DELETE_PASSWORD
    required MONGO_ARCHIVE_DELETE_CONFIRM

    expected_confirmation="DELETE ${MONGO_ARCHIVE_DATABASE}.${MONGO_ARCHIVE_COLLECTION_1},${MONGO_ARCHIVE_DATABASE}.${MONGO_ARCHIVE_COLLECTION_2}"
    [[ $MONGO_ARCHIVE_DELETE_CONFIRM == "$expected_confirmation" ]] \
        || die "MONGO_ARCHIVE_DELETE_CONFIRM harus persis: $expected_confirmation"

    if ! bool_value "$MONGO_ARCHIVE_OLD_DATA_IMMUTABLE" \
       && ! bool_value "$MONGO_ARCHIVE_WRITES_PAUSED"; then
        die "Untuk menghapus, set MONGO_ARCHIVE_OLD_DATA_IMMUTABLE=true atau hentikan write lalu set MONGO_ARCHIVE_WRITES_PAUSED=true"
    fi
elif [[ $mode == archive ]]; then
    log "Mode archive-only: data MongoDB tidak akan dihapus"
fi

safe_db=${MONGO_ARCHIVE_DATABASE//[^a-zA-Z0-9_.-]/_}
set_backup_name "mongodb-archive-${safe_db}"

if [[ $mode == check-years ]]; then
    secure_dir "$BACKUP_DIR"
    exec 9>"$BACKUP_DIR/.${ENGINE}-${BACKUP_NAME}.lock"
    flock -n 9 || die "Archive atau pemeriksaan tahun masih berjalan"
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    RUN_DIR=$(mktemp -d "$BACKUP_DIR/.${ENGINE}-${BACKUP_NAME}-${STAMP}.XXXXXX")
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    log "Pemeriksaan tahun MongoDB (read-only)"
else
    begin_backup
fi

host_arg="$MONGO_HOST:$MONGO_PORT"
if [[ -n $MONGO_REPLICA_SET ]]; then
    host_arg="$MONGO_REPLICA_SET/$host_arg"
fi

shell_connection=(--quiet --norc --host "$host_arg")
dump_connection=()
restore_connection=()

if [[ $mode == archive ]]; then
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
const e = process.env;
const auth = db.getSiblingDB(e.ARCHIVE_AUTH_DB);
try { auth.auth({user: e.ARCHIVE_USER, pwd: e.ARCHIVE_PASSWORD}); }
catch (error) { console.error(error.message); quit(18); }
const coll = db.getSiblingDB(e.ARCHIVE_DATABASE).getCollection(e.ARCHIVE_COLLECTION);
const field = e.ARCHIVE_DATE_FIELD;
const dateFilter = {[field]: {$gte: new Date(e.ARCHIVE_START), $lt: new Date(e.ARCHIVE_END)}};
const nonObjectIds = coll.countDocuments({$and: [dateFilter, {$expr: {$ne: [{$type: "$_id"}, "objectId"]}}]});
if (nonObjectIds !== 0) {
  console.error("NON_OBJECT_ID\t" + nonObjectIds);
  quit(42);
}
const docs = coll.find(dateFilter, {_id: 1}).sort({_id: -1}).limit(1).toArray();
if (docs.length === 0) {
  print("EMPTY");
  quit(0);
}
const maxId = docs[0]._id;
const exactFilter = {$and: [dateFilter, {_id: {$lte: maxId}}]};
const count = coll.countDocuments(exactFilter);
print("BOUNDARY\t" + maxId.toHexString() + "\t" + count);
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
const filter = {$and: [
  {[field]: {$gte: new Date(e.ARCHIVE_START), $lt: new Date(e.ARCHIVE_END)}},
  {_id: {$lte: maxId}}
]};
let total = 0;
while (true) {
  const ids = coll.find(filter, {_id: 1}).sort({_id: 1}).limit(batchSize).toArray().map(row => row._id);
  if (ids.length === 0) break;
  const result = coll.deleteMany({_id: {$in: ids}}, {writeConcern: {w: "majority", wtimeout: 60000}});
  total += result.deletedCount;
  if (result.deletedCount !== ids.length) {
    console.error("DELETE_BATCH_MISMATCH\t" + ids.length + "\t" + result.deletedCount);
    quit(43);
  }
}
const remaining = coll.countDocuments(filter);
print("DELETED\t" + total + "\t" + remaining);
if (remaining !== 0) quit(44);
JS

chmod 600 "$list_years_js" "$boundary_js" "$count_js" "$delete_js"

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

report_available_years() {
    local index
    local collection
    local date_field
    local output
    local year
    local oldest
    local overall_oldest=''
    local all_list
    local eligible_list
    local -a found_years=()
    local -a eligible_years=()

    printf 'Database: %s\n' "$MONGO_ARCHIVE_DATABASE"
    printf 'Timezone: %s\n' "$MONGO_ARCHIVE_TIMEZONE"
    printf 'Tahun berjalan yang dilindungi: %s\n\n' "$current_year"

    for index in "${!collections[@]}"; do
        collection=${collections[$index]}
        date_field=${date_fields[$index]}
        export ARCHIVE_COLLECTION=$collection
        export ARCHIVE_DATE_FIELD=$date_field

        output=$(run_mongosh_script "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$list_years_js") \
            || die "Gagal memeriksa tahun pada $collection"

        mapfile -t found_years < <(
            awk -F '\t' '$1 == "ARCHIVE_YEAR" && $2 ~ /^[0-9]{4}$/ {print $2}' \
                <<<"$output" | sort -nu
        )

        if (( ${#found_years[@]} == 0 )); then
            printf '%s (%s): tidak ada BSON Date\n\n' "$collection" "$date_field"
            continue
        fi

        oldest=${found_years[0]}
        if [[ -z $overall_oldest ]] || (( 10#$oldest < 10#$overall_oldest )); then
            overall_oldest=$oldest
        fi

        eligible_years=()
        for year in "${found_years[@]}"; do
            if (( 10#$year < 10#$current_year )); then
                eligible_years+=("$year")
            fi
        done

        all_list=$(IFS=,; printf '%s' "${found_years[*]}")
        if (( ${#eligible_years[@]} > 0 )); then
            eligible_list=$(IFS=,; printf '%s' "${eligible_years[*]}")
        else
            eligible_list='tidak ada'
        fi

        printf '%s (%s):\n' "$collection" "$date_field"
        printf '  Tahun paling tua : %s\n' "$oldest"
        printf '  Tahun tersedia   : %s\n' "$all_list"
        printf '  Boleh di-archive : %s\n\n' "$eligible_list"
    done

    if [[ -n $overall_oldest ]]; then
        printf 'Tahun paling tua dari kedua collection: %s\n' "$overall_oldest"
    else
        printf 'Tidak ditemukan data BSON Date pada kedua collection.\n'
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
    local artifact

    start_iso=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date --iso-8601=seconds -d "$range_start_local 00:00:00")
    end_iso=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date --iso-8601=seconds -d "$range_end_local 00:00:00")

    export ARCHIVE_COLLECTION=$collection
    export ARCHIVE_DATE_FIELD=$date_field
    export ARCHIVE_START=$start_iso
    export ARCHIVE_END=$end_iso

    boundary_output=$(run_mongosh_script "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$boundary_js") \
        || die "Gagal menentukan boundary $collection $range_label"

    if grep -qx 'EMPTY' <<<"$boundary_output"; then
        return 0
    fi

    boundary_line=$(awk -F '\t' '$1 == "BOUNDARY" {print; exit}' <<<"$boundary_output")
    [[ -n $boundary_line ]] || die "Boundary tidak valid untuk $collection $range_label"
    IFS=$'\t' read -r _ max_id expected_count <<<"$boundary_line"
    [[ $max_id =~ ^[0-9a-fA-F]{24}$ ]] || die "ObjectId boundary tidak valid"
    [[ $expected_count =~ ^[1-9][0-9]*$ ]] || die "Jumlah dokumen boundary tidak valid"

    check_free_space

    query_file="$RUN_DIR/query-${collection}-${range_label}.json"
    printf '{"$and":[{"%s":{"$gte":{"$date":"%s"},"$lt":{"$date":"%s"}}},{"_id":{"$lte":{"$oid":"%s"}}}]}\n' \
        "$date_field" "$start_iso" "$end_iso" "$max_id" >"$query_file"
    chmod 600 "$query_file"

    artifact="$RUN_DIR/${BACKUP_FILE_SERVER}-${safe_db}-${collection}-${range_label}-${STAMP}.archive.gz"

    log "Archive $collection $range_label ($expected_count dokumen)"
    run_backup mongodump \
        "${dump_connection[@]}" \
        --db="$MONGO_ARCHIVE_DATABASE" \
        --collection="$collection" \
        --queryFile="$query_file" \
        --gzip \
        --archive="$artifact"

    gzip -t "$artifact"
    run_backup mongorestore \
        "${restore_connection[@]}" \
        --archive="$artifact" \
        --gzip \
        --dryRun \
        --verbose \
        --nsInclude="${MONGO_ARCHIVE_DATABASE}.${collection}" \
        >/dev/null

    GCS_BACKUP_PATH="mongodb/archive/${safe_db}/${collection}/${year}"
    upload_backup "$artifact"

    if bool_value "$MONGO_ARCHIVE_DELETE_AFTER_UPLOAD"; then
        export ARCHIVE_MAX_ID=$max_id
        count_output=$(run_mongosh_script "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$count_js") \
            || die "Gagal memeriksa ulang jumlah dokumen $collection $range_label"
        current_count=$(awk -F '\t' '$1 == "ARCHIVE_COUNT" {print $2; exit}' <<<"$count_output")
        [[ $current_count =~ ^[0-9]+$ ]] || die "Hasil recount tidak valid"
        [[ $current_count == "$expected_count" ]] \
            || die "Jumlah dokumen berubah setelah backup ($expected_count menjadi $current_count); data tidak dihapus"

        delete_output=$(run_mongosh_script \
            "$MONGO_ARCHIVE_DELETE_USER" \
            "$MONGO_ARCHIVE_DELETE_PASSWORD" \
            "${MONGO_ARCHIVE_DELETE_AUTH_DB:-$MONGO_AUTH_DB}" \
            "$delete_js") || die "Penghapusan gagal untuk $collection $range_label; backup GCS tetap aman"

        IFS=$'\t' read -r _ deleted_count remaining_count \
            <<<"$(awk -F '\t' '$1 == "DELETED" {print; exit}' <<<"$delete_output")"
        [[ $deleted_count == "$expected_count" && $remaining_count == 0 ]] \
            || die "Verifikasi penghapusan gagal untuk $collection $range_label"

        log "Terhapus aman: $collection $range_label ($deleted_count dokumen)"
    else
        log "Archive terverifikasi; delete nonaktif untuk $collection $range_label"
    fi

    rm -f -- "$artifact" "$artifact.sha256" "$query_file"
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
            process_range "$collection" "$date_field" "$year" \
                "$year-01-01" "$next_year-01-01" "$year"
            ;;

        month)
            for month in {01..12}; do
                start_local="$year-$month-01"
                end_local=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date -d "$start_local +1 month" +%F)
                process_range "$collection" "$date_field" "$year" \
                    "$start_local" "$end_local" "$year-$month"
            done
            ;;

        day)
            cursor="$year-01-01"
            while [[ $cursor < "$next_year-01-01" ]]; do
                next_day=$(TZ="$MONGO_ARCHIVE_TIMEZONE" date -d "$cursor +1 day" +%F)
                process_range "$collection" "$date_field" "$year" \
                    "$cursor" "$next_day" "$cursor"
                cursor=$next_day
            done
            ;;
    esac
}

explicit_years=()
if [[ $MONGO_ARCHIVE_YEARS != auto ]]; then
    IFS=',' read -r -a requested_years <<<"$MONGO_ARCHIVE_YEARS"
    for year in "${requested_years[@]}"; do
        year="${year#"${year%%[![:space:]]*}"}"
        year="${year%"${year##*[![:space:]]}"}"
        [[ $year =~ ^[0-9]{4}$ ]] || die "Tahun archive tidak valid: $year"
        (( 10#$year < 10#$current_year )) \
            || die "Tahun $year dilindungi; hanya tahun sebelum $current_year yang boleh diproses"
        explicit_years+=("$year")
    done
    mapfile -t explicit_years < <(printf '%s\n' "${explicit_years[@]}" | sort -nu)
    (( ${#explicit_years[@]} > 0 )) || die "MONGO_ARCHIVE_YEARS kosong"
fi

for index in "${!collections[@]}"; do
    collection=${collections[$index]}
    date_field=${date_fields[$index]}

    if [[ $MONGO_ARCHIVE_YEARS == auto ]]; then
        export ARCHIVE_COLLECTION=$collection
        export ARCHIVE_DATE_FIELD=$date_field
        years_output=$(run_mongosh_script "$MONGO_USER" "$MONGO_PASSWORD" "$MONGO_AUTH_DB" "$list_years_js") \
            || die "Gagal mencari tahun pada $collection"
        mapfile -t years < <(
            awk -F '\t' -v current="$current_year" \
                '$1 == "ARCHIVE_YEAR" && $2 ~ /^[0-9]{4}$/ && $2 < current {print $2}' \
                <<<"$years_output" | sort -nu
        )
    else
        years=("${explicit_years[@]}")
    fi

    if (( ${#years[@]} == 0 )); then
        log "Tidak ada tahun lama untuk collection $collection"
        continue
    fi

    for year in "${years[@]}"; do
        log "Proses $collection tahun $year"
        process_year "$collection" "$date_field" "$year"
    done
done

log "Archive MongoDB selesai; tahun $current_year tetap dipertahankan"
