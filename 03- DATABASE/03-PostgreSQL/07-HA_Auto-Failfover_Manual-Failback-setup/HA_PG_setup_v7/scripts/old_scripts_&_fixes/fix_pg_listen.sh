#!/bin/bash
# Fix PostgreSQL listen_addresses and pg_hba configuration for repmgr
set -euo pipefail

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

# Check current status
info "Current PostgreSQL status:"
systemctl status postgresql --no-pager -l || true

info "Current listen_addresses setting:"
sudo -u postgres psql -Atqc "show listen_addresses" postgres 2>/dev/null || echo "Could not query"

info "Current socket bindings:"
ss -lnpt | grep :5432 || echo "No port 5432 bindings found"

info "Getting metadata..."
REPMGR_PRIMARY_HOST="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_primary_host || echo 192.168.14.21)"
REPMGR_USER="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_user || echo repmgr)"
REPMGR_DB="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_db || echo repmgr)"

info "Primary host: $REPMGR_PRIMARY_HOST"
info "Repmgr user: $REPMGR_USER"
info "Repmgr DB: $REPMGR_DB"

# Detect PostgreSQL config paths
PG_VERSION="17"
PG_CLUSTER_NAME="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
PG_HBA="${PG_DATA_DIR}/pg_hba.conf"
PG_CONF="${PG_DATA_DIR}/postgresql.conf"

if [[ -f "/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/pg_hba.conf" ]]; then
  PG_HBA="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/pg_hba.conf"
fi
if [[ -f "/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/postgresql.conf" ]]; then
  PG_CONF="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/postgresql.conf"
fi

info "Using config files:"
info "  postgresql.conf: $PG_CONF"
info "  pg_hba.conf: $PG_HBA"

# Force listen_addresses to '*'
info "Setting listen_addresses to '*'..."
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = '*';" postgres || warn "ALTER SYSTEM failed"

# Also ensure it's in postgresql.conf
if ! grep -q "^listen_addresses.*=" "$PG_CONF" 2>/dev/null; then
  echo "listen_addresses = '*'" >> "$PG_CONF"
  info "Added listen_addresses = '*' to postgresql.conf"
else
  sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
  info "Updated listen_addresses in postgresql.conf"
fi

# Get local IP
self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
info "Self IP: $self_ip"

# Configure pg_hba.conf
auth_method="md5"
enc=$(sudo -u postgres psql -Atqc "show password_encryption" postgres 2>/dev/null || echo '')
if [[ "$enc" == "scram-sha-256" ]]; then auth_method="scram-sha-256"; fi

info "Using auth method: $auth_method"

# Detect network CIDR
allow_cidr="192.168.0.0/16"
if [[ -n "$self_ip" ]]; then
  case "$self_ip" in
    10.*) allow_cidr="10.0.0.0/8" ;;
    192.168.*) allow_cidr="192.168.0.0/16" ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) allow_cidr="172.16.0.0/12" ;;
    *) allow_cidr="${self_ip%.*}.0/24" ;;
  esac
fi

info "Using network CIDR: $allow_cidr"

# Add comprehensive pg_hba.conf entries
if ! grep -q '# REPMGR-HA-HBA' "$PG_HBA" 2>/dev/null; then
  cat >> "$PG_HBA" <<EOF
# REPMGR-HA-HBA (comprehensive access)
local   all             all                                     peer
host    all             all             127.0.0.1/32            ${auth_method}
host    all             all             ::1/128                 ${auth_method}
host    replication     replication     ${allow_cidr}           ${auth_method}
host    ${REPMGR_DB}    ${REPMGR_USER}  ${allow_cidr}           ${auth_method}
host    all             ${REPMGR_USER}  ${allow_cidr}           ${auth_method}
host    replication     ${REPMGR_USER}  ${allow_cidr}           ${auth_method}
EOF
  info "Added comprehensive pg_hba.conf entries"
fi

# Add specific IP entries
if [[ -n "$self_ip" ]]; then
  if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${self_ip}/32" "$PG_HBA" 2>/dev/null; then
    cat >> "$PG_HBA" <<EOF
# Specific IP entries for ${self_ip}
host    ${REPMGR_DB}    ${REPMGR_USER}  ${self_ip}/32           ${auth_method}
host    replication     replication     ${self_ip}/32           ${auth_method}
host    replication     ${REPMGR_USER}  ${self_ip}/32           ${auth_method}
EOF
    info "Added specific entries for self IP ${self_ip}"
  fi
fi

if [[ "$REPMGR_PRIMARY_HOST" != "$self_ip" && "$REPMGR_PRIMARY_HOST" != "pg-primary" ]]; then
  if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${REPMGR_PRIMARY_HOST}/32" "$PG_HBA" 2>/dev/null; then
    cat >> "$PG_HBA" <<EOF
# Specific IP entries for primary ${REPMGR_PRIMARY_HOST}
host    ${REPMGR_DB}    ${REPMGR_USER}  ${REPMGR_PRIMARY_HOST}/32  ${auth_method}
host    replication     replication     ${REPMGR_PRIMARY_HOST}/32  ${auth_method}
host    replication     ${REPMGR_USER}  ${REPMGR_PRIMARY_HOST}/32  ${auth_method}
EOF
    info "Added specific entries for primary host ${REPMGR_PRIMARY_HOST}"
  fi
fi

# Restart PostgreSQL
info "Restarting PostgreSQL..."
systemctl restart postgresql

# Wait for startup
info "Waiting for PostgreSQL to start..."
sleep 5

# Check if it's now listening
for i in {1..10}; do
  if sudo -u postgres psql -Atqc 'select 1' postgres >/dev/null 2>&1; then
    info "PostgreSQL is responding (attempt $i)"
    break
  fi
  sleep 2
done

# Final status check
info "Final status check:"
info "listen_addresses: $(sudo -u postgres psql -Atqc "show listen_addresses" postgres 2>/dev/null || echo 'Could not query')"
info "Socket bindings:"
ss -lnpt | grep :5432 || echo "No port 5432 bindings found"

# Test repmgr connection
info "Testing repmgr connection to self..."
if sudo -u postgres psql -h "$self_ip" -U "$REPMGR_USER" -d "$REPMGR_DB" -Atqc 'select 1' 2>/dev/null; then
  info "SUCCESS: Can connect to repmgr database on $self_ip"
else
  warn "FAILED: Cannot connect to repmgr database on $self_ip"
fi

# Test local repmgr connection
info "Testing local repmgr connection..."
if sudo -u postgres psql -U "$REPMGR_USER" -d "$REPMGR_DB" -Atqc 'select 1' 2>/dev/null; then
  info "SUCCESS: Can connect to repmgr database locally"
else
  warn "FAILED: Cannot connect to repmgr database locally"
fi

info "Fix script completed. Run validate_phase4.sh to check results."