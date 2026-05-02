#!/bin/bash
# Quick fix for systemd service port conflicts

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

echo "🔧 Quick Fix: SystemD Service Port Conflicts"
echo "============================================"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Stop and disable conflicting services"
systemctl stop final-pg-health.service final-pgbouncer-health.service 2>/dev/null || true
systemctl disable final-pg-health.service final-pgbouncer-health.service 2>/dev/null || true

info "Step 2: Kill ALL processes on ports 8001/8002"
fuser -k 8001/tcp 2>/dev/null || true
fuser -k 8002/tcp 2>/dev/null || true
sleep 2

info "Step 3: Verify ports are free"
if ss -tuln | grep -q ":8001 "; then
    error "❌ Port 8001 still in use - manual cleanup needed"
    exit 1
fi

if ss -tuln | grep -q ":8002 "; then
    error "❌ Port 8002 still in use - manual cleanup needed"
    exit 1
fi

success "✅ Ports 8001/8002 are now free"

info "Step 4: Start health services manually (for external connectivity)"

# Start PostgreSQL health service in background
nohup python3 /usr/local/bin/final-pg-health.py > /var/log/pg-health.log 2>&1 &
PG_PID=$!

# Start PgBouncer health service in background  
nohup python3 /usr/local/bin/final-pgbouncer-health.py > /var/log/pgbouncer-health.log 2>&1 &
PGB_PID=$!

sleep 3

info "Step 5: Verify services are running"
if kill -0 $PG_PID 2>/dev/null; then
    success "✅ PostgreSQL health service running (PID: $PG_PID)"
else
    error "❌ PostgreSQL health service failed to start"
fi

if kill -0 $PGB_PID 2>/dev/null; then
    success "✅ PgBouncer health service running (PID: $PGB_PID)"
else
    error "❌ PgBouncer health service failed to start"
fi

info "Step 6: Test endpoints"
sleep 2

echo "Testing PostgreSQL health endpoint:"
curl -s http://localhost:8001 | jq . 2>/dev/null && success "✅ PostgreSQL health endpoint working" || error "❌ PostgreSQL health endpoint failed"

echo "Testing PgBouncer health endpoint:"
curl -s http://localhost:8002 | jq . 2>/dev/null && success "✅ PgBouncer health endpoint working" || error "❌ PgBouncer health endpoint failed"

info "Step 7: Save PIDs for cleanup"
echo $PG_PID > /tmp/pg-health.pid
echo $PGB_PID > /tmp/pgbouncer-health.pid

success "🎉 Quick fix complete!"
info "Health services are now running manually"
info "PIDs saved to /tmp/pg-health.pid and /tmp/pgbouncer-health.pid"
info "To stop: kill \$(cat /tmp/pg-health.pid) \$(cat /tmp/pgbouncer-health.pid)"