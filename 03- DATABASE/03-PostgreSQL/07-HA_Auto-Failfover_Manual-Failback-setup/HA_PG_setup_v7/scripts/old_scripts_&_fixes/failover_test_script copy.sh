#!/bin/bash
# PostgreSQL HA Failover and Failback Testing Script
# Enhanced interactive testing with proper repmgr configuration
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"
PGPASS_FILE="/var/lib/postgresql/.pgpass"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

get_pg_role() {
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        echo "stopped"
        return
    fi
    
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        echo "standby"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
        echo "primary"
    else
        echo "unknown"
    fi
}

get_repmgr_config() {
    if [[ ! -f "$REPMGR_CONF_FILE" ]]; then
        error "Repmgr configuration file not found: $REPMGR_CONF_FILE"
        return 1
    fi
    
    local node_id node_name conninfo
    node_id=$(grep "^node_id" "$REPMGR_CONF_FILE" | cut -d'=' -f2 | tr -d ' ' || echo "")
    node_name=$(grep "^node_name" "$REPMGR_CONF_FILE" | cut -d'=' -f2 | tr -d "' " || echo "")
    conninfo=$(grep "^conninfo" "$REPMGR_CONF_FILE" | cut -d'=' -f2- | tr -d "' " || echo "")
    
    if [[ -n "$node_id" && -n "$node_name" && -n "$conninfo" ]]; then
        info "Repmgr configuration:"
        info "  • Node ID: $node_id"
        info "  • Node Name: $node_name"
        info "  • Connection: $conninfo"
        return 0
    else
        error "Invalid repmgr configuration in $REPMGR_CONF_FILE"
        return 1
    fi
}

show_cluster_status() {
    section "Current Cluster Status"
    
    local role
    role=$(get_pg_role)
    info "Current node role: $role"
    
    if [[ "$role" == "stopped" ]]; then
        warn "PostgreSQL is not running on this node"
        return 1
    fi
    
    # Show repmgr cluster status
    info "Repmgr cluster status:"
    if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" repmgr -f "$REPMGR_CONF_FILE" cluster show 2>/dev/null; then
        success "Cluster status retrieved successfully"
    else
        error "Failed to retrieve cluster status"
        return 1
    fi
    
    # Show PostgreSQL replication status if primary
    if [[ "$role" == "primary" ]]; then
        info "PostgreSQL replication status:"
        sudo -u postgres psql -c "SELECT client_addr, application_name, state, sync_state, backend_start FROM pg_stat_replication;" postgres 2>/dev/null || echo "No replication connections"
    elif [[ "$role" == "standby" ]]; then
        info "WAL receiver status:"
        sudo -u postgres psql -c "SELECT status, receive_start_lsn, received_lsn, last_msg_send_time, last_msg_receipt_time FROM pg_stat_wal_receiver;" postgres 2>/dev/null || echo "WAL receiver not active"
        
        # Show replication lag
        local lag
        lag=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" postgres 2>/dev/null || echo "unknown")
        if [[ "$lag" != "unknown" ]]; then
            info "Replication lag: ${lag} seconds"
        fi
    fi
}

test_failover() {
    section "Failover Testing"
    
    local role
    role=$(get_pg_role)
    
    if [[ "$role" != "primary" ]]; then
        error "This node is not the primary. Failover must be initiated from the primary node."
        return 1
    fi
    
    # Show pre-failover status
    info "Current cluster status before failover:"
    show_cluster_status
    
    echo
    warn "🚨 FAILOVER TESTING - READ CAREFULLY 🚨"
    warn "This will test actual failover by stopping PostgreSQL on this primary node."
    warn "The standby should automatically promote itself to primary."
    echo
    info "Failover test steps:"
    info "1. Stop PostgreSQL service on this primary node"
    info "2. Wait for automatic failover (repmgrd should promote standby)"
    info "3. Verify new primary is working"
    info "4. This node will need to be rejoined as standby"
    echo
    
    read -p "❓ Do you want to proceed with failover testing? (yes/NO): " confirm
    if [[ "$confirm" != "yes" ]]; then
        info "Failover testing cancelled"
        return 0
    fi
    
    echo
    info "🔄 Starting failover test..."
    
    # Stop PostgreSQL to trigger failover
    info "Step 1: Stopping PostgreSQL service..."
    if systemctl stop postgresql; then
        success "PostgreSQL stopped successfully"
    else
        error "Failed to stop PostgreSQL"
        return 1
    fi
    
    info "Step 2: Waiting for automatic failover (30 seconds)..."
    for i in {30..1}; do
        printf "\r  Waiting... %2d seconds" $i
        sleep 1
    done
    echo
    
    # Check cluster status from standby node
    info "Step 3: Checking if failover completed..."
    
    # Since this node is now down, we can't check the cluster status from here
    # The user needs to check from the new primary (former standby)
    
    warn "📋 Manual verification required:"
    info "1. SSH to the standby node (former standby)"
    info "2. Run: sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f /etc/repmgr/repmgr.conf cluster show"
    info "3. Verify the standby has been promoted to primary"
    info "4. Test database connectivity on the new primary"
    
    echo
    warn "🔧 To rejoin this node as standby after failover:"
    info "1. Ensure the new primary is stable"
    info "2. On this node, run the rejoin command (see failback testing)"
    
    success "Failover test initiated. Check the other node for results."
}

test_failback() {
    section "Failback Testing"
    
    local role
    role=$(get_pg_role)
    
    info "Current node status: $role"
    
    if [[ "$role" == "stopped" ]]; then
        info "PostgreSQL is stopped on this node - this is expected after failover"
        
        echo
        info "🔄 Failback process (rejoining as standby):"
        info "This will rejoin this node to the cluster as a standby"
        
        # Get the new primary's connection info
        read -p "❓ Enter the new primary's IP address: " primary_ip
        if [[ -z "$primary_ip" ]]; then
            error "Primary IP is required"
            return 1
        fi
        
        read -p "❓ Proceed with failback (rejoin as standby)? (yes/NO): " confirm
        if [[ "$confirm" != "yes" ]]; then
            info "Failback cancelled"
            return 0
        fi
        
        echo
        info "Step 1: Testing connection to new primary..."
        if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h "$primary_ip" -U repmgr -d repmgr -c "SELECT 1" >/dev/null 2>&1; then
            success "Connection to primary established"
        else
            error "Cannot connect to primary at $primary_ip"
            return 1
        fi
        
        info "Step 2: Cleaning up old data directory..."
        local pg_data_dir="/var/lib/postgresql/17/main"
        if [[ -d "$pg_data_dir" ]]; then
            warn "Removing existing PostgreSQL data directory"
            rm -rf "${pg_data_dir}"/*
        fi
        
        info "Step 3: Cloning from new primary..."
        if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" repmgr -h "$primary_ip" -U repmgr -d repmgr -f "$REPMGR_CONF_FILE" standby clone --force; then
            success "Standby cloned successfully"
        else
            error "Failed to clone standby"
            return 1
        fi
        
        info "Step 4: Starting PostgreSQL..."
        if systemctl start postgresql; then
            success "PostgreSQL started"
        else
            error "Failed to start PostgreSQL"
            return 1
        fi
        
        info "Step 5: Registering with cluster..."
        if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" repmgr -f "$REPMGR_CONF_FILE" standby register --force; then
            success "Standby registered successfully"
        else
            warn "Registration failed, but node may be working"
        fi
        
        info "Step 6: Starting repmgrd daemon..."
        if systemctl start repmgrd; then
            success "repmgrd started"
        else
            warn "Failed to start repmgrd daemon"
        fi
        
        success "✅ Failback completed! This node is now a standby."
        
    elif [[ "$role" == "primary" ]]; then
        warn "This node is currently primary"
        info "Failback scenarios:"
        info "1. If this is the NEW primary (after failover): No action needed"
        info "2. If you want to switch back roles: Use switchover instead"
        
        read -p "❓ Do you want to perform a controlled switchover back? (yes/NO): " confirm
        if [[ "$confirm" == "yes" ]]; then
            perform_switchover
        fi
        
    elif [[ "$role" == "standby" ]]; then
        success "This node is already a standby - failback not needed"
        
    else
        error "Unable to determine node role for failback"
        return 1
    fi
}

perform_switchover() {
    section "Controlled Switchover"
    
    warn "🔄 Switchover will gracefully switch primary/standby roles"
    info "This is safer than failover as it's a controlled operation"
    
    read -p "❓ Proceed with switchover? (yes/NO): " confirm
    if [[ "$confirm" != "yes" ]]; then
        info "Switchover cancelled"
        return 0
    fi
    
    # Get standby node information
    local standby_node
    standby_node=$(sudo -u postgres env PGPASSFILE="$PGPASS_FILE" repmgr -f "$REPMGR_CONF_FILE" cluster show 2>/dev/null | grep standby | awk '{print $8}' | cut -d'=' -f2 || echo "")
    
    if [[ -z "$standby_node" ]]; then
        error "Cannot identify standby node for switchover"
        return 1
    fi
    
    info "Target standby node: $standby_node"
    
    # Perform switchover
    if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" repmgr -f "$REPMGR_CONF_FILE" standby switchover; then
        success "Switchover completed successfully"
    else
        error "Switchover failed"
        return 1
    fi
}

run_pre_failover_checks() {
    section "Pre-Failover Safety Checks"
    
    # Check if repmgr configuration is valid
    if ! get_repmgr_config; then
        return 1
    fi
    
    # Check if .pgpass file exists and has correct permissions
    if [[ -f "$PGPASS_FILE" ]]; then
        local perms
        perms=$(stat -c %a "$PGPASS_FILE" 2>/dev/null || echo "")
        if [[ "$perms" == "600" ]]; then
            success ".pgpass file has correct permissions"
        else
            warn ".pgpass file permissions: $perms (should be 600)"
        fi
    else
        error ".pgpass file not found: $PGPASS_FILE"
        return 1
    fi
    
    # Check cluster connectivity
    if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" repmgr -f "$REPMGR_CONF_FILE" cluster show >/dev/null 2>&1; then
        success "Cluster connectivity verified"
    else
        error "Cannot connect to cluster"
        return 1
    fi
    
    # Check replication status
    local role
    role=$(get_pg_role)
    
    if [[ "$role" == "primary" ]]; then
        local standby_count
        standby_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" postgres 2>/dev/null || echo "0")
        if [[ "$standby_count" -gt 0 ]]; then
            success "Standby nodes connected: $standby_count"
        else
            error "No standby nodes connected - failover not possible"
            return 1
        fi
    fi
    
    success "Pre-failover checks passed"
}

show_menu() {
    echo
    printf "%b%s%b\n" "$CYAN$BOLD" "PostgreSQL HA Failover Testing Options:" "$NC"
    echo "1. Show cluster status"
    echo "2. Run pre-failover safety checks"
    echo "3. Test failover scenario (⚠️  DISRUPTIVE)"
    echo "4. Test failback scenario"
    echo "5. Perform controlled switchover"
    echo "6. Show repmgr commands reference"
    echo "7. Exit"
    echo
}

show_commands_reference() {
    section "Repmgr Commands Reference"
    
    info "Useful repmgr commands (run as postgres user):"
    echo
    info "Cluster Status:"
    echo "  sudo -u postgres env PGPASSFILE=$PGPASS_FILE repmgr -f $REPMGR_CONF_FILE cluster show"
    echo "  sudo -u postgres env PGPASSFILE=$PGPASS_FILE repmgr -f $REPMGR_CONF_FILE node check"
    echo
    info "Manual Failover (on standby):"
    echo "  sudo -u postgres env PGPASSFILE=$PGPASS_FILE repmgr -f $REPMGR_CONF_FILE standby promote"
    echo
    info "Rejoin Node (on failed primary):"
    echo "  sudo -u postgres env PGPASSFILE=$PGPASS_FILE repmgr -h NEW_PRIMARY_IP -U repmgr -d repmgr -f $REPMGR_CONF_FILE standby clone --force"
    echo "  sudo -u postgres env PGPASSFILE=$PGPASS_FILE repmgr -f $REPMGR_CONF_FILE standby register --force"
    echo
    info "Switchover (controlled role change):"
    echo "  sudo -u postgres env PGPASSFILE=$PGPASS_FILE repmgr -f $REPMGR_CONF_FILE standby switchover"
    echo
}

main() {
    printf "%b" "$BLUE$BOLD"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║         PostgreSQL HA Failover Testing               ║
║              Use with Extreme Caution                ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # Initial setup check
    if [[ ! -f "$REPMGR_CONF_FILE" ]]; then
        error "Repmgr configuration file not found: $REPMGR_CONF_FILE"
        exit 1
    fi
    
    while true; do
        show_menu
        read -p "Enter your choice (1-7): " choice
        
        case $choice in
            1)
                show_cluster_status
                ;;
            2)
                run_pre_failover_checks
                ;;
            3)
                warn "⚠️  DESTRUCTIVE TEST - This will cause service interruption!"
                test_failover
                ;;
            4)
                test_failback
                ;;
            5)
                perform_switchover
                ;;
            6)
                show_commands_reference
                ;;
            7)
                info "Exiting failover testing"
                break
                ;;
            *)
                warn "Invalid choice. Please select 1-7."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
    
    success "Failover testing session completed"
}

main "$@"