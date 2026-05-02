#!/bin/bash
# Complete Cluster Fix - Run on both servers
# Fixes health endpoints and ensures all connections work

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

echo "🔧 Complete PostgreSQL HA Cluster Fix"
echo "======================================"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# Step 1: Fix health endpoints with proper netcat approach
info "1. Fixing health endpoints with enhanced approach..."

# Stop existing health services
systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true
pkill -f "health.sh" 2>/dev/null || true
pkill -f "pg-ha-health" 2>/dev/null || true
pkill -f "pgbouncer-health" 2>/dev/null || true
sleep 3

# Create enhanced health endpoints that definitely work
cat > /usr/local/bin/pg-ha-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8001}

# Simple HTTP server using netcat
while true; do
    {
        status_code="503"
        role="unknown"
        
        if systemctl is-active --quiet postgresql; then
            if sudo -u postgres psql -tAc "SELECT NOT pg_is_in_recovery();" postgres 2>/dev/null | grep -q "^t"; then
                status_code="200"
                role="primary"
            else
                if sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q "^t"; then
                    wal_count=$(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';" postgres 2>/dev/null || echo 0)
                    if [ "$wal_count" = "1" ]; then
                        status_code="200"
                    fi
                fi
                role="standby"
            fi
        fi
        
        response="{\"status\": \"$([ "$status_code" = "200" ] && echo healthy || echo unhealthy)\", \"role\": \"$role\", \"timestamp\": \"$(date -Iseconds)\"}"
        content_length=${#response}
        
        echo "HTTP/1.1 $status_code $([ "$status_code" = "200" ] && echo OK || echo "Service Unavailable")"
        echo "Content-Type: application/json"
        echo "Content-Length: $content_length"
        echo "Connection: close"
        echo "Access-Control-Allow-Origin: *"
        echo ""
        echo "$response"
    } | nc -l -p $PORT -q 1
    
    sleep 0.1
done
EOF

cat > /usr/local/bin/pgbouncer-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8002}

while true; do
    {
        status_code="503"
        service_status="unhealthy"
        
        if systemctl is-active --quiet pgbouncer && nc -zv localhost 6432 2>/dev/null; then
            status_code="200"
            service_status="healthy"
        fi
        
        response="{\"status\": \"$service_status\", \"service\": \"pgbouncer\", \"timestamp\": \"$(date -Iseconds)\"}"
        content_length=${#response}
        
        echo "HTTP/1.1 $status_code $([ "$status_code" = "200" ] && echo OK || echo "Service Unavailable")"
        echo "Content-Type: application/json"
        echo "Content-Length: $content_length"
        echo "Connection: close"
        echo "Access-Control-Allow-Origin: *"
        echo ""
        echo "$response"
    } | nc -l -p $PORT -q 1
    
    sleep 0.1
done
EOF

chmod +x /usr/local/bin/pg-ha-health.sh /usr/local/bin/pgbouncer-health.sh

# Step 2: Restart services
info "2. Restarting health services..."
systemctl daemon-reload
systemctl start pg-ha-health.service
systemctl start pgbouncer-health.service

# Wait for services to start
sleep 5

# Step 3: Test health endpoints
info "3. Testing health endpoints..."
echo -n "PostgreSQL Health (port 8001): "
if timeout 10 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ Working!"
    curl -s http://localhost:8001 | jq . 2>/dev/null || curl -s http://localhost:8001
else
    error "❌ Still not working"
fi

echo
echo -n "PgBouncer Health (port 8002): "
if timeout 10 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ Working!"
    curl -s http://localhost:8002 | jq . 2>/dev/null || curl -s http://localhost:8002
else
    error "❌ Still not working"
fi

# Step 4: Get and display working connection strings
echo
info "4. Testing database connections..."

# Get passwords
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id)
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')

get_secret() {
    local secret_id="$1"
    local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${secret_id}/versions/latest:access"
    curl -sf -H "Authorization: Bearer $TOKEN" "$url" | jq -r '.payload.data' | base64 -d 2>/dev/null || echo "FAILED"
}

PG_PASS=$(get_secret "ipa-nprd-sec-pg-superuser-password-01")
PGBOUNCER_PASS=$(get_secret "ipa-nprd-sec-pgbouncer-password-01")

if [[ "$PG_PASS" != "FAILED" ]]; then
    export PGPASSWORD="$PG_PASS"
    
    echo "Testing connections..."
    
    # Test primary direct
    if PGPASSWORD="$PG_PASS" psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c "SELECT 'Primary Direct ✅';" >/dev/null 2>&1; then
        success "✅ Primary Direct Connection"
    else
        error "❌ Primary Direct Connection"
    fi
    
    # Test standby direct
    if PGPASSWORD="$PG_PASS" psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c "SELECT 'Standby Direct ✅';" >/dev/null 2>&1; then
        success "✅ Standby Direct Connection"
    else
        error "❌ Standby Direct Connection"
    fi
    
    # Test primary pgbouncer
    if PGPASSWORD="$PG_PASS" psql -h 192.168.14.21 -p 6432 -U postgres -d postgres -c "SELECT 'Primary PgBouncer ✅';" >/dev/null 2>&1; then
        success "✅ Primary PgBouncer Connection"
    else
        error "❌ Primary PgBouncer Connection"
    fi
    
    # Test standby pgbouncer
    if PGPASSWORD="$PG_PASS" psql -h 192.168.14.22 -p 6432 -U postgres -d postgres -c "SELECT 'Standby PgBouncer ✅';" >/dev/null 2>&1; then
        success "✅ Standby PgBouncer Connection"
    else
        error "❌ Standby PgBouncer Connection"
    fi
    
    echo
    info "📋 Working Connection Commands:"
    echo "export PGPASSWORD='$PG_PASS'"
    echo "psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c \"SELECT 'Primary works';\""
    echo "psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c \"SELECT 'Standby works';\""
    echo "psql -h 192.168.14.21 -p 6432 -U postgres -d postgres -c \"SELECT 'Primary PgBouncer works';\""
    echo "psql -h 192.168.14.22 -p 6432 -U postgres -d postgres -c \"SELECT 'Standby PgBouncer works';\""
fi

echo
info "5. Final service status:"
echo "PostgreSQL:       $(systemctl is-active postgresql)"
echo "PgBouncer:        $(systemctl is-active pgbouncer)" 
echo "repmgrd:          $(systemctl is-active repmgrd)"
echo "PG Health:        $(systemctl is-active pg-ha-health)"
echo "PgBouncer Health: $(systemctl is-active pgbouncer-health)"

echo
success "🎉 Complete cluster fix finished!"
success "🔗 Health endpoints should now be accessible on ports 8001 and 8002"