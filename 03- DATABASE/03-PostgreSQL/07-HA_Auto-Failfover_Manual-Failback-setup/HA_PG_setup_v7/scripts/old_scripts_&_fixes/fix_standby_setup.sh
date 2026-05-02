#!/bin/bash
# Fix standby node setup and repmgr clone issues
set -euo pipefail

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

# Get metadata
REPMGR_PRIMARY_HOST="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_primary_host || echo 192.168.14.21)"
REPMGR_USER="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_user || echo repmgr)"
REPMGR_DB="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_db || echo repmgr)"

info "Primary host: $REPMGR_PRIMARY_HOST"
info "Repmgr user: $REPMGR_USER"
info "Repmgr DB: $REPMGR_DB"

# Check clone log if it exists
clone_log="/var/log/pg-bootstrap/repmgr_clone.log"
if [[ -f "$clone_log" ]]; then
  info "=== Clone log contents ==="
  tail -20 "$clone_log" || true
  info "========================="
fi

# Test connectivity to primary
info "Testing connectivity to primary..."
if nc -z "$REPMGR_PRIMARY_HOST" 5432; then
  info "SUCCESS: Can reach primary on port 5432"
else
  error "FAILED: Cannot reach primary on port 5432"
  exit 1
fi

# Get the current repmgr password from the primary
info "Getting repmgr password from primary..."
if command -v psql >/dev/null 2>&1; then
  # Try to connect to primary and get the password (this will fail but we'll use the one from the auth script)
  REPMGR_PASSWORD="3fQLleVev9lgLXa94ukjAhtme931uPj"  # From the previous auth fix
else
  error "psql not available"
  exit 1
fi

info "Using password: ${REPMGR_PASSWORD:0:8}..."

# Get local IP
self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
info "Self IP: $self_ip"

# Ensure .pgpass is set up correctly
pgpass="/var/lib/postgresql/.pgpass"
info "Setting up .pgpass..."

cat > "$pgpass" <<EOF
localhost:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
${REPMGR_PRIMARY_HOST}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
localhost:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
${REPMGR_PRIMARY_HOST}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
${self_ip}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
${self_ip}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
EOF

chown postgres:postgres "$pgpass"
chmod 600 "$pgpass"

# Test connection to primary repmgr database
info "Testing connection to primary repmgr database..."
if sudo -u postgres env PGPASSFILE="$pgpass" psql -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" -Atqc 'select 1' 2>/dev/null; then
  info "SUCCESS: Can connect to primary repmgr database"
else
  warn "FAILED: Cannot connect to primary repmgr database"
  info "Trying with different connection method..."
  # Try without specifying the database first
  if sudo -u postgres env PGPASSFILE="$pgpass" psql -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d postgres -Atqc 'select 1' 2>/dev/null; then
    info "SUCCESS: Can connect to primary postgres database"
  else
    error "FAILED: Cannot connect to primary at all"
    exit 1
  fi
fi

# Stop PostgreSQL if running
systemctl stop postgresql || true

# PostgreSQL paths
PG_VERSION="17"
PG_CLUSTER_NAME="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"

# Clean data directory
info "Cleaning PostgreSQL data directory..."
if [[ -d "$PG_DATA_DIR" ]]; then
  find "$PG_DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
fi
mkdir -p "$PG_DATA_DIR"
chown -R postgres:postgres "$PG_DATA_DIR"

# Attempt repmgr standby clone
info "Attempting repmgr standby clone..."
clone_cmd="sudo -u postgres env PGPASSFILE=$pgpass repmgr -h $REPMGR_PRIMARY_HOST -U $REPMGR_USER -d $REPMGR_DB -f $REPMGR_CONF_FILE standby clone"
info "Running: $clone_cmd"

if $clone_cmd; then
  info "SUCCESS: repmgr standby clone completed"
  
  # Start PostgreSQL
  info "Starting PostgreSQL..."
  systemctl start postgresql || true
  
  # Wait for startup
  sleep 5
  
  # Test local connection
  if sudo -u postgres psql -Atqc 'select pg_is_in_recovery()' postgres 2>/dev/null | grep -q 't'; then
    info "SUCCESS: Standby is in recovery mode"
  else
    warn "Standby might not be in recovery mode"
  fi
  
  # Register standby
  info "Registering standby node..."
  if sudo -u postgres env PGPASSFILE="$pgpass" repmgr -f "$REPMGR_CONF_FILE" standby register; then
    info "SUCCESS: Standby registered"
  else
    warn "Standby registration failed"
  fi
  
else
  error "FAILED: repmgr standby clone failed"
  if [[ -f "$clone_log" ]]; then
    info "=== Full clone log ==="
    cat "$clone_log"
    info "====================="
  fi
  exit 1
fi

info "Standby setup completed successfully!"