#!/bin/bash
# Health Service Debug Script
# Investigates why pg-ha-health.service is failing with fatal signal

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

echo "🔍 Health Service Debug & Fix"
echo "============================"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Checking current service status"

echo "PostgreSQL Health Service:"
systemctl status pg-ha-health.service --no-pager -l || true
echo

echo "PgBouncer Health Service:"
systemctl status pgbouncer-health.service --no-pager -l || true
echo

info "Step 2: Checking service logs"
echo "Recent pg-ha-health.service logs:"
journalctl -u pg-ha-health.service --lines=20 --no-pager || true
echo

echo "Recent pgbouncer-health.service logs:"
journalctl -u pgbouncer-health.service --lines=20 --no-pager || true
echo

info "Step 3: Checking health script permissions and syntax"
echo "PostgreSQL health script:"
ls -la /usr/local/bin/pg-ha-health.sh 2>/dev/null || echo "File not found"
if [[ -f "/usr/local/bin/pg-ha-health.sh" ]]; then
    echo "Checking syntax:"
    bash -n /usr/local/bin/pg-ha-health.sh && echo "Syntax OK" || echo "Syntax ERROR"
fi
echo

echo "PgBouncer health script:"
ls -la /usr/local/bin/pgbouncer-health.sh 2>/dev/null || echo "File not found"
if [[ -f "/usr/local/bin/pgbouncer-health.sh" ]]; then
    echo "Checking syntax:"
    bash -n /usr/local/bin/pgbouncer-health.sh && echo "Syntax OK" || echo "Syntax ERROR"
fi
echo

info "Step 4: Testing ExecStartPre commands"
echo "Testing PostgreSQL cleanup command:"
/bin/bash -lc "pkill -f 'nc -l -p 8001' || true; pkill -f 'pg-http-server.sh' || true; lsof -ti:8001 2>/dev/null | xargs -r kill -9 || true" && echo "✅ PostgreSQL cleanup OK" || echo "❌ PostgreSQL cleanup FAILED"

echo "Testing PgBouncer cleanup command:"
/bin/bash -lc "pkill -f 'nc -l -p 8002' || true; pkill -f 'pgbouncer-http-server.sh' || true; lsof -ti:8002 2>/dev/null | xargs -r kill -9 || true" && echo "✅ PgBouncer cleanup OK" || echo "❌ PgBouncer cleanup FAILED"
echo

info "Step 5: Testing health script execution"
echo "Testing PostgreSQL health script directly:"
if timeout 10 sudo -u postgres /usr/local/bin/pg-ha-health.sh 8001 &
then
    PG_HEALTH_PID=$!
    sleep 2
    if kill -0 $PG_HEALTH_PID 2>/dev/null; then
        echo "✅ PostgreSQL health script started successfully"
        kill $PG_HEALTH_PID 2>/dev/null || true
    else
        echo "❌ PostgreSQL health script failed to start"
    fi
else
    echo "❌ PostgreSQL health script execution failed"
fi
echo

info "Step 6: Creating simplified health services without ExecStartPre"

# Create simplified health services without the problematic ExecStartPre
cat > /etc/systemd/system/pg-ha-health-simple.service <<EOF
[Unit]
Description=PostgreSQL HA Health Check Endpoint (Simplified)
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

cat > /etc/systemd/system/pgbouncer-health-simple.service <<EOF
[Unit]
Description=PgBouncer HA Health Check Endpoint (Simplified)
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

success "Created simplified health services"

info "Step 7: Manual cleanup and service start"

# Manual cleanup first
info "Performing manual cleanup..."
pkill -f "health" 2>/dev/null || true
pkill -f "8001" 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true
sleep 2

# Kill any processes on health ports
for port in 8001 8002; do
    lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
done

# Reload systemd and start simplified services
systemctl daemon-reload

info "Starting simplified health services..."

# Stop existing services
systemctl stop pg-ha-health.service 2>/dev/null || true
systemctl stop pgbouncer-health.service 2>/dev/null || true

# Start simplified services
if systemctl start pg-ha-health-simple.service; then
    success "✅ PostgreSQL health service (simplified) started"
else
    error "❌ PostgreSQL health service (simplified) failed"
    journalctl -u pg-ha-health-simple.service --lines=10 --no-pager
fi

if systemctl start pgbouncer-health-simple.service; then
    success "✅ PgBouncer health service (simplified) started"
else
    error "❌ PgBouncer health service (simplified) failed"
    journalctl -u pgbouncer-health-simple.service --lines=10 --no-pager
fi

sleep 3

info "Step 8: Testing health endpoints"

echo -n "Local PostgreSQL (8001): "
timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "Local PgBouncer (8002): "  
timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

# Test self-IP access
SELF_IP=$(hostname -I | awk '{print $1}')
echo -n "Self PostgreSQL ($SELF_IP:8001): "
timeout 5 curl -sf http://$SELF_IP:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "Self PgBouncer ($SELF_IP:8002): "
timeout 5 curl -sf http://$SELF_IP:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo
success "🎉 Health service debugging complete!"

echo
info "📋 Summary:"
echo "- Simplified services created without ExecStartPre"
echo "- Services should now start without fatal signals"
echo "- Run 'sudo systemctl enable pg-ha-health-simple.service pgbouncer-health-simple.service' to make permanent"
echo "- Test with: sudo ./test_health_checks_v1.2.sh"