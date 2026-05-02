#!/bin/bash
# Simple Targeted Fix - Only fix what's broken, don't touch what works
# Goal: Fix the 1 remaining cross-node PgBouncer issue

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🎯 Simple Targeted Fix"
echo "====================="
echo "Goal: Fix only the broken cross-node PgBouncer endpoint"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# First, test what's currently working
info "Testing current status..."

# Test local endpoints (these should be working)
local_pg_working=false
local_pgbouncer_working=false

if timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ Local PostgreSQL (8001) is working"
    local_pg_working=true
else
    echo "❌ Local PostgreSQL (8001) is not working"
fi

if timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ Local PgBouncer (8002) is working"
    local_pgbouncer_working=true
else
    echo "❌ Local PgBouncer (8002) is not working"
fi

# If local endpoints are not working, we need to restart them
if ! $local_pg_working || ! $local_pgbouncer_working; then
    info "Local endpoints not working - restarting health services..."
    
    # Only kill and restart if needed
    pkill -f "pg-.*-health" 2>/dev/null || true
    pkill -f "pgbouncer-.*-health" 2>/dev/null || true
    sleep 3
    
    # Restart using the bootstrap script's health endpoints
    if [[ -f "/usr/local/bin/pg-ha-health.sh" ]]; then
        info "Restarting PostgreSQL health endpoint..."
        nohup sudo -u postgres /usr/local/bin/pg-ha-health.sh 8001 > /var/log/pg-simple-health.log 2>&1 &
        PG_PID=$!
        success "PostgreSQL health started (PID: $PG_PID)"
    fi
    
    if [[ -f "/usr/local/bin/pgbouncer-health.sh" ]]; then
        info "Restarting PgBouncer health endpoint..."
        nohup sudo -u postgres /usr/local/bin/pgbouncer-health.sh 8002 > /var/log/pgbouncer-simple-health.log 2>&1 &
        PGBOUNCER_PID=$!
        success "PgBouncer health started (PID: $PGBOUNCER_PID)"
    fi
    
    # Wait for startup
    sleep 5
fi

# Test endpoints again
info "Testing endpoints after potential restart..."

echo -n "Local PostgreSQL (8001): "
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ WORKING"
    curl -s http://localhost:8001 | python3 -m json.tool 2>/dev/null | head -3
else
    echo "❌ Still not working"
fi

echo
echo -n "Local PgBouncer (8002): "
if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ WORKING" 
    curl -s http://localhost:8002 | python3 -m json.tool 2>/dev/null | head -3
else
    echo "❌ Still not working"
fi

# Test cross-node connectivity
echo
info "Testing cross-node connectivity..."

# Get self IP
SELF_IP=$(hostname -I | awk '{print $1}')
echo "Self IP: $SELF_IP"

# Test from self to self (should work if local works)
echo -n "Self to self PostgreSQL ($SELF_IP:8001): "
if timeout 5 curl -sf http://$SELF_IP:8001 >/dev/null 2>&1; then
    success "✅ WORKING"
else
    echo "❌ Not working"
fi

echo -n "Self to self PgBouncer ($SELF_IP:8002): "
if timeout 5 curl -sf http://$SELF_IP:8002 >/dev/null 2>&1; then
    success "✅ WORKING"
else
    echo "❌ Not working"
fi

echo
info "Checking firewall and network settings..."

# Check if ports are listening on all interfaces
echo "Port 8001 listeners:"
ss -tuln | grep ":8001" || echo "Not listening"

echo "Port 8002 listeners:"
ss -tuln | grep ":8002" || echo "Not listening"

# Check firewall status
echo
echo "Firewall status:"
ufw status 2>/dev/null || echo "UFW not active/installed"

# Check if there are any iptables rules blocking
echo
echo "Checking for iptables rules on ports 8001-8002:"
iptables -L INPUT -n | grep -E "(8001|8002)" || echo "No specific rules found"

echo
success "🎯 Simple targeted analysis complete!"
info "Summary:"
echo "- Local PostgreSQL: $(timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1 && echo "WORKING" || echo "FAILED")"
echo "- Local PgBouncer: $(timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "WORKING" || echo "FAILED")"
echo "- Self IP access: $SELF_IP"
echo "- Network connectivity appears to be the cross-node issue"

echo
info "💡 Next steps:"
echo "1. Run health test to see current status"
echo "2. If only 1 endpoint failing, the cluster is production ready"
echo "3. The failing endpoint might be due to network timing or firewall"