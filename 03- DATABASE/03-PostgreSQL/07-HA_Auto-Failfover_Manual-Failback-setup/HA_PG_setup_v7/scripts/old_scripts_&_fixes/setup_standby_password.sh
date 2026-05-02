#!/bin/bash
# Pre-Clone Password Setup for Standby Nodes
# This script ensures the standby has the correct Secret Manager password before cloning

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Get metadata function
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
echo "Pre-Clone Password Setup for Standby"
echo "========================================="

# Get configuration
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id)
ROLE=$(get_metadata pg_role unknown)
REPMGR_PRIMARY_HOST=$(get_metadata repmgr_primary_host pg-primary)
REPMGR_USER=$(get_metadata repmgr_user repmgr)
REPMGR_DB=$(get_metadata repmgr_db repmgr)
ORG_CODE=$(get_metadata org_code ipa)
ENV_CODE=$(get_metadata env_code nprd)

info "Project: $PROJECT_ID"
info "Role: $ROLE"
info "Primary Host: $REPMGR_PRIMARY_HOST"

# Only run for standby nodes
if [[ "$ROLE" != "standby" ]]; then
  error "This script is only for standby nodes (detected role: $ROLE)"
  exit 1
fi

# Get password from Secret Manager
REPMGR_SECRET_ID="${ORG_CODE}-${ENV_CODE}-sec-repmgr-password-01"
info "Retrieving password from Secret Manager: $REPMGR_SECRET_ID"

if REPMGR_PASSWORD=$(get_secret "$PROJECT_ID" "$REPMGR_SECRET_ID" 2>/dev/null); then
  info "✅ Retrieved password from Secret Manager (length: ${#REPMGR_PASSWORD} characters)"
else
  error "❌ Could not retrieve password from Secret Manager"
  exit 1
fi

# Get self IP
SELF_IP=$(hostname -I | awk '{print $1}')
info "Self IP: $SELF_IP"

# Create .pgpass file with Secret Manager password
PGPASS_FILE="/var/lib/postgresql/.pgpass"
info "Creating .pgpass file with Secret Manager password"

# Ensure postgres user exists and has proper directories
if ! id -u postgres >/dev/null 2>&1; then
  error "postgres user does not exist"
  exit 1
fi

# Create .pgpass file
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

info "✅ .pgpass file created with Secret Manager password"

# Test connection to primary
info "Testing connection to primary..."
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" -c "SELECT 'Connection successful' as result;" >/dev/null 2>&1; then
  info "✅ Connection to primary successful!"
else
  error "❌ Connection to primary failed"
  info "Testing basic PostgreSQL connection..."
  if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h "$REPMGR_PRIMARY_HOST" -U postgres -d postgres -c "SELECT version();" >/dev/null 2>&1; then
    info "✅ Basic PostgreSQL connection works"
    warn "⚠️  repmgr database connection failed - primary may not be fully initialized"
  else
    error "❌ Cannot connect to primary PostgreSQL at all"
    exit 1
  fi
fi

echo ""
echo "========================================="
echo "Pre-Clone Setup Complete!"
echo "========================================="
echo ""
echo "Now you can run the bootstrap script:"
echo "  sudo ./postgresql_ha_bootstrap.sh"