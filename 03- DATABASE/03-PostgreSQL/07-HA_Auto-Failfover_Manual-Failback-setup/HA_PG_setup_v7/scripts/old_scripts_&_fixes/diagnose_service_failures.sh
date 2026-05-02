#!/bin/bash
# Diagnose why systemd health services are failing

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "🔍 Diagnosing SystemD Health Service Failures"
echo "=============================================="

info "Step 1: Check service logs for errors"
echo
echo "PostgreSQL Health Service Logs (last 20 lines):"
echo "------------------------------------------------"
journalctl -u final-pg-health.service -n 20 --no-pager || true

echo
echo "PgBouncer Health Service Logs (last 20 lines):"
echo "-----------------------------------------------"
journalctl -u final-pgbouncer-health.service -n 20 --no-pager || true

echo
info "Step 2: Test scripts manually as different users"

echo
echo "Testing as root:"
echo "----------------"
python3 /usr/local/bin/final-pg-health.py &
PG_PID=$!
sleep 2
if kill -0 $PG_PID 2>/dev/null; then
    success "✅ PostgreSQL health script runs as root"
    kill $PG_PID
else
    error "❌ PostgreSQL health script fails as root"
fi

python3 /usr/local/bin/final-pgbouncer-health.py &
PGB_PID=$!
sleep 2
if kill -0 $PGB_PID 2>/dev/null; then
    success "✅ PgBouncer health script runs as root"
    kill $PGB_PID
else
    error "❌ PgBouncer health script fails as root"
fi

echo
echo "Testing as postgres user:"
echo "-------------------------"
sudo -u postgres python3 /usr/local/bin/final-pg-health.py &
PG_PG_PID=$!
sleep 2
if kill -0 $PG_PG_PID 2>/dev/null; then
    success "✅ PostgreSQL health script runs as postgres user"
    sudo kill $PG_PG_PID
else
    error "❌ PostgreSQL health script fails as postgres user"
fi

sudo -u postgres python3 /usr/local/bin/final-pgbouncer-health.py &
PGB_PG_PID=$!
sleep 2
if kill -0 $PGB_PG_PID 2>/dev/null; then
    success "✅ PgBouncer health script runs as postgres user"
    sudo kill $PGB_PG_PID
else
    error "❌ PgBouncer health script fails as postgres user"
fi

echo
info "Step 3: Check port conflicts"
echo
echo "Current port usage:"
ss -tuln | grep -E ':(8001|8002) ' || echo "No ports bound"

echo
echo "Process details for ports 8001/8002:"
lsof -i:8001 2>/dev/null || echo "Port 8001: No processes found"
lsof -i:8002 2>/dev/null || echo "Port 8002: No processes found"

echo
info "Step 4: Check file permissions"
ls -la /usr/local/bin/final-pg-health.py
ls -la /usr/local/bin/final-pgbouncer-health.py
ls -la /etc/systemd/system/final-pg-health.service
ls -la /etc/systemd/system/final-pgbouncer-health.service

echo
info "Step 5: Test direct script execution"
echo
echo "Direct PostgreSQL health test:"
timeout 5 python3 /usr/local/bin/final-pg-health.py &
sleep 2
curl -s http://localhost:8001 | jq . 2>/dev/null || echo "Failed to get response"
pkill -f final-pg-health.py

echo
echo "Direct PgBouncer health test:"
timeout 5 python3 /usr/local/bin/final-pgbouncer-health.py &
sleep 2
curl -s http://localhost:8002 | jq . 2>/dev/null || echo "Failed to get response"
pkill -f final-pgbouncer-health.py

echo
info "Step 6: Systemd service configuration check"
echo
echo "PostgreSQL service configuration:"
cat /etc/systemd/system/final-pg-health.service

echo
echo "PgBouncer service configuration:"
cat /etc/systemd/system/final-pgbouncer-health.service

echo
success "🔍 Diagnosis complete!"
echo
info "Analysis:"
echo "1. Check the service logs above for specific error messages"
echo "2. Verify if scripts run properly as postgres user"
echo "3. Look for port conflicts or permission issues"
echo "4. Check if systemd service configuration is correct"