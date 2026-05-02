#!/bin/bash
# Get PostgreSQL Passwords for Testing
# Extracts passwords from GCP Secret Manager for connection testing

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🔐 PostgreSQL Password Extractor"
echo "================================"
echo

# Get project and metadata
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id)
ORG_CODE=$(curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code" 2>/dev/null || echo "ipa")
ENV_CODE=$(curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code" 2>/dev/null || echo "nprd")

info "Project: $PROJECT_ID"
info "Org: $ORG_CODE, Env: $ENV_CODE"
echo

# Get access token
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')

# Function to get secret
get_secret() {
    local secret_id="$1"
    local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${secret_id}/versions/latest:access"
    
    curl -sf -H "Authorization: Bearer $TOKEN" "$url" | jq -r '.payload.data' | base64 -d
}

# Get passwords
info "Extracting passwords..."

PG_SUPERUSER_PASS=$(get_secret "${ORG_CODE}-${ENV_CODE}-sec-pg-superuser-password-01")
PGBOUNCER_PASS=$(get_secret "${ORG_CODE}-${ENV_CODE}-sec-pgbouncer-password-01")

success "✅ Passwords extracted successfully!"
echo

echo "🔗 Connection Strings:"
echo "======================"
echo
echo "# PostgreSQL Direct Connections (URL-safe method):"
echo "export PG_SUPER_PASS='$PG_SUPERUSER_PASS'"
echo "export PGBOUNCER_PASS='$PGBOUNCER_PASS'"
echo
echo "# Use PGPASSWORD environment variable method:"
echo "PGPASSWORD='\$PG_SUPER_PASS' psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c \"SELECT 'Primary Direct';\""
echo "PGPASSWORD='\$PG_SUPER_PASS' psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c \"SELECT 'Standby Direct';\""
echo
echo "# PgBouncer Connections:"
echo "PGPASSWORD='\$PG_SUPER_PASS' psql -h 192.168.14.21 -p 6432 -U postgres -d postgres -c \"SELECT 'Primary PgBouncer';\""
echo "PGPASSWORD='\$PG_SUPER_PASS' psql -h 192.168.14.22 -p 6432 -U postgres -d postgres -c \"SELECT 'Standby PgBouncer';\""
echo
echo "# PgBouncer Admin:"
echo "PGPASSWORD='\$PGBOUNCER_PASS' psql -h 192.168.14.21 -p 6432 -U pgbouncer_admin -d pgbouncer -c \"SHOW POOLS;\""
echo

echo "📋 Test Script:"
echo "==============="
cat > test_connections.sh << EOF
#!/bin/bash
# Automated PostgreSQL HA Connection Tests

set -euo pipefail

PG_SUPER_PASS='$PG_SUPERUSER_PASS'
PGBOUNCER_PASS='$PGBOUNCER_PASS'

echo "🧪 Testing PostgreSQL HA Connections..."
echo "======================================="
echo

echo "1. Testing Primary Direct Connection:"
if PGPASSWORD="\$PG_SUPER_PASS" psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c "SELECT 'Primary Direct Connection ✅' as status, now() as timestamp;" 2>/dev/null; then
    echo "   ✅ PRIMARY DIRECT: SUCCESS"
else
    echo "   ❌ PRIMARY DIRECT: FAILED"
fi
echo

echo "2. Testing Standby Direct Connection:"
if PGPASSWORD="\$PG_SUPER_PASS" psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c "SELECT 'Standby Direct Connection ✅' as status, pg_is_in_recovery() as is_standby, now() as timestamp;" 2>/dev/null; then
    echo "   ✅ STANDBY DIRECT: SUCCESS"
else
    echo "   ❌ STANDBY DIRECT: FAILED"
fi
echo

echo "3. Testing Primary PgBouncer:"
if PGPASSWORD="\$PG_SUPER_PASS" psql -h 192.168.14.21 -p 6432 -U postgres -d postgres -c "SELECT 'Primary PgBouncer ✅' as status, now() as timestamp;" 2>/dev/null; then
    echo "   ✅ PRIMARY PGBOUNCER: SUCCESS"
else
    echo "   ❌ PRIMARY PGBOUNCER: FAILED"
fi
echo

echo "4. Testing Standby PgBouncer:"
if PGPASSWORD="\$PG_SUPER_PASS" psql -h 192.168.14.22 -p 6432 -U postgres -d postgres -c "SELECT 'Standby PgBouncer ✅' as status, pg_is_in_recovery() as is_standby, now() as timestamp;" 2>/dev/null; then
    echo "   ✅ STANDBY PGBOUNCER: SUCCESS"
else
    echo "   ❌ STANDBY PGBOUNCER: FAILED"
fi
echo

echo "5. Testing Replication Status:"
echo "   Primary replication status:"
PGPASSWORD="\$PG_SUPER_PASS" psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;" 2>/dev/null || echo "   No replication connections"

echo "   Standby replication status:"
PGPASSWORD="\$PG_SUPER_PASS" psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c "SELECT status, received_lsn, last_msg_receipt_time FROM pg_stat_wal_receiver;" 2>/dev/null || echo "   Not a standby or no WAL receiver"
echo

echo "6. Testing PgBouncer Pool Status:"
if PGPASSWORD="\$PGBOUNCER_PASS" psql -h 192.168.14.21 -p 6432 -U pgbouncer_admin -d pgbouncer -c "SHOW POOLS;" 2>/dev/null; then
    echo "   ✅ PGBOUNCER ADMIN: SUCCESS"
else
    echo "   ❌ PGBOUNCER ADMIN: FAILED"
fi
echo

echo "🎉 Connection testing complete!"
EOF

chmod +x test_connections.sh
success "✅ Test script created: test_connections.sh"
echo
info "Run: ./test_connections.sh to test all connections"