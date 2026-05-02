#!/bin/bash
# PostgreSQL Streaming Replication Deployment Verification
# Quick verification script for the expert-validated setup

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { printf "%b✅ %s%b\n" "$GREEN" "$*" "$NC"; }
fail() { printf "%b❌ %s%b\n" "$RED" "$*" "$NC"; }
info() { printf "%b🔍 %s%b\n" "$YELLOW" "$*" "$NC"; }

echo "PostgreSQL Streaming Replication Deployment Verification"
echo "========================================================"

# 1. Check PostgreSQL service
if systemctl is-active --quiet postgresql; then
    success "PostgreSQL service is running"
else
    fail "PostgreSQL service is not running"
fi

# 2. Check database connectivity
if sudo -u postgres psql -c "SELECT version();" postgres >/dev/null 2>&1; then
    success "PostgreSQL database is accessible"
    info "Version: $(sudo -u postgres psql -Atqc "SELECT version();" postgres | cut -d' ' -f1-2)"
else
    fail "Cannot connect to PostgreSQL database"
fi

# 3. Check node role
if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
    role="standby"
elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
    role="primary"
else
    role="unknown"
fi
success "Node role: $role"

# 4. Check streaming replication configuration
if sudo -u postgres psql -Atqc "SHOW wal_level;" postgres 2>/dev/null | grep -q replica; then
    success "WAL level configured for replication"
else
    fail "WAL level not configured for replication"
fi

# 5. Check replication users
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='replication' AND rolreplication;" postgres 2>/dev/null | grep -q 1; then
    success "Replication user exists with proper privileges"
else
    fail "Replication user missing or lacks privileges"
fi

# 6. Check PgBouncer
if systemctl is-active --quiet pgbouncer; then
    success "PgBouncer service is running"
    
    if timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        success "PgBouncer is accepting connections on port 6432"
    else
        fail "PgBouncer not accepting connections"
    fi
else
    fail "PgBouncer service is not running"
fi

# 7. Check health endpoints
if timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "PostgreSQL health endpoint responding"
else
    fail "PostgreSQL health endpoint not responding"
fi

if timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "PgBouncer health endpoint responding"
else
    fail "PgBouncer health endpoint not responding"
fi

# 8. Check failover script
if [[ -f "/usr/local/bin/pg-failover-manager.sh" && -x "/usr/local/bin/pg-failover-manager.sh" ]]; then
    success "Custom failover script exists and is executable"
else
    fail "Custom failover script missing or not executable"
fi

# 9. Show replication status
echo
info "=== Replication Status ==="
if [[ "$role" == "primary" ]]; then
    info "Active replication connections:"
    sudo -u postgres psql -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;" postgres 2>/dev/null || echo "No active connections"
    
    info "Replication slots:"
    sudo -u postgres psql -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;" postgres 2>/dev/null || echo "No replication slots"
    
elif [[ "$role" == "standby" ]]; then
    info "WAL receiver status:"
    sudo -u postgres psql -c "SELECT status, received_lsn FROM pg_stat_wal_receiver;" postgres 2>/dev/null || echo "No WAL receiver info"
    
    info "Replication lag:"
    local lag=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp());" postgres 2>/dev/null || echo "unknown")
    echo "Lag: $lag seconds"
fi

# 10. Connection information
echo
info "=== Connection Information ==="
current_ip=$(hostname -I | awk '{print $1}')
echo "PostgreSQL Direct: postgresql://postgres:***@$current_ip:5432/postgres"
echo "PgBouncer Pooled: postgresql://postgres:***@$current_ip:6432/postgres"
echo "PostgreSQL Health: http://$current_ip:8001"
echo "PgBouncer Health: http://$current_ip:8002"
echo "Node Role: $role"

echo
success "Deployment verification completed!"