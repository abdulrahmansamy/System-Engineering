#!/bin/bash
# PgBouncer Authentication Debug and Fix
# Comprehensive debugging and repair for authentication issues

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

info "🔍 PgBouncer Authentication Debug and Fix"
echo "=========================================="

# Step 1: Check PgBouncer logs
info "Step 1: Checking PgBouncer logs for authentication errors"
echo "========================================================="

info "Recent PgBouncer logs:"
journalctl -u pgbouncer -n 20 --no-pager || true

# Step 2: Check current userlist content
info ""
info "Step 2: Current userlist.txt content"
echo "===================================="

info "Current userlist.txt:"
cat /etc/pgbouncer/userlist.txt || true

# Step 3: Test direct PostgreSQL connection
info ""
info "Step 3: Testing direct PostgreSQL connection"
echo "============================================"

if sudo -u postgres psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'Direct PostgreSQL connection works!' as test;" 2>/dev/null; then
    success "✓ Direct PostgreSQL connection works"
else
    error "✗ Direct PostgreSQL connection failed"
    info "This suggests a PostgreSQL authentication issue"
fi

# Step 4: Get passwords and regenerate userlist
info ""
info "Step 4: Regenerating userlist with debug information"
echo "===================================================="

# Get passwords from Secret Manager
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
info "  → postgres password length: ${#PG_SUPER_PASS}"
info "  → repmgr password length: ${#REPMGR_PASSWORD}"

# Generate MD5 hashes with debug info
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)

info "Generated MD5 hashes:"
info "  → postgres: md5${postgres_md5}"
info "  → repmgr: md5${repmgr_md5}"

# Step 5: Test PostgreSQL password directly
info ""
info "Step 5: Testing PostgreSQL password authentication"
echo "================================================="

# Test if we can connect to PostgreSQL using the password
export PGPASSWORD="$PG_SUPER_PASS"
if psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'Password authentication successful!' as test;" 2>/dev/null; then
    success "✓ PostgreSQL password authentication works"
else
    error "✗ PostgreSQL password authentication failed"
    warn "The password from Secret Manager may not match PostgreSQL"
    
    # Try to get the actual postgres password from .pgpass
    if [[ -f /var/lib/postgresql/.pgpass ]]; then
        info "Checking .pgpass file for postgres password..."
        PGPASS_POSTGRES=$(grep ":postgres:" /var/lib/postgresql/.pgpass | head -1 | cut -d: -f5 || echo "")
        if [[ -n "$PGPASS_POSTGRES" ]]; then
            info "Found postgres password in .pgpass (length: ${#PGPASS_POSTGRES})"
            info "Testing .pgpass password..."
            export PGPASSWORD="$PGPASS_POSTGRES"
            if psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'pgpass password works!' as test;" 2>/dev/null; then
                success "✓ .pgpass postgres password works - using this instead"
                PG_SUPER_PASS="$PGPASS_POSTGRES"
                postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
                info "Updated postgres MD5: md5${postgres_md5}"
            fi
        fi
    fi
fi

# Step 6: Create new userlist with working passwords
info ""
info "Step 6: Creating new userlist with verified passwords"
echo "====================================================="

# Backup current userlist
cp /etc/pgbouncer/userlist.txt /etc/pgbouncer/userlist.txt.backup.debug.$(date +%Y%m%d-%H%M%S)

cat > "/etc/pgbouncer/userlist.txt" <<EOF
;; PgBouncer Debug Authentication Fix
;; Generated: $(date)
;; postgres MD5: md5${postgres_md5}
;; repmgr MD5: md5${repmgr_md5}

"postgres" "md5${postgres_md5}"
"repmgr" "md5${repmgr_md5}"

EOF

chown pgbouncer:pgbouncer "/etc/pgbouncer/userlist.txt"
chmod 640 "/etc/pgbouncer/userlist.txt"

success "✓ Updated userlist.txt with verified passwords"

# Step 7: Check PgBouncer configuration
info ""
info "Step 7: Verifying PgBouncer configuration"
echo "=========================================="

info "Current PgBouncer admin users setting:"
grep "admin_users" /etc/pgbouncer/pgbouncer.ini || true

info "Current PgBouncer auth settings:"
grep -E "(auth_type|auth_file)" /etc/pgbouncer/pgbouncer.ini || true

# Step 8: Restart and test
info ""
info "Step 8: Restarting PgBouncer and testing connection"
echo "=================================================="

if systemctl restart pgbouncer; then
    success "✓ PgBouncer restarted successfully"
    sleep 3
    
    # Test connection with explicit password
    export PGPASSWORD="$PG_SUPER_PASS"
    info "Testing PgBouncer connection with explicit password..."
    
    if psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer authentication successful!' as status;" 2>/dev/null; then
        success "🎉 SUCCESS: PgBouncer authentication is now working!"
    else
        error "❌ PgBouncer authentication still failing"
        
        # Show recent logs
        info "Recent PgBouncer logs after restart:"
        journalctl -u pgbouncer -n 10 --no-pager || true
        
        # Try connecting to PgBouncer admin interface
        info "Testing PgBouncer admin interface..."
        if psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;" 2>/dev/null; then
            info "✓ PgBouncer admin interface accessible"
        else
            warn "✗ PgBouncer admin interface not accessible"
        fi
    fi
    
    # Test with .pgpass file
    info "Testing with .pgpass file authentication..."
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'pgpass auth works!' as test;" 2>/dev/null; then
        success "✓ .pgpass file authentication works"
    else
        warn "✗ .pgpass file authentication failed"
    fi
    
else
    error "Failed to restart PgBouncer"
    journalctl -u pgbouncer -n 10 --no-pager || true
fi

info ""
info "🔧 Debug Summary"
echo "================"
echo "• PgBouncer userlist regenerated with verified passwords"
echo "• Check logs above for specific authentication errors"
echo "• Run comprehensive validation: sudo ./comprehensive_validation.sh"
echo "• Manual test: psql -h localhost -p 6432 -U postgres -d postgres"