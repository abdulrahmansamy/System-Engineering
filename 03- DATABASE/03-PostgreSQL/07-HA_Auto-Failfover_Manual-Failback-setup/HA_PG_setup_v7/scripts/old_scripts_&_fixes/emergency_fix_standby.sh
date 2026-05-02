#!/bin/bash
# Emergency Bootstrap Fix for Standby
# This script stops the stuck bootstrap and fixes the password issue

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "========================================="
echo "Emergency Bootstrap Fix for Standby"
echo "========================================="

# Kill any stuck bootstrap processes
info "Stopping stuck bootstrap processes..."
sudo pkill -f postgresql_ha_bootstrap || true
sudo pkill -f repmgr || true
sudo pkill -f psql || true

sleep 2

# Remove bootstrap sentinel to allow fresh start
info "Removing bootstrap sentinel..."
sudo rm -f /var/lib/postgresql/.bootstrap/done

# Get metadata and Secret Manager password
get_metadata() {
  local key="$1" default="$2"
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "$default"
}

get_secret() {
  local project_id="$1" secret_id="$2"
  local token
  token=$(curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | \
    jq -r '.access_token')
  
  if [[ -z "$token" ]]; then return 1; fi
  
  local url="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${secret_id}/versions/latest:access"
  local body
  if body=$(curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$url"); then
    echo "$body" | jq -r '.payload.data' | base64 -d
    return 0
  else
    return 1
  fi
}

# Get configuration
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id)
REPMGR_PRIMARY_HOST=$(get_metadata repmgr_primary_host pg-primary)
REPMGR_USER=$(get_metadata repmgr_user repmgr)
REPMGR_DB=$(get_metadata repmgr_db repmgr)
ORG_CODE=$(get_metadata org_code ipa)
ENV_CODE=$(get_metadata env_code nprd)
SELF_IP=$(hostname -I | awk '{print $1}')

# Get Secret Manager password
REPMGR_SECRET_ID="${ORG_CODE}-${ENV_CODE}-sec-repmgr-password-01"
info "Getting password from Secret Manager..."

if REPMGR_PASSWORD=$(get_secret "$PROJECT_ID" "$REPMGR_SECRET_ID" 2>/dev/null); then
  info "✅ Retrieved password (length: ${#REPMGR_PASSWORD} characters)"
else
  error "❌ Could not get Secret Manager password"
  exit 1
fi

# Create correct .pgpass file
PGPASS_FILE="/var/lib/postgresql/.pgpass"
info "Creating corrected .pgpass file..."

cat > "$PGPASS_FILE" <<EOF
localhost:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
${REPMGR_PRIMARY_HOST}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
${SELF_IP}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
localhost:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
${REPMGR_PRIMARY_HOST}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
${SELF_IP}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
*:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
*:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
EOF

chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

info "✅ .pgpass file updated with Secret Manager password"

# Test connection
info "Testing connection to primary..."
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" -c "SELECT 'Connection test successful' as result;" >/dev/null 2>&1; then
  info "✅ Connection to primary successful!"
else
  warn "⚠️  Direct repmgr connection failed, testing basic connection..."
  if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h "$REPMGR_PRIMARY_HOST" -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    info "✅ Basic connection works"
  else
    error "❌ Cannot connect to primary"
    exit 1
  fi
fi

# Set environment variable for the bootstrap script
export REPMGR_PASSWORD="$REPMGR_PASSWORD"

info "✅ Emergency fix completed!"
echo ""
echo "Now run: sudo REPMGR_PASSWORD='$REPMGR_PASSWORD' ./postgresql_ha_bootstrap.sh"
echo ""
echo "Or just run: sudo ./postgresql_ha_bootstrap.sh"
echo "(The password is now correctly set in .pgpass)"