#!/bin/bash
# Complete Health Service Diagnostic and Final Fix
# Comprehensive troubleshooting and resolution

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

echo "🔍 Complete Health Service Diagnostic"
echo "===================================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Comprehensive system status check"

echo "Current health service status:"
for service in pg-ha-health-final pgbouncer-ha-health-final; do
    echo -n "$service: "
    systemctl is-active $service.service 2>/dev/null || echo "INACTIVE"
done
echo

echo "Port usage:"
ss -tupln | grep -E ':(8001|8002)' || echo "No processes on ports 8001/8002"
echo

echo "Health-related processes:"
ps aux | grep -E "(health|8001|8002|socat)" | grep -v grep || echo "No health processes running"
echo

info "Step 2: Force cleanup everything"

# Kill all possible health processes
pkill -f "health" 2>/dev/null || true
pkill -f "socat" 2>/dev/null || true
pkill -f "8001" 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true

# Stop all health services
systemctl stop pg-ha-health-final.service 2>/dev/null || true
systemctl stop pgbouncer-ha-health-final.service 2>/dev/null || true

# Force kill anything on the ports
for port in 8001 8002; do
    lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
done

sleep 2
success "✅ Force cleanup completed"

info "Step 3: Create ultra-simple health scripts"

# Create ultra-simple PostgreSQL health script
cat > /usr/local/bin/pg-simple-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Simple HTTP response function
http_response() {
    local status_code="200"
    local role="primary"
    
    # Quick PostgreSQL check
    if ! systemctl is-active --quiet postgresql; then
        status_code="503"
        role="unknown"
    elif ! sudo -u postgres psql -tAc "SELECT 1;" postgres >/dev/null 2>&1; then
        status_code="503"
        role="unknown"
    else
        # Check if primary or standby
        if sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q "^t"; then
            role="standby"
        fi
    fi
    
    local response="{\"status\":\"$([ "$status_code" = "200" ] && echo "healthy" || echo "unhealthy")\",\"role\":\"$role\",\"timestamp\":\"$(date -Iseconds)\"}"
    
    echo "HTTP/1.1 $status_code OK"
    echo "Content-Type: application/json"
    echo "Content-Length: ${#response}"
    echo "Connection: close"
    echo
    echo "$response"
}

# Start simple HTTP server on port 8001
while true; do
    nc -l -p 8001 -e /bin/bash -c 'http_response' 2>/dev/null || sleep 1
done
EOF

# Create ultra-simple PgBouncer health script
cat > /usr/local/bin/pgbouncer-simple-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Simple HTTP response function
http_response() {
    local status_code="200"
    
    # Quick PgBouncer check
    if ! systemctl is-active --quiet pgbouncer || ! nc -z localhost 6432 2>/dev/null; then
        status_code="503"
    fi
    
    local response="{\"status\":\"$([ "$status_code" = "200" ] && echo "healthy" || echo "unhealthy")\",\"service\":\"pgbouncer\",\"timestamp\":\"$(date -Iseconds)\"}"
    
    echo "HTTP/1.1 $status_code OK"
    echo "Content-Type: application/json"
    echo "Content-Length: ${#response}"
    echo "Connection: close"
    echo
    echo "$response"
}

# Start simple HTTP server on port 8002
while true; do
    nc -l -p 8002 -e /bin/bash -c 'http_response' 2>/dev/null || sleep 1
done
EOF

chmod +x /usr/local/bin/pg-simple-health.sh /usr/local/bin/pgbouncer-simple-health.sh
success "✅ Created ultra-simple health scripts using netcat"

info "Step 4: Create simple systemd services"

cat > /etc/systemd/system/pg-simple-health.service <<EOF
[Unit]
Description=PostgreSQL Simple Health Check
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pg-simple-health.sh
Restart=always
RestartSec=3
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-simple-health.service <<EOF
[Unit]
Description=PgBouncer Simple Health Check
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pgbouncer-simple-health.sh
Restart=always
RestartSec=3
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

success "✅ Created simple systemd services"

info "Step 5: Start services with monitoring"

systemctl daemon-reload

echo "Starting PostgreSQL health service..."
if systemctl start pg-simple-health.service; then
    success "✅ PostgreSQL health service started"
    sleep 2
    if systemctl is-active --quiet pg-simple-health.service; then
        success "✅ PostgreSQL health service is running"
    else
        error "❌ PostgreSQL health service stopped immediately"
        journalctl -u pg-simple-health.service --lines=5 --no-pager
    fi
else
    error "❌ Failed to start PostgreSQL health service"
    journalctl -u pg-simple-health.service --lines=10 --no-pager
fi

echo "Starting PgBouncer health service..."
if systemctl start pgbouncer-simple-health.service; then
    success "✅ PgBouncer health service started"
    sleep 2
    if systemctl is-active --quiet pgbouncer-simple-health.service; then
        success "✅ PgBouncer health service is running"
    else
        error "❌ PgBouncer health service stopped immediately"
        journalctl -u pgbouncer-simple-health.service --lines=5 --no-pager
    fi
else
    error "❌ Failed to start PgBouncer health service"
    journalctl -u pgbouncer-simple-health.service --lines=10 --no-pager
fi

# Enable services
systemctl enable pg-simple-health.service
systemctl enable pgbouncer-simple-health.service

sleep 3

info "Step 6: Comprehensive endpoint testing"

echo "Service status check:"
systemctl status pg-simple-health.service --no-pager -l | head -3
systemctl status pgbouncer-simple-health.service --no-pager -l | head -3
echo

echo "Port binding check:"
ss -tupln | grep -E ':(8001|8002)' || echo "❌ No services bound to 8001/8002"
echo

echo "Local endpoint tests:"
echo -n "PostgreSQL (localhost:8001): "
timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "PgBouncer (localhost:8002): "
timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

# Test self-IP access
SELF_IP=$(hostname -I | awk '{print $1}')
echo -n "PostgreSQL ($SELF_IP:8001): "
timeout 3 curl -sf http://$SELF_IP:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "PgBouncer ($SELF_IP:8002): "
timeout 3 curl -sf http://$SELF_IP:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo

if timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1 && timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "🎉 Both local health endpoints are working!"
    
    echo
    info "Sample responses:"
    echo "PostgreSQL Health:"
    curl -s http://localhost:8001 | jq . 2>/dev/null || curl -s http://localhost:8001
    echo
    echo "PgBouncer Health:"
    curl -s http://localhost:8002 | jq . 2>/dev/null || curl -s http://localhost:8002
    echo
else
    error "❌ Local health endpoints still not working"
    
    echo
    info "Troubleshooting information:"
    echo "Recent PostgreSQL health service logs:"
    journalctl -u pg-simple-health.service --lines=10 --no-pager
    echo
    echo "Recent PgBouncer health service logs:"
    journalctl -u pgbouncer-simple-health.service --lines=10 --no-pager
fi

echo
success "🔧 Complete diagnostic finished!"

echo
info "📋 Summary:"
echo "- Created ultra-simple health scripts using netcat"
echo "- Eliminated complex socat and heredoc syntax"
echo "- Used basic systemd services without complex options"
echo "- Services: pg-simple-health.service, pgbouncer-simple-health.service"

echo
info "🚀 Next steps:"
echo "1. Run this script on BOTH servers"
echo "2. Test: sudo ./test_health_checks_v1.2.sh"
echo "3. If local endpoints work, cross-node issues may be network/firewall related"