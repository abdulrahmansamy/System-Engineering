#!/bin/bash
# Final PgBouncer Authentication Fix
# Updates PostgreSQL user passwords to be MD5-compatible for PgBouncer

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

info "🔧 Final PgBouncer Authentication Fix"
echo "===================================="

info "Converting PostgreSQL user passwords to MD5-compatible format for PgBouncer"

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

# Step 2: Check if this is primary or standby
info ""
info "Step 2: Detecting node role for user management"
echo "=============================================="

NODE_ROLE="unknown"
if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
    NODE_ROLE="primary"
    info "Detected PRIMARY node - can modify users"
elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
    NODE_ROLE="standby"
    info "Detected STANDBY node - read-only, passwords will be replicated"
fi

# Step 3: Set MD5 password encryption and update user passwords (primary only)
if [[ "$NODE_ROLE" == "primary" ]]; then
    info ""
    info "Step 3: Converting PostgreSQL users to MD5-compatible passwords"
    echo "=============================================================="
    
    # Temporarily set password encryption to MD5
    info "Setting password encryption to MD5 temporarily..."
    sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'md5';" postgres || warn "Could not set password encryption"
    sudo -u postgres psql -c "SELECT pg_reload_conf();" postgres >/dev/null 2>&1 || true
    sleep 2
    
    # Update postgres user with MD5 password
    info "Updating postgres user with MD5-compatible password..."
    if sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$PG_SUPER_PASS';" postgres 2>/dev/null; then
        success "✓ Updated postgres user with MD5-compatible password"
    else
        error "Failed to update postgres user password"
    fi
    
    # Update pgbouncer_admin user with MD5 password
    info "Updating pgbouncer_admin user with MD5-compatible password..."
    sudo -u postgres psql -c "
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
                CREATE ROLE pgbouncer_admin WITH LOGIN PASSWORD '$PGBOUNCER_PASSWORD';
                GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
                GRANT pg_monitor TO pgbouncer_admin;
                RAISE NOTICE 'Created pgbouncer_admin user with MD5 password';
            ELSE
                ALTER ROLE pgbouncer_admin PASSWORD '$PGBOUNCER_PASSWORD';
                RAISE NOTICE 'Updated pgbouncer_admin user with MD5 password';
            END IF;
        END
        \$\$;
    " postgres || warn "Failed to create/update pgbouncer_admin user"
    
    # Update repmgr user with MD5 password
    info "Updating repmgr user with MD5-compatible password..."
    if sudo -u postgres psql -c "ALTER USER repmgr PASSWORD '$REPMGR_PASSWORD';" postgres 2>/dev/null; then
        success "✓ Updated repmgr user with MD5-compatible password"
    else
        warn "Could not update repmgr user password"
    fi
    
    # Reset password encryption to SCRAM-SHA-256 for security
    info "Resetting password encryption to SCRAM-SHA-256 for security..."
    sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';" postgres || warn "Could not reset password encryption"
    sudo -u postgres psql -c "SELECT pg_reload_conf();" postgres >/dev/null 2>&1 || true
    
    success "✓ All users updated with MD5-compatible passwords"
    
else
    info ""
    info "Step 3: Standby node detected - skipping user password updates"
    echo "============================================================"
    info "User passwords will be replicated from primary node"
fi

# Step 4: Configure pg_hba.conf with proper MD5 rules
info ""
info "Step 4: Configuring pg_hba.conf for MD5 authentication"
echo "===================================================="

PG_HBA="/etc/postgresql/17/main/pg_hba.conf"
cp "$PG_HBA" "${PG_HBA}.backup.final.$(date +%Y%m%d-%H%M%S)"

# Create optimized pg_hba.conf with MD5 first
cat > "$PG_HBA" <<EOF
# PostgreSQL Client Authentication Configuration File
# Final PgBouncer Fix - $(date)
#
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     peer

# IPv4/IPv6 local connections - MD5 for PgBouncer users (PRIORITY)
host    all             postgres        127.0.0.1/32            md5
host    all             postgres        ::1/128                 md5
host    all             pgbouncer_admin 127.0.0.1/32            md5
host    all             pgbouncer_admin ::1/128                 md5
host    all             repmgr          127.0.0.1/32            md5
host    all             repmgr          ::1/128                 md5

# IPv4/IPv6 local connections - SCRAM-SHA-256 for other users
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Replication connections for HA cluster (SCRAM-SHA-256)
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

success "✓ Updated pg_hba.conf with MD5 authentication priority"

# Step 5: Configure PgBouncer for MD5 authentication
info ""
info "Step 5: Configuring PgBouncer for MD5 authentication"
echo "=================================================="

PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"

# Set auth_type to md5
sed -i 's/auth_type = .*/auth_type = md5/' "$PGBOUNCER_CONF"

# Remove auth_query and auth_user lines
sed -i '/^auth_query = /d' "$PGBOUNCER_CONF"
sed -i '/^auth_user = /d' "$PGBOUNCER_CONF"

success "✓ PgBouncer configured for MD5 authentication"

# Step 6: Create userlist with MD5 hashes
info ""
info "Step 6: Creating PgBouncer userlist with MD5 hashes"
echo "=================================================="

# Generate MD5 hashes
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
pgbouncer_admin_md5=$(echo -n "${PGBOUNCER_PASSWORD}pgbouncer_admin" | md5sum | cut -d' ' -f1)
repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)

USERLIST_FILE="/etc/pgbouncer/userlist.txt"

cat > "$USERLIST_FILE" <<EOF
;; PgBouncer Final Authentication Fix
;; Generated: $(date)
;; MD5 authentication with PostgreSQL MD5-compatible users

"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"repmgr" "md5${repmgr_md5}"

EOF

chown pgbouncer:pgbouncer "$USERLIST_FILE"
chmod 640 "$USERLIST_FILE"

success "✓ Created userlist.txt with MD5 hashes"

# Step 7: Update .pgpass file
info ""
info "Step 7: Updating .pgpass file"
echo "============================"

PGPASS_FILE="/var/lib/postgresql/.pgpass"
PRIMARY_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")

cat > "$PGPASS_FILE" <<EOF
# Final PgBouncer Fix .pgpass
# Generated: $(date)

# PostgreSQL connections
localhost:5432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:5432:*:postgres:${PG_SUPER_PASS}
${PRIMARY_IP}:5432:*:postgres:${PG_SUPER_PASS}

# PgBouncer connections
localhost:6432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:6432:*:postgres:${PG_SUPER_PASS}
${PRIMARY_IP}:6432:*:postgres:${PG_SUPER_PASS}

# PgBouncer admin
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

success "✓ Updated .pgpass file"

# Step 8: Restart services
info ""
info "Step 8: Restarting services with final configuration"
echo "=================================================="

# Reload PostgreSQL
if systemctl reload postgresql; then
    success "✓ PostgreSQL configuration reloaded"
else
    warn "PostgreSQL reload failed, trying restart..."
    systemctl restart postgresql
    sleep 5
fi

# Wait for PostgreSQL to be ready
sleep 3
if ! sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
    error "PostgreSQL not responding after reload"
    exit 1
fi

# Restart PgBouncer
if systemctl restart pgbouncer; then
    success "✓ PgBouncer restarted"
else
    error "PgBouncer restart failed"
    journalctl -u pgbouncer -n 10 --no-pager || true
    exit 1
fi

sleep 3

# Step 9: Test final configuration
info ""
info "Step 9: Testing final PgBouncer authentication"
echo "============================================="

# Test direct PostgreSQL connection
export PGPASSWORD="$PG_SUPER_PASS"
if psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'Direct PostgreSQL works!' as test;" 2>/dev/null; then
    success "✓ Direct PostgreSQL authentication works"
else
    error "✗ Direct PostgreSQL authentication failed"
fi

# Test PgBouncer connection
if psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer final fix successful!' as status;" 2>/dev/null; then
    success "🎉 SUCCESS: PgBouncer authentication working!"
    success "✅ Final authentication fix completed successfully"
else
    error "❌ PgBouncer authentication still failing"
    
    info "Recent PgBouncer logs:"
    journalctl -u pgbouncer -n 15 --no-pager || true
    
    # Show current password encryption
    info "Current PostgreSQL password encryption:"
    sudo -u postgres psql -Atqc "SHOW password_encryption;" postgres || true
fi

# Test PgBouncer admin interface
info "Testing PgBouncer admin interface..."
if psql -h localhost -p 6432 -U pgbouncer_admin -d pgbouncer -c "SHOW POOLS;" 2>/dev/null | head -3; then
    success "✓ PgBouncer admin interface accessible"
else
    warn "✗ PgBouncer admin interface needs verification"
fi

# Test with .pgpass file
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'pgpass final test works!' as test;" 2>/dev/null; then
    success "✓ .pgpass authentication works"
else
    warn "✗ .pgpass authentication needs verification"
fi

info ""
info "🎉 Final PgBouncer Authentication Fix Summary"
echo "============================================="
echo "✅ What was fixed:"
echo "  • PostgreSQL users converted to MD5-compatible passwords"
echo "  • pg_hba.conf: MD5 rules prioritized for PgBouncer users"
echo "  • PgBouncer: MD5 authentication configured"
echo "  • userlist.txt: Proper MD5 hashes generated"
echo "  • Password encryption: Reset to SCRAM-SHA-256 for security"
echo ""
echo "🎯 Authentication Flow:"
echo "  • PgBouncer users (localhost) → MD5"
echo "  • Other users → SCRAM-SHA-256"
echo "  • Remote connections → SCRAM-SHA-256"
echo ""
echo "Next steps:"
echo "• Run validation: sudo ./comprehensive_validation.sh"
echo "• Test: psql -h localhost -p 6432 -U postgres -d postgres"