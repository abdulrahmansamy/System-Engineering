#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="./pgsql_ha_audit_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

exec > >(tee "$OUTPUT_DIR/audit.log") 2>&1

echo "=== PostgreSQL HA Configuration Audit ==="
echo "Timestamp: $(date)"
echo "Hostname: $(hostname)"
echo

########################################
# Helper functions
########################################

dump_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    echo "----- FILE: $file -----"
    stat "$file"
    echo
    sed 's/^/    /' "$file"
    echo
  fi
}

dump_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    echo "----- DIRECTORY: $dir -----"
    find "$dir" -type f -maxdepth 2 | while read -r f; do
      dump_file "$f"
    done
  fi
}

########################################
# PostgreSQL discovery
########################################

echo "=== PostgreSQL Runtime Discovery ==="

PG_BIN=$(command -v psql || true)
if [[ -z "$PG_BIN" ]]; then
  echo "psql not found. Exiting."
  exit 1
fi

PGDATA=$(psql -Atqc "SHOW data_directory;")
PGCONF=$(psql -Atqc "SHOW config_file;")
HBA=$(psql -Atqc "SHOW hba_file;")
IDENT=$(psql -Atqc "SHOW ident_file;")

echo "PGDATA: $PGDATA"
echo "Config file: $PGCONF"
echo "pg_hba.conf: $HBA"
echo "pg_ident.conf: $IDENT"
echo

########################################
# Core PostgreSQL configs
########################################

echo "=== PostgreSQL Core Configuration ==="
dump_file "$PGCONF"
dump_file "$HBA"
dump_file "$IDENT"
dump_file "$PGDATA/postgresql.auto.conf"

########################################
# Streaming replication
########################################

echo "=== Streaming Replication Settings ==="
psql -Atqc "
SELECT name || ' = ' || setting
FROM pg_settings
WHERE name IN (
  'wal_level',
  'max_wal_senders',
  'max_replication_slots',
  'hot_standby',
  'primary_conninfo',
  'restore_command',
  'archive_mode',
  'archive_command'
);
" | sed 's/^/    /'
echo

########################################
# Replication slots
########################################

echo "=== Replication Slots ==="
psql -Atqc "
SELECT slot_name, slot_type, active, restart_lsn
FROM pg_replication_slots;
" | sed 's/^/    /'
echo

########################################
# PgBouncer
########################################

echo "=== PgBouncer Configuration ==="

PGBOUNCER_CONF_LOCATIONS=(
  /etc/pgbouncer/pgbouncer.ini
  /etc/pgbouncer/pgbouncer.conf
  /etc/pgbouncer/userlist.txt
)

for f in "${PGBOUNCER_CONF_LOCATIONS[@]}"; do
  dump_file "$f"
done

########################################
# Patroni
########################################

echo "=== Patroni Configuration ==="
dump_dir /etc/patroni
dump_dir /var/lib/patroni

########################################
# repmgr
########################################

echo "=== repmgr Configuration ==="
dump_dir /etc/repmgr
dump_file /etc/repmgr.conf

########################################
# systemd overrides
########################################

echo "=== systemd PostgreSQL Overrides ==="
dump_dir /etc/systemd/system/postgresql.service.d
dump_dir /etc/systemd/system/postgresql@*.service.d

########################################
# Permissions summary
########################################

echo "=== Permissions Summary ==="
find \
  "$PGDATA" \
  "$PGCONF" \
  "$HBA" \
  "$IDENT" \
  /etc/pgbouncer \
  /etc/patroni \
  /etc/repmgr \
  2>/dev/null \
  -type f \
  -exec stat --format '%A %U:%G %n' {} \; \
  | sort

echo
echo "=== Audit Complete ==="
echo "Output directory: $OUTPUT_DIR"
