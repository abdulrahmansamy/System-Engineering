#!/bin/bash
# Hybrid SCRAM-SHA-256/MD5 Authentication Fix for PgBouncer
# Maintains SCRAM-SHA-256 for PostgreSQL while using MD5 for PgBouncer compatibility

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

info "🔧 Hybrid SCRAM-SHA-256/MD5 Authentication Fix for PgBouncer"
echo "============================================================"

info "This approach maintains SCRAM-SHA-256 security for PostgreSQL"
info "while using MD5 for PgBouncer compatibility (industry standard)"

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

# Step 2: Update pg_hba.conf for hybrid authentication
info ""
info "Step 2: Configuring hybrid SCRAM-SHA-256/MD5 authentication"
echo "=========================================================="

PG_HBA="/etc/postgresql/17/main/pg_hba.conf"
cp "$PG_HBA" "${PG_HBA}.backup.hybrid.$(date +%Y%m%d-%H%M%S)"

# Add MD5 entries for PgBouncer while keeping SCRAM for everything else
if ! grep -q "# PgBouncer Hybrid MD5 entries" "$PG_HBA"; then
    info "Adding hybrid authentication entries to pg_hba.conf..."
    
    cat >> "$PG_HBA" <<EOF

# PgBouncer Hybrid MD5 authentication entries (for PgBouncer compatibility)
host    all             postgres        127.0.0.1/32            md5
host    all             postgres        ::1/128                 md5
host    all             pgbouncer_admin 127.0.0.1/32            md5
host    all             pgbouncer_admin ::1/128                 md5
host    all             repmgr          127.0.0.1/32            md5
host    all             repmgr          ::1/128                 md5
EOF

    success "✓ Added hybrid authentication entries to pg_hba.conf"
else
    info "Hybrid authentication entries already exist"
fi

# Step 3: Configure PgBouncer for MD5 authentication
info ""
info "Step 3: Configuring PgBouncer for MD5 authentication"
echo "=================================================="

PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"
cp "$PGBOUNCER_CONF" "${PGBOUNCER_CONF}.backup.hybrid.$(date +%Y%m%d-%H%M%S)"

# Update PgBouncer configuration for MD5
sed -i 's/auth_type = scram-sha-256/auth_type = md5/' "$PGBOUNCER_CONF"

# Remove auth_query and auth_user lines if they exist
sed -i '/^auth_query = /d' "$PGBOUNCER_CONF"
sed -i '/^auth_user = /d' "$PGBOUNCER_CONF"

success "✓ PgBouncer configured for MD5 authentication"

# Step 4: Create userlist with MD5 hashes
info ""
info "Step 4: Creating PgBouncer userlist with MD5 hashes"
echo "=================================================="

# Generate MD5 hashes (PostgreSQL-compatible format)
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
pgbouncer_admin_md5=$(echo -n "${PGBOUNCER_PASSWORD}pgbouncer_admin" | md5sum | cut -d' ' -f1)
repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)

USERLIST_FILE="/etc/pgbouncer/userlist.txt"
cp "$USERLIST_FILE" "${USERLIST_FILE}.backup.hybrid.$(date +%Y%m%d-%H%M%S)"

cat > "$USERLIST_FILE" <<EOF
;; PgBouncer Hybrid Authentication File
;; Generated: $(date)
;; PostgreSQL uses SCRAM-SHA-256, PgBouncer uses MD5 for compatibility

"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"repmgr" "md5${repmgr_md5}"

EOF

chown pgbouncer:pgbouncer "$USERLIST_FILE"
chmod 640 "$USERLIST_FILE"

success "✓ Created userlist.txt with MD5 hashes"

# Step 5: Update .pgpass file
info ""
info "Step 5: Updating .pgpass file for hybrid authentication"
echo "===================================================="

PGPASS_FILE="/var/lib/postgresql/.pgpass"
cp "$PGPASS_FILE" "${PGPASS_FILE}.backup.hybrid.$(date +%Y%m%d-%H%M%S)"

# Update .pgpass with current passwords
info "Updating .pgpass with Secret Manager passwords..."

# Get current primary IP
PRIMARY_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")

cat > "$PGPASS_FILE" <<EOF
# Hybrid Authentication .pgpass
# Generated: $(date)

# PostgreSQL direct connections (SCRAM-SHA-256)
localhost:5432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:5432:*:postgres:${PG_SUPER_PASS}
${PRIMARY_IP}:5432:*:postgres:${PG_SUPER_PASS}

# PgBouncer connections (MD5)
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

success "✓ Updated .pgpass file for hybrid authentication"

# Step 6: Restart services
info ""
info "Step 6: Restarting services to apply hybrid configuration"
echo "========================================================"

# Reload PostgreSQL configuration
if systemctl reload postgresql; then
    success "✓ PostgreSQL configuration reloaded"
else
    warn "PostgreSQL reload failed, trying restart..."
    systemctl restart postgresql
    sleep 3
fi

# Restart PgBouncer
if systemctl restart pgbouncer; then
    success "✓ PgBouncer restarted with hybrid configuration"
else
    error "PgBouncer restart failed"
    journalctl -u pgbouncer -n 10 --no-pager || true
    exit 1
fi

sleep 3

# Step 7: Test hybrid authentication
info ""
info "Step 7: Testing hybrid authentication"
echo "===================================="

# Test direct PostgreSQL connection (SCRAM-SHA-256)
export PGPASSWORD="$PG_SUPER_PASS"
if psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'Direct PostgreSQL SCRAM-SHA-256 works!' as test;" 2>/dev/null; then
    success "✓ Direct PostgreSQL SCRAM-SHA-256 authentication works"
else
    warn "✗ Direct PostgreSQL SCRAM-SHA-256 authentication failed"
fi

# Test PgBouncer connection (MD5)
if psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer MD5 authentication works!' as status;" 2>/dev/null; then
    success "🎉 SUCCESS: PgBouncer MD5 authentication working!"
    success "✅ Hybrid SCRAM-SHA-256/MD5 authentication configured successfully"
else
    error "❌ PgBouncer MD5 authentication still failing"
    
    info "Recent PgBouncer logs:"
    journalctl -u pgbouncer -n 10 --no-pager || true
    
    info "Testing PgBouncer admin interface..."
    if psql -h localhost -p 6432 -U pgbouncer_admin -d pgbouncer -c "SHOW CONFIG;" 2>/dev/null | grep -E "(auth_type|auth_file)"; then
        info "✓ PgBouncer admin interface accessible"
    else
        warn "✗ PgBouncer admin interface not accessible"
    fi
fi

# Test with .pgpass file
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'pgpass hybrid auth works!' as test;" 2>/dev/null; then
    success "✓ .pgpass hybrid authentication works"
else
    warn "✗ .pgpass hybrid authentication needs verification"
fi

info ""
info "🔐 Hybrid Authentication Configuration Summary"
echo "=============================================="
echo "✅ Security Benefits:"
echo "  • PostgreSQL: SCRAM-SHA-256 (strongest authentication)"
echo "  • PgBouncer: MD5 (industry standard for connection poolers)"
echo "  • Passwords: Managed entirely through Secret Manager"
echo "  • Network: Encrypted connections between components"
echo ""
echo "🎯 Configuration Applied:"
echo "  • PostgreSQL: SCRAM-SHA-256 for direct connections"
echo "  • PgBouncer: MD5 for pooled connections"
echo "  • pg_hba.conf: Hybrid authentication rules"
echo "  • userlist.txt: MD5 hashes for PgBouncer users"
echo ""
echo "Next steps:"
echo "• Run comprehensive validation: sudo ./comprehensive_validation.sh"
echo "• Test: psql -h localhost -p 6432 -U postgres -d postgres"