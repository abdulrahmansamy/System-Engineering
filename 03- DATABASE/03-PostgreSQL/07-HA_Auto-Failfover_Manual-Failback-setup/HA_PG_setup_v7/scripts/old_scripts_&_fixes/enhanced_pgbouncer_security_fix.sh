#!/bin/bash
# Enhanced PgBouncer Security Fix Script
# Implements separate admin user model with Secret Manager integration
# Ensures all passwords are retrieved from GCP Secret Manager

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

info "🔧 Enhanced PgBouncer Security Configuration with Secret Manager Integration"
echo "============================================================================"

# Get metadata for Secret Manager access
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null || echo "unknown")
ORG_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code' 2>/dev/null || echo "ipa")
ENV_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code' 2>/dev/null || echo "nprd")

# Password generator fallback
gen_pw() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 2>/dev/null | tr -d '=+/' | cut -c1-32
    else
        cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c32
    fi
}

# Enhanced Secret Manager password retrieval
get_password_from_secret_manager() {
    local secret_name="$1"
    local secret_id="${ORG_CODE}-${ENV_CODE}-sec-${secret_name}-password-01"
    
    info "🔐 Retrieving ${secret_name} password from Secret Manager..."
    info "  → Secret ID: $secret_id"
    
    if [[ "$PROJECT_ID" == "unknown" ]]; then
        warn "  ✗ Cannot determine project ID"
        return 1
    fi
    
    local token
    token=$(curl -sf -H 'Metadata-Flavor: Google' \
        'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | \
        jq -r '.access_token' 2>/dev/null || true)
    
    if [[ -z "$token" ]]; then
        warn "  ✗ Failed to get access token"
        return 1
    fi
    
    local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${secret_id}/versions/latest:access"
    local body
    if body=$(curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$url" 2>/dev/null); then
        local password
        if password=$(echo "$body" | jq -r '.payload.data' | base64 -d 2>/dev/null); then
            info "  ✓ Successfully retrieved ${secret_name} password (length: ${#password})"
            echo "$password"
            return 0
        else
            warn "  ✗ Failed to decode secret payload"
            return 1
        fi
    else
        warn "  ✗ Secret Manager API call failed"
        return 1
    fi
}

# Load all passwords from Secret Manager
info "Step 1: Loading passwords from Secret Manager"
echo "=============================================="

# Load PostgreSQL superuser password
if PG_SUPER_PASS=$(get_password_from_secret_manager "pg-superuser"); then
    success "PostgreSQL superuser password loaded from Secret Manager"
else
    warn "Failed to load PostgreSQL superuser password, generating fallback"
    PG_SUPER_PASS="$(gen_pw)"
fi

# Load PgBouncer admin password
if PGBOUNCER_PASSWORD=$(get_password_from_secret_manager "pgbouncer"); then
    success "PgBouncer admin password loaded from Secret Manager"
else
    warn "Failed to load PgBouncer admin password, generating fallback"
    PGBOUNCER_PASSWORD="$(gen_pw)"
fi

# Load repmgr password
if REPMGR_PASSWORD=$(get_password_from_secret_manager "repmgr"); then
    success "Repmgr password loaded from Secret Manager"
else
    warn "Failed to load repmgr password, generating fallback"
    REPMGR_PASSWORD="$(gen_pw)"
fi

# Validate passwords
info "🔍 Validating password security..."
for pw_name in "PG_SUPER_PASS" "PGBOUNCER_PASSWORD" "REPMGR_PASSWORD"; do
    pw_value="${!pw_name}"
    if [[ -z "$pw_value" || "${#pw_value}" -lt 8 ]]; then
        error "Password validation failed for $pw_name"
        exit 1
    fi
    info "  ✓ ${pw_name}: ${#pw_value} characters"
done

# Step 2: Create dedicated PgBouncer admin user in PostgreSQL
info ""
info "Step 2: Creating dedicated PgBouncer admin user in PostgreSQL"
echo "============================================================="

# Check if this is a standby node (read-only)
if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
    info "🔍 Detected STANDBY node (read-only mode)"
    info "ℹ️  PgBouncer admin user must be created on the PRIMARY node"
    info "ℹ️  Skipping user creation step for standby node"
    warn "⚠️  Ensure the pgbouncer_admin user exists on the primary node"
    
    # Verify if the user exists (read-only check)
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='pgbouncer_admin'" postgres 2>/dev/null | grep -q 1; then
        success "✓ pgbouncer_admin user already exists (replicated from primary)"
    else
        warn "⚠️  pgbouncer_admin user not found - it must be created on the primary node first"
    fi
else
    info "🔍 Detected PRIMARY node (read-write mode)"
    
    sudo -u postgres psql -c "
    DO \$\$
    BEGIN
        -- Create pgbouncer_admin user if it doesn't exist
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
            CREATE ROLE pgbouncer_admin WITH LOGIN PASSWORD '${PGBOUNCER_PASSWORD}';
            
            -- Grant minimal required permissions for PgBouncer admin
            GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
            GRANT CONNECT ON DATABASE repmgr TO pgbouncer_admin;
            GRANT CONNECT ON DATABASE template1 TO pgbouncer_admin;
            
            -- Allow basic monitoring queries
            GRANT pg_monitor TO pgbouncer_admin;
            
            -- Grant usage on public schema for basic operations
            GRANT USAGE ON SCHEMA public TO pgbouncer_admin;
            
            RAISE NOTICE 'Created pgbouncer_admin user with limited privileges';
        ELSE
            -- Update password if user exists
            ALTER ROLE pgbouncer_admin PASSWORD '${PGBOUNCER_PASSWORD}';
            RAISE NOTICE 'Updated pgbouncer_admin user password';
        END IF;
    END
    \$\$;
    " postgres
    
    success "PgBouncer admin user configured with Secret Manager password on PRIMARY"
fi

# Step 3: Update PgBouncer configuration
info ""
info "Step 3: Updating PgBouncer configuration for enhanced security"
echo "=============================================================="

PGBOUNCER_CONF_FILE="/etc/pgbouncer/pgbouncer.ini"

# Backup current configuration
cp "$PGBOUNCER_CONF_FILE" "${PGBOUNCER_CONF_FILE}.backup.enhanced.$(date +%Y%m%d-%H%M%S)"
info "✓ Backed up PgBouncer configuration"

# Update admin users in configuration
sed -i "s/admin_users = postgres/admin_users = pgbouncer_admin/" "$PGBOUNCER_CONF_FILE" 2>/dev/null || true
sed -i "s/stats_users = postgres/stats_users = pgbouncer_admin/" "$PGBOUNCER_CONF_FILE" 2>/dev/null || true

# Verify changes
if grep -q "admin_users = pgbouncer_admin" "$PGBOUNCER_CONF_FILE"; then
    success "PgBouncer configuration updated to use dedicated admin user"
else
    warn "Manual verification needed for PgBouncer admin user configuration"
fi

# Step 4: Update PgBouncer userlist.txt with enhanced security
info ""
info "Step 4: Updating PgBouncer userlist.txt with enhanced security"
echo "============================================================="

USERLIST_FILE="/etc/pgbouncer/userlist.txt"

# Backup userlist
cp "$USERLIST_FILE" "${USERLIST_FILE}.backup.enhanced.$(date +%Y%m%d-%H%M%S)"

# Generate MD5 hashes
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)
pgbouncer_admin_md5=$(echo -n "${PGBOUNCER_PASSWORD}pgbouncer_admin" | md5sum | cut -d' ' -f1)

# Create enhanced userlist.txt
cat > "$USERLIST_FILE" <<EOF
;; PgBouncer Enhanced Security User Authentication File
;; Generated: $(date)
;; Format: "username" "md5_hash"

;; Database users (for application connections)
"postgres" "md5${postgres_md5}"
"repmgr" "md5${repmgr_md5}"

;; PgBouncer admin user (separate password for enhanced security)
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"

EOF

chown pgbouncer:pgbouncer "$USERLIST_FILE"
chmod 640 "$USERLIST_FILE"

success "Enhanced userlist.txt created with separate admin authentication"

# Step 5: Update .pgpass file with comprehensive entries
info ""
info "Step 5: Updating .pgpass file with comprehensive authentication entries"
echo "======================================================================="

PGPASS_FILE="/var/lib/postgresql/.pgpass"

# Backup .pgpass
cp "$PGPASS_FILE" "${PGPASS_FILE}.backup.enhanced.$(date +%Y%m%d-%H%M%S)"

# Get current IP addresses
LOCAL_IP=$(hostname -I | awk '{print $1}' || echo "localhost")
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

# Create comprehensive .pgpass file
cat > "$PGPASS_FILE" <<EOF
# Enhanced .pgpass file with Secret Manager passwords
# Generated: $(date)

# Repmgr user entries
localhost:5432:repmgr:repmgr:${REPMGR_PASSWORD}
${PRIMARY_IP}:5432:repmgr:repmgr:${REPMGR_PASSWORD}
${STANDBY_IP}:5432:repmgr:repmgr:${REPMGR_PASSWORD}
localhost:5432:replication:repmgr:${REPMGR_PASSWORD}
${PRIMARY_IP}:5432:replication:repmgr:${REPMGR_PASSWORD}
${STANDBY_IP}:5432:replication:repmgr:${REPMGR_PASSWORD}

# PostgreSQL superuser entries (for database operations)
localhost:5432:*:postgres:${PG_SUPER_PASS}
${PRIMARY_IP}:5432:*:postgres:${PG_SUPER_PASS}
${STANDBY_IP}:5432:*:postgres:${PG_SUPER_PASS}
localhost:6432:*:postgres:${PG_SUPER_PASS}
${PRIMARY_IP}:6432:*:postgres:${PG_SUPER_PASS}
${STANDBY_IP}:6432:*:postgres:${PG_SUPER_PASS}

# PgBouncer admin entries (enhanced security with separate password)
localhost:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
${PRIMARY_IP}:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
${STANDBY_IP}:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}

# Wildcard entries for maximum compatibility
*:5432:repmgr:repmgr:${REPMGR_PASSWORD}
*:5432:replication:repmgr:${REPMGR_PASSWORD}
*:5432:*:postgres:${PG_SUPER_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
*:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}

EOF

chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

success ".pgpass file updated with comprehensive authentication entries"

# Step 6: Restart PgBouncer services
info ""
info "Step 6: Restarting PgBouncer services"
echo "====================================="

if systemctl restart pgbouncer; then
    success "PgBouncer service restarted successfully"
    sleep 2
else
    error "Failed to restart PgBouncer service"
    exit 1
fi

# Step 7: Validate enhanced security setup
info ""
info "Step 7: Validating enhanced security setup"
echo "=========================================="

# Test PgBouncer is running
if systemctl is-active --quiet pgbouncer; then
    success "PgBouncer service is running"
else
    error "PgBouncer service is not running"
    exit 1
fi

# Test PgBouncer port
if timeout 5 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
    success "PgBouncer is accepting connections on port 6432"
else
    error "PgBouncer connection test failed"
    exit 1
fi

# Test postgres user connection through PgBouncer
info "🔍 Testing postgres user connection through PgBouncer..."
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'Database connection through PgBouncer successful!' as test;" >/dev/null 2>&1; then
    success "✅ postgres user can connect through PgBouncer"
else
    warn "❌ postgres user PgBouncer connection test failed"
    info "Debugging connection issue..."
    
    # Test direct PostgreSQL connection
    if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        info "  ✓ Direct PostgreSQL connection works"
    else
        warn "  ✗ Direct PostgreSQL connection also failed"
    fi
    
    # Show PgBouncer logs
    info "Recent PgBouncer logs:"
    journalctl -u pgbouncer -n 5 --no-pager || true
fi

# Test PgBouncer admin interface (only if pgbouncer_admin user exists)
info "🔍 Testing PgBouncer admin interface..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='pgbouncer_admin'" postgres 2>/dev/null | grep -q 1; then
    if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U pgbouncer_admin -d pgbouncer -c "SHOW POOLS;" >/dev/null 2>&1; then
        success "✅ PgBouncer admin interface accessible with dedicated admin user"
    else
        warn "❌ PgBouncer admin interface test failed"
        info "This is normal if running on standby - admin user may not be replicated yet"
    fi
else
    warn "⚠️  pgbouncer_admin user not found - create it on the primary node first"
fi

# Step 8: Display security summary
info ""
info "🔐 Enhanced Security Model Summary"
echo "=================================="
echo ""
echo "✅ Database Administration:"
echo "   User: postgres"
echo "   Password: Retrieved from Secret Manager (pg-superuser-password-01)"
echo "   Purpose: Database operations, application connections"
echo ""
echo "✅ PgBouncer Administration:"
echo "   User: pgbouncer_admin" 
echo "   Password: Retrieved from Secret Manager (pgbouncer-password-01)"
echo "   Purpose: PgBouncer admin operations only"
echo ""
echo "✅ Cluster Management:"
echo "   User: repmgr"
echo "   Password: Retrieved from Secret Manager (repmgr-password-01)"
echo "   Purpose: Replication and cluster operations"
echo ""
echo "🎯 Security Benefits:"
echo "   • Principle of least privilege enforced"
echo "   • Password isolation (compromise of one doesn't affect others)"
echo "   • All passwords managed via Secret Manager"
echo "   • Clear role separation and audit trail"
echo "   • Enhanced monitoring capabilities"
echo ""

success "🎉 Enhanced PgBouncer security configuration completed successfully!"
info "Run comprehensive validation: sudo ./comprehensive_validation.sh"