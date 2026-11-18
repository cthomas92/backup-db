#!/usr/bin/env bash
# Restore interaktif hasil archive-purge-mongodb.sh (GCS / file lokal).
# Tidak melakukan delete, --drop, atau mengubah script archive sumber.
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${1:-"$SCRIPT_DIR/.env"}

usage() {
  cat <<'HELP'
Cara pakai:
  ./restore-mongodb-archive.sh [path-ke-.env]

Script membaca GCS_URI, MONGO_ARCHIVE_DATABASE, MONGO_ARCHIVE_COLLECTIONS,
MONGO_HOST/PORT/USER/PASSWORD/AUTH_DB, TLS, dan GCP_SERVICE_ACCOUNT_FILE
langsung dari .env script archive. Pilih sumber GCS atau folder lokal.

Default restore: database BARU (contoh: equipment_restore_20261118T001500Z).
Tidak pernah memakai --drop. Mendukung download/validasi tanpa restore.
HELP
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
if (( $# > 1 )); then usage >&2; exit 2; fi

error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || error "Command '$1' belum tersedia"; }
need mongorestore
need mongosh
need gzip
need sha256sum
need find
need sort
need date
need mktemp
need flock

[[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || error "File konfigurasi tidak bisa dibaca: $CONFIG_FILE"
# .env adalah konfigurasi Bash tepercaya yang memang di-source script archive asal.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${MONGO_ARCHIVE_DATABASE:?MONGO_ARCHIVE_DATABASE harus diisi di .env}"
: "${MONGO_USER:?MONGO_USER harus diisi di .env}"
: "${MONGO_PASSWORD:?MONGO_PASSWORD harus diisi di .env}"
: "${MONGO_HOST:=127.0.0.1}"
: "${MONGO_PORT:=27017}"
: "${MONGO_AUTH_DB:=admin}"
: "${MONGO_REPLICA_SET:=}"
: "${MONGO_TLS:=false}"
: "${MONGO_TLS_CA_FILE:=}"
: "${NOTIFY_TIMEZONE:=Asia/Makassar}"

[[ "$MONGO_ARCHIVE_DATABASE" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || error 'Nama database sumber tidak valid'
[[ "$MONGO_PORT" =~ ^[0-9]+$ ]] || error 'MONGO_PORT tidak valid'
[[ "$NOTIFY_TIMEZONE" =~ ^[a-zA-Z0-9_+.-]+(/[a-zA-Z0-9_+.-]+)*$ && -e "/usr/share/zoneinfo/$NOTIFY_TIMEZONE" ]] || error 'NOTIFY_TIMEZONE tidak valid'
[[ "$MONGO_TLS" == true || "$MONGO_TLS" == false ]] || error 'MONGO_TLS harus true/false'

collection_names=()
if declare -p MONGO_ARCHIVE_COLLECTIONS 2>/dev/null | grep -q '^declare -a '; then
  for spec in "${MONGO_ARCHIVE_COLLECTIONS[@]}"; do
    coll=${spec%%:*}
    [[ "$spec" == *:* && "$coll" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || error "Collection spec tidak valid: $spec"
    collection_names+=("$coll")
  done
elif [[ -n ${MONGO_ARCHIVE_COLLECTION_1:-} ]]; then
  collection_names+=("$MONGO_ARCHIVE_COLLECTION_1")
  [[ -z ${MONGO_ARCHIVE_COLLECTION_2:-} ]] || collection_names+=("$MONGO_ARCHIVE_COLLECTION_2")
else
  error 'MONGO_ARCHIVE_COLLECTIONS harus ada di .env'
fi
(( ${#collection_names[@]} > 0 )) || error 'Daftar collection kosong'

DOWNLOAD_DIR=${MONGO_RESTORE_DOWNLOAD_DIR:-"$SCRIPT_DIR/restore-downloads"}
mkdir -p -m 700 -- "$DOWNLOAD_DIR"
[[ -w "$DOWNLOAD_DIR" ]] || error "Folder download tidak writable: $DOWNLOAD_DIR"
WORK_DIR=$(mktemp -d "$DOWNLOAD_DIR/.restore-working.XXXXXXXX")
chmod 700 "$WORK_DIR"
CLOUDSDK_CONFIG_TEMP=''
cleanup() {
  rm -rf -- "$WORK_DIR"
  if [[ -n $CLOUDSDK_CONFIG_TEMP ]]; then rm -rf -- "$CLOUDSDK_CONFIG_TEMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
exec 9>"$DOWNLOAD_DIR/.mongodb-restore.lock"
flock -n 9 || error 'Ada proses restore lain sedang berjalan pada folder ini'

# Jawaban menu disimpan pada SELECTED, jangan panggil fungsi ini via $(...) .
choose() {
  local title=$1; shift
  local -a options=("$@")
  local n i
  (( ${#options[@]} > 0 )) || error "Tidak ada opsi untuk $title"
  printf '\n%s\n' "$title"
  for i in "${!options[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${options[$i]}"; done
  while :; do
    read -r -p 'Pilih nomor: ' n || error 'Input dibatalkan'
    if [[ $n =~ ^[0-9]+$ ]] && (( 10#$n >= 1 && 10#$n <= ${#options[@]} )); then
      SELECTED=$((10#$n - 1))
      return
    fi
    note 'Nomor tidak valid.'
  done
}

printf '\n=== RESTORE MONGODB ARCHIVE ===\nDatabase asal : %s\nTimezone      : %s\n' "$MONGO_ARCHIVE_DATABASE" "$NOTIFY_TIMEZONE"
choose 'Sumber backup:' 'GCS (lihat daftar & download sesuai pilihan)' 'Lokal (backup sudah di-download)'
source_mode=$SELECTED

index_file="$WORK_DIR/archive-index.txt"
if (( source_mode == 0 )); then
  need gcloud
  : "${GCS_URI:?GCS_URI belum diisi di .env}"
  base="${GCS_URI%/}/mongodb/archive/$MONGO_ARCHIVE_DATABASE"
  [[ "$base" == gs://* ]] || error 'GCS_URI harus dimulai gs://'
  if [[ -n ${GCP_SERVICE_ACCOUNT_FILE:-} ]]; then
    [[ -f "$GCP_SERVICE_ACCOUNT_FILE" && -r "$GCP_SERVICE_ACCOUNT_FILE" ]] || error "Service account JSON tidak dapat dibaca: $GCP_SERVICE_ACCOUNT_FILE"
    CLOUDSDK_CONFIG_TEMP=$(mktemp -d "$WORK_DIR/.gcloud-config.XXXXXXXX")
    chmod 700 "$CLOUDSDK_CONFIG_TEMP"
    export CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG_TEMP"
    note 'Mengaktifkan service account pada konfigurasi gcloud sementara...'
    gcloud --quiet auth activate-service-account --key-file="$GCP_SERVICE_ACCOUNT_FILE" >/dev/null
  fi
  note "Membaca daftar objek yang sudah ada: $base/"
  gcloud storage ls --recursive "$base/" >"$index_file" || error 'Gagal list GCS. Periksa URI dan IAM Storage Object Viewer.'
else
  read -r -p "Folder lokal [$DOWNLOAD_DIR]: " requested_folder || error 'Input dibatalkan'
  local_dir=${requested_folder:-$DOWNLOAD_DIR}
  [[ -d "$local_dir" && -r "$local_dir" ]] || error "Folder lokal tidak ditemukan: $local_dir"
  # Backup dari script asal memiliki suffix .archive.gz .
  find "$local_dir" -type f -name '*.archive.gz' -print >"$index_file"
fi

# Parse HANYA nama sesuai pola script archive dan collection di .env.
# Metadata: arrays by index. Tidak mengunduh file saat listing.
archive_paths=()
archive_collections=()
archive_periods=()
archive_stamps=()
archive_days=()
while IFS= read -r path; do
  [[ $path == *.archive.gz ]] || continue
  filename=${path##*/}
  for coll in "${collection_names[@]}"; do
    marker="-${MONGO_ARCHIVE_DATABASE}-${coll}-period-"
    [[ $filename == *"$marker"* ]] || continue
    suffix=${filename##*"$marker"}
    if [[ $suffix =~ ^([0-9]{4}(-[0-9]{2}){0,2})-backup-([0-9]{8}T[0-9]{6}Z)\.archive\.gz$ ]]; then
      period=${BASH_REMATCH[1]}
      stamp=${BASH_REMATCH[3]}
      yyyy=${period:0:4}
      # Periksa periode kalender. Reject nama file dengan bulan/hari tidak valid.
      case ${#period} in
        4) date -u -d "$period-01-01" +%F >/dev/null 2>&1 || continue ;;
        7) date -u -d "$period-01" +%F >/dev/null 2>&1 || continue
           [[ $(date -u -d "$period-01" +%Y-%m) == "$period" ]] || continue ;;
        10) date -u -d "$period" +%F >/dev/null 2>&1 || continue
            [[ $(date -u -d "$period" +%F) == "$period" ]] || continue ;;
        *) continue ;;
      esac
      # File GCS harus berada di path database/collection/tahun yang cocok.
      if (( source_mode == 0 )); then
        [[ ${path%/*} == "$base/$coll/$yyyy" ]] || continue
      fi
      utc_datetime="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2} UTC"
      epoch=$(date -u -d "$utc_datetime" +%s 2>/dev/null) || continue
      day=$(TZ="$NOTIFY_TIMEZONE" date -d "@$epoch" +%F)
      archive_paths+=("$path")
      archive_collections+=("$coll")
      archive_periods+=("$period")
      archive_stamps+=("$stamp")
      archive_days+=("$day")
      break
    fi
  done
done <"$index_file"

(( ${#archive_paths[@]} > 0 )) || error 'Tidak ada backup yang cocok dengan database/collection di .env dan pola filename archive.'
printf '\nDitemukan %s file archive (metadata), tanpa download isi backup.\n' "${#archive_paths[@]}"

# Hanya tampilkan collection/tahun/bulan/tanggal yang betul-betul tersedia.
available_collections=()
for coll in "${collection_names[@]}"; do
  for i in "${!archive_paths[@]}"; do
    if [[ ${archive_collections[$i]} == "$coll" ]]; then
      available_collections+=("$coll")
      break
    fi
  done
done
choose 'Collection yang mau di-restore:' "${available_collections[@]}"
selected_collection=${available_collections[$SELECTED]}

mapfile -t years < <(
  for i in "${!archive_paths[@]}"; do
    if [[ ${archive_collections[$i]} == "$selected_collection" ]]; then
      printf '%s\n' "${archive_periods[$i]:0:4}"
    fi
  done | sort -u
)
choose 'Pilih TAHUN DATA (bukan tanggal backup):' "${years[@]}"
selected_year=${years[$SELECTED]}

month_choices=("Seluruh data tahun $selected_year (file yang tersedia)")
mapfile -t months < <(
  for i in "${!archive_paths[@]}"; do
    if [[ ${archive_collections[$i]} == "$selected_collection" && ${archive_periods[$i]:0:4} == "$selected_year" && ${#archive_periods[$i]} -ge 7 ]]; then
      printf '%s\n' "${archive_periods[$i]:5:2}"
    fi
  done | sort -u
)
for month in "${months[@]}"; do month_choices+=("Bulan $selected_year-$month"); done
choose 'Pilih PERIODE DATA:' "${month_choices[@]}"
selected_month=''
if (( SELECTED > 0 )); then selected_month=${months[$((SELECTED - 1))]}; fi

eligible=()
for i in "${!archive_paths[@]}"; do
  [[ ${archive_collections[$i]} == "$selected_collection" ]] || continue
  [[ ${archive_periods[$i]:0:4} == "$selected_year" ]] || continue
  if [[ -n "$selected_month" ]]; then
    # Archive tahunan tidak boleh dipakai memulihkan hanya satu bulan.
    [[ ${#archive_periods[$i]} -ge 7 && ${archive_periods[$i]:5:2} == "$selected_month" ]] || continue
  fi
  eligible+=("$i")
done
(( ${#eligible[@]} > 0 )) || error 'Periode tidak punya archive.'

mapfile -t backup_dates < <(
  for i in "${eligible[@]}"; do printf '%s\n' "${archive_days[$i]}"; done | sort -ur
)
date_choices=('Terbaru per periode (tidak dibatasi tanggal backup)')
for d in "${backup_dates[@]}"; do date_choices+=("Backup tanggal $d ($NOTIFY_TIMEZONE)"); done
choose 'Pilih TANGGAL BACKUP yang tersedia:' "${date_choices[@]}"
selected_backup_date=''
if (( SELECTED > 0 )); then selected_backup_date=${backup_dates[$((SELECTED-1))]}; fi

# Pilih snapshot TERBARU untuk setiap data period. Jangan gabungkan
# backup ulang dari periode sama, karena dapat menimbulkan duplicate _id.
declare -A best_by_period=()
for i in "${eligible[@]}"; do
  if [[ -n "$selected_backup_date" && ${archive_days[$i]} != "$selected_backup_date" ]]; then continue; fi
  period=${archive_periods[$i]}
  if [[ -z ${best_by_period[$period]+x} ]] || [[ ${archive_stamps[$i]} > ${archive_stamps[${best_by_period[$period]}]} ]]; then
    best_by_period[$period]=$i
  fi
done
(( ${#best_by_period[@]} > 0 )) || error 'Tidak ada file sesuai tanggal backup yang dipilih.'
mapfile -t selected_periods < <(printf '%s\n' "${!best_by_period[@]}" | sort)
selected_archive_ids=()
for period in "${selected_periods[@]}"; do selected_archive_ids+=("${best_by_period[$period]}"); done

# Cegah overlap archive year/month/day di collection yang sama (mis. 2021
# bersamaan dengan 2021-01), karena dapat menghasilkan insert ganda.
previous_end=''
for period in "${selected_periods[@]}"; do
  case ${#period} in
    4) p_start="$period-01-01"; p_end="$((10#$period+1))-01-01" ;;
    7) p_start="$period-01"; p_end=$(date -u -d "$p_start +1 month" +%F) ;;
    10) p_start="$period"; p_end=$(date -u -d "$p_start +1 day" +%F) ;;
  esac
  if [[ -n "$previous_end" && "$p_start" < "$previous_end" ]]; then
    error "Periode backup saling overlap ($period). Pilih periode/tanggal backup lain; jangan restore archive tahunan dan bulanan bersamaan."
  fi
  previous_end=$p_end
done

printf '\n=== RENCANA PEMULIHAN ===\n'
printf 'Source database : %s\nCollection      : %s\nTahun data      : %s\nBulan data      : %s\nTanggal backup  : %s\n' \
  "$MONGO_ARCHIVE_DATABASE" "$selected_collection" "$selected_year" "${selected_month:-semua yang tersedia}" "${selected_backup_date:-terbaru per periode}"
printf 'Jumlah archive  : %s\n' "${#selected_archive_ids[@]}"
for i in "${selected_archive_ids[@]}"; do
  printf '  - data=%-10s  dibuat=%s %s  file=%s\n' \
    "${archive_periods[$i]}" "${archive_days[$i]}" "$NOTIFY_TIMEZONE" "${archive_paths[$i]##*/}"
done
note 'CATATAN: Bulan/hari tanpa file tidak ikut dipulihkan (bisa memang kosong pada saat backup).'

choose 'Aksi:' 'Download (jika GCS), validasi, lalu RESTORE MongoDB' 'Hanya download dan validasi (TANPA restore)'
action=$SELECTED

target_db=''
if (( action == 0 )); then
  default_target="${MONGO_ARCHIVE_DATABASE}_restore_$(date -u +%Y%m%dT%H%M%SZ)"
  read -r -p "Target database MongoDB [$default_target]: " target_db || error 'Input dibatalkan'
  target_db=${target_db:-$default_target}
  [[ "$target_db" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || error 'Target DB hanya boleh mengandung huruf, angka, underscore, dan strip (diawali huruf/underscore).'
fi

printf '\nFolder download/validasi: %s\n' "$DOWNLOAD_DIR"
read -r -p 'Ketik LANJUT untuk memproses pilihan: ' confirmation || error 'Input dibatalkan'
[[ $confirmation == LANJUT ]] || error 'Dibatalkan, belum ada data yang diubah.'

# Credential mongorestore hanya ada dalam file mode 600, bukan argument --password.
# Escape ke string YAML double-quoted. Reject control characters yang ambigu.
[[ "$MONGO_PASSWORD" != *$'\n'* && "$MONGO_PASSWORD" != *$'\r'* ]] || error 'Password yang mengandung newline/CR tidak didukung.'
escaped_password=${MONGO_PASSWORD//\\/\\\\}
escaped_password=${escaped_password//\"/\\\"}
config_mongo="$WORK_DIR/mongodb-restore.yml"
printf 'password: "%s"\n' "$escaped_password" >"$config_mongo"
chmod 600 "$config_mongo"

mongo_host="$MONGO_HOST:$MONGO_PORT"
[[ -z "$MONGO_REPLICA_SET" ]] || mongo_host="$MONGO_REPLICA_SET/$mongo_host"
mongo_restore_args=(--config="$config_mongo" --host="$mongo_host" --username="$MONGO_USER" --authenticationDatabase="$MONGO_AUTH_DB")
mongo_shell_args=(--quiet --norc --host "$mongo_host")
if [[ $MONGO_TLS == true ]]; then
  mongo_restore_args+=(--ssl)
  mongo_shell_args+=(--tls)
fi
if [[ -n "$MONGO_TLS_CA_FILE" ]]; then
  [[ -f "$MONGO_TLS_CA_FILE" ]] || error 'MONGO_TLS_CA_FILE tidak ditemukan'
  mongo_restore_args+=(--sslCAFile="$MONGO_TLS_CA_FILE")
  mongo_shell_args+=(--tlsCAFile="$MONGO_TLS_CA_FILE")
fi

if (( action == 0 )); then
  check_js="$WORK_DIR/check-target.js"
  cat >"$check_js" <<'JS'
const e = process.env;
try {
  const auth = db.getSiblingDB(e.RESTORE_AUTH_DB);
  const valid = auth.auth({user: e.RESTORE_USER, pwd: e.RESTORE_PASSWORD});
  if (!valid) throw new Error('Autentikasi MongoDB gagal');
  const cols = db.getSiblingDB(e.RESTORE_TARGET).getCollectionNames();
  print('EXISTING_COLLECTIONS\t' + cols.join(','));
  print('HAS_SELECTED_COLLECTION\t' + (cols.includes(e.RESTORE_COLLECTION) ? 'yes' : 'no'));
} catch (err) { console.error(err.message); quit(18); }
JS
  note "Memeriksa target MongoDB: $target_db ..."
  target_result=$(RESTORE_AUTH_DB="$MONGO_AUTH_DB" RESTORE_USER="$MONGO_USER" \
    RESTORE_PASSWORD="$MONGO_PASSWORD" RESTORE_TARGET="$target_db" RESTORE_COLLECTION="$selected_collection" \
    mongosh "${mongo_shell_args[@]}" --file="$check_js") || error 'Tidak bisa mengecek target MongoDB. Tidak melanjutkan.'
  selected_exists=$(printf '%s\n' "$target_result" | awk -F '\t' '$1 == "HAS_SELECTED_COLLECTION" {print $2}')
  [[ $selected_exists == yes || $selected_exists == no ]] || error 'Pemeriksaan collection target gagal'
  if [[ $target_db == "$MONGO_ARCHIVE_DATABASE" || $selected_exists == yes ]]; then
    printf '\nPERINGATAN: Target %s.%s sudah ada atau merupakan DB sumber!\n' "$target_db" "$selected_collection"
    note 'Tidak ada --drop. Tetapi duplicate _id dapat menggagalkan restore dan proses mungkin berhenti setelah sebagian data masuk.'
    read -r -p "Ketik tepat 'RESTORE $target_db.$selected_collection' untuk mengizinkan insert: " dangerous_confirm || error 'Input dibatalkan'
    [[ $dangerous_confirm == "RESTORE $target_db.$selected_collection" ]] || error 'Konfirmasi target existing gagal; batal.'
  fi
fi

# Download GCS jika belum ada. Checksum sidecar opsional; gzip test wajib.
# Backup lokal harus sudah ada, tidak ada aktivitas GCS sama sekali.
restored=0
validated=0
for i in "${selected_archive_ids[@]}"; do
  source_path=${archive_paths[$i]}
  filename=${source_path##*/}
  if (( source_mode == 0 )); then
    dest="$DOWNLOAD_DIR/$filename"
    if [[ -f "$dest" ]]; then
      note "Menggunakan file yang sudah di-download: $filename"
    else
      note "DOWNLOAD: $filename"
      temp_dest="$WORK_DIR/$filename"
      gcloud --quiet storage cp "$source_path" "$temp_dest" || error "Download gagal: $source_path"
      [[ -s "$temp_dest" ]] || error "File hasil download kosong: $filename"
      mv -n -- "$temp_dest" "$dest"
    fi
    if grep -Fxq -- "${source_path}.sha256" "$index_file"; then
      if [[ ! -f "${dest}.sha256" ]]; then
        gcloud --quiet storage cp "${source_path}.sha256" "${dest}.sha256" || error 'Checksum GCS gagal di-download'
      fi
    fi
  else
    dest=$source_path
  fi
  [[ -f "$dest" && -s "$dest" && ! -L "$dest" ]] || error "File backup tidak valid: $dest"
  if [[ -f "${dest}.sha256" ]]; then
    expected_hash=$(head -n1 "${dest}.sha256" | awk '{print $1}')
    [[ $expected_hash =~ ^[[:xdigit:]]{64}$ ]] || error "Format SHA256 tidak dikenali: ${dest}.sha256"
    actual_hash=$(sha256sum "$dest" | awk '{print $1}')
    [[ ${actual_hash,,} == "${expected_hash,,}" ]] || error "CHECKSUM TIDAK COCOK: $filename"
    note "SHA256: OK $filename"
  else
    note "INFO: tidak ada sidecar .sha256 untuk $filename; validasi gzip dan mongorestore tetap dilakukan."
  fi
  note "GZIP TEST: $filename"
  gzip -t -- "$dest" || error "Archive GZIP rusak: $filename"
  note "MONGORESTORE DRY RUN: $filename"
  mongorestore "${mongo_restore_args[@]}" --archive="$dest" --gzip \
    --dryRun --nsInclude="${MONGO_ARCHIVE_DATABASE}.${selected_collection}" \
    --nsFrom="${MONGO_ARCHIVE_DATABASE}.${selected_collection}" \
    --nsTo="${target_db:-${MONGO_ARCHIVE_DATABASE}_restore_preview}.${selected_collection}" \
    >/dev/null || error "Dry-run mongorestore gagal: $filename"
  ((validated+=1))

  if (( action == 0 )); then
    note "RESTORE: ${archive_periods[$i]} -> $target_db.$selected_collection"
    mongorestore "${mongo_restore_args[@]}" --archive="$dest" --gzip \
      --nsInclude="${MONGO_ARCHIVE_DATABASE}.${selected_collection}" \
      --nsFrom="${MONGO_ARCHIVE_DATABASE}.${selected_collection}" \
      --nsTo="${target_db}.${selected_collection}" \
      --stopOnError || error "Restore gagal pada ${archive_periods[$i]}. Sebagian data mungkin sudah masuk ke target; jangan mengulang tanpa pengecekan."
    ((restored+=1))
  fi
done

printf '\n=== SELESAI ===\nFile tervalidasi : %d\nPeriode restore : %d\n' "$validated" "$restored"
if (( action == 0 )); then
  printf 'Tujuan           : %s.%s\n' "$target_db" "$selected_collection"
else
  printf 'Mode             : Hanya download + validasi (MongoDB tidak diubah)\n'
fi
printf 'Simpan lokal     : %s\n' "$DOWNLOAD_DIR"