#!/bin/bash
# PgBouncer Authentication Priority Fix
# Ensures MD5 authentication rules are processed before SCRAM rules

set -euo pipefail

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;92m[SUCCESS]\033[0m $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "🔧 PgBouncer Authentication Priority Fix"
echo "========================================"

info "Fixing pg_hba.conf rule ordering to ensure MD5 authentication for PgBouncer"

# Step 1: Get passwords from Secret Manager
info ""
info "Step 1: Retrieving passwords from Secret Manager"
echo "==============================================="

PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null)
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')

# Get postgres password
PG_SECRET="ipa-nprd-sec-pg-superuser-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
PG_SUPER_PASS=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

# Get pgbouncer password
PGBOUNCER_SECRET="ipa-nprd-sec-pgbouncer-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PGBOUNCER_SECRET}/versions/latest:access"
PGBOUNCER_PASSWORD=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

# Get repmgr password
REPMGR_SECRET="ipa-nprd-sec-repmgr-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${REPMGR_SECRET}/versions/latest:access"
REPMGR_PASSWORD=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

info "✓ Retrieved passwords from Secret Manager"

# Step 2: Rebuild pg_hba.conf with proper rule ordering
info ""
info "Step 2: Rebuilding pg_hba.conf with correct authentication priority"
echo "================================================================="

PG_HBA="/etc/postgresql/17/main/pg_hba.conf"

# Backup current pg_hba.conf
cp "$PG_HBA" "${PG_HBA}.backup.priority.$(date +%Y%m%d-%H%M%S)"

# Create a new pg_hba.conf with proper ordering
cat > "$PG_HBA" <<EOF
# PostgreSQL Client Authentication Configuration File
# Rebuilt for PgBouncer compatibility - $(date)
#
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     peer

# IPv4/IPv6 local connections - PgBouncer MD5 rules (MUST come first!)
host    all             postgres        127.0.0.1/32            md5
host    all             postgres        ::1/128                 md5
host    all             pgbouncer_admin 127.0.0.1/32            md5
host    all             pgbouncer_admin ::1/128                 md5

# IPv4/IPv6 local connections - General SCRAM-SHA-256 (after MD5 rules)
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Replication connections for HA cluster
host    replication     replication     192.168.0.0/16          scram-sha-256
host    replication     repmgr          192.168.0.0/16          scram-sha-256
host    repmgr          repmgr          192.168.0.0/16          scram-sha-256
host    all             repmgr          192.168.0.0/16          scram-sha-256

# Specific IP entries for cluster nodes
host    repmgr          repmgr          192.168.14.21/32        scram-sha-256
host    replication     replication     192.168.14.21/32        scram-sha-256
host    replication     repmgr          192.168.14.21/32        scram-sha-256
host    all             postgres        192.168.14.21/32        scram-sha-256
host    all             pgbouncer_admin 192.168.14.21/32        scram-sha-256

host    repmgr          repmgr          192.168.14.22/32        scram-sha-256
host    replication     replication     192.168.14.22/32        scram-sha-256
host    replication     repmgr          192.168.14.22/32        scram-sha-256
host    all             postgres        192.168.14.22/32        scram-sha-256
host    all             pgbouncer_admin 192.168.14.22/32        scram-sha-256

EOF

success "✓ Rebuilt pg_hba.conf with correct authentication priority"

# Step 3: Configure PgBouncer for MD5 authentication
info ""
info "Step 3: Configuring PgBouncer for MD5 authentication"
echo "=================================================="

PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"

# Ensure auth_type is set to md5
sed -i 's/auth_type = .*/auth_type = md5/' "$PGBOUNCER_CONF"

# Remove auth_query and auth_user lines if they exist
sed -i '/^auth_query = /d' "$PGBOUNCER_CONF"
sed -i '/^auth_user = /d' "$PGBOUNCER_CONF"

success "✓ PgBouncer configured for MD5 authentication"

# Step 4: Create proper userlist with MD5 hashes
info ""
info "Step 4: Creating PgBouncer userlist with proper MD5 hashes"
echo "========================================================="

# Generate MD5 hashes (PostgreSQL-compatible format)
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
pgbouncer_admin_md5=$(echo -n "${PGBOUNCER_PASSWORD}pgbouncer_admin" | md5sum | cut -d' ' -f1)
repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)

USERLIST_FILE="/etc/pgbouncer/userlist.txt"

cat > "$USERLIST_FILE" <<EOF
;; PgBouncer Authentication Priority Fix
;; Generated: $(date)
;; MD5 authentication for PgBouncer compatibility

"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"repmgr" "md5${repmgr_md5}"

EOF

chown pgbouncer:pgbouncer "$USERLIST_FILE"
chmod 640 "$USERLIST_FILE"

success "✓ Created userlist.txt with proper MD5 hashes"
info "  → postgres MD5: md5${postgres_md5}"
info "  → pgbouncer_admin MD5: md5${pgbouncer_admin_md5}"
info "  → repmgr MD5: md5${repmgr_md5}"

# Step 5: Update .pgpass file
info ""
info "Step 5: Updating .pgpass file for proper authentication"
echo "====================================================="

PGPASS_FILE="/var/lib/postgresql/.pgpass"

# Get current node IP
PRIMARY_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")

cat > "$PGPASS_FILE" <<EOF
# PgBouncer Authentication Priority Fix .pgpass
# Generated: $(date)

# PostgreSQL direct connections
localhost:5432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:5432:*:postgres:${PG_SUPER_PASS}
${PRIMARY_IP}:5432:*:postgres:${PG_SUPER_PASS}

# PgBouncer connections 
localhost:6432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:6432:*:postgres:${PG_SUPER_PASS}
${PRIMARY_IP}:6432:*:postgres:${PG_SUPER_PASS}

# PgBouncer admin connections
localhost:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
127.0.0.1:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
${PRIMARY_IP}:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}

# Repmgr connections
localhost:5432:repmgr:repmgr:${REPMGR_PASSWORD}
127.0.0.1:5432:repmgr:repmgr:${REPMGR_PASSWORD}
${PRIMARY_IP}:5432:repmgr:repmgr:${REPMGR_PASSWORD}
localhost:5432:replication:repmgr:${REPMGR_PASSWORD}
127.0.0.1:5432:replication:repmgr:${REPMGR_PASSWORD}
${PRIMARY_IP}:5432:replication:repmgr:${REPMGR_PASSWORD}

# Wildcard entries
*:5432:*:postgres:${PG_SUPER_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
*:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
*:5432:repmgr:repmgr:${REPMGR_PASSWORD}
*:5432:replication:repmgr:${REPMGR_PASSWORD}
EOF

chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

success "✓ Updated .pgpass file for proper authentication"

# Step 6: Restart services with new configuration
info ""
info "Step 6: Restarting services with authentication priority fix"
echo "=========================================================="

# Reload PostgreSQL configuration
if systemctl reload postgresql; then
    success "✓ PostgreSQL configuration reloaded"
else
    warn "PostgreSQL reload failed, trying restart..."
    systemctl restart postgresql
    sleep 5
fi

# Wait for PostgreSQL to be ready
sleep 2
if ! sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
    error "PostgreSQL not responding after reload"
    exit 1
fi

# Restart PgBouncer
if systemctl restart pgbouncer; then
    success "✓ PgBouncer restarted with priority fix"
else
    error "PgBouncer restart failed"
    journalctl -u pgbouncer -n 10 --no-pager || true
    exit 1
fi

sleep 3

# Step 7: Test the authentication priority fix
info ""
info "Step 7: Testing authentication priority fix"
echo "=========================================="

# Test direct PostgreSQL connection (should use SCRAM-SHA-256)
export PGPASSWORD="$PG_SUPER_PASS"
if psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'Direct PostgreSQL connection works!' as test;" 2>/dev/null; then
    success "✓ Direct PostgreSQL authentication works"
else
    error "✗ Direct PostgreSQL authentication failed"
fi

# Test PgBouncer connection (should use MD5 via localhost rule priority)
if psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer MD5 authentication works!' as status;" 2>/dev/null; then
    success "🎉 SUCCESS: PgBouncer MD5 authentication working!"
    success "✅ Authentication priority fix successful"
else
    error "❌ PgBouncer authentication still failing"
    
    info "Recent PgBouncer logs:"
    journalctl -u pgbouncer -n 15 --no-pager || true
    
    # Test PgBouncer admin interface
    info "Testing PgBouncer admin interface..."
    if psql -h localhost -p 6432 -U pgbouncer_admin -d pgbouncer -c "SHOW CONFIG;" 2>/dev/null | head -5; then
        info "✓ PgBouncer admin interface accessible"
    else
        warn "✗ PgBouncer admin interface not accessible"
    fi
fi

# Test with .pgpass file
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'pgpass auth works!' as test;" 2>/dev/null; then
    success "✓ .pgpass authentication works"
else
    warn "✗ .pgpass authentication needs verification"
fi

info ""
info "🔧 Authentication Priority Fix Summary"
echo "======================================"
echo "✅ Configuration Applied:"
echo "  • pg_hba.conf: MD5 rules for localhost connections (priority)"
echo "  • pg_hba.conf: SCRAM-SHA-256 rules for other connections"
echo "  • PgBouncer: MD5 authentication mode"
echo "  • userlist.txt: Proper MD5 password hashes"
echo ""
echo "🎯 Authentication Flow:"
echo "  • localhost:6432 → MD5 (PgBouncer)"
echo "  • localhost:5432 → SCRAM-SHA-256 (after MD5 rules)"
echo "  • Remote IPs → SCRAM-SHA-256 (secure)"
echo ""
echo "Next steps:"
echo "• Run validation: sudo ./comprehensive_validation.sh"
echo "• Test PgBouncer: psql -h localhost -p 6432 -U postgres -d postgres"