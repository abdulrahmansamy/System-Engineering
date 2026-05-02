#!/bin/bash
# Post-Failback Repair Script
# Fixes repmgr configuration and replication issues after failback
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
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PRIMARY_SSH_HOST="ipa-nprd-ha-pg-primary-01"
STANDBY_SSH_HOST="ipa-nprd-ha-pg-standby-01"
SSH_USER="asamy_nominations_ipa_edu_sa"
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
DB_PORT="6432"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

# Get credentials
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    if PG_SUPER_PASS=$(timeout 5 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
        export PG_SUPER_PASS
        success "Retrieved password from Secret Manager"
    else
        warn "Using default password"
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

# Function to check PostgreSQL role
check_pg_role() {
    local host="$1"
    local result
    result=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$host" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    echo "$result"
}

# Function to fix repmgr node registration
fix_repmgr_registration() {
    section "🔧 Fixing repmgr Node Registration"
    
    info "Current cluster state analysis..."
    local primary_role standby_role
    primary_role=$(check_pg_role "$PRIMARY_IP")
    standby_role=$(check_pg_role "$STANDBY_IP")
    
    info "PostgreSQL roles:"
    info "  • $PRIMARY_IP: $primary_role"
    info "  • $STANDBY_IP: $standby_role"
    
    if [[ "$primary_role" != "PRIMARY" || "$standby_role" != "STANDBY" ]]; then
        error "PostgreSQL roles are not correct. Cannot proceed."
        return 1
    fi
    
    # Step 1: Stop repmgrd on both nodes
    info "1️⃣ Stopping repmgrd services..."
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl stop repmgrd" 2>/dev/null || warn "repmgrd may not be running on primary"
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl stop repmgrd" 2>/dev/null || warn "repmgrd may not be running on standby"
    
    # Step 2: Unregister both nodes from repmgr
    info "2️⃣ Unregistering nodes from repmgr cluster..."
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf node rejoin --force --dry-run 2>/dev/null || sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf standby unregister --node=1 2>/dev/null || true" 2>/dev/null || true
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf standby unregister --node=2 2>/dev/null || true" 2>/dev/null || true
    
    # Step 3: Re-register primary as primary
    info "3️⃣ Registering primary node (192.168.14.21) as PRIMARY..."
    if ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf primary register --force" 2>/dev/null; then
        success "✅ Primary node registered successfully"
    else
        error "❌ Failed to register primary node"
        info "Trying alternative method..."
        # Alternative: update repmgr tables directly
        ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -d repmgr -c \"UPDATE repmgr.nodes SET type = 'primary', upstream_node_id = NULL WHERE node_id = 1;\"" 2>/dev/null || warn "Direct database update failed"
    fi
    
    # Step 4: Ensure standby is properly configured
    info "4️⃣ Ensuring standby configuration..."
    
    # Check if standby needs to be re-configured
    local standby_upstream
    standby_upstream=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -d postgres -Atqc \"SELECT pg_is_in_recovery();\"" 2>/dev/null || echo "unknown")
    
    if [[ "$standby_upstream" == "t" ]]; then
        success "✅ Standby is correctly in recovery mode"
        
        # Re-register standby
        info "Re-registering standby node..."
        if ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf standby register --force --upstream-node-id=1" 2>/dev/null; then
            success "✅ Standby node registered successfully"
        else
            warn "⚠️ Standby registration may have issues, but continuing..."
        fi
    else
        error "❌ Standby is not in recovery mode"
        return 1
    fi
    
    # Step 5: Update repmgr metadata directly if needed
    info "5️⃣ Updating repmgr metadata..."
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -d repmgr -c \"
        UPDATE repmgr.nodes SET 
            type = 'primary', 
            upstream_node_id = NULL,
            active = true,
            priority = 100
        WHERE node_id = 1;
        
        UPDATE repmgr.nodes SET 
            type = 'standby', 
            upstream_node_id = 1,
            active = true,
            priority = 100
        WHERE node_id = 2;
        
        SELECT node_id, type, node_name, active, upstream_node_id FROM repmgr.nodes ORDER BY node_id;
    \"" 2>/dev/null || warn "Failed to update repmgr metadata"
    
    success "✅ repmgr registration repair completed"
}

# Function to start repmgrd services
start_repmgrd_services() {
    section "🚀 Starting repmgrd Services"
    
    info "1️⃣ Starting repmgrd on primary..."
    if ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl start repmgrd && sudo systemctl enable repmgrd" 2>/dev/null; then
        success "✅ repmgrd started on primary"
    else
        error "❌ Failed to start repmgrd on primary"
        
        # Check for errors
        local repmgrd_error
        repmgrd_error=$(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo journalctl -u repmgrd --no-pager -n 5" 2>/dev/null || echo "Cannot get logs")
        info "repmgrd error details: $repmgrd_error"
    fi
    
    sleep 3
    
    info "2️⃣ Starting repmgrd on standby..."
    if ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl start repmgrd && sudo systemctl enable repmgrd" 2>/dev/null; then
        success "✅ repmgrd started on standby"
    else
        error "❌ Failed to start repmgrd on standby"
        
        # Check for errors
        local repmgrd_error
        repmgrd_error=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo journalctl -u repmgrd --no-pager -n 5" 2>/dev/null || echo "Cannot get logs")
        info "repmgrd error details: $repmgrd_error"
    fi
    
    # Check service status
    info "3️⃣ Checking service status..."
    local primary_status standby_status
    primary_status=$(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
    standby_status=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
    
    info "Service Status:"
    info "  • Primary repmgrd: $primary_status"
    info "  • Standby repmgrd: $standby_status"
}

# Function to verify replication
verify_replication() {
    section "🔄 Verifying Replication"
    
    info "1️⃣ Checking replication connections..."
    local repl_count
    repl_count=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    if [[ "$repl_count" -gt 0 ]]; then
        success "✅ $repl_count replication connection(s) active"
        
        # Show replication details
        local repl_details
        repl_details=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
            SELECT 
                client_addr,
                application_name,
                state,
                sync_state,
                pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes
            FROM pg_stat_replication;
        " 2>/dev/null || echo "Query failed")
        
        info "📊 Replication Details:"
        echo "$repl_details"
    else
        warn "⚠️ No replication connections found"
        
        info "2️⃣ Checking if standby can connect to primary..."
        if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p 5432 -U repmgr -d repmgr -c "SELECT 1;" >/dev/null 2>&1; then
            success "✅ Standby can connect to primary"
        else
            error "❌ Standby cannot connect to primary"
        fi
        
        info "3️⃣ Attempting to restart standby PostgreSQL..."
        ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl restart postgresql" 2>/dev/null || warn "Failed to restart standby PostgreSQL"
        
        sleep 5
        
        # Recheck
        repl_count=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
        
        if [[ "$repl_count" -gt 0 ]]; then
            success "✅ Replication established after restart ($repl_count connection(s))"
        else
            error "❌ Replication still not working"
        fi
    fi
}

# Function to test data synchronization
test_data_sync() {
    section "📋 Testing Data Synchronization"
    
    local test_table="repair_test_$(date +%s)"
    local test_data="repair_test_data_$(date +%s%N)"
    
    info "1️⃣ Creating test data on primary..."
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
        CREATE TABLE $test_table (id SERIAL, data TEXT, created_at TIMESTAMP DEFAULT NOW());
        INSERT INTO $test_table (data) VALUES ('$test_data');
    " >/dev/null 2>&1; then
        success "✅ Test data created on primary"
    else
        error "❌ Failed to create test data on primary"
        return 1
    fi
    
    info "2️⃣ Waiting for replication (max 30 seconds)..."
    local wait_count=0
    local max_wait=30
    local data_found=false
    
    while [[ $wait_count -lt $max_wait ]]; do
        if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT data FROM $test_table WHERE data = '$test_data';" 2>/dev/null | grep -q "$test_data"; then
            data_found=true
            break
        fi
        sleep 2
        ((wait_count += 2))
        if [[ $((wait_count % 10)) -eq 0 ]]; then
            info "    Still waiting... ($wait_count/$max_wait seconds)"
        fi
    done
    
    # Cleanup
    timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "DROP TABLE $test_table;" >/dev/null 2>&1 || true
    
    if [[ "$data_found" == true ]]; then
        success "✅ Data synchronization working (synced in $wait_count seconds)"
        return 0
    else
        error "❌ Data synchronization failed (timeout after $max_wait seconds)"
        return 1
    fi
}

# Function to show final status
show_final_status() {
    section "📊 Final Cluster Status"
    
    info "1️⃣ PostgreSQL Roles:"
    local primary_role standby_role
    primary_role=$(check_pg_role "$PRIMARY_IP")
    standby_role=$(check_pg_role "$STANDBY_IP")
    
    info "  • $PRIMARY_IP (original primary): $primary_role"
    info "  • $STANDBY_IP (original standby): $standby_role"
    
    info "2️⃣ repmgr Cluster Status:"
    if ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show" 2>/dev/null; then
        success "✅ repmgr cluster show working"
    else
        warn "⚠️ repmgr cluster show still has issues"
        
        # Show database-level info
        info "Database-level cluster info:"
        ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c \"
            SELECT 
                node_id,
                type,
                node_name,
                active,
                upstream_node_id
            FROM repmgr.nodes 
            ORDER BY node_id;
        \"" 2>/dev/null || warn "Cannot query repmgr database"
    fi
    
    info "3️⃣ Replication Status:"
    local repl_count
    repl_count=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    if [[ "$repl_count" -gt 0 ]]; then
        success "✅ $repl_count active replication connection(s)"
    else
        error "❌ No active replication connections"
    fi
    
    info "4️⃣ Service Status:"
    local primary_repmgrd standby_repmgrd
    primary_repmgrd=$(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
    standby_repmgrd=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
    
    info "  • Primary repmgrd: $primary_repmgrd"
    info "  • Standby repmgrd: $standby_repmgrd"
}

# Main repair function
main() {
    printf "%b" "$BLUE$BOLD"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║          Post-Failback Repair Script                 ║
║       Fixing repmgr and Replication Issues          ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    info "Timestamp: $(date)"
    info "Starting post-failback repair process..."
    
    # Step 1: Fix repmgr registration
    if ! fix_repmgr_registration; then
        error "Failed to fix repmgr registration. Stopping."
        exit 1
    fi
    
    # Step 2: Start repmgrd services
    start_repmgrd_services
    
    # Step 3: Verify replication
    verify_replication
    
    # Step 4: Test data synchronization
    test_data_sync
    
    # Step 5: Show final status
    show_final_status
    
    echo
    success "🎉 Post-failback repair completed!"
    
    info "📋 Next Steps:"
    info "1. Update your load balancer to route writes to 192.168.14.21"
    info "2. Update DNS entries if needed:"
    info "   • pg-write.db.internal.nprd.ipa.edu.sa → 192.168.14.21"
    info "   • pg-read.db.internal.nprd.ipa.edu.sa → 192.168.14.19 (load balancer)"
    info "3. Monitor the cluster for 30 minutes to ensure stability"
    info "4. Run option 10 (Comprehensive Health Check) to verify everything"
}

main "$@"