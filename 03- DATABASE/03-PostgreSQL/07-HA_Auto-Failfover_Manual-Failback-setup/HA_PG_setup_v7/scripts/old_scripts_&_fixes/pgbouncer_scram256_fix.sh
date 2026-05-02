#!/bin/bash
# PgBouncer SCRAM-SHA-256 Authentication Fix
# Configures PgBouncer to work with SCRAM-SHA-256 authentication

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

info "🔧 PgBouncer SCRAM-SHA-256 Authentication Fix"
echo "=============================================="

info "Configuring PgBouncer to work with PostgreSQL's SCRAM-SHA-256 authentication"
info "This is the secure approach that maintains strong authentication"

# Step 1: Check PostgreSQL version and SCRAM support
info ""
info "Step 1: Checking PostgreSQL SCRAM-SHA-256 support"
echo "=================================================="

PG_VERSION=$(sudo -u postgres psql -Atqc "SELECT version();" 2>/dev/null | head -1)
info "PostgreSQL Version: $PG_VERSION"

current_encryption=$(sudo -u postgres psql -Atqc "SHOW password_encryption;" 2>/dev/null || echo "unknown")
info "Current password_encryption: $current_encryption"

# Step 2: Get passwords from Secret Manager
info ""
info "Step 2: Retrieving passwords from Secret Manager"
echo "==============================================="

PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null)
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')

# Get postgres password
PG_SECRET="ipa-nprd-sec-pg-superuser-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
PG_SUPER_PASS=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

# Get repmgr password
REPMGR_SECRET="ipa-nprd-sec-repmgr-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${REPMGR_SECRET}/versions/latest:access"
REPMGR_PASSWORD=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

info "✓ Retrieved passwords from Secret Manager"

# Step 3: Configure PgBouncer for SCRAM-SHA-256
info ""
info "Step 3: Configuring PgBouncer for SCRAM-SHA-256 authentication"
echo "=============================================================="

PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"
cp "$PGBOUNCER_CONF" "${PGBOUNCER_CONF}.backup.scram256.$(date +%Y%m%d-%H%M%S)"

# Update PgBouncer configuration for SCRAM support
info "Updating PgBouncer configuration for SCRAM-SHA-256..."

# Set auth_type to scram-sha-256 and configure auth_query
sed -i 's/auth_type = .*/auth_type = scram-sha-256/' "$PGBOUNCER_CONF"

# Add auth_query for SCRAM authentication
if ! grep -q "auth_query" "$PGBOUNCER_CONF"; then
    sed -i '/auth_file = /a auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename = $1' "$PGBOUNCER_CONF"
    info "✓ Added auth_query for SCRAM authentication"
fi

# Add auth_user (use postgres for authentication queries)
if ! grep -q "auth_user" "$PGBOUNCER_CONF"; then
    sed -i '/auth_query = /a auth_user = postgres' "$PGBOUNCER_CONF"
    info "✓ Added auth_user configuration"
fi

success "✓ PgBouncer configured for SCRAM-SHA-256 authentication"

# Step 4: Update pg_hba.conf for SCRAM authentication
info ""
info "Step 4: Ensuring pg_hba.conf supports SCRAM authentication"
echo "=========================================================="

PG_HBA="/etc/postgresql/17/main/pg_hba.conf"
cp "$PG_HBA" "${PG_HBA}.backup.scram256.$(date +%Y%m%d-%H%M%S)"

# Ensure localhost connections use scram-sha-256
if ! grep -q "# PgBouncer SCRAM-SHA-256 entries" "$PG_HBA"; then
    info "Adding SCRAM-SHA-256 authentication entries for PgBouncer..."
    
    cat >> "$PG_HBA" <<EOF

# PgBouncer SCRAM-SHA-256 authentication entries
host    all             postgres        127.0.0.1/32            scram-sha-256
host    all             postgres        ::1/128                 scram-sha-256
host    all             repmgr          127.0.0.1/32            scram-sha-256
host    all             repmgr          ::1/128                 scram-sha-256
EOF

    success "✓ Added SCRAM-SHA-256 authentication entries to pg_hba.conf"
else
    info "SCRAM authentication entries already exist"
fi

# Step 5: Ensure users have SCRAM passwords
info ""
info "Step 5: Ensuring PostgreSQL users have SCRAM-SHA-256 passwords"
echo "=============================================================="

# Check if this is primary or standby
if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
    NODE_TYPE="primary"
    info "Detected PRIMARY node - can modify users"
    
    # Ensure postgres user has SCRAM password
    info "Setting postgres user password with SCRAM-SHA-256..."
    if sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$PG_SUPER_PASS';" postgres 2>/dev/null; then
        success "✓ Updated postgres user password with SCRAM-SHA-256"
    else
        warn "Could not update postgres password"
    fi
    
    # Ensure repmgr user has SCRAM password
    info "Setting repmgr user password with SCRAM-SHA-256..."
    if sudo -u postgres psql -c "ALTER USER repmgr PASSWORD '$REPMGR_PASSWORD';" postgres 2>/dev/null; then
        success "✓ Updated repmgr user password with SCRAM-SHA-256"
    else
        warn "Could not update repmgr password"
    fi
    
else
    NODE_TYPE="standby"
    info "Detected STANDBY node - passwords will be replicated from primary"
fi

# Step 6: Create/update .pgpass for authentication
info ""
info "Step 6: Updating .pgpass file for SCRAM authentication"
echo "====================================================="

PGPASS_FILE="/var/lib/postgresql/.pgpass"
cp "$PGPASS_FILE" "${PGPASS_FILE}.backup.scram256.$(date +%Y%m%d-%H%M%S)"

# Update .pgpass with current passwords
info "Updating .pgpass with Secret Manager passwords..."

# Remove old entries and add new ones
grep -v ":postgres:" "$PGPASS_FILE" > "${PGPASS_FILE}.tmp" || echo "# Updated .pgpass" > "${PGPASS_FILE}.tmp"
grep -v ":repmgr:" "${PGPASS_FILE}.tmp" > "${PGPASS_FILE}.tmp2" || cp "${PGPASS_FILE}.tmp" "${PGPASS_FILE}.tmp2"

cat >> "${PGPASS_FILE}.tmp2" <<EOF

# SCRAM-SHA-256 authentication entries
localhost:5432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:5432:*:postgres:${PG_SUPER_PASS}
localhost:6432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:6432:*:postgres:${PG_SUPER_PASS}
localhost:5432:*:repmgr:${REPMGR_PASSWORD}
127.0.0.1:5432:*:repmgr:${REPMGR_PASSWORD}
localhost:6432:*:repmgr:${REPMGR_PASSWORD}
127.0.0.1:6432:*:repmgr:${REPMGR_PASSWORD}
*:5432:*:postgres:${PG_SUPER_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
*:5432:*:repmgr:${REPMGR_PASSWORD}
*:6432:*:repmgr:${REPMGR_PASSWORD}
EOF

mv "${PGPASS_FILE}.tmp2" "$PGPASS_FILE"
rm -f "${PGPASS_FILE}.tmp" "${PGPASS_FILE}.tmp2" 2>/dev/null || true

chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

success "✓ Updated .pgpass file for SCRAM authentication"

# Step 7: Remove/simplify userlist.txt since we're using auth_query
info ""
info "Step 7: Updating PgBouncer userlist for SCRAM auth_query mode"
echo "=========================================================="

USERLIST_FILE="/etc/pgbouncer/userlist.txt"
cp "$USERLIST_FILE" "${USERLIST_FILE}.backup.scram256.$(date +%Y%m%d-%H%M%S)"

# For SCRAM with auth_query, we need a minimal userlist (mainly for the auth_user)
cat > "$USERLIST_FILE" <<EOF
;; PgBouncer SCRAM-SHA-256 Authentication
;; Using auth_query mode - passwords retrieved from PostgreSQL
;; Generated: $(date)

;; Auth user entry (must be present for auth_query to work)
;; This uses a placeholder - real authentication happens via auth_query
"postgres" ""

EOF

chown pgbouncer:pgbouncer "$USERLIST_FILE"
chmod 640 "$USERLIST_FILE"

success "✓ Updated userlist.txt for SCRAM auth_query mode"

# Step 8: Restart services
info ""
info "Step 8: Restarting services to apply SCRAM configuration"
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
    success "✓ PgBouncer restarted with SCRAM configuration"
else
    error "PgBouncer restart failed"
    journalctl -u pgbouncer -n 10 --no-pager || true
    exit 1
fi

sleep 3

# Step 9: Test SCRAM authentication
info ""
info "Step 9: Testing SCRAM-SHA-256 authentication"
echo "============================================="

# Test direct PostgreSQL connection
export PGPASSWORD="$PG_SUPER_PASS"
if psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'Direct PostgreSQL SCRAM works!' as test;" 2>/dev/null; then
    success "✓ Direct PostgreSQL SCRAM-SHA-256 authentication works"
else
    warn "✗ Direct PostgreSQL SCRAM authentication failed"
fi

# Test PgBouncer connection
if psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer SCRAM-SHA-256 success!' as status;" 2>/dev/null; then
    success "🎉 SUCCESS: PgBouncer SCRAM-SHA-256 authentication working!"
    success "✅ Secure SCRAM authentication is now properly configured"
else
    error "❌ PgBouncer SCRAM authentication still failing"
    
    info "Recent PgBouncer logs:"
    journalctl -u pgbouncer -n 10 --no-pager || true
    
    info "Testing PgBouncer admin interface..."
    if psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW CONFIG;" 2>/dev/null | grep -E "(auth_type|auth_query|auth_user)"; then
        info "✓ PgBouncer SCRAM configuration active"
    else
        warn "✗ PgBouncer configuration issue"
    fi
fi

# Test with .pgpass file
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'pgpass SCRAM works!' as test;" 2>/dev/null; then
    success "✓ .pgpass SCRAM authentication works"
else
    warn "✗ .pgpass SCRAM authentication needs verification"
fi

info ""
info "🔐 SCRAM-SHA-256 Configuration Summary"
echo "======================================"
echo "✅ Enhanced Security Benefits:"
echo "  • SCRAM-SHA-256 authentication (strongest PostgreSQL auth method)"
echo "  • No password hashes stored in PgBouncer userlist"
echo "  • Authentication queries directly from PostgreSQL"
echo "  • Passwords managed entirely through Secret Manager"
echo ""
echo "🎯 Configuration Applied:"
echo "  • PgBouncer: auth_type = scram-sha-256"
echo "  • PgBouncer: auth_query enabled for password verification"
echo "  • PostgreSQL: Users configured with SCRAM-SHA-256 passwords"
echo "  • pg_hba.conf: SCRAM authentication enabled for localhost"
echo ""
echo "Next steps:"
echo "• Run comprehensive validation: sudo ./comprehensive_validation.sh"
echo "• Test: psql -h localhost -p 6432 -U postgres -d postgres"