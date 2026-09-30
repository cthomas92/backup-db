# Auto Backup Database ke Google Cloud Storage

Versi ini dibuat supaya konfigurasi sesederhana mungkin: **semua script memakai satu `.env`**.
Tidak perlu membuat file `.conf`, `.cnf`, `.pgpass`, atau file credential database secara manual.
File credential sementara dibuat otomatis dengan permission `600`, lalu dihapus setelah proses selesai.

Backup yang tersedia:

| Script | Fungsi | Hasil |
| --- | --- | --- |
| `backup-mongodb.sh` | MongoDB: semua DB, satu DB, atau satu collection | `.archive.gz` |
| `backup-mariadb.sh` | MariaDB logical: satu / beberapa DB | `.sql.gz` |
| `backup-mariadb-physical.sh` | MariaDB physical: seluruh instance | `.xbstream.zst` |
| `backup-postgresql.sh` | PostgreSQL: satu DB | `.dump` |
| `backup-all.sh` | Menjalankan semua backup yang diaktifkan di `.env` | sesuai script |

Setelah backup selesai, script otomatis:

1. memvalidasi file hasil backup;
2. membuat SHA-256;
3. upload file + `.sha256` ke GCS;
4. memverifikasi size dan MD5 object di GCS;
5. retry upload GCS bila terjadi kegagalan sementara;
6. menghapus staging lokal bila sukses;
7. mempertahankan staging lokal bila gagal agar bisa diperiksa;
8. menyimpan log;
9. mengirim ringkasan ke Discord/Telegram bila diaktifkan.

## 1. Setup cepat

Clone/copy folder ini, misalnya ke `/opt/auto-backup`:

```bash
sudo install -d -m 700 /opt/auto-backup
sudo cp -a . /opt/auto-backup/
cd /opt/auto-backup
sudo cp .env.example .env
sudo chmod 600 .env
sudo mkdir -p backups
sudo chmod 700 backups
```

Edit hanya `.env`:

```bash
sudo nano /opt/auto-backup/.env
```

Minimal isi:

```bash
GCS_URI='gs://nama-bucket/database-backups'

MONGO_USER='backup_user'
MONGO_PASSWORD='password'
MONGO_DATABASE='nama_db'
MONGO_COLLECTION=''

MARIADB_USER='backup_user'
MARIADB_PASSWORD='password'
MARIADB_DATABASES='nama_db'

POSTGRES_USER='backup_user'
POSTGRES_PASSWORD='password'
POSTGRES_DATABASE='nama_db'
```

Untuk physical MariaDB, backup selalu **seluruh instance**, bukan satu database:

```bash
MARIADB_PHYSICAL_USER='mariabackup'
MARIADB_PHYSICAL_PASSWORD='password'
BACKUP_MARIADB_PHYSICAL=true
```

Jika `MARIADB_PHYSICAL_USER/PASSWORD` dikosongkan, script memakai `MARIADB_USER/PASSWORD`.
Pastikan user tersebut memang memiliki privilege yang dibutuhkan `mariadb-backup`.

## 2. Pilih backup yang aktif

Di `.env`:

```bash
BACKUP_MONGODB=true
BACKUP_MARIADB=true
BACKUP_MARIADB_PHYSICAL=false
BACKUP_POSTGRESQL=true
```

Lalu satu perintah menjalankan semuanya:

```bash
cd /opt/auto-backup
sudo ./backup-all.sh
```

Atau jalankan satu engine saja:

```bash
sudo ./backup-mongodb.sh
sudo ./backup-mariadb.sh
sudo ./backup-mariadb-physical.sh
sudo ./backup-postgresql.sh
```

Semua script otomatis membaca `/opt/auto-backup/.env`. Path `.env` lain juga boleh:

```bash
sudo ./backup-postgresql.sh /etc/backup-prod.env
```

## 3. GCS authentication

### Opsi A — VM/service account sudah terpasang

Biarkan:

```bash
GCP_SERVICE_ACCOUNT_FILE=''
```

Tes:

```bash
gcloud storage ls gs://NAMA_BUCKET
```

### Opsi B — JSON service account

Taruh file JSON secara private:

```bash
sudo install -m 600 key.json /opt/auto-backup/service-account.json
```

Isi `.env`:

```bash
GCP_SERVICE_ACCOUNT_FILE="$SCRIPT_DIR/service-account.json"
```

Script akan menjalankan `gcloud auth activate-service-account` otomatis sebelum upload.
Jangan commit `.env` atau `service-account.json`.

## 4. MongoDB

Contoh satu database:

```bash
MONGO_HOST='127.0.0.1'
MONGO_PORT=27017
MONGO_USER='backup_user'
MONGO_PASSWORD='password'
MONGO_AUTH_DB='admin'
MONGO_DATABASE='equipment'
MONGO_COLLECTION=''
```

Satu collection:

```bash
MONGO_DATABASE='equipment'
MONGO_COLLECTION='live_locations'
```

Semua database:

```bash
MONGO_DATABASE=''
MONGO_COLLECTION=''
```

Untuk replica set:

```bash
MONGO_REPLICA_SET='rs0'
```

Jika `MONGO_REPLICA_SET` diisi dan `MONGO_DATABASE`/`MONGO_COLLECTION` dikosongkan, script otomatis menambahkan `--oplog` sehingga full dump replica set dapat direstore dengan `--oplogReplay`. Opsi ini memang tidak boleh digabung dengan `--db` atau `--collection`.

Password MongoDB tidak dikirim lewat argument process. Script membuat file YAML sementara untuk `mongodump --config`, sesuai mekanisme yang direkomendasikan MongoDB Database Tools.

> Catatan konsistensi: `mongodump` dapat membackup seluruh server, database, atau collection. Backup scoped ke satu DB/collection tidak menggunakan `--oplog`. Hindari migration/DDL dan write penting selama backup bila Anda membutuhkan snapshot lintas collection yang benar-benar seragam.

## 5. MariaDB logical

Satu database:

```bash
MARIADB_DATABASES='app_database'
```

Beberapa database:

```bash
MARIADB_DATABASES='app_database,billing_database'
```

Untuk server lokal gunakan socket:

```bash
MARIADB_SOCKET='/run/mysqld/mysqld.sock'
```

Untuk TCP:

```bash
MARIADB_SOCKET=''
MARIADB_HOST='10.10.10.10'
MARIADB_PORT=3306
```

Jika memakai TLS:

```bash
MARIADB_SSL_CA='/etc/ssl/certs/mariadb-ca.pem'
```

Logical backup memakai `--single-transaction`. Secara default `MARIADB_SKIP_OBJECT_ERRORS=true`, sehingga `mariadb-dump --force` akan melanjutkan ke object berikutnya bila satu table/view/object bermasalah. Error tetap dicatat di `LOG_DIR/mariadb-dump-TIMESTAMP.log` dan hasil `backup-all.sh` menjadi `WARNING`, bukan menghentikan seluruh backup.

Contoh:

```bash
MARIADB_SKIP_OBJECT_ERRORS=true
```

Error fatal seperti gagal login, tidak dapat terhubung, koneksi putus, timeout, atau masalah storage tetap dianggap `FAILED`; error tersebut tidak disamarkan sebagai skip karena dapat menghasilkan backup parsial. Bila ada tabel non-InnoDB, backup tetap berjalan namun dicatat sebagai warning karena `--single-transaction` tidak menjamin konsistensi tabel non-InnoDB.

## 6. MariaDB physical

Physical backup memakai `mariadb-backup` / `mariabackup`, `xbstream`, dan `zstd`.
Backup ini selalu mencakup seluruh instance MariaDB termasuk system tables/user/grant yang berada di datadir.

Contoh:

```bash
MARIADB_PHYSICAL_USER='mariabackup'
MARIADB_PHYSICAL_PASSWORD='password'
MARIADB_PHYSICAL_SOCKET='/run/mysqld/mysqld.sock'
MARIABACKUP_PARALLEL=1
ZSTD_LEVEL=3
ZSTD_THREADS=1
```

Contoh privilege user physical (sesuaikan dengan versi MariaDB Anda):

```sql
CREATE USER 'mariabackup'@'localhost' IDENTIFIED BY 'PASSWORD_KUAT';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'mariabackup'@'localhost';
```

Gunakan versi `mariadb-backup` yang kompatibel dengan server MariaDB.

## 7. PostgreSQL

Contoh lokal via Unix socket:

```bash
POSTGRES_HOST='/var/run/postgresql'
POSTGRES_PORT=5432
POSTGRES_USER='backup_user'
POSTGRES_PASSWORD='password'
POSTGRES_DATABASE='app_database'
```

Untuk remote:

```bash
POSTGRES_HOST='postgres.example.com'
POSTGRES_SSLMODE='verify-full'
POSTGRES_SSLROOTCERT='/etc/ssl/certs/postgres-ca.pem'
```

Satu eksekusi PostgreSQL menghasilkan satu custom-format dump. Untuk database kedua, gunakan file `.env` kedua atau jadwal kedua dengan nilai `POSTGRES_DATABASE` berbeda.

## 8. Cron otomatis

Contoh paling sederhana sudah ada di `cron/db-backup.crontab.example`:

```cron
0 2 * * * /opt/auto-backup/backup-all.sh >>/var/log/auto-backup.log 2>&1
```

Pasang sebagai root bila physical MariaDB juga dijalankan dan membutuhkan akses host-level:

```bash
sudo crontab /opt/auto-backup/cron/db-backup.crontab.example
sudo crontab -l
```

Untuk logical-only, Anda boleh memakai user OS khusus dengan permission minimum.


## 9. Log dan notifikasi

Default log disimpan di:

```bash
LOG_DIR="$SCRIPT_DIR/logs"
```

Jika menjalankan `backup-all.sh`, semua output MongoDB/MariaDB/PostgreSQL/GCS masuk ke satu log harian, misalnya:

```text
/opt/auto-backup/logs/backup-all-20260930.log
```

Khusus error/warning `mariadb-dump`, detail tambahan disimpan sebagai:

```text
/opt/auto-backup/logs/mariadb-dump-20260930T062830Z.log
```

### Discord

Buat Incoming Webhook di Discord lalu isi:

```bash
NOTIFY_DISCORD=true
DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/ID/TOKEN'
```

### Telegram

Buat bot Telegram, lalu isi token bot dan chat ID:

```bash
NOTIFY_TELEGRAM=true
TELEGRAM_BOT_TOKEN='123456789:AA...'
TELEGRAM_CHAT_ID='123456789'
```

Atur kondisi pengiriman:

```bash
NOTIFY_ON_SUCCESS=true
NOTIFY_ON_WARNING=true
NOTIFY_ON_FAILURE=true
```

`backup-all.sh` mengirim **satu ringkasan** setelah seluruh job selesai. Status yang mungkin: `SUCCESS`, `WARNING`, atau `FAILED`. Warning MariaDB karena object yang dilewati akan ikut tercantum dalam notifikasi. Kegagalan mengirim notifikasi tidak mengubah backup yang sudah sukses menjadi gagal; kegagalan notifikasi tetap dicatat di log.

## 10. Struktur object GCS

Contoh:

```text
gs://bucket/database-backups/mongodb/mongodb-equipment/
gs://bucket/database-backups/mariadb/mariadb-logical/
gs://bucket/database-backups/mariadb-physical/mariadb-full/
gs://bucket/database-backups/postgresql/postgresql-app_database/
```

Setiap folder berisi file backup dan file `.sha256`.
Retention sebaiknya diatur dengan lifecycle policy pada bucket GCS, bukan dengan `rm` di server backup.

## 11. Restore singkat

MariaDB logical:

```bash
gzip -dc mariadb-logical-*.sql.gz | mariadb --user=root -p
```

MariaDB physical:

```bash
mkdir extracted
zstd -dc mariadb-full-*.xbstream.zst | mbstream -x -C extracted
mariadb-backup --prepare --target-dir="$PWD/extracted"
```

MongoDB biasa / backup DB atau collection:

```bash
mongorestore --archive=mongodb-*.archive.gz --gzip --stopOnError
```

Untuk **full dump replica set** yang otomatis memakai `--oplog`, tambahkan:

```bash
mongorestore --archive=mongodb-all-*.archive.gz --gzip --oplogReplay --stopOnError
```

PostgreSQL:

```bash
pg_restore --dbname=target_database --no-owner --no-acl --exit-on-error postgresql-*.dump
```

Selalu uji restore ke environment terpisah sebelum menganggap backup siap untuk disaster recovery.

## 12. Dependency

Umum:

```text
bash flock timeout sha256sum openssl base64 gcloud curl hostname tee
```

MongoDB:

```text
mongodump
```

MariaDB logical:

```text
mariadb mariadb-dump gzip
```

MariaDB physical:

```text
mariadb-backup (atau mariabackup), mbstream, zstd
```

PostgreSQL:

```text
pg_dump pg_restore
```

## 13. Validasi script

```bash
bash -n backup-all.sh backup-mongodb.sh backup-mariadb.sh \
  backup-mariadb-physical.sh backup-postgresql.sh lib/common.bash
```
