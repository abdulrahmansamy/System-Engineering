#!/bin/bash
# Fix repmgr user authentication and .pgpass configuration
set -euo pipefail

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

# Get metadata
REPMGR_PRIMARY_HOST="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_primary_host || echo 192.168.14.21)"
REPMGR_USER="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_user || echo repmgr)"
REPMGR_DB="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_db || echo repmgr)"

info "Getting current repmgr password from database..."
# Get the current password from the database
CURRENT_PASSWORD=$(sudo -u postgres psql -Atqc "SELECT rolpassword FROM pg_authid WHERE rolname='${REPMGR_USER}'" postgres 2>/dev/null || echo '')

if [[ -z "$CURRENT_PASSWORD" ]]; then
  warn "No repmgr user found, creating with new password..."
  # Generate new password
  NEW_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)
  sudo -u postgres psql -c "CREATE ROLE ${REPMGR_USER} WITH LOGIN SUPERUSER PASSWORD '${NEW_PASSWORD}';" postgres || warn "Create role failed"
  sudo -u postgres psql -c "ALTER ROLE ${REPMGR_USER} PASSWORD '${NEW_PASSWORD}';" postgres || warn "Alter role failed"
  REPMGR_PASSWORD="$NEW_PASSWORD"
  info "Created repmgr user with new password"
else
  # Use existing password - we'll extract it or reset it
  info "Repmgr user exists, resetting password for testing..."
  NEW_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)
  sudo -u postgres psql -c "ALTER ROLE ${REPMGR_USER} PASSWORD '${NEW_PASSWORD}';" postgres
  REPMGR_PASSWORD="$NEW_PASSWORD"
  info "Reset repmgr user password"
fi

# Ensure repmgr database exists
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${REPMGR_DB}'" postgres | grep -q 1 || \
  sudo -u postgres createdb -O ${REPMGR_USER} ${REPMGR_DB}

info "Using password: ${REPMGR_PASSWORD:0:8}..." # Show first 8 chars only

# Get local IP
self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
info "Self IP: $self_ip"

# Create/update .pgpass file
pgpass="/var/lib/postgresql/.pgpass"
info "Updating $pgpass..."

# Remove existing entries for repmgr user
if [[ -f "$pgpass" ]]; then
  grep -v ":${REPMGR_DB}:${REPMGR_USER}:" "$pgpass" > "${pgpass}.tmp" 2>/dev/null || true
  grep -v ":replication:${REPMGR_USER}:" "${pgpass}.tmp" > "$pgpass" 2>/dev/null || true
  rm -f "${pgpass}.tmp"
fi

# Add new entries
cat >> "$pgpass" <<EOF
localhost:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
${REPMGR_PRIMARY_HOST}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
localhost:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
${REPMGR_PRIMARY_HOST}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
EOF

if [[ -n "$self_ip" && "$self_ip" != "localhost" && "$self_ip" != "$REPMGR_PRIMARY_HOST" ]]; then
  cat >> "$pgpass" <<EOF
${self_ip}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
${self_ip}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
EOF
fi

chown postgres:postgres "$pgpass"
chmod 600 "$pgpass"

info "Updated .pgpass file"

# Test connections
info "Testing local connection..."
if sudo -u postgres env PGPASSFILE="$pgpass" psql -U "$REPMGR_USER" -d "$REPMGR_DB" -Atqc 'select 1' 2>/dev/null; then
  info "SUCCESS: Local connection works"
else
  warn "FAILED: Local connection failed"
fi

info "Testing self-IP connection..."
if sudo -u postgres env PGPASSFILE="$pgpass" psql -h "$self_ip" -U "$REPMGR_USER" -d "$REPMGR_DB" -Atqc 'select 1' 2>/dev/null; then
  info "SUCCESS: Self-IP connection works"
else
  warn "FAILED: Self-IP connection failed"
fi

# Update repmgr.conf with correct connection info
REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"
if [[ -f "$REPMGR_CONF_FILE" ]]; then
  info "Updating repmgr.conf conninfo..."
  sed -i "s/conninfo=.*/conninfo='host=${self_ip} user=${REPMGR_USER} dbname=${REPMGR_DB}'/" "$REPMGR_CONF_FILE"
  info "Updated repmgr.conf"
fi

# Test repmgr primary register
info "Testing repmgr primary register..."
if sudo -u postgres env PGPASSFILE="$pgpass" repmgr -f "$REPMGR_CONF_FILE" primary register --force 2>/dev/null; then
  info "SUCCESS: repmgr primary register works"
else
  warn "FAILED: repmgr primary register failed"
fi

# Test repmgr cluster show
info "Testing repmgr cluster show..."
if sudo -u postgres env PGPASSFILE="$pgpass" repmgr -f "$REPMGR_CONF_FILE" cluster show 2>/dev/null; then
  info "SUCCESS: repmgr cluster show works"
else
  warn "FAILED: repmgr cluster show failed"
fi

info "Authentication fix completed. Password: ${REPMGR_PASSWORD}"
info "Run validate_phase4.sh to check results."