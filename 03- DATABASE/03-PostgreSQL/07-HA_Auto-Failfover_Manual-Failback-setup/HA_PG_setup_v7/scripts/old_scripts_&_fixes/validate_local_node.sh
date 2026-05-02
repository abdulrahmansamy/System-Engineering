#!/bin/bash
# PostgreSQL HA Local Node Validation Script
# Run this script on each PostgreSQL server individually

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
debug() { echo -e "${BLUE}[INFO]${NC} $*"; }

echo "=========================================="
echo "PostgreSQL HA Local Node Validation"
echo "=========================================="
echo "Hostname: $(hostname)"
echo "IP Address: $(hostname -I | awk '{print $1}')"
echo "Time: $(date)"
echo ""

# Check 1: PostgreSQL Service
echo "1. PostgreSQL Service Status:"
if systemctl is-active --quiet postgresql; then
    info "PostgreSQL service is running"
else
    error "PostgreSQL service is not running"
    exit 1
fi

# Check 2: Database Connectivity
echo ""
echo "2. Database Connectivity:"
if sudo -u postgres psql -Atqc "SELECT 1;" >/dev/null 2>&1; then
    info "PostgreSQL database is accessible locally"
else
    error "Cannot connect to PostgreSQL database"
    exit 1
fi

# Check 3: Node Role
echo ""
echo "3. Node Role and Status:"
pg_version=$(sudo -u postgres psql -Atqc "SELECT version();" | head -1)
info "PostgreSQL Version: $pg_version"

is_in_recovery=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null)
if [[ "$is_in_recovery" == "f" ]]; then
    info "Node Role: PRIMARY"
    node_role="primary"
elif [[ "$is_in_recovery" == "t" ]]; then
    info "Node Role: STANDBY (in recovery mode)"
    node_role="standby"
else
    error "Cannot determine node role"
    exit 1
fi

# Check 4: Replication Status (Role-specific)
echo ""
echo "4. Replication Status:"
if [[ "$node_role" == "primary" ]]; then
    # Primary-specific checks
    debug "Checking outbound replication connections..."
    
    repl_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null)
    if [[ "$repl_count" -gt 0 ]]; then
        info "Active replication connections: $repl_count"
        
        echo ""
        debug "Replication connection details:"
        sudo -u postgres psql -c "
            SELECT 
                client_addr as standby_ip,
                application_name,
                state,
                sync_state,
                pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) as write_lag,
                pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn)) as flush_lag,
                pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) as replay_lag
            FROM pg_stat_replication;
        " 2>/dev/null
        
    else
        warn "No active replication connections (standby may be down)"
    fi
    
    # Check replication slots
    debug "Checking replication slots..."
    slot_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_replication_slots;" 2>/dev/null)
    if [[ "$slot_count" -gt 0 ]]; then
        info "Replication slots: $slot_count"
        sudo -u postgres psql -c "
            SELECT 
                slot_name,
                slot_type,
                active,
                wal_status,
                safe_wal_size
            FROM pg_replication_slots;
        " 2>/dev/null
    else
        warn "No replication slots found"
    fi
    
elif [[ "$node_role" == "standby" ]]; then
    # Standby-specific checks
    debug "Checking inbound replication status..."
    
    wal_receiver=$(sudo -u postgres psql -Atqc "SELECT status FROM pg_stat_wal_receiver;" 2>/dev/null || echo "")
    if [[ "$wal_receiver" == "streaming" ]]; then
        info "WAL receiver status: $wal_receiver (actively receiving from primary)"
        
        echo ""
        debug "WAL receiver details:"
        sudo -u postgres psql -c "
            SELECT 
                sender_host as primary_ip,
                sender_port,
                status,
                receive_start_lsn,
                received_lsn,
                last_msg_send_time,
                last_msg_receipt_time,
                latest_end_lsn,
                latest_end_time
            FROM pg_stat_wal_receiver;
        " 2>/dev/null
        
    else
        error "WAL receiver status: '$wal_receiver' (not streaming!)"
    fi
    
    # Check recovery status
    debug "Checking recovery progress..."
    last_replay_lsn=$(sudo -u postgres psql -Atqc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null)
    recovery_time=$(sudo -u postgres psql -Atqc "SELECT pg_last_xact_replay_timestamp();" 2>/dev/null)
    
    info "Last replayed LSN: $last_replay_lsn"
    info "Last transaction replay time: $recovery_time"
fi

# Check 5: Repmgr Status
echo ""
echo "5. Repmgr Configuration:"
if [[ -f /etc/repmgr/repmgr.conf ]]; then
    info "Repmgr configuration file exists"
    
    if command -v repmgr >/dev/null 2>&1; then
        info "Repmgr is installed"
        
        # Get node info from config
        node_id=$(grep "^node_id" /etc/repmgr/repmgr.conf | cut -d'=' -f2 | tr -d ' ' || echo "unknown")
        node_name=$(grep "^node_name" /etc/repmgr/repmgr.conf | cut -d'=' -f2 | tr -d "' " || echo "unknown")
        
        info "Node ID: $node_id"
        info "Node Name: $node_name"
        
        # Check repmgr cluster status
        debug "Checking repmgr cluster status..."
        if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null; then
            info "Repmgr cluster status is available"
        else
            warn "Cannot get repmgr cluster status"
        fi
        
    else
        error "Repmgr is not installed"
    fi
else
    error "Repmgr configuration file not found"
fi

# Check 6: Services Status  
echo ""
echo "6. Related Services:"

if systemctl is-active --quiet repmgrd; then
    info "repmgrd service is running"
else
    warn "repmgrd service is not running"
fi

if systemctl is-active --quiet pg-ha-health.service; then
    info "pg-ha-health service is running"
    
    # Test health endpoint
    health_port="8001"  # Default health port
    if curl -s "http://localhost:${health_port}" >/dev/null 2>&1; then
        info "Health endpoint is responding on port $health_port"
        health_response=$(curl -s "http://localhost:${health_port}" 2>/dev/null || echo "{}")
        debug "Health response: $health_response"
    else
        warn "Health endpoint is not responding on port $health_port"
    fi
else
    warn "pg-ha-health service is not running"
fi

# Check 7: Key Configuration Files
echo ""
echo "7. Configuration Files:"

if [[ -f /etc/postgresql/17/main/postgresql.conf ]]; then
    info "PostgreSQL config file exists"
    
    # Check key HA settings
    wal_level=$(sudo -u postgres psql -Atqc "SHOW wal_level;" 2>/dev/null)
    max_wal_senders=$(sudo -u postgres psql -Atqc "SHOW max_wal_senders;" 2>/dev/null)
    hot_standby=$(sudo -u postgres psql -Atqc "SHOW hot_standby;" 2>/dev/null)
    
    info "WAL level: $wal_level"
    info "Max WAL senders: $max_wal_senders"
    info "Hot standby: $hot_standby"
    
    if [[ "$wal_level" == "replica" && "$max_wal_senders" -gt 0 ]]; then
        info "✓ Replication settings are properly configured"
    else
        warn "⚠ Replication settings may need review"
    fi
else
    error "PostgreSQL configuration file not found"
fi

if [[ -f /etc/postgresql/17/main/pg_hba.conf ]]; then
    info "pg_hba.conf file exists"
    
    # Check for replication entries
    repl_entries=$(grep -c "replication" /etc/postgresql/17/main/pg_hba.conf 2>/dev/null || echo "0")
    if [[ "$repl_entries" -gt 0 ]]; then
        info "✓ Found $repl_entries replication entries in pg_hba.conf"
    else
        warn "⚠ No replication entries found in pg_hba.conf"
    fi
else
    error "pg_hba.conf file not found"
fi

# Summary
echo ""
echo "=========================================="
echo "VALIDATION SUMMARY"
echo "=========================================="
echo "Node Role: $node_role"
echo "PostgreSQL: $(systemctl is-active postgresql)"
echo "Repmgrd: $(systemctl is-active repmgrd || echo "inactive")"
echo "Health Service: $(systemctl is-active pg-ha-health.service || echo "inactive")"

if [[ "$node_role" == "primary" ]]; then
    echo "Replication Connections: $repl_count"
    echo "Replication Slots: $slot_count"
elif [[ "$node_role" == "standby" ]]; then
    echo "WAL Receiver: $wal_receiver"
    echo "Last Replay: $recovery_time"
fi

echo ""
info "Local validation completed successfully!"
echo ""
echo "To validate the entire cluster, run this script on each node:"
echo "• Primary node: 192.168.14.21"  
echo "• Standby node: 192.168.14.22"