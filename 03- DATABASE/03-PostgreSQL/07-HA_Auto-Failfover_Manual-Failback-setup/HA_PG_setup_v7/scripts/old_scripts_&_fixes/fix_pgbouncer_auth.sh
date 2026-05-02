#!/bin/bash
# PgBouncer Authentication Fixer
# This script diagnoses and fixes PgBouncer authentication issues

set -euo pipefail

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "🔧 PgBouncer Authentication Diagnostic and Fix"
echo "================================================"

# Check PostgreSQL postgres user password
info "Step 1: Checking PostgreSQL postgres user setup..."
if sudo -u postgres psql -c "SELECT rolname FROM pg_roles WHERE rolname='postgres';" postgres >/dev/null 2>&1; then
    info "✓ PostgreSQL postgres user exists"
    
    # Get the actual password hash from PostgreSQL
    POSTGRES_HASH=$(sudo -u postgres psql -Atqc "SELECT rolpassword FROM pg_authid WHERE rolname='postgres';" postgres 2>/dev/null || echo "")
    
    if [[ -n "$POSTGRES_HASH" ]]; then
        info "✓ PostgreSQL postgres user has a password set"
    else
        warn "✗ PostgreSQL postgres user has no password - setting one..."
        # Generate a secure password
        NEW_PG_PASS=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)
        sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$NEW_PG_PASS';" postgres
        info "✓ Set new password for postgres user"
        export PG_SUPER_PASS="$NEW_PG_PASS"
    fi
else
    error "✗ Cannot access PostgreSQL"
    exit 1
fi

# Check .pgpass file
info "Step 2: Checking .pgpass file..."
PGPASS_FILE="/var/lib/postgresql/.pgpass"

if [[ -f "$PGPASS_FILE" ]]; then
    info "✓ .pgpass file exists"
    
    # Check permissions
    PERMS=$(stat -c %a "$PGPASS_FILE")
    if [[ "$PERMS" == "600" ]]; then
        info "✓ .pgpass permissions are correct (600)"
    else
        warn "✗ .pgpass permissions are wrong ($PERMS), fixing..."
        chmod 600 "$PGPASS_FILE"
        chown postgres:postgres "$PGPASS_FILE"
    fi
else
    warn "✗ .pgpass file doesn't exist, creating..."
    touch "$PGPASS_FILE"
    chmod 600 "$PGPASS_FILE"
    chown postgres:postgres "$PGPASS_FILE"
fi

# Get current postgres password from Secret Manager or bootstrap log
info "Step 3: Getting postgres password from Secret Manager..."
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null || echo "unknown")
ORG_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code' 2>/dev/null || echo "ipa")
ENV_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code' 2>/dev/null || echo "nprd")

if [[ "$PROJECT_ID" != "unknown" ]]; then
    TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token' 2>/dev/null || echo "")
    
    if [[ -n "$TOKEN" ]]; then
        PG_SECRET="${ORG_CODE}-${ENV_CODE}-sec-pg-superuser-password-01"
        URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
        
        if SECRET_DATA=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" 2>/dev/null); then
            if PG_SUPER_PASS=$(echo "$SECRET_DATA" | jq -r '.payload.data' | base64 -d 2>/dev/null); then
                info "✓ Retrieved postgres password from Secret Manager"
            fi
        fi
    fi
fi

# If we still don't have the password, check bootstrap logs
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    warn "Could not get password from Secret Manager, checking bootstrap logs..."
    if [[ -f "/var/log/pg-bootstrap/bootstrap.log" ]]; then
        # This is just for diagnostic - we'll generate a new one
        warn "Please run the bootstrap script again or set a new password manually"
    fi
    
    # Generate a new password as fallback
    PG_SUPER_PASS=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)
    sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$PG_SUPER_PASS';" postgres
    info "✓ Generated and set new postgres password"
fi

# Update .pgpass file
info "Step 4: Updating .pgpass file..."
cat > "$PGPASS_FILE" << EOF
# PostgreSQL HA .pgpass file
# Format: hostname:port:database:username:password

# Direct PostgreSQL connections
localhost:5432:*:postgres:$PG_SUPER_PASS
$(hostname -I | awk '{print $1}'):5432:*:postgres:$PG_SUPER_PASS

# PgBouncer connections  
localhost:6432:*:postgres:$PG_SUPER_PASS
$(hostname -I | awk '{print $1}'):6432:*:postgres:$PG_SUPER_PASS

# Repmgr connections (if different password)
localhost:5432:repmgr:repmgr:$PG_SUPER_PASS
$(hostname -I | awk '{print $1}'):5432:repmgr:repmgr:$PG_SUPER_PASS
EOF

chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"
info "✓ Updated .pgpass file with current passwords"

# Update PgBouncer userlist.txt
info "Step 5: Updating PgBouncer userlist.txt..."
USERLIST_FILE="/etc/pgbouncer/userlist.txt"

if [[ -f "$USERLIST_FILE" ]]; then
    # Generate MD5 hash for PgBouncer
    POSTGRES_MD5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
    
    cat > "$USERLIST_FILE" << EOF
;; PgBouncer user authentication file
;; Format: "username" "md5_hash"

"postgres" "md5${POSTGRES_MD5}"
"pgbouncer_admin" "md5${POSTGRES_MD5}"
"pgbouncer_stats" "md5${POSTGRES_MD5}"
EOF

    chown pgbouncer:pgbouncer "$USERLIST_FILE"
    chmod 640 "$USERLIST_FILE"
    info "✓ Updated PgBouncer userlist.txt with correct password hashes"
else
    warn "✗ PgBouncer userlist.txt not found at $USERLIST_FILE"
fi

# Restart PgBouncer to reload configuration
info "Step 6: Restarting PgBouncer..."
if systemctl restart pgbouncer; then
    info "✓ PgBouncer restarted successfully"
    sleep 2
else
    error "✗ Failed to restart PgBouncer"
fi

# Test connections
info "Step 7: Testing connections..."

# Test direct PostgreSQL
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 5432 -U postgres -d postgres -c "SELECT 'Direct PostgreSQL connection working' as test;" >/dev/null 2>&1; then
    info "✓ Direct PostgreSQL connection working"
else
    warn "✗ Direct PostgreSQL connection failed"
fi

# Test PgBouncer
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer connection working' as test;" >/dev/null 2>&1; then
    info "✅ PgBouncer connection working!"
else
    warn "✗ PgBouncer connection still failing"
    
    # Show diagnostic info
    echo ""
    warn "Diagnostic information:"
    echo "PgBouncer status: $(systemctl is-active pgbouncer || echo 'inactive')"
    echo "PgBouncer logs (last 10 lines):"
    journalctl -u pgbouncer -n 10 --no-pager || echo "Could not get logs"
fi

echo ""
info "🎉 PgBouncer authentication fix completed!"
info "You can now run the validation script again: sudo ./comprehensive_validation.sh"

# Quick fix for PgBouncer authentication issues
# This script synchronizes passwords between PostgreSQL and PgBouncer

set -euo pipefail

echo "🔧 PgBouncer Authentication Fix Script"
echo "======================================"

# Get the actual passwords from Secret Manager (same as bootstrap script)
get_secret_enhanced() {
    local secret_id="$1"
    echo "🔐 Retrieving secret: $secret_id"
    
    local token
    token=$(curl -sf -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | \
      jq -r '.access_token' 2>/dev/null || true)
    
    if [[ -z "$token" ]]; then 
        echo "✗ Failed to get access token for $secret_id"
        return 1
    fi
    
    local url="https://secretmanager.googleapis.com/v1/projects/ipa-nprd-svc-db-01/secrets/${secret_id}/versions/latest:access"
    local body
    if body=$(curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$url" 2>/dev/null); then
        local secret_value
        if secret_value=$(echo "$body" | jq -r '.payload.data' | base64 -d 2>/dev/null); then
            echo "$secret_value"
            return 0
        else
            echo "✗ Failed to decode secret payload"
            return 1
        fi
    else
        echo "✗ Secret Manager API call failed for $secret_id"
        return 1
    fi
}

# Get the passwords from Secret Manager
echo "📋 Loading passwords from Secret Manager..."
PG_SUPER_PASS=$(get_secret_enhanced "ipa-nprd-sec-pg-superuser-password-01")
PGBOUNCER_PASSWORD=$(get_secret_enhanced "ipa-nprd-sec-pgbouncer-password-01") 
REPMGR_PASSWORD=$(get_secret_enhanced "ipa-nprd-sec-repmgr-password-01")

echo "✅ Retrieved all passwords successfully"

# Check current PostgreSQL users and their auth methods
echo "🔍 Checking current PostgreSQL user authentication..."
sudo -u postgres psql -c "
SELECT usename, 
       CASE WHEN passwd IS NULL THEN 'no password'
            WHEN passwd LIKE 'SCRAM-SHA-256%' THEN 'SCRAM-SHA-256'
            WHEN passwd LIKE 'md5%' THEN 'MD5'
            ELSE 'unknown'
       END AS auth_method
FROM pg_shadow 
WHERE usename IN ('postgres', 'pgbouncer_admin', 'repmgr')
ORDER BY usename;
" postgres

echo ""
echo "🔧 Step 1: Reset PostgreSQL user passwords to MD5"

# Temporarily set password encryption to MD5
sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'md5';" postgres
sudo -u postgres psql -c "SELECT pg_reload_conf();" postgres
sleep 2

# Update users with MD5 passwords
echo "  → Updating postgres user..."
sudo -u postgres psql -c "ALTER ROLE postgres PASSWORD '$PG_SUPER_PASS';" postgres

echo "  → Updating/creating pgbouncer_admin user..."
sudo -u postgres psql -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
        CREATE ROLE pgbouncer_admin WITH LOGIN PASSWORD '$PGBOUNCER_PASSWORD';
        GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
        GRANT CONNECT ON DATABASE repmgr TO pgbouncer_admin;
        GRANT CONNECT ON DATABASE template1 TO pgbouncer_admin;
        GRANT pg_monitor TO pgbouncer_admin;
        GRANT USAGE ON SCHEMA public TO pgbouncer_admin;
    ELSE
        ALTER ROLE pgbouncer_admin PASSWORD '$PGBOUNCER_PASSWORD';
    END IF;
END
\$\$;
" postgres

echo "  → Updating repmgr user..."
sudo -u postgres psql -c "ALTER ROLE repmgr PASSWORD '$REPMGR_PASSWORD';" postgres

echo ""
echo "🔧 Step 2: Regenerate PgBouncer userlist with correct MD5 hashes"

# Generate MD5 hashes (PostgreSQL-compatible format)
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
pgbouncer_admin_md5=$(echo -n "${PGBOUNCER_PASSWORD}pgbouncer_admin" | md5sum | cut -d' ' -f1)
repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)

echo "  → Generated MD5 hashes"
echo "    postgres: md5${postgres_md5}"
echo "    pgbouncer_admin: md5${pgbouncer_admin_md5}"  
echo "    repmgr: md5${repmgr_md5}"

# Update PgBouncer userlist
cat > /etc/pgbouncer/userlist.txt <<EOF
;; PgBouncer MD5 Authentication File
;; Generated by fix script
;; MD5 authentication for production compatibility

"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"repmgr" "md5${repmgr_md5}"

EOF

chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
chmod 640 /etc/pgbouncer/userlist.txt

echo ""
echo "🔧 Step 3: Update .pgpass file"
cat > /var/lib/postgresql/.pgpass <<EOF
# Updated .pgpass with correct passwords
localhost:5432:*:postgres:${PG_SUPER_PASS}
localhost:6432:*:postgres:${PG_SUPER_PASS}
localhost:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
localhost:5432:repmgr:repmgr:${REPMGR_PASSWORD}
localhost:5432:replication:repmgr:${REPMGR_PASSWORD}
*:5432:*:postgres:${PG_SUPER_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
*:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
EOF

chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

echo ""
echo "🔧 Step 4: Restart PgBouncer to reload configuration"
systemctl restart pgbouncer
sleep 3

echo ""
echo "🔧 Step 5: Reset PostgreSQL encryption to SCRAM-SHA-256"
sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';" postgres
sudo -u postgres psql -c "SELECT pg_reload_conf();" postgres

echo ""
echo "✅ Authentication fix complete!"
echo ""
echo "🧪 Testing connections..."

# Test direct PostgreSQL connection
if sudo -u postgres psql -c "SELECT 'Direct PostgreSQL works!' as status;" postgres >/dev/null 2>&1; then
    echo "✅ Direct PostgreSQL connection: SUCCESS"
else
    echo "❌ Direct PostgreSQL connection: FAILED"
fi

# Test PgBouncer connection
if sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer works!' as status;" >/dev/null 2>&1; then
    echo "✅ PgBouncer connection: SUCCESS"
else
    echo "❌ PgBouncer connection: FAILED"
fi

# Test PgBouncer admin connection  
if sudo -u postgres psql -h localhost -p 6432 -U pgbouncer_admin -d pgbouncer -c "SHOW POOLS;" >/dev/null 2>&1; then
    echo "✅ PgBouncer admin connection: SUCCESS"
else
    echo "❌ PgBouncer admin connection: FAILED"
fi

echo ""
echo "🎉 Fix script completed!"
echo "   Run validation again to verify all connections work"