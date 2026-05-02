#!/bin/bash
# PostgreSQL HA Secret Manager Deployment Test
# This script verifies the Secret Manager integration for repmgr passwords

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Get metadata
get_metadata() {
  local key="$1" default="$2"
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "$default"
}

# Test Secret Manager access
test_secret_manager() {
  info "Testing Secret Manager integration..."
  
  local project_id
  project_id=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id)
  info "Project ID: $project_id"
  
  # Get metadata from instance
  local env_code org_code
  env_code="$(get_metadata env_code nprd)"
  org_code="$(get_metadata org_code ipa)"
  
  info "Environment: $env_code, Organization: $org_code"
  
  # Test secret access
  local repmgr_secret_id="${org_code}-${env_code}-sec-repmgr-password-01"
  info "Testing access to secret: $repmgr_secret_id"
  
  # Get access token
  local token
  token=$(curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | \
    jq -r '.access_token')
  
  if [[ -z "$token" ]]; then
    error "Failed to get access token"
    return 1
  fi
  
  # Test secret retrieval
  local secret_url="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${repmgr_secret_id}/versions/latest:access"
  
  if curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$secret_url" >/dev/null 2>&1; then
    info "✅ Secret Manager access successful"
    
    # Get the actual password (for verification only - don't log it)
    local secret_response
    secret_response=$(curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$secret_url")
    local password_length
    password_length=$(echo "$secret_response" | jq -r '.payload.data' | base64 -d | wc -c)
    info "✅ Password retrieved successfully (length: $password_length characters)"
    
  else
    error "❌ Failed to access Secret Manager"
    warn "Make sure the service account has secretmanager.secretAccessor role"
    return 1
  fi
}

# Test cluster status
test_cluster() {
  info "Testing PostgreSQL cluster status..."
  
  if command -v repmgr >/dev/null 2>&1; then
    info "✅ repmgr is installed"
    
    if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null; then
      info "✅ Cluster status available"
    else
      warn "⚠️  Cluster status not available (may be normal during setup)"
    fi
  else
    warn "⚠️  repmgr not installed"
  fi
}

# Test health endpoint
test_health() {
  info "Testing health endpoint..."
  
  local health_port
  health_port="$(get_metadata pg_health_port 8001)"
  
  if curl -sf "http://localhost:${health_port}" >/dev/null 2>&1; then
    info "✅ Health endpoint responding on port $health_port"
    local health_response
    health_response=$(curl -s "http://localhost:${health_port}")
    info "Health status: $health_response"
  else
    warn "⚠️  Health endpoint not responding on port $health_port"
  fi
}

# Main test function
main() {
  info "=== PostgreSQL HA Secret Manager Integration Test ==="
  info "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  info "Hostname: $(hostname)"
  
  local role
  role="$(get_metadata pg_role unknown)"
  info "Node role: $role"
  
  # Run tests
  test_secret_manager || { error "Secret Manager test failed"; exit 1; }
  test_cluster
  test_health
  
  info "=== Test completed successfully ==="
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi