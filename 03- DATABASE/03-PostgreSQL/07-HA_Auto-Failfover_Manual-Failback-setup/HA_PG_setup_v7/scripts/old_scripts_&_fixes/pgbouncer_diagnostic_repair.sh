#!/bin/bash
# PgBouncer Diagnostic and Repair Script
# Identifies and fixes PgBouncer startup issues

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

info "🔍 PgBouncer Diagnostic and Repair"
echo "=================================="

# Step 1: Check PgBouncer status
info "Step 1: Checking PgBouncer service status"
echo "========================================="

if systemctl is-active --quiet pgbouncer; then
    success "✓ PgBouncer service is running"
else
    warn "✗ PgBouncer service is not running"
    
    info "PgBouncer service status:"
    systemctl status pgbouncer --no-pager || true
    
    info ""
    info "PgBouncer logs (last 20 lines):"
    journalctl -u pgbouncer -n 20 --no-pager || true
fi

# Step 2: Test PgBouncer configuration syntax
info ""
info "Step 2: Testing PgBouncer configuration syntax"
echo "=============================================="

PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"

if [[ -f "$PGBOUNCER_CONF" ]]; then
    info "Testing PgBouncer configuration syntax..."
    
    # Test configuration by attempting to start in foreground mode briefly
    if timeout 3 sudo -u pgbouncer /usr/sbin/pgbouncer -v "$PGBOUNCER_CONF" 2>&1; then
        success "✓ PgBouncer configuration syntax is valid"
    else
        error "✗ PgBouncer configuration has syntax errors"
        
        info "Configuration test output:"
        sudo -u pgbouncer /usr/sbin/pgbouncer -v "$PGBOUNCER_CONF" 2>&1 || true
    fi
else
    error "PgBouncer configuration file not found: $PGBOUNCER_CONF"
fi

# Step 3: Check configuration files
info ""
info "Step 3: Checking configuration files"
echo "===================================="

info "PgBouncer configuration file content:"
echo "-------------------------------------"
cat "$PGBOUNCER_CONF" || true

echo ""
info "PgBouncer userlist file content:"
echo "-------------------------------"
cat "/etc/pgbouncer/userlist.txt" || true

# Step 4: Check file permissions
info ""
info "Step 4: Checking file permissions"
echo "================================="

ls -la /etc/pgbouncer/ || true
ls -la /var/lib/pgbouncer/ 2>/dev/null || true
ls -la /var/log/pgbouncer/ 2>/dev/null || true
ls -la /var/run/pgbouncer/ 2>/dev/null || true

# Step 5: Check if pgbouncer user can access files
info ""
info "Step 5: Testing pgbouncer user file access"
echo "=========================================="

if sudo -u pgbouncer test -r "$PGBOUNCER_CONF"; then
    success "✓ pgbouncer user can read configuration file"
else
    error "✗ pgbouncer user cannot read configuration file"
fi

if sudo -u pgbouncer test -r "/etc/pgbouncer/userlist.txt"; then
    success "✓ pgbouncer user can read userlist file"
else
    error "✗ pgbouncer user cannot read userlist file"
fi

# Step 6: Check for common issues and fix them
info ""
info "Step 6: Checking for common issues and applying fixes"
echo "====================================================="

# Get passwords from Secret Manager for repair
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null || echo "unknown")
ORG_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code' 2>/dev/null || echo "ipa")
ENV_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code' 2>/dev/null || echo "nprd")

# Get postgres password
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token' 2>/dev/null || echo "")

if [[ -n "$TOKEN" ]]; then
    # Get postgres password
    PG_SECRET="${ORG_CODE}-${ENV_CODE}-sec-pg-superuser-password-01"
    URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
    if SECRET_DATA=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" 2>/dev/null); then
        PG_SUPER_PASS=$(echo "$SECRET_DATA" | jq -r '.payload.data' | base64 -d 2>/dev/null)
        info "✓ Retrieved postgres password from Secret Manager"
    else
        warn "Could not retrieve postgres password from Secret Manager"
        PG_SUPER_PASS=""
    fi
    
    # Get repmgr password
    REPMGR_SECRET="${ORG_CODE}-${ENV_CODE}-sec-repmgr-password-01"
    URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${REPMGR_SECRET}/versions/latest:access"
    if SECRET_DATA=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" 2>/dev/null); then
        REPMGR_PASSWORD=$(echo "$SECRET_DATA" | jq -r '.payload.data' | base64 -d 2>/dev/null)
        info "✓ Retrieved repmgr password from Secret Manager"
    else
        warn "Could not retrieve repmgr password from Secret Manager"
        REPMGR_PASSWORD=""
    fi
fi

# Create a working PgBouncer configuration
info "Creating known-working PgBouncer configuration..."

# Detect role
if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
    ROLE="standby"
    POOL_MODE="transaction"
    MAX_CLIENT_CONN=150
else
    ROLE="primary"
    POOL_MODE="session"  
    MAX_CLIENT_CONN=100
fi

info "Detected role: $ROLE"

# Backup current config
cp "$PGBOUNCER_CONF" "${PGBOUNCER_CONF}.backup.diagnostic.$(date +%Y%m%d-%H%M%S)"

# Create minimal working configuration
cat > "$PGBOUNCER_CONF" <<EOF
;; PgBouncer Diagnostic Configuration - $ROLE Node
;; Generated by diagnostic script

[databases]
postgres = host=localhost port=5432 dbname=postgres
template1 = host=localhost port=5432 dbname=template1
repmgr = host=localhost port=5432 dbname=repmgr

[pgbouncer]
;; Connection settings
listen_addr = 0.0.0.0
listen_port = 6432

;; Authentication
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

;; Pool settings
pool_mode = $POOL_MODE
max_client_conn = $MAX_CLIENT_CONN
default_pool_size = 25
reserve_pool_size = 5
max_db_connections = 50

;; Timeouts
server_connect_timeout = 15
server_login_retry = 3

;; Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

;; Administration  
admin_users = postgres
stats_users = postgres

;; Security
ignore_startup_parameters = extra_float_digits

EOF

chown pgbouncer:pgbouncer "$PGBOUNCER_CONF"
chmod 640 "$PGBOUNCER_CONF"
success "✓ Created minimal working PgBouncer configuration"

# Create working userlist.txt
if [[ -n "$PG_SUPER_PASS" && -n "$REPMGR_PASSWORD" ]]; then
    info "Creating working userlist.txt with Secret Manager passwords..."
    
    postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
    repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)
    
    cat > "/etc/pgbouncer/userlist.txt" <<EOF
;; PgBouncer Diagnostic Userlist
;; Generated by diagnostic script

"postgres" "md5${postgres_md5}"
"repmgr" "md5${repmgr_md5}"

EOF
    
    chown pgbouncer:pgbouncer "/etc/pgbouncer/userlist.txt"
    chmod 640 "/etc/pgbouncer/userlist.txt"
    success "✓ Created working userlist.txt"
else
    warn "Skipping userlist creation - passwords not available"
fi

# Step 7: Try to start PgBouncer
info ""
info "Step 7: Attempting to start PgBouncer with repaired configuration"
echo "================================================================"

# Make sure directories exist with correct permissions
mkdir -p /var/run/pgbouncer /var/lib/pgbouncer /var/log/pgbouncer
chown pgbouncer:pgbouncer /var/run/pgbouncer /var/lib/pgbouncer /var/log/pgbouncer

# Try to start PgBouncer
if systemctl start pgbouncer; then
    success "🎉 PgBouncer started successfully!"
    
    # Wait a moment and check status
    sleep 3
    
    if systemctl is-active --quiet pgbouncer; then
        success "✓ PgBouncer is running"
        
        # Test connection
        if timeout 5 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
            success "✅ PgBouncer is accepting connections on port 6432"
            
            # Test postgres user connection if password available
            if [[ -n "$PG_SUPER_PASS" ]]; then
                if echo "SELECT 'PgBouncer diagnostic test successful!' as status;" | sudo -u postgres psql -h localhost -p 6432 -U postgres postgres 2>/dev/null; then
                    success "✅ postgres user authentication through PgBouncer working!"
                else
                    warn "❌ postgres user authentication test failed"
                fi
            fi
        else
            warn "❌ PgBouncer not accepting connections"
        fi
    else
        error "PgBouncer failed to stay running"
        journalctl -u pgbouncer -n 10 --no-pager || true
    fi
else
    error "Failed to start PgBouncer"
    info "Latest PgBouncer logs:"
    journalctl -u pgbouncer -n 15 --no-pager || true
fi

info ""
info "🔧 Diagnostic Summary"
echo "===================="
echo "• Configuration backed up with .diagnostic timestamp"
echo "• Minimal working configuration applied"
echo "• Check logs if issues persist: journalctl -u pgbouncer -f"
echo "• Run comprehensive validation: sudo ./comprehensive_validation.sh"