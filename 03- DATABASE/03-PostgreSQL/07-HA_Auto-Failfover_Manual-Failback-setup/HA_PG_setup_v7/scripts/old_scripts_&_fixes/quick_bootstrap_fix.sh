#!/bin/bash
# Quick Bootstrap Fix and Test Script
# Fixes the MAINPID issue and completes the bootstrap

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🔧 Quick Bootstrap Fix and Test"
echo "==============================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Clean up any incomplete bootstrap state"
rm -f /var/lib/postgresql/.bootstrap/* 2>/dev/null || true

info "Step 2: Kill any existing health processes"
pkill -f "health" 2>/dev/null || true
pkill -f "8001" 2>/dev/null || true  
pkill -f "8002" 2>/dev/null || true
sleep 2

info "Step 3: Run the fixed bootstrap script"
if ./postgresql_ha_bootstrap_clean_v3.sh; then
    success "✅ Bootstrap completed successfully!"
else
    echo "❌ Bootstrap failed, checking logs..."
    tail -10 /var/log/pg-bootstrap/bootstrap.log 2>/dev/null || echo "No bootstrap log found"
    exit 1
fi

echo
info "Step 4: Verify services are running"

echo -n "PostgreSQL: "
systemctl is-active postgresql >/dev/null 2>&1 && echo "✅ ACTIVE" || echo "❌ INACTIVE"

echo -n "PgBouncer: "
systemctl is-active pgbouncer >/dev/null 2>&1 && echo "✅ ACTIVE" || echo "❌ INACTIVE"

echo -n "PostgreSQL Health: "
systemctl is-active pg-ha-health >/dev/null 2>&1 && echo "✅ ACTIVE" || echo "❌ INACTIVE"

echo -n "PgBouncer Health: "
systemctl is-active pgbouncer-health >/dev/null 2>&1 && echo "✅ ACTIVE" || echo "❌ INACTIVE"

echo -n "Repmgrd: "
systemctl is-active repmgrd >/dev/null 2>&1 && echo "✅ ACTIVE" || echo "❌ INACTIVE"

echo
info "Step 5: Test health endpoints (quick check)"

echo -n "Local PostgreSQL (8001): "
timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "Local PgBouncer (8002): "
timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

# Get self IP
SELF_IP=$(hostname -I | awk '{print $1}')
echo -n "Self IP PostgreSQL ($SELF_IP:8001): "
timeout 3 curl -sf http://$SELF_IP:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "Self IP PgBouncer ($SELF_IP:8002): "
timeout 3 curl -sf http://$SELF_IP:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo
success "🎉 Quick fix complete! Now run the comprehensive test:"
echo "sudo ./test_health_checks_v1.2.sh"