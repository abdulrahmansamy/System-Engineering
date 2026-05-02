#!/bin/bash
# Immediate Health Endpoint Fix Script
# Fixes the connection reset and timeout issues without full bootstrap

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "🔧 IMMEDIATE Health Endpoint Fix"
echo "==============================="
echo "Fixing connection reset and timeout issues"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Stop all existing health services and processes"

# Stop all health-related systemd services
for service in pg-ha-health pgbouncer-health pg-definitive-health pgbouncer-definitive-health; do
    systemctl stop ${service}.service 2>/dev/null || true
done

# Kill ALL netcat and health processes
pkill -f "nc.*-l.*-p.*8001" 2>/dev/null || true
pkill -f "nc.*-l.*-p.*8002" 2>/dev/null || true
pkill -f "socat.*8001" 2>/dev/null || true
pkill -f "socat.*8002" 2>/dev/null || true
pkill -f "health" 2>/dev/null || true

sleep 3

# Force kill anything still on ports 8001/8002
for port in 8001 8002; do
    lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
done

sleep 2

success "✅ All health processes stopped and ports cleared"

info "Step 2: Create WORKING health scripts with proper HTTP format"

# Create the WORKING PostgreSQL health script
cat > /usr/local/bin/pg-ha-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8001}

# Health check function with proper HTTP response
check_health() {
    local status_code="503"
    local role="unknown"
    
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
    
    local response="{\"status\":\"$([ "$status_code" = "200" ] && echo "healthy" || echo "unhealthy")\",\"role\":\"$role\",\"timestamp\":\"$(date -Iseconds)\"}"
    local content_length=${#response}
    
    # Proper HTTP/1.1 response with \r\n line endings
    printf "HTTP/1.1 %s %s\r\n" "$status_code" "$([ "$status_code" = "200" ] && echo "OK" || echo "Service Unavailable")"
    printf "Content-Type: application/json\r\n"
    printf "Content-Length: %d\r\n" "$content_length"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "$response"
}

# Export function for socat
export -f check_health

# Use socat with proper options
exec socat TCP4-LISTEN:$PORT,reuseaddr,fork,nodelay SYSTEM:'check_health'
EOF

# Create the WORKING PgBouncer health script
cat > /usr/local/bin/pgbouncer-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8002}

# Health check function with proper HTTP response
check_health() {
    local status_code="503"
    local service_status="unhealthy"
    
    if systemctl is-active --quiet pgbouncer; then
        # Test actual connectivity to PgBouncer port
        if timeout 2 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
            status_code="200"
            service_status="healthy"
        fi
    fi
    
    local response="{\"status\":\"$service_status\",\"service\":\"pgbouncer\",\"timestamp\":\"$(date -Iseconds)\"}"
    local content_length=${#response}
    
    # Proper HTTP/1.1 response with \r\n line endings
    printf "HTTP/1.1 %s %s\r\n" "$status_code" "$([ "$status_code" = "200" ] && echo "OK" || echo "Service Unavailable")"
    printf "Content-Type: application/json\r\n"
    printf "Content-Length: %d\r\n" "$content_length"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "$response"
}

# Export function for socat
export -f check_health

# Use socat with proper options
exec socat TCP4-LISTEN:$PORT,reuseaddr,fork,nodelay SYSTEM:'check_health'
EOF

chmod +x /usr/local/bin/pg-ha-health.sh /usr/local/bin/pgbouncer-health.sh

success "✅ Created WORKING health scripts with proper HTTP format"

info "Step 3: Update systemd service files to remove problematic ExecStartPre"

# Create clean systemd service files without problematic cleanup commands
cat > /etc/systemd/system/pg-ha-health.service <<EOF
[Unit]
Description=PostgreSQL HA Health Check Endpoint
After=network-online.target postgresql.service
Wants=postgresql.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pg-ha-health.sh 8001
Restart=always
RestartSec=5
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-health.service <<EOF
[Unit]
Description=PgBouncer HA Health Check Endpoint
After=network-online.target pgbouncer.service
Wants=pgbouncer.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pgbouncer-health.sh 8002
Restart=always
RestartSec=5
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

success "✅ Updated systemd service files"

info "Step 4: Start the WORKING health services"

systemctl daemon-reload

# Start PostgreSQL health service
if systemctl start pg-ha-health.service; then
    success "✅ PostgreSQL health service started"
    sleep 2
    if systemctl is-active --quiet pg-ha-health.service; then
        success "✅ PostgreSQL health service is running"
    else
        error "❌ PostgreSQL health service failed"
        journalctl -u pg-ha-health.service --lines=5 --no-pager
    fi
else
    error "❌ Failed to start PostgreSQL health service"
    journalctl -u pg-ha-health.service --lines=10 --no-pager
fi

# Start PgBouncer health service  
if systemctl start pgbouncer-health.service; then
    success "✅ PgBouncer health service started"
    sleep 2
    if systemctl is-active --quiet pgbouncer-health.service; then
        success "✅ PgBouncer health service is running"
    else
        error "❌ PgBouncer health service failed"
        journalctl -u pgbouncer-health.service --lines=5 --no-pager
    fi
else
    error "❌ Failed to start PgBouncer health service"
    journalctl -u pgbouncer-health.service --lines=10 --no-pager
fi

# Enable services for auto-start
systemctl enable pg-ha-health.service
systemctl enable pgbouncer-health.service

sleep 5

info "Step 5: Test the WORKING health endpoints"

echo "Service status check:"
systemctl status pg-ha-health.service --no-pager | head -3
systemctl status pgbouncer-health.service --no-pager | head -3

echo
echo "Port binding check:"
ss -tupln | grep -E ':(8001|8002)' && echo "✅ Services bound to ports" || echo "❌ No port bindings"

echo
echo "Testing endpoints:"

# Test with proper error handling
test_endpoint() {
    local url="$1"
    local name="$2"
    
    echo -n "$name: "
    if response=$(timeout 5 curl -sf "$url" 2>/dev/null); then
        if echo "$response" | jq . >/dev/null 2>&1; then
            echo "✅ WORKING"
            echo "   Response: $response"
        else
            echo "❌ INVALID JSON: $response"
        fi
    else
        echo "❌ CONNECTION FAILED"
    fi
}

test_endpoint "http://localhost:8001" "PostgreSQL (localhost:8001)"
test_endpoint "http://localhost:8002" "PgBouncer (localhost:8002)"

SELF_IP=$(hostname -I | awk '{print $1}')
test_endpoint "http://$SELF_IP:8001" "PostgreSQL ($SELF_IP:8001)"
test_endpoint "http://$SELF_IP:8002" "PgBouncer ($SELF_IP:8002)"

echo

# Final verification
local_working=0
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    ((local_working++))
fi
if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    ((local_working++))
fi

if [ $local_working -eq 2 ]; then
    success "🎉 IMMEDIATE FIX SUCCESSFUL!"
    success "✅ Both local health endpoints are now working"
    success "✅ Ready for cross-node testing"
    
    echo
    info "📋 What was fixed:"
    echo "1. ✅ Removed complex socat EXEC syntax with nested quotes"
    echo "2. ✅ Used proper HTTP/1.1 format with \\r\\n line endings"
    echo "3. ✅ Used SYSTEM command instead of complex EXEC"
    echo "4. ✅ Eliminated all process competition"
    echo "5. ✅ Removed problematic ExecStartPre commands"
    
else
    error "❌ Some endpoints still not working ($local_working/2 working)"
    info "Check service logs:"
    journalctl -u pg-ha-health.service --lines=5 --no-pager
    journalctl -u pgbouncer-health.service --lines=5 --no-pager
fi

echo
success "🔧 Immediate fix complete!"
echo
info "🚀 Next steps:"
echo "1. Run this script on BOTH servers"
echo "2. Test: sudo ./test_health_checks_v1.2.sh"
echo "3. Expect 6/6 working endpoints!"