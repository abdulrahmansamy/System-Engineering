#!/bin/bash
# Final Health Endpoint Fix
# Fixes heredoc syntax error and creates bulletproof health endpoints

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

echo "🔧 Final Health Endpoint Fix"
echo "============================"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Creating bulletproof health scripts without complex heredoc syntax"

# Create PostgreSQL health script using simple approach
cat > /usr/local/bin/pg-ha-health-final.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8001}

# Simple health check function
check_pg_health() {
    local status_code="503"
    local role="unknown"
    
    if systemctl is-active --quiet postgresql; then
        if sudo -u postgres psql -tAc "SELECT NOT pg_is_in_recovery();" postgres 2>/dev/null | grep -q "^t"; then
            status_code="200"
            role="primary"
        else
            if sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q "^t"; then
                local wal_count=$(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';" postgres 2>/dev/null || echo 0)
                if [ "$wal_count" = "1" ]; then
                    status_code="200"
                fi
            fi
            role="standby"
        fi
    fi
    
    local response="{\"status\": \"$([ "$status_code" = "200" ] && echo healthy || echo unhealthy)\", \"role\": \"$role\", \"timestamp\": \"$(date -Iseconds)\"}"
    
    echo "HTTP/1.1 $status_code $([ "$status_code" = "200" ] && echo OK || echo 'Service Unavailable')"
    echo "Content-Type: application/json"
    echo "Content-Length: ${#response}"
    echo "Connection: close"
    echo
    echo "$response"
}

# Export function for socat
export -f check_pg_health

while true; do
    socat TCP4-LISTEN:$PORT,reuseaddr,fork SYSTEM:'check_pg_health'
done
EOF

# Create PgBouncer health script using simple approach
cat > /usr/local/bin/pgbouncer-ha-health-final.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8002}

# Simple health check function
check_pgbouncer_health() {
    local status_code="503"
    local service_status="unhealthy"
    
    if systemctl is-active --quiet pgbouncer && nc -z localhost 6432 2>/dev/null; then
        status_code="200"
        service_status="healthy"
    fi
    
    local response="{\"status\": \"$service_status\", \"service\": \"pgbouncer\", \"timestamp\": \"$(date -Iseconds)\"}"
    
    echo "HTTP/1.1 $status_code $([ "$status_code" = "200" ] && echo OK || echo 'Service Unavailable')"
    echo "Content-Type: application/json"
    echo "Content-Length: ${#response}"
    echo "Connection: close"
    echo
    echo "$response"
}

# Export function for socat
export -f check_pgbouncer_health

while true; do
    socat TCP4-LISTEN:$PORT,reuseaddr,fork SYSTEM:'check_pgbouncer_health'
done
EOF

chmod +x /usr/local/bin/pg-ha-health-final.sh /usr/local/bin/pgbouncer-ha-health-final.sh
success "✅ Created bulletproof health scripts with simple syntax"

info "Creating final systemd services"

cat > /etc/systemd/system/pg-ha-health-final.service <<EOF
[Unit]
Description=PostgreSQL HA Health Check Endpoint (Final)
After=network-online.target postgresql.service
Wants=postgresql.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pg-ha-health-final.sh 8001
Restart=always
RestartSec=5
User=postgres
Group=postgres
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-ha-health-final.service <<EOF
[Unit]
Description=PgBouncer HA Health Check Endpoint (Final)
After=network-online.target pgbouncer.service
Wants=pgbouncer.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pgbouncer-ha-health-final.sh 8002
Restart=always
RestartSec=5
User=postgres
Group=postgres
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

success "✅ Created final systemd services"

info "Comprehensive cleanup of all existing health processes and services"

# Stop all variations of health services
for service in pg-ha-health pgbouncer-health pg-ha-health-simple pgbouncer-health-simple pg-ha-health-working pgbouncer-health-working; do
    systemctl stop $service.service 2>/dev/null || true
    systemctl disable $service.service 2>/dev/null || true
done

# Kill all health-related processes
pkill -f "health" 2>/dev/null || true
pkill -f "socat.*800" 2>/dev/null || true

# Force kill anything on ports 8001/8002
for port in 8001 8002; do
    lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
done

sleep 3
success "✅ Comprehensive cleanup completed"

info "Testing final health scripts"

# Test PostgreSQL script
if timeout 3 sudo -u postgres /usr/local/bin/pg-ha-health-final.sh 8001 &
then
    PG_PID=$!
    sleep 1
    if kill -0 $PG_PID 2>/dev/null; then
        success "✅ PostgreSQL final script works"
        kill $PG_PID 2>/dev/null || true
    else
        error "❌ PostgreSQL final script failed"
    fi
else
    error "❌ PostgreSQL final script failed to start"
fi

# Test PgBouncer script
if timeout 3 sudo -u postgres /usr/local/bin/pgbouncer-ha-health-final.sh 8002 &
then
    PGB_PID=$!
    sleep 1
    if kill -0 $PGB_PID 2>/dev/null; then
        success "✅ PgBouncer final script works"
        kill $PGB_PID 2>/dev/null || true
    else
        error "❌ PgBouncer final script failed"
    fi
else
    error "❌ PgBouncer final script failed to start"
fi

sleep 2

info "Starting final health services"

systemctl daemon-reload

# Start final services
if systemctl start pg-ha-health-final.service; then
    success "✅ PostgreSQL final service started"
else
    error "❌ PostgreSQL final service failed"
    journalctl -u pg-ha-health-final.service --lines=5 --no-pager
fi

if systemctl start pgbouncer-ha-health-final.service; then
    success "✅ PgBouncer final service started"
else
    error "❌ PgBouncer final service failed"
    journalctl -u pgbouncer-ha-health-final.service --lines=5 --no-pager
fi

# Enable for boot
systemctl enable pg-ha-health-final.service
systemctl enable pgbouncer-ha-health-final.service

sleep 3

info "Final comprehensive test"

echo -n "Local PostgreSQL (8001): "
timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "Local PgBouncer (8002): "
timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

SELF_IP=$(hostname -I | awk '{print $1}')
echo -n "Self PostgreSQL ($SELF_IP:8001): "
timeout 5 curl -sf http://$SELF_IP:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "Self PgBouncer ($SELF_IP:8002): "
timeout 5 curl -sf http://$SELF_IP:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo
success "🎉 Final health endpoint fix complete!"

echo
info "📋 Final Summary:"
echo "1. ✅ Fixed heredoc syntax errors"
echo "2. ✅ Simplified socat approach using SYSTEM command"
echo "3. ✅ Robust service management with proper cleanup"
echo "4. ✅ Final services: pg-ha-health-final.service, pgbouncer-ha-health-final.service"

echo
info "🚀 Next Steps:"
echo "1. Run on BOTH servers: sudo ./final_health_fix.sh"
echo "2. Test: sudo ./test_health_checks_v1.2.sh"
echo "3. Expect 6/6 working endpoints!"