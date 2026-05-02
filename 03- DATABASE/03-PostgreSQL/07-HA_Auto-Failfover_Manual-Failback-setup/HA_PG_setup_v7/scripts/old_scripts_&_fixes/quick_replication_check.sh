#!/bin/bash
# Quick PostgreSQL HA Replication Health Check
# This script provides a fast health check of replication status

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
PRIMARY_HOST="${1:-192.168.14.21}"
STANDBY_HOST="${2:-192.168.14.22}"
WARN_LAG_MB=10
CRITICAL_LAG_MB=100

info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "PostgreSQL HA Replication Health Check"
echo "======================================="
echo "Primary: $PRIMARY_HOST | Standby: $STANDBY_HOST"
echo "Time: $(date)"
echo ""

# Check 1: Node accessibility via health endpoints
echo "1. Node Connectivity:"
if curl -s "http://${PRIMARY_HOST}:8001" >/dev/null 2>&1; then
    info "Primary health endpoint is accessible"
else
    error "Primary health endpoint is not accessible"
    exit 1
fi

if curl -s "http://${STANDBY_HOST}:8001" >/dev/null 2>&1; then
    info "Standby health endpoint is accessible"
else
    error "Standby health endpoint is not accessible"
    exit 1
fi

# Check 2: Roles via health endpoints
echo ""
echo "2. Node Roles:"
primary_role=$(curl -s "http://${PRIMARY_HOST}:8001" 2>/dev/null | jq -r '.is_in_recovery // "error"' 2>/dev/null || echo "error")
standby_role=$(curl -s "http://${STANDBY_HOST}:8001" 2>/dev/null | jq -r '.is_in_recovery // "error"' 2>/dev/null || echo "error")

if [[ "$primary_role" == "f" ]]; then
    info "Primary is in primary mode"
elif [[ "$primary_role" == "error" ]]; then
    error "Cannot determine primary role"
else
    error "Primary is in recovery mode!"
fi

if [[ "$standby_role" == "t" ]]; then
    info "Standby is in recovery mode"
elif [[ "$standby_role" == "error" ]]; then
    error "Cannot determine standby role"
else
    error "Standby is in primary mode!"
fi

# Check 3: Replication connections
echo ""
echo "3. Replication Status:"
current_host=$(hostname -I | awk '{print $1}')

# Check replication from the appropriate host
if [[ "$current_host" == "$PRIMARY_HOST" ]]; then
    repl_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
else
    repl_count=$(sudo -u postgres psql -h "$PRIMARY_HOST" -U repmgr -d repmgr -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "unknown")
fi

if [[ "$repl_count" -gt 0 ]]; then
    info "Active replication connections: $repl_count"
elif [[ "$repl_count" == "0" ]]; then
    error "No active replication connections"
else
    warn "Cannot check replication connections (remote access limited)"
fi

# Check WAL receiver from the appropriate host
if [[ "$current_host" == "$STANDBY_HOST" ]]; then
    wal_receiver=$(sudo -u postgres psql -Atqc "SELECT status FROM pg_stat_wal_receiver;" 2>/dev/null || echo "")
else
    wal_receiver=$(sudo -u postgres psql -h "$STANDBY_HOST" -U repmgr -d repmgr -Atqc "SELECT status FROM pg_stat_wal_receiver;" 2>/dev/null || echo "")
fi

if [[ "$wal_receiver" == "streaming" ]]; then
    info "Standby is receiving WAL stream"
elif [[ -z "$wal_receiver" ]]; then
    warn "Cannot check WAL receiver status (remote access limited)"
else
    error "Standby WAL receiver status: '$wal_receiver'"
fi

# Check 4: Replication lag
echo ""
echo "4. Replication Lag:"

# Get LSNs from appropriate hosts
if [[ "$current_host" == "$PRIMARY_HOST" ]]; then
    primary_lsn=$(sudo -u postgres psql -Atqc "SELECT pg_current_wal_lsn();" 2>/dev/null)
else
    primary_lsn=$(sudo -u postgres psql -h "$PRIMARY_HOST" -U repmgr -d repmgr -Atqc "SELECT pg_current_wal_lsn();" 2>/dev/null || echo "")
fi

if [[ "$current_host" == "$STANDBY_HOST" ]]; then
    standby_lsn=$(sudo -u postgres psql -Atqc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null)
else
    standby_lsn=$(sudo -u postgres psql -h "$STANDBY_HOST" -U repmgr -d repmgr -Atqc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null || echo "")
fi

if [[ -n "$primary_lsn" && -n "$standby_lsn" ]]; then
    # Calculate lag from appropriate host
    if [[ "$current_host" == "$PRIMARY_HOST" ]]; then
        lag_bytes=$(sudo -u postgres psql -Atqc "SELECT pg_wal_lsn_diff('$primary_lsn', '$standby_lsn');" 2>/dev/null)
    else
        lag_bytes=$(sudo -u postgres psql -h "$PRIMARY_HOST" -U repmgr -d repmgr -Atqc "SELECT pg_wal_lsn_diff('$primary_lsn', '$standby_lsn');" 2>/dev/null || echo "-1")
    fi
    
    if [[ "$lag_bytes" != "-1" && -n "$lag_bytes" ]]; then
        lag_mb=$(echo "scale=2; $lag_bytes / 1024 / 1024" | bc)
    
        if (( $(echo "$lag_mb < $WARN_LAG_MB" | bc -l) )); then
            info "Replication lag: ${lag_mb} MB (Good)"
        elif (( $(echo "$lag_mb < $CRITICAL_LAG_MB" | bc -l) )); then
            warn "Replication lag: ${lag_mb} MB (Warning threshold: ${WARN_LAG_MB} MB)"
        else
            error "Replication lag: ${lag_mb} MB (Critical threshold: ${CRITICAL_LAG_MB} MB)"
        fi
    else
        warn "Cannot calculate replication lag (remote access limited)"
    fi
else
    warn "Cannot determine replication lag (missing LSN data)"
fi

# Check 5: Repmgr status (quick)
echo ""
echo "5. Cluster Status:"
if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show --compact 2>/dev/null | grep -q "running"; then
    info "Repmgr cluster is operational"
    running_nodes=$(sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show --compact 2>/dev/null | grep -c "running" || echo "0")
    info "Running nodes: $running_nodes"
else
    warn "Repmgr cluster status check failed"
fi

echo ""
echo "Health Check Complete"
echo "===================="