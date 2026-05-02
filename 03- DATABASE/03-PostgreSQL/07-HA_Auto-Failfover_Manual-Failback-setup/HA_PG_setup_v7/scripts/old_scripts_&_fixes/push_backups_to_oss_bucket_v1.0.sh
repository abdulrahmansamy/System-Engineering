#!/bin/bash
# push_backups_to_oss_bucket.sh
# Push PostgreSQL backups into GCS bucket directories that match lifecycle rules

# Create log file with proper permissions if it doesn't exist
# sudo touch /var/log/push_backups.log
# sudo chown postgres:postgres /var/log/push_backups.log
# sudo chmod 644 /var/log/push_backups.log

BUCKET="gs://ipa-nominations-platform-prd-tiered-backup-storage-bucket-01"
BASE="/var/lib/postgresql/pg_care/backup"
DATE=$(date +"%Y%m%d-%H%M%S")
LOGFILE="/var/log/push_backups.log"

# === Logging helpers ===
log_info() {
  echo "[$(date)] INFO: $1" | tee -a "$LOGFILE"
}

log_success() {
  echo "[$(date)] SUCCESS: $1" | tee -a "$LOGFILE"
}

log_fail() {
  echo "[$(date)] FAIL: $1" | tee -a "$LOGFILE"
}

# === Backup push function ===
push_backup() {
  local src="$1"
  local type="$2"
  local target="$3"

  log_info "Uploading ${type} backup from ${src} to ${target}"
  gsutil -m cp -r "${src}"/* "${BUCKET}/${target}/${type}/${DATE}/" >>"$LOGFILE" 2>&1
  if [ $? -eq 0 ]; then
    log_success "${type} backup pushed to ${target}"
  else
    log_fail "${type} backup push to ${target}"
  fi
}

# === Dispatch by argument ===
case "$1" in
  logical)
    # Daily logical backup
    push_backup "${BASE}/AllDBData" "logical" "pgsql/daily"
    ;;
  physical)
    # Daily physical backup
    push_backup "${BASE}/phybackup" "physical" "pgsql/daily"
    ;;
  wal)
    # WAL backups every 6 hours
    push_backup "${BASE}/walbackup" "wal" "pgsql/daily"
    ;;
  weekly)
    # Copy logical backup into weekly retention
    push_backup "${BASE}/AllDBData" "logical" "pgsql/weekly"
    # Copy physical backup into weekly retention
    push_backup "${BASE}/phybackup" "physical" "pgsql/weekly"
    ;;
  monthly)
    # Copy logical backup into monthly retention
    push_backup "${BASE}/AllDBData" "logical" "pgsql/monthly"
    # Copy physical backup into monthly retention
    push_backup "${BASE}/phybackup" "physical" "pgsql/monthly"
    ;;
  *)
    log_fail "Unknown backup type argument: $1"
    ;;
esac


# =================================================================
# Example Cron Job Entries
# =================================================================

# # === Pushing Daily backups ===
# # Logical backup push at 1:00 AM
# 0 1 * * * /u01/backup/script/push_backups_to_oss_bucket.sh logical >> /u01/backup/log/push_backups.log 2>&1

# # Physical backup push at 1:30 AM
# 30 1 * * * /u01/backup/script/push_backups_to_oss_bucket.sh physical >> /u01/backup/log/push_backups.log 2>&1

# # WAL backups every 6 hours (01:00, 07:00, 13:00, 19:00)
# 0 1,7,13,19 * * * /u01/backup/script/push_backups_to_oss_bucket.sh wal >> /u01/backup/log/push_backups.log 2>&1

# # === Pushing Weekly backups ===
# # Copy logical + physical backups into weekly retention (Friday at 2:00 AM)
# 0 2 * * 5 /u01/backup/script/push_backups_to_oss_bucket.sh weekly >> /u01/backup/log/push_backups.log 2>&1

# # === Pushing Monthly backups ===
# # Copy logical + physical backups into monthly retention (1st of month at 3:00 AM)
# 0 3 1 * * /u01/backup/script/push_backups_to_oss_bucket.sh monthly >> /u01/backup/log/push_backups.log 2>&1




# # Daily backups
# 0 1 * * * /u01/backup/script/push_backups_to_oss_bucket.sh logical >> /var/log/push_backups.log 2>&1
# 30 1 * * * /u01/backup/script/push_backups_to_oss_bucket.sh physical >> /var/log/push_backups.log 2>&1

# # WAL backups every 6 hours
# 0 1,7,13,19 * * * /u01/backup/script/push_backups_to_oss_bucket.sh wal >> /var/log/push_backups.log 2>&1
# # Weekly backups (e.g., Sunday 2 AM)
# 0 2 * * 0 /u01/backup/script/push_backups_to_oss_bucket.sh weekly >> /var/log/push_backups.log 2>&1

# # Monthly backups (e.g., 1st of month 3 AM)
# 0 3 1 * * /u01/backup/script/push_backups_to_oss_bucket.sh monthly >> /var/log/push_backups.log 2>&1


# =================================================================
# Diagram of Backup Push Process
# =================================================================

# +-----------------------+
# | PostgreSQL Server     |
# | (/var/lib/postgresql) |
# +----------+------------+
#            |
#            | (Local backups stored in:)
#            | - AllDBData     -> Logical backup
#            | - phybackup     -> Physical backup
#            | - walbackup     -> WAL backup
#            v
# +------------------------------------------+
# |     push_backups.sh (Bash Script)        |
# |  - Accepts input arg: logical, physical, |
# |    wal, weekly, monthly                  |
# |  - Chooses source & target accordingly   |
# |  - Logs success or failure               |
# +------------------------------------------+
#            |
#            | Executes gsutil command
#            v
# +--------------------------------------------------------+
# | Google Cloud Storage Bucket: gs://prd-backup-bucket-01 |
# |                                                        |
# | Folder structure created dynamically:                  |
# |   /pgsql/                                              |
# |      ├── daily/                                        |
# |      │    ├── logical/YYYYMMDD-HHMMSS/                 |
# |      │    ├── physical/YYYYMMDD-HHMMSS/                |
# |      │    └── wal/YYYYMMDD-HHMMSS/                     |
# |      ├── weekly/                                       |
# |      │    ├── logical/YYYYMMDD-HHMMSS/                 |
# |      │    └── physical/YYYYMMDD-HHMMSS/                |
# |      └── monthly/                                      |
# |           ├── logical/YYYYMMDD-HHMMSS/                 |
# |           └── physical/YYYYMMDD-HHMMSS/                |
# +--------------------------------------------------------+

