#!/bin/bash
# Quick Repmgr Password Patch for Bootstrap
# This script patches the bootstrap environment with the correct Secret Manager password

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
echo "Quick Repmgr Password Patch"
echo "========================================="

# Get metadata
get_metadata() {
  local key="$1" default="$2"
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "$default"
}

# Get secret from Secret Manager
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
ORG_CODE=$(get_metadata org_code ipa)
ENV_CODE=$(get_metadata env_code nprd)

# Get Secret Manager password
REPMGR_SECRET_ID="${ORG_CODE}-${ENV_CODE}-sec-repmgr-password-01"
info "Getting password from Secret Manager: $REPMGR_SECRET_ID"

if REPMGR_PASSWORD=$(get_secret "$PROJECT_ID" "$REPMGR_SECRET_ID" 2>/dev/null); then
  info "✅ Retrieved password (length: ${#REPMGR_PASSWORD} characters)"
else
  error "❌ Could not get Secret Manager password"
  exit 1
fi

# Kill any stuck processes
info "Stopping any stuck processes..."
sudo pkill -f postgresql_ha_bootstrap || true
sleep 2

# Clear bootstrap sentinel
info "Clearing bootstrap state..."
sudo rm -f /var/lib/postgresql/.bootstrap/done

# Create environment script
ENV_SCRIPT="/tmp/bootstrap_env.sh"
cat > "$ENV_SCRIPT" <<EOF
#!/bin/bash
export REPMGR_PASSWORD='$REPMGR_PASSWORD'
export PROJECT_ID='$PROJECT_ID'
exec "\$@"
EOF
chmod +x "$ENV_SCRIPT"

info "✅ Environment prepared with Secret Manager password"
echo ""
echo "Now run with the patched environment:"
echo "  sudo $ENV_SCRIPT ./postgresql_ha_bootstrap.sh"
echo ""
echo "Or export the password manually:"
echo "  export REPMGR_PASSWORD='$REPMGR_PASSWORD'"
echo "  sudo -E ./postgresql_ha_bootstrap.sh"