#!/bin/bash
# Comprehensive PostgreSQL HA Cluster Diagnostic and Fix
# Diagnoses and fixes common issues with the cluster setup

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "🔧 PostgreSQL HA Cluster Diagnostic & Fix"
echo "=========================================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# Step 1: Basic service status
info "1. Checking basic service status..."
echo "PostgreSQL: $(systemctl is-active postgresql || echo 'INACTIVE')"
echo "PgBouncer:  $(systemctl is-active pgbouncer || echo 'INACTIVE')"
echo "repmgrd:    $(systemctl is-active repmgrd || echo 'INACTIVE')"
echo

# Step 2: Check PostgreSQL connectivity
info "2. Checking PostgreSQL connectivity..."
if sudo -u postgres psql -c "SELECT 'PostgreSQL is responding' as status;" 2>/dev/null; then
    success "✅ PostgreSQL is responding"
else
    error "❌ PostgreSQL is not responding"
    info "Attempting to restart PostgreSQL..."
    systemctl restart postgresql
    sleep 5
fi

# Step 3: Get role information
info "3. Detecting node role..."
ROLE=$(curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_role" 2>/dev/null || echo "unknown")
IS_PRIMARY=$(sudo -u postgres psql -Atqc "SELECT NOT pg_is_in_recovery();" 2>/dev/null || echo "f")
IS_STANDBY=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "f")

info "Configured role: $ROLE"
info "Actual role: $([ "$IS_PRIMARY" = "t" ] && echo "primary" || echo "standby")"
echo

# Step 4: Fix health endpoints  
info "4. Fixing health endpoints..."
cat > /usr/local/bin/pg-ha-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8001}

while true; do
    socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'/bin/bash -c "
        status_code=\"503\"
        role=\"unknown\"
        
        if systemctl is-active --quiet postgresql; then
            if sudo -u postgres psql -tAc \"SELECT NOT pg_is_in_recovery();\" postgres 2>/dev/null | grep -q \"^t\"; then
                status_code=\"200\"
                role=\"primary\"
            else
                if sudo -u postgres psql -tAc \"SELECT pg_is_in_recovery();\" postgres 2>/dev/null | grep -q \"^t\"; then
                    wal_count=\$(sudo -u postgres psql -tAc \"SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = \'streaming\';\" postgres 2>/dev/null || echo 0)
                    if [ \"\$wal_count\" = \"1\" ]; then
                        status_code=\"200\"
                    fi
                fi
                role=\"standby\"
            fi
        fi
        
        response=\"{\\\"status\\\": \\\"\$([ \"\$status_code\" = \"200\" ] && echo healthy || echo unhealthy)\\\", \\\"role\\\": \\\"\$role\\\", \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\"}\"
        
        echo \"HTTP/1.1 \$status_code \$([ \"\$status_code\" = \"200\" ] && echo OK || echo \"Service Unavailable\")\"
        echo \"Content-Type: application/json\"
        echo \"Content-Length: \${#response}\"
        echo \"Connection: close\"
        echo
        echo \"\$response\"
    "'
done
EOF

cat > /usr/local/bin/pgbouncer-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8002}

while true; do
    socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'/bin/bash -c "
        status_code=\"503\"
        service_status=\"unhealthy\"
        
        if systemctl is-active --quiet pgbouncer && nc -zv localhost 6432 2>/dev/null; then
            status_code=\"200\"
            service_status=\"healthy\"
        fi
        
        response=\"{\\\"status\\\": \\\"\$service_status\\\", \\\"service\\\": \\\"pgbouncer\\\", \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\"}\"
        
        echo \"HTTP/1.1 \$status_code \$([ \"\$status_code\" = \"200\" ] && echo OK || echo \"Service Unavailable\")\"
        echo \"Content-Type: application/json\"
        echo \"Content-Length: \${#response}\"
        echo \"Connection: close\"
        echo
        echo \"\$response\"
    "'
done
EOF

chmod +x /usr/local/bin/pg-ha-health.sh /usr/local/bin/pgbouncer-health.sh

# Restart health services
systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true
pkill -f health.sh 2>/dev/null || true
sleep 2
systemctl start pg-ha-health.service pgbouncer-health.service

success "✅ Health endpoints updated"
echo

# Step 5: Test health endpoints
info "5. Testing health endpoints..."
sleep 3
echo -n "PostgreSQL Health: "
if timeout 5 curl -s http://localhost:8001 >/dev/null 2>&1; then
    success "✅ Working"
    curl -s http://localhost:8001 | jq . 2>/dev/null || curl -s http://localhost:8001
else
    error "❌ Not working"
fi

echo
echo -n "PgBouncer Health: "
if timeout 5 curl -s http://localhost:8002 >/dev/null 2>&1; then
    success "✅ Working"
    curl -s http://localhost:8002 | jq . 2>/dev/null || curl -s http://localhost:8002
else
    error "❌ Not working"
fi
echo

# Step 6: Get passwords and test connections
info "6. Testing database connections..."

# Get passwords from Secret Manager
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id)
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')

get_secret() {
    local secret_id="$1"
    local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${secret_id}/versions/latest:access"
    curl -sf -H "Authorization: Bearer $TOKEN" "$url" | jq -r '.payload.data' | base64 -d 2>/dev/null || echo "FAILED"
}

PG_PASS=$(get_secret "ipa-nprd-sec-pg-superuser-password-01")
PGBOUNCER_PASS=$(get_secret "ipa-nprd-sec-pgbouncer-password-01")

if [[ "$PG_PASS" == "FAILED" ]]; then
    warn "Could not get password from Secret Manager, checking local .pgpass"
    if [[ -f /var/lib/postgresql/.pgpass ]]; then
        PG_PASS=$(grep "postgres:" /var/lib/postgresql/.pgpass | cut -d: -f5 | head -1)
    fi
fi

if [[ -n "$PG_PASS" && "$PG_PASS" != "FAILED" ]]; then
    info "Testing connections with password (length: ${#PG_PASS} chars)"
    
    # Test local PostgreSQL
    echo -n "Local PostgreSQL: "
    if sudo -u postgres psql -c "SELECT 'Local connection works' as status;" >/dev/null 2>&1; then
        success "✅ Working"
    else
        error "❌ Failed"
    fi
    
    # Test local PgBouncer  
    echo -n "Local PgBouncer: "
    if PGPASSWORD="$PG_PASS" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer works' as status;" >/dev/null 2>&1; then
        success "✅ Working"
    else
        error "❌ Failed"
    fi
    
    # Test remote connections (if this is primary, test standby; if standby, test primary)
    if [[ "$IS_PRIMARY" == "t" ]]; then
        echo -n "Standby Connection: "
        if PGPASSWORD="$PG_PASS" psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c "SELECT 'Standby connection works' as status;" >/dev/null 2>&1; then
            success "✅ Working"
        else
            error "❌ Failed"
        fi
    else
        echo -n "Primary Connection: "
        if PGPASSWORD="$PG_PASS" psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c "SELECT 'Primary connection works' as status;" >/dev/null 2>&1; then
            success "✅ Working" 
        else
            error "❌ Failed"
        fi
    fi
else
    warn "Could not retrieve password for connection testing"
fi
echo

# Step 7: Check replication status
info "7. Checking replication status..."
if [[ "$IS_PRIMARY" == "t" ]]; then
    info "Primary node - checking replication slots and connections:"
    sudo -u postgres psql -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;" 2>/dev/null || true
    sudo -u postgres psql -c "SELECT application_name, state, sync_state FROM pg_stat_replication;" 2>/dev/null || true
else
    info "Standby node - checking WAL receiver status:"
    sudo -u postgres psql -c "SELECT status, received_lsn, last_msg_receipt_time FROM pg_stat_wal_receiver;" 2>/dev/null || true
fi
echo

# Step 8: Check repmgr status
info "8. Checking repmgr cluster status..."
if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null; then
    success "✅ repmgr cluster is working"
else
    warn "❌ repmgr cluster check failed"
fi
echo

# Step 9: Final summary
info "9. Final Status Summary:"
echo "========================"
echo "PostgreSQL Service: $(systemctl is-active postgresql)"
echo "PgBouncer Service:  $(systemctl is-active pgbouncer)"
echo "repmgrd Service:    $(systemctl is-active repmgrd)"
echo "Health Endpoints:   $(systemctl is-active pg-ha-health)/$(systemctl is-active pgbouncer-health)"
echo "Node Role:          $([ "$IS_PRIMARY" = "t" ] && echo "PRIMARY" || echo "STANDBY")"
echo "Password Available: $([ -n "$PG_PASS" ] && [ "$PG_PASS" != "FAILED" ] && echo "YES" || echo "NO")"
echo

success "🎉 Diagnostic and fix completed!"

if [[ -n "$PG_PASS" && "$PG_PASS" != "FAILED" ]]; then
    echo
    info "📋 Manual Connection Test Commands:"
    echo "=================================="
    echo "# Direct PostgreSQL connections:"
    echo "PGPASSWORD='$PG_PASS' psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c \"SELECT 'Primary Direct';\""
    echo "PGPASSWORD='$PG_PASS' psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c \"SELECT 'Standby Direct';\""
    echo
    echo "# PgBouncer connections:"
    echo "PGPASSWORD='$PG_PASS' psql -h 192.168.14.21 -p 6432 -U postgres -d postgres -c \"SELECT 'Primary PgBouncer';\""
    echo "PGPASSWORD='$PG_PASS' psql -h 192.168.14.22 -p 6432 -U postgres -d postgres -c \"SELECT 'Standby PgBouncer';\""
fi