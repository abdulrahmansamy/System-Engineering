#!/bin/bash
# Final Health Endpoint Fix for Both Primary and Standby
# Quick fix for the health endpoint issues

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "🔧 Final Health Endpoint Fix"
echo "============================"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root"
    exit 1
fi

info "Stopping and restarting all health services..."

# Stop all health services
systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true
sleep 2

# Kill any hanging processes
pkill -f pg-ha-health.sh 2>/dev/null || true
pkill -f pgbouncer-health.sh 2>/dev/null || true
sleep 1

# Reload systemd daemon
systemctl daemon-reload

# Start health services
info "Starting PostgreSQL health endpoint..."
systemctl start pg-ha-health.service
sleep 2

if systemctl is-active --quiet pg-ha-health.service; then
    success "✅ PostgreSQL health service is running"
else
    warn "PostgreSQL health service issue, checking logs..."
    journalctl -u pg-ha-health.service --lines=5 --no-pager
fi

info "Starting PgBouncer health endpoint..."
systemctl start pgbouncer-health.service
sleep 2

if systemctl is-active --quiet pgbouncer-health.service; then
    success "✅ PgBouncer health service is running"
else
    warn "PgBouncer health service issue, checking logs..."
    journalctl -u pgbouncer-health.service --lines=5 --no-pager
fi

echo
info "Testing health endpoints..."

# Test PostgreSQL health endpoint
echo -n "PostgreSQL Health (port 8001): "
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ RESPONDING"
    curl -s http://localhost:8001 2>/dev/null | jq . 2>/dev/null || curl -s http://localhost:8001
else
    warn "❌ NOT RESPONDING"
    info "Checking if port is open..."
    ss -tulpn | grep :8001 || echo "Port 8001 not listening"
fi

echo
echo -n "PgBouncer Health (port 8002): "
if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ RESPONDING"
    curl -s http://localhost:8002 2>/dev/null | jq . 2>/dev/null || curl -s http://localhost:8002
else
    warn "❌ NOT RESPONDING"
    info "Checking if port is open..."
    ss -tulpn | grep :8002 || echo "Port 8002 not listening"
fi

echo
info "Service status summary:"
systemctl is-active pg-ha-health.service && echo "✅ pg-ha-health: ACTIVE" || echo "❌ pg-ha-health: INACTIVE"
systemctl is_active pgbouncer-health.service && echo "✅ pgbouncer-health: ACTIVE" || echo "❌ pgbouncer-health: INACTIVE"
systemctl is-active postgresql && echo "✅ postgresql: ACTIVE" || echo "❌ postgresql: INACTIVE" 
systemctl is-active pgbouncer && echo "✅ pgbouncer: ACTIVE" || echo "❌ pgbouncer: INACTIVE"
systemctl is-active repmgrd && echo "✅ repmgrd: ACTIVE" || echo "❌ repmgrd: INACTIVE"

echo
success "🎉 Health endpoint fix attempt complete!"
info "If endpoints are still not responding, check firewall rules and port availability."