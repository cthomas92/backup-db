# Backup database ke Google Cloud Storage

Project ini sengaja sederhana. Ada empat perintah backup:

| Script | File hasil | Restore |
| --- | --- | --- |
| `backup-mongodb.sh` | `.archive.gz` | `mongorestore` |
| `backup-mariadb.sh` | `.sql.gz` | `mariadb` |
| `backup-mariadb-physical.sh` | `.xbstream.zst` | `mbstream` + `mariadb-backup` |
| `backup-postgresql.sh` | `.dump` | `pg_restore` |

Setiap script melakukan dump, memeriksa hasil, membuat SHA-256, lalu mengunggah
file backup dan file `.sha256` ke GCS. Tidak ada Python, init gcloud, tar tambahan,
manifest, atau service. `lib/common.bash` hanya berisi fungsi bersama agar empat
script tidak mengulang kode upload, lock, dan cleanup.

## Persyaratan

- Linux, Bash, `flock`, `timeout`, `sha256sum`, dan Google Cloud CLI (`gcloud`).
- MongoDB Database Tools untuk MongoDB.
- Client MariaDB (`mariadb` dan `mariadb-dump`) yang sesuai dengan server.
- `mariabackup`/`mariadb-backup`, `mbstream`, dan `zstd` untuk physical backup.
- Client PostgreSQL yang sesuai dengan server.
- Bucket GCS private dan user/service account dengan izin `storage.objects.create`
  dan `storage.objects.get` pada prefix tujuan.

Google Cloud dan database harus sudah disiapkan oleh operator. Script tidak
melakukan login, membuat bucket, membuat user database, atau menghapus backup lama.
Atur retention/lifecycle langsung pada bucket GCS.

Untuk MariaDB dan PostgreSQL, gunakan account khusus backup yang hanya
memiliki izin baca dan metadata yang diperlukan tool dump. Jangan berikan hak DML,
DDL, superuser, atau administrasi lain. Untuk MongoDB gunakan role `backup` bawaan
yang direkomendasikan MongoDB dan jangan tambahkan role lain.

## Instalasi

Contoh memakai user OS khusus bernama `dbbackup`:

```bash
sudo useradd --system --create-home --home-dir /var/lib/db-backup \
  --shell /usr/sbin/nologin dbbackup
sudo install -d -o root -g root -m 755 /opt/db-backup /opt/db-backup/lib
sudo install -m 755 backup-mongodb.sh backup-mariadb.sh \
  backup-mariadb-physical.sh backup-postgresql.sh /opt/db-backup/
sudo install -m 644 lib/common.bash /opt/db-backup/lib/
sudo install -d -o dbbackup -g dbbackup -m 700 \
  /etc/db-backup /var/lib/db-backup /var/log/db-backup
sudo install -o dbbackup -g dbbackup -m 600 /dev/null \
  /var/log/db-backup/mongodb.log
sudo install -o dbbackup -g dbbackup -m 600 /dev/null \
  /var/log/db-backup/mariadb.log
sudo install -o dbbackup -g dbbackup -m 600 /dev/null \
  /var/log/db-backup/postgresql-app.log
```

Script dapat dipindahkan ke mesin Linux lain. Salin empat script bersama direktori
`lib`, instal client database dan `gcloud`, lalu buat config untuk mesin tersebut.

## Setup gcloud

Tidak perlu initialization di dalam script. Login satu kali sebagai user yang
menjalankan cron, lalu periksa hasilnya:

```bash
sudo -H -u dbbackup gcloud auth list
sudo -H -u dbbackup gcloud storage ls gs://NAMA_BUCKET
```

Attached service account pada VM adalah pilihan paling sederhana karena tidak
memerlukan file JSON. Bila setup Anda memakai JSON key, tempat yang aman dan mudah
dipahami adalah:

```text
/etc/db-backup/gcp-service-account.json
owner: dbbackup
mode: 600
```

Aktivasi dilakukan manual oleh Anda, bukan oleh script:

```bash
sudo install -o dbbackup -g dbbackup -m 600 /lokasi/key.json \
  /etc/db-backup/gcp-service-account.json
sudo -H -u dbbackup gcloud auth activate-service-account \
  --key-file=/etc/db-backup/gcp-service-account.json
```

Jangan menaruh JSON key di crontab, source code, bucket backup, atau argument
command. Kelola atau hapus file setup itu sesuai kebijakan key organisasi Anda;
script backup tidak pernah membacanya.

## Konfigurasi

Salin contoh untuk database yang dipakai:

```bash
sudo install -o dbbackup -g dbbackup -m 600 \
  config/mariadb.conf.example /etc/db-backup/mariadb.conf
sudo install -o dbbackup -g dbbackup -m 600 \
  config/mariadb.cnf.example /etc/db-backup/mariadb.cnf
```

Untuk MongoDB gunakan `mongodb.conf.example` dan `mongodb.yml.example`. Untuk
PostgreSQL gunakan `postgresql.conf.example` dan `pgpass.example`. Semua file
config/credential harus dimiliki `dbbackup`, mode `600`, dan menggunakan absolute
path. Ganti seluruh nilai `REPLACE`.

Pengaturan yang sama pada semua config hanya tiga:

```bash
GCS_URI='gs://bucket/database-backups'
BACKUP_NAME='nama-yang-unik'
BACKUP_DIR='/var/lib/db-backup'
```

`GCS_URI` menentukan bucket sekaligus folder dasar tujuan. Script otomatis
menambahkan nama engine dan `BACKUP_NAME`:

```text
GCS_URI/ENGINE/BACKUP_NAME/NAMA_FILE

gs://bucket/database-backups/mongodb/production-mongodb/...
gs://bucket/database-backups/mariadb/production-mariadb/...
gs://bucket/database-backups/postgresql/production-postgresql-app/...
```

Untuk mengganti folder GCS, cukup ubah `GCS_URI`. Contohnya
`GCS_URI='gs://bucket-backup-prod/db-harian'`. `BACKUP_DIR` berbeda: nilai itu
hanya folder staging sementara pada mesin lokal dan tidak menentukan tujuan GCS.

MariaDB logical backup meminta daftar database aplikasi secara eksplisit. Ini
menghindari ikut menyalin system schema dan account server:

```bash
MARIADB_DATABASES=('app_database' 'billing_database')
```

Account logical backup cukup diberi akses baca/metadata pada database tersebut.
Contoh untuk setiap database yang dibackup:

```sql
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY 'PASSWORD_KUAT';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT
  ON app_database.* TO 'backup_user'@'localhost';
```

Pada versi MariaDB yang masih menyimpan definisi routine di `mysql.proc`, opsi
`--routines` juga memerlukan `GRANT SELECT ON mysql.proc`.

PostgreSQL memakai satu database per config agar satu backup menghasilkan satu
file. Untuk tiga database, buat tiga config dengan `PGDATABASE` dan `BACKUP_NAME`
berbeda lalu tambahkan tiga jadwal cron.

### Full physical backup MariaDB

Physical backup harus dijalankan pada host MariaDB oleh OS user yang dapat membaca
seluruh datadir dan file plugin/encryption MariaDB. Biasanya gunakan OS user
`mysql`. Versi `mariadb-backup` harus sama dengan versi MariaDB Server.

Siapkan direktori dan config terpisah:

```bash
sudo install -d -o mysql -g mysql -m 700 \
  /etc/mariadb-backup /var/lib/mariadb-backup /var/log/mariadb-backup
sudo install -o mysql -g mysql -m 600 config/mariabackup.conf.example \
  /etc/mariadb-backup/mariabackup.conf
sudo install -o mysql -g mysql -m 600 config/mariabackup.cnf.example \
  /etc/mariadb-backup/mariabackup.cnf
sudo install -o mysql -g mysql -m 600 /dev/null \
  /var/log/mariadb-backup/backup.log
```

Siapkan user database khusus. Contoh privilege MariaDB modern:

```sql
CREATE USER 'mariabackup'@'localhost' IDENTIFIED BY 'PASSWORD_KUAT';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR
  ON *.* TO 'mariabackup'@'localhost';
```

Gunakan privilege yang sesuai dengan versi MariaDB Anda; versi lama memakai nama
`REPLICATION CLIENT`. Script tidak memakai `--history`, sehingga tidak menulis
record riwayat backup ke database.

Pastikan autentikasi gcloud tersedia untuk OS user yang sama:

```bash
sudo -u mysql env HOME=/var/lib/mariadb-backup gcloud auth list
sudo -u mysql env HOME=/var/lib/mariadb-backup \
  gcloud storage ls gs://NAMA_BUCKET
```

Jika autentikasi awal memakai JSON key, letakkan sementara di
`/etc/mariadb-backup/gcp-service-account.json` dengan owner `mysql` dan mode `600`,
lalu jalankan `gcloud auth activate-service-account` sebagai OS user `mysql`.
Script physical backup tidak membaca file JSON tersebut.

## Menjalankan

Uji manual menggunakan user yang sama dengan cron:

```bash
sudo -H -u dbbackup /opt/db-backup/backup-mariadb.sh /etc/db-backup/mariadb.conf
```

Ganti script/config untuk MongoDB atau PostgreSQL. Pesan `SUCCESS: gs://...`
menunjukkan lokasi file. Contoh isi bucket:

```text
gs://bucket/database-backups/mariadb/production-mariadb/
├── production-mariadb-20260911T020000Z.sql.gz
└── production-mariadb-20260911T020000Z.sql.gz.sha256
```

File sementara otomatis dihapus setelah upload berhasil. Bila gagal, file tetap
berada pada direktori private yang ditulis di log agar dapat diperiksa atau upload
ulang. Lock internal mencegah jadwal backup yang sama berjalan bersamaan.

Menjalankan full physical backup MariaDB:

```bash
sudo -u mysql env HOME=/var/lib/mariadb-backup \
  /opt/db-backup/backup-mariadb-physical.sh \
  /etc/mariadb-backup/mariabackup.conf
```

Hasilnya satu file terkompresi beserta checksum:

```text
gs://bucket/database-backups/mariadb-physical/production-mariadb-physical/
├── production-mariadb-physical-20260914T003000Z.xbstream.zst
└── production-mariadb-physical-20260914T003000Z.xbstream.zst.sha256
```

Anggap backup lengkap hanya jika file `.xbstream.zst` dan `.sha256` keduanya ada.
Jika salah satu upload/verifikasi gagal, script keluar nonzero dan mempertahankan
salinan lokal untuk diperiksa atau diunggah ulang.

## Cron

Buka [contoh crontab](cron/db-backup.crontab.example), sesuaikan jadwal dan email,
lalu pasang:

```bash
sudo crontab -u dbbackup cron/db-backup.crontab.example
sudo crontab -u dbbackup -l
```

Cron langsung memanggil tiga script logical; tidak ada wrapper atau service tambahan.
Pasang [contoh logrotate](cron/db-backup.logrotate.example) bila log disimpan terus.
Hubungkan exit nonzero dari cron ke email atau monitoring Anda.

Physical backup memiliki [contoh crontab terpisah](cron/mariabackup.crontab.example)
karena dijalankan oleh OS user yang dapat membaca datadir:

```bash
sudo crontab -u mysql cron/mariabackup.crontab.example
```

## Restore di mesin lain

Unduh file yang dipilih beserta checksum ke direktori kosong:

```bash
umask 077
mkdir restore-work && cd restore-work
OBJECT='gs://bucket/database-backups/mariadb/production-mariadb/production-mariadb-20260911T020000Z.sql.gz'
gcloud storage cp "$OBJECT" .
gcloud storage cp "$OBJECT.sha256" .
sha256sum --check ./*.sha256
```

MariaDB logical backup:

```bash
set -o pipefail
gzip -dc production-mariadb-*.sql.gz | \
  mariadb --defaults-file=/etc/db-restore/target.cnf --binary-mode
```

Dump berisi `CREATE DATABASE`, table, data, trigger, routine, event, dan view.
User/password/grant server dibuat terpisah pada mesin tujuan.

Full physical backup MariaDB harus direstore sebagai satu instance utuh. Pakai
versi `mariadb-backup` yang sama dengan versi pembuat backup:

```bash
set -o pipefail
ARCHIVE='production-mariadb-physical-20260914T003000Z.xbstream.zst'
zstd --test "$ARCHIVE"
mkdir -m 700 extracted
(cd extracted && zstd -dc "../$ARCHIVE" | mbstream -x)
mariadb-backup --prepare --target-dir="$PWD/extracted"
```

Restore ke datadir kosong. Sesuaikan `/var/lib/mysql` bila datadir Anda berbeda:

```bash
sudo systemctl stop mariadb
sudo mv /var/lib/mysql /var/lib/mysql.before-physical-restore
sudo install -d -o mysql -g mysql -m 750 /var/lib/mysql
sudo mariadb-backup --copy-back --target-dir="$PWD/extracted"
sudo chown -R mysql:mysql /var/lib/mysql
sudo systemctl start mariadb
```

Jangan menjalankan `--copy-back` ketika MariaDB aktif. Physical backup mencakup
semua database, system tables, user, role, dan grant dalam instance. Binlog dan
file konfigurasi/secret eksternal tidak ikut; simpan terpisah bila dibutuhkan.

MongoDB replica set:

```bash
mongorestore --config=/etc/db-restore/target-mongodb.yml \
  --archive=production-mongodb-*.archive.gz --gzip --oplogReplay --stopOnError
```

Untuk backup standalone, hilangkan `--oplogReplay`.

PostgreSQL:

```bash
createdb --host=TARGET_HOST --username=TARGET_USER target_database
pg_restore --host=TARGET_HOST --username=TARGET_USER --dbname=target_database \
  --no-owner --no-acl --exit-on-error production-postgresql-*.dump
```

Archive PostgreSQL tidak membawa role dan grant agar mudah dipindah ke server lain.
Buat user/role tujuan secara terpisah, lalu berikan permission yang diperlukan.

## Batas keamanan dan konsistensi

- Config dan staging bersifat private (`600` dan `700`); `set -x` dinonaktifkan agar
  credential tidak tercetak ke log.
- Script logical hanya menjalankan tool dump; query tambahan MariaDB hanyalah `SELECT`.
  Tidak ada perintah perubahan data/schema. Tool dapat mengambil read/metadata lock
  sementara dan mengubah setting sesi koneksinya sendiri, tetapi tidak mengubah data.
- Gunakan account MariaDB dengan privilege baca/metadata saja dan role
  PostgreSQL dengan `CONNECT`, `USAGE`, serta `SELECT` yang diperlukan. Untuk
  MongoDB gunakan role `backup` bawaan tanpa role tambahan.
- Upload menggunakan HTTPS dari `gcloud`, checksum transfer bawaan gcloud, SHA-256
  tambahan, dan object tidak boleh menimpa nama yang sudah ada.
- MariaDB memakai satu `--single-transaction` untuk semua database terpilih,
  dan menolak table non-InnoDB. Jangan jalankan migration/DDL selama dump.
- MongoDB replica set memakai `--oplog`; pastikan oplog cukup panjang selama dump.
  Standalone hanya aman jika seluruh write dihentikan.
- PostgreSQL custom dump konsisten untuk satu database dan sudah terkompresi secara
  internal, sehingga tidak perlu zip lagi.
- Physical MariaDB menjalankan hot backup seluruh instance dan menggunakan backup
  locks untuk konsistensi. Ia tidak mengubah data aplikasi, tetapi dapat menahan DDL
  sebentar. Jangan memakai `--no-lock`; script ini sengaja tidak mengaktifkannya.
- Physical backup ditulis dahulu ke local disk sebagai `xbstream`, dikompres zstd,
  diuji dengan `zstd --test`, dan diberi SHA-256. Kedua object GCS diverifikasi
  ukuran dan MD5-nya; file lokal baru dihapus setelah semua verifikasi berhasil.
- Restore physical memerlukan versi MariaDB/`mariadb-backup` yang kompatibel. Untuk
  encrypted tables, sediakan kembali key-management plugin dan encryption key.
- Restore selalu ke database kosong dahulu. Setelah restore, periksa jumlah data,
  index, constraint, view/routine, dan query aplikasi sebelum memindahkan traffic.
- Backup terjadwal ini bukan pengganti binlog/WAL/PITR. Uji restore nyata secara
  berkala pada versi database tujuan.

Validasi syntax setelah menyalin atau mengubah file:

```bash
bash -n backup-mongodb.sh backup-mariadb.sh backup-mariadb-physical.sh \
  backup-postgresql.sh lib/common.bash
```
