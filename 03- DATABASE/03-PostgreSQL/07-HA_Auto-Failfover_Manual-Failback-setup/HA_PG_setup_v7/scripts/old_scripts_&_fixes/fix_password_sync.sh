#!/bin/bash
# PostgreSQL HA Password Synchronization Fix Script
# This script fixes password mismatches between PostgreSQL users and .pgpass

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Get metadata
get_metadata() {
  local key="$1" default="$2"
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "$default"
}

# Get secret from Secret Manager
get_secret() {
  local project_id="$1" secret_id="$2"
  
  # Get access token
  local token
  token=$(curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | \
    jq -r '.access_token')
  
  if [[ -z "$token" ]]; then
    return 1
  fi
  
  # Get secret
  local url="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${secret_id}/versions/latest:access"
  local body
  if body=$(curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$url"); then
    echo "$body" | jq -r '.payload.data' | base64 -d
    return 0
  else
    return 1
  fi
}

echo "========================================="
echo "PostgreSQL HA Password Sync Fix Script"
echo "========================================="

# Get configuration
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id)
ROLE=$(get_metadata pg_role unknown)
REPMGR_USER=$(get_metadata repmgr_user repmgr)
REPMGR_DB=$(get_metadata repmgr_db repmgr)
ORG_CODE=$(get_metadata org_code ipa)
ENV_CODE=$(get_metadata env_code nprd)

info "Project: $PROJECT_ID"
info "Role: $ROLE" 
info "Repmgr user: $REPMGR_USER"
info "Repmgr database: $REPMGR_DB"

# Check if PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
  error "PostgreSQL is not running. Please start it first:"
  echo "  sudo systemctl start postgresql"
  exit 1
fi

# Check if we can connect as postgres user
if ! sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
  error "Cannot connect to PostgreSQL as postgres user"
  exit 1
fi

info "PostgreSQL is running and accessible"

# Try to get password from Secret Manager
REPMGR_SECRET_ID="${ORG_CODE}-${ENV_CODE}-sec-repmgr-password-01"
info "Attempting to retrieve password from Secret Manager: $REPMGR_SECRET_ID"

REPMGR_PASSWORD=""
if REPMGR_PASSWORD=$(get_secret "$PROJECT_ID" "$REPMGR_SECRET_ID" 2>/dev/null); then
  info "✅ Retrieved password from Secret Manager (length: ${#REPMGR_PASSWORD} characters)"
else
  warn "⚠️  Could not retrieve from Secret Manager, checking metadata fallback..."
  REPMGR_PASSWORD=$(get_metadata repmgr_password "")
  if [[ -n "$REPMGR_PASSWORD" ]]; then
    info "✅ Retrieved password from metadata (length: ${#REPMGR_PASSWORD} characters)"
  else
    error "❌ Could not retrieve password from Secret Manager or metadata"
    exit 1
  fi
fi

# Get current self IP
SELF_IP=$(hostname -I | awk '{print $1}')
info "Self IP: $SELF_IP"

# Check if repmgr user exists
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REPMGR_USER}'" postgres | grep -q 1; then
  info "✅ User '$REPMGR_USER' exists - updating password"
  
  # Update the password
  if sudo -u postgres psql -c "ALTER ROLE ${REPMGR_USER} PASSWORD '${REPMGR_PASSWORD}';" postgres; then
    info "✅ Password updated successfully"
  else
    error "❌ Failed to update password"
    exit 1
  fi
else
  info "Creating user '$REPMGR_USER' with correct password"
  if sudo -u postgres psql -c "CREATE ROLE ${REPMGR_USER} WITH LOGIN SUPERUSER PASSWORD '${REPMGR_PASSWORD}';" postgres; then
    info "✅ User created successfully"
  else
    error "❌ Failed to create user"
    exit 1
  fi
fi

# Ensure database exists
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${REPMGR_DB}'" postgres | grep -q 1; then
  info "Creating database '$REPMGR_DB'"
  sudo -u postgres createdb -O ${REPMGR_USER} ${REPMGR_DB}
fi

# Create/update .pgpass file
PGPASS_FILE="/var/lib/postgresql/.pgpass"
info "Creating .pgpass file with correct password"

cat > "$PGPASS_FILE" <<EOF
localhost:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
${SELF_IP}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
localhost:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
${SELF_IP}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
*:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
*:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
EOF

chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

info "✅ .pgpass file updated"

# Test connection
info "Testing connection with new password..."
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h "$SELF_IP" -U "$REPMGR_USER" -d "$REPMGR_DB" -c "SELECT 'Connection successful' as result;" >/dev/null 2>&1; then
  info "✅ Connection test successful!"
else
  error "❌ Connection test failed"
  info "Trying localhost connection..."
  if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -U "$REPMGR_USER" -d "$REPMGR_DB" -c "SELECT 'Connection successful' as result;" >/dev/null 2>&1; then
    info "✅ Localhost connection successful!"
  else
    error "❌ Localhost connection also failed"
    exit 1
  fi
fi

# Now try repmgr registration
info "Attempting repmgr primary registration..."
REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"

# Clear any existing repmgr tables
info "Clearing existing repmgr tables..."
sudo -u postgres psql -d "$REPMGR_DB" -c "DROP TABLE IF EXISTS repmgr.nodes CASCADE;" 2>/dev/null || true
sudo -u postgres psql -d "$REPMGR_DB" -c "DROP SCHEMA IF EXISTS repmgr CASCADE;" 2>/dev/null || true

# Register primary
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" repmgr -f "$REPMGR_CONF_FILE" primary register --force; then
  info "✅ Primary registration successful!"
  
  # Show cluster status
  info "Cluster status:"
  sudo -u postgres env PGPASSFILE="$PGPASS_FILE" repmgr -f "$REPMGR_CONF_FILE" cluster show
  
  # Restart repmgrd
  info "Restarting repmgrd service..."
  systemctl restart repmgrd
  
  info "✅ Password synchronization and registration completed successfully!"
else
  error "❌ Primary registration failed"
  exit 1
fi

echo ""
echo "========================================="
echo "Password Sync Fix Completed Successfully"
echo "========================================="