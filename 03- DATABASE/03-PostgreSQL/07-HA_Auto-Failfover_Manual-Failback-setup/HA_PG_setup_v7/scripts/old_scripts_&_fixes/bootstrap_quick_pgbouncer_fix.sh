#!/bin/bash
# Bootstrap Quick Fix for PgBouncer Authentication
# This script fixes the PgBouncer authentication issue during bootstrap
# Run this immediately after bootstrap completion if PgBouncer fails

set -euo pipefail

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "🔧 Quick PgBouncer Authentication Fix for Bootstrap"
echo "================================================="

# Detect if this is a primary node
if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
    info "Primary node detected - applying authentication fix"
    
    # Get passwords from Secret Manager
    PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null)
    TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')
    
    ORG_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code')
    ENV_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code')
    
    # Get postgres password
    PG_SECRET="${ORG_CODE}-${ENV_CODE}-sec-pg-superuser-password-01"
    URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
    PG_SUPER_PASS=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)
    
    # Get pgbouncer password
    PGBOUNCER_SECRET="${ORG_CODE}-${ENV_CODE}-sec-pgbouncer-password-01"
    URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PGBOUNCER_SECRET}/versions/latest:access"
    PGBOUNCER_PASSWORD=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)
    
    # Get repmgr password
    REPMGR_SECRET="${ORG_CODE}-${ENV_CODE}-sec-repmgr-password-01"
    URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${REPMGR_SECRET}/versions/latest:access"
    REPMGR_PASSWORD=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)
    
    info "✓ Retrieved passwords from Secret Manager"
    
    # Set password encryption to MD5 temporarily
    info "Setting password encryption to MD5 temporarily..."
    sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'md5';" postgres
    sudo -u postgres psql -c "SELECT pg_reload_conf();" postgres >/dev/null
    sleep 2
    
    # Update postgres user
    info "Updating postgres user with MD5-compatible password..."
    sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$PG_SUPER_PASS';" postgres
    
    # Create/update pgbouncer_admin user
    info "Creating/updating pgbouncer_admin user..."
    sudo -u postgres psql -c "
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
                CREATE ROLE pgbouncer_admin WITH LOGIN PASSWORD '$PGBOUNCER_PASSWORD';
                GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
                GRANT pg_monitor TO pgbouncer_admin;
            ELSE
                ALTER ROLE pgbouncer_admin PASSWORD '$PGBOUNCER_PASSWORD';
            END IF;
        END
        \$\$;
    " postgres
    
    # Update repmgr user
    info "Updating repmgr user with MD5-compatible password..."
    sudo -u postgres psql -c "ALTER USER repmgr PASSWORD '$REPMGR_PASSWORD';" postgres || true
    
    # Reset password encryption to SCRAM-SHA-256
    info "Resetting password encryption to SCRAM-SHA-256..."
    sudo -u postgres psql -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';" postgres
    sudo -u postgres psql -c "SELECT pg_reload_conf();" postgres >/dev/null
    
    # Regenerate PgBouncer userlist
    info "Regenerating PgBouncer userlist..."
    postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
    pgbouncer_admin_md5=$(echo -n "${PGBOUNCER_PASSWORD}pgbouncer_admin" | md5sum | cut -d' ' -f1)
    repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)
    
    cat > "/etc/pgbouncer/userlist.txt" <<EOF
"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"repmgr" "md5${repmgr_md5}"
EOF
    
    chown pgbouncer:pgbouncer "/etc/pgbouncer/userlist.txt"
    chmod 640 "/etc/pgbouncer/userlist.txt"
    
    # Restart PgBouncer
    info "Restarting PgBouncer..."
    systemctl restart pgbouncer
    sleep 3
    
    # Test connection
    info "Testing PgBouncer connection..."
    if timeout 5 sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'Quick fix successful!' as status;" >/dev/null 2>&1; then
        info "🎉 SUCCESS: PgBouncer authentication fixed!"
    else
        warn "Connection test failed - may need further troubleshooting"
    fi
    
else
    info "Standby node detected - no action needed (will replicate from primary)"
fi

info "✅ Quick fix completed"