#!/bin/bash
# SCRAM Authentication Fix for PgBouncer
# Fixes the SCRAM vs MD5 authentication mismatch

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

info "🔧 SCRAM Authentication Fix for PgBouncer"
echo "=========================================="

info "Problem identified: PostgreSQL is using SCRAM-SHA-256, but PgBouncer is configured for MD5"
info "Solution: Configure PostgreSQL to accept both SCRAM and MD5 authentication"

# Step 1: Check current PostgreSQL password encryption
info ""
info "Step 1: Checking PostgreSQL authentication settings"
echo "=================================================="

current_encryption=$(sudo -u postgres psql -Atqc "SHOW password_encryption;" 2>/dev/null || echo "unknown")
info "Current password_encryption: $current_encryption"

# Step 2: Check pg_hba.conf authentication method
info ""
info "Step 2: Checking pg_hba.conf authentication methods"
echo "=================================================="

PG_HBA="/etc/postgresql/17/main/pg_hba.conf"
if [[ -f "$PG_HBA" ]]; then
    info "Current authentication methods in pg_hba.conf:"
    grep -E "^(local|host)" "$PG_HBA" | grep -v "^#" || true
else
    warn "pg_hba.conf not found at expected location"
fi

# Step 3: Fix PostgreSQL authentication for PgBouncer compatibility
info ""
info "Step 3: Configuring PostgreSQL for PgBouncer compatibility"
echo "==========================================================="

# Get passwords from Secret Manager
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null)
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')

# Get postgres password
PG_SECRET="ipa-nprd-sec-pg-superuser-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
PG_SUPER_PASS=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

info "✓ Retrieved postgres password from Secret Manager"

# Check if this is primary or standby
if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
    NODE_TYPE="primary"
    info "Detected PRIMARY node - can modify users"
    
    # On primary: recreate postgres user with MD5 password for PgBouncer compatibility
    info "Setting postgres user password for MD5 compatibility..."
    
    # Set password_encryption to md5 temporarily
    sudo -u postgres psql -c "SET password_encryption = 'md5';" postgres 2>/dev/null || true
    
    # Update postgres user password with MD5 encryption
    if sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$PG_SUPER_PASS';" postgres 2>/dev/null; then
        success "✓ Updated postgres user password for MD5 compatibility"
    else
        warn "Could not update postgres password (might be read-only or permission issue)"
    fi
    
    # Reset password_encryption to default
    sudo -u postgres psql -c "SET password_encryption = 'scram-sha-256';" postgres 2>/dev/null || true
    
else
    NODE_TYPE="standby"
    info "Detected STANDBY node - cannot modify users (read-only)"
fi

# Step 4: Update pg_hba.conf for mixed authentication
info ""
info "Step 4: Updating pg_hba.conf for mixed authentication support"
echo "============================================================="

# Backup pg_hba.conf
cp "$PG_HBA" "${PG_HBA}.backup.scram.$(date +%Y%m%d-%H%M%S)"

# Add MD5 authentication entries for PgBouncer
if ! grep -q "# PgBouncer MD5 compatibility" "$PG_HBA"; then
    info "Adding MD5 authentication entries for PgBouncer..."
    
    cat >> "$PG_HBA" <<EOF

# PgBouncer MD5 compatibility entries
# These allow MD5 authentication for PgBouncer connections
host    all             postgres        127.0.0.1/32            md5
host    all             postgres        ::1/128                 md5
host    all             repmgr          127.0.0.1/32            md5
host    all             repmgr          ::1/128                 md5
EOF

    success "✓ Added MD5 authentication entries to pg_hba.conf"
else
    info "MD5 authentication entries already exist"
fi

# Step 5: Configure PgBouncer for proper authentication
info ""
info "Step 5: Configuring PgBouncer authentication settings"
echo "===================================================="

# Update PgBouncer config to use proper authentication
PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"
cp "$PGBOUNCER_CONF" "${PGBOUNCER_CONF}.backup.scram.$(date +%Y%m%d-%H%M%S)"

# Ensure auth_type is set to md5
sed -i 's/auth_type = .*/auth_type = md5/' "$PGBOUNCER_CONF"

success "✓ PgBouncer configured for MD5 authentication"

# Step 6: Regenerate userlist with proper MD5 hashes
info ""
info "Step 6: Regenerating PgBouncer userlist with proper MD5 hashes"
echo "=============================================================="

# Get repmgr password too
REPMGR_SECRET="ipa-nprd-sec-repmgr-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${REPMGR_SECRET}/versions/latest:access"
REPMGR_PASSWORD=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

# Generate proper MD5 hashes
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)

cat > "/etc/pgbouncer/userlist.txt" <<EOF
;; PgBouncer SCRAM Fix Authentication File
;; Generated: $(date)
;; Compatible with MD5 authentication

"postgres" "md5${postgres_md5}"
"repmgr" "md5${repmgr_md5}"

EOF

chown pgbouncer:pgbouncer "/etc/pgbouncer/userlist.txt"
chmod 640 "/etc/pgbouncer/userlist.txt"

success "✓ Updated userlist.txt with proper MD5 hashes"

# Step 7: Restart services
info ""
info "Step 7: Restarting services to apply changes"
echo "============================================"

# Reload PostgreSQL configuration
if systemctl reload postgresql; then
    success "✓ PostgreSQL configuration reloaded"
else
    warn "PostgreSQL reload failed, trying restart..."
    systemctl restart postgresql
fi

sleep 2

# Restart PgBouncer
if systemctl restart pgbouncer; then
    success "✓ PgBouncer restarted"
else
    error "PgBouncer restart failed"
    exit 1
fi

sleep 3

# Step 8: Test the fix
info ""
info "Step 8: Testing SCRAM authentication fix"
echo "========================================"

# Test direct PostgreSQL connection with MD5
export PGPASSWORD="$PG_SUPER_PASS"
if psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'Direct PostgreSQL MD5 auth works!' as test;" 2>/dev/null; then
    success "✓ Direct PostgreSQL connection with MD5 works"
else
    warn "✗ Direct PostgreSQL MD5 authentication still failing"
fi

# Test PgBouncer connection
if psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer SCRAM fix successful!' as status;" 2>/dev/null; then
    success "🎉 SUCCESS: PgBouncer SCRAM authentication fix worked!"
    success "✅ postgres user can now connect through PgBouncer"
else
    error "❌ PgBouncer authentication still failing"
    info "Recent PgBouncer logs:"
    journalctl -u pgbouncer -n 5 --no-pager || true
fi

# Test with .pgpass file
if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'pgpass works!' as test;" 2>/dev/null; then
    success "✓ .pgpass file authentication works"
else
    warn "✗ .pgpass file authentication still issues"
fi

info ""
info "🔧 SCRAM Fix Summary"
echo "===================="
echo "• PostgreSQL configured for MD5 compatibility"
echo "• pg_hba.conf updated with MD5 entries"
echo "• PgBouncer userlist regenerated with proper MD5 hashes"
echo "• Both services restarted"
echo ""
echo "Next steps:"
echo "• Run comprehensive validation: sudo ./comprehensive_validation.sh"
echo "• Manual test: psql -h localhost -p 6432 -U postgres -d postgres"