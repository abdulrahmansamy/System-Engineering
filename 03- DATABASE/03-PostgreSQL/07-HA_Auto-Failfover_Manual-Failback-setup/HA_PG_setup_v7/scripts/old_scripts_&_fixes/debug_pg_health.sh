#!/bin/bash
# Debug PostgreSQL Health Issues
# Run this to see what's happening with the PostgreSQL health checks

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

echo "🔍 PostgreSQL Health Debug"
echo "=========================="
echo

# Test 1: Check PostgreSQL service status
info "1. Testing PostgreSQL service status..."
if systemctl is-active --quiet postgresql; then
    success "✅ PostgreSQL service is active"
    systemctl status postgresql --no-pager -l | head -5
else
    error "❌ PostgreSQL service is not active"
    exit 1
fi

echo
# Test 2: Check database connectivity
info "2. Testing database connectivity..."
if sudo -u postgres psql -c "SELECT 'Connection OK' as status;" >/dev/null 2>&1; then
    success "✅ Database connection working"
else
    error "❌ Cannot connect to database"
    sudo -u postgres psql -c "SELECT 'Connection OK' as status;" || true
    exit 1
fi

echo
# Test 3: Check recovery status
info "3. Testing recovery status detection..."
echo -n "Is in recovery: "
sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" postgres || echo "FAILED"

echo -n "Is NOT in recovery: "
sudo -u postgres psql -tAc "SELECT NOT pg_is_in_recovery();" postgres || echo "FAILED"

echo
# Test 4: Test the exact commands from health check
info "4. Testing exact health check commands..."

echo -n "SystemCtl check: "
if systemctl is-active postgresql >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
fi

echo -n "Primary check: "
primary_result=$(sudo -u postgres psql -tAc 'SELECT NOT pg_is_in_recovery();' postgres 2>/dev/null || echo "FAILED")
echo "Result: '$primary_result'"
if [[ "$primary_result" == "t" ]]; then
    success "This node is PRIMARY"
elif [[ "$primary_result" == "f" ]]; then
    info "This node is not primary, checking if standby..."
    
    echo -n "Standby check: "
    standby_result=$(sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();' postgres 2>/dev/null || echo "FAILED")
    echo "Result: '$standby_result'"
    
    if [[ "$standby_result" == "t" ]]; then
        success "This node is STANDBY"
        
        echo -n "WAL receiver check: "
        wal_result=$(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';" postgres 2>/dev/null || echo "FAILED")
        echo "Result: '$wal_result'"
        
        if [[ "$wal_result" =~ ^[0-9]+$ ]] && [[ "$wal_result" -ge 1 ]]; then
            success "WAL receiver is streaming - standby is healthy"
        else
            warn "WAL receiver not streaming properly"
        fi
    else
        error "Node is neither primary nor standby"
    fi
else
    error "Primary check failed: $primary_result"
fi

echo
# Test 5: Show current replication status
info "5. Current replication status..."
echo "PostgreSQL version:"
sudo -u postgres psql -c "SELECT version();" | head -1

echo
echo "Current role and replication status:"
sudo -u postgres psql -c "
SELECT 
    CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role,
    pg_is_in_recovery() as in_recovery,
    (SELECT count(*) FROM pg_stat_replication) as replication_connections,
    (SELECT count(*) FROM pg_stat_wal_receiver WHERE status = 'streaming') as wal_receivers;
" || true

echo
success "🎯 Debug complete! Check the results above to see what's failing."