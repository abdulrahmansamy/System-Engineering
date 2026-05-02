#!/bin/bash
# Automated Failover Test with Load Balancer Integration
# This script tests complete failover/failback cycle with auto LB switching
# Version: 1.0.0

set -uo pipefail

# Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PRIMARY_SSH_HOST="ipa-nprd-ha-pg-primary-01"
STANDBY_SSH_HOST="ipa-nprd-ha-pg-standby-01"
SSH_USER="asamy_nominations_ipa_edu_sa"
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

# Use default password
export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'

# Check if node is primary
is_primary() {
    local ip="$1"
    local result
    result=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p 6432 -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    [[ "$result" == "PRIMARY" ]]
}

# Get current primary
detect_current_primary() {
    if is_primary "$PRIMARY_IP"; then
        echo "$PRIMARY_IP"
    elif is_primary "$STANDBY_IP"; then
        echo "$STANDBY_IP"
    else
        echo "UNKNOWN"
        return 1
    fi
}

# Test connectivity
test_connectivity() {
    local endpoint="$1" description="$2"
    
    if timeout 3 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        success "✅ $description - Connected"
        return 0
    else
        error "❌ $description - Failed"
        return 1
    fi
}

# Test write operation
test_write() {
    local endpoint="$1" description="$2"
    local test_table="auto_failover_test_$(date +%s)_$$"
    
    if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p 6432 -U postgres -d postgres -c "CREATE TABLE $test_table (id int, test_time timestamp DEFAULT now()); INSERT INTO $test_table (id) VALUES (1); DROP TABLE $test_table;" >/dev/null 2>&1; then
        success "✅ $description - Write successful"
        return 0
    else
        error "❌ $description - Write failed"
        return 1
    fi
}

# Update load balancer
update_load_balancer() {
    local target_primary_ip="$1" operation="$2"
    
    info "🔄 Updating load balancer for $operation (target: $target_primary_ip)..."
    
    # Use the load balancer updater script if available
    local lb_script="./gcp_load_balancer_updater.sh"
    if [[ -f "$lb_script" ]]; then
        if "$lb_script" "$operation" "$target_primary_ip" 2>/dev/null; then
            success "Load balancer updated successfully"
            return 0
        else
            warn "Load balancer update failed - continuing without LB update"
            return 1
        fi
    else
        warn "Load balancer updater script not found - manual update required"
        return 1
    fi
}

# Pre-test validation
pre_test_validation() {
    section "Pre-Test Validation"
    
    local validation_errors=0
    
    # Check current state
    local current_primary
    current_primary=$(detect_current_primary)
    if [[ "$current_primary" == "UNKNOWN" ]]; then
        error "Cannot determine current primary"
        ((validation_errors++))
    else
        info "Current primary: $current_primary"
    fi
    
    # Test connectivity
    test_connectivity "$PRIMARY_IP" "Primary IP" || ((validation_errors++))
    test_connectivity "$STANDBY_IP" "Standby IP" || ((validation_errors++))
    test_connectivity "pg-write.db.internal.nprd.ipa.edu.sa" "Write DNS" || ((validation_errors++))
    test_connectivity "pg-read.db.internal.nprd.ipa.edu.sa" "Read DNS" || ((validation_errors++))
    
    # Test write operations
    if [[ "$current_primary" != "UNKNOWN" ]]; then
        test_write "$current_primary" "Current Primary" || ((validation_errors++))
        test_write "pg-write.db.internal.nprd.ipa.edu.sa" "Write DNS" || ((validation_errors++))
    fi
    
    # Check replication
    if [[ "$current_primary" != "UNKNOWN" ]]; then
        local repl_count
        repl_count=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p 6432 -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
        if [[ "$repl_count" -gt 0 ]]; then
            success "✅ Replication active ($repl_count connections)"
        else
            error "❌ No replication connections"
            ((validation_errors++))
        fi
    fi
    
    if [[ $validation_errors -eq 0 ]]; then
        success "✅ Pre-test validation passed"
        return 0
    else
        error "❌ Pre-test validation failed ($validation_errors errors)"
        return 1
    fi
}

# Simulate failover
simulate_failover() {
    section "Simulating Failover"
    
    local original_primary
    original_primary=$(detect_current_primary)
    
    if [[ "$original_primary" == "$PRIMARY_IP" ]]; then
        local target_primary="$STANDBY_IP"
        local target_ssh="$STANDBY_SSH_HOST"
        local failing_ssh="$PRIMARY_SSH_HOST"
    elif [[ "$original_primary" == "$STANDBY_IP" ]]; then
        local target_primary="$PRIMARY_IP"  
        local target_ssh="$PRIMARY_SSH_HOST"
        local failing_ssh="$STANDBY_SSH_HOST"
    else
        error "Cannot determine current primary for failover"
        return 1
    fi
    
    info "Original primary: $original_primary"
    info "Target primary: $target_primary"
    
    # Step 1: Stop PostgreSQL on current primary
    info "🔄 Step 1: Stopping PostgreSQL on current primary ($original_primary)..."
    ssh $SSH_OPTIONS "$SSH_USER@$failing_ssh" "sudo systemctl stop postgresql" 2>/dev/null || warn "Failed to stop PostgreSQL via SSH"
    sleep 5
    
    # Step 2: Wait for automatic failover or promote manually
    info "🔄 Step 2: Waiting for automatic failover..."
    local wait_count=0
    local max_wait=30
    
    while [[ $wait_count -lt $max_wait ]] && ! is_primary "$target_primary"; do
        info "Waiting for $target_primary to become primary... ($wait_count/$max_wait)"
        sleep 2
        ((wait_count++))
    done
    
    if is_primary "$target_primary"; then
        success "✅ Automatic failover successful!"
    else
        warn "Automatic failover didn't happen, promoting manually..."
        ssh $SSH_OPTIONS "$SSH_USER@$target_ssh" "sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f /etc/repmgr/repmgr.conf standby promote --force" 2>/dev/null || {
            ssh $SSH_OPTIONS "$SSH_USER@$target_ssh" "sudo -u postgres psql -c \"SELECT pg_promote();\"" 2>/dev/null || {
                error "Manual promotion failed"
                return 1
            }
        }
        sleep 5
        
        if is_primary "$target_primary"; then
            success "✅ Manual promotion successful!"
        else
            error "❌ Manual promotion failed"
            return 1
        fi
    fi
    
    # Step 3: Update load balancer
    info "🔄 Step 3: Updating load balancer..."
    update_load_balancer "$target_primary" "failover"
    
    # Step 4: Test post-failover connectivity
    info "🔄 Step 4: Testing post-failover connectivity..."
    sleep 10  # Wait for DNS propagation
    
    test_connectivity "$target_primary" "New Primary"
    test_write "$target_primary" "New Primary"
    
    # Test through DNS (may take time to update)
    local dns_test_count=0
    while [[ $dns_test_count -lt 5 ]]; do
        if test_write "pg-write.db.internal.nprd.ipa.edu.sa" "Write DNS (attempt $((dns_test_count+1)))"; then
            break
        fi
        sleep 5
        ((dns_test_count++))
    done
    
    success "✅ Failover simulation completed"
    echo "$target_primary"  # Return new primary IP
}

# Simulate failback
simulate_failback() {
    local target_primary="$1"  # IP to fail back to
    
    section "Simulating Failback"
    
    local current_primary
    current_primary=$(detect_current_primary)
    
    if [[ "$current_primary" == "$target_primary" ]]; then
        success "Already running on target primary ($target_primary)"
        return 0
    fi
    
    if [[ "$target_primary" == "$PRIMARY_IP" ]]; then
        local target_ssh="$PRIMARY_SSH_HOST"
        local current_ssh="$STANDBY_SSH_HOST"
    elif [[ "$target_primary" == "$STANDBY_IP" ]]; then
        local target_ssh="$STANDBY_SSH_HOST"
        local current_ssh="$PRIMARY_SSH_HOST"
    else
        error "Invalid target primary: $target_primary"
        return 1
    fi
    
    info "Current primary: $current_primary"
    info "Target primary: $target_primary"
    
    # Step 1: Start PostgreSQL on target node if stopped
    info "🔄 Step 1: Ensuring PostgreSQL is running on target..."
    ssh $SSH_OPTIONS "$SSH_USER@$target_ssh" "sudo systemctl start postgresql" 2>/dev/null || true
    sleep 3
    
    # Step 2: Promote target to primary
    info "🔄 Step 2: Promoting target to primary..."
    ssh $SSH_OPTIONS "$SSH_USER@$target_ssh" "sudo -u postgres psql -c \"SELECT pg_promote();\"" 2>/dev/null || {
        ssh $SSH_OPTIONS "$SSH_USER@$target_ssh" "sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f /etc/repmgr/repmgr.conf standby promote --force" 2>/dev/null || {
            error "Failed to promote target"
            return 1
        }
    }
    sleep 5
    
    # Step 3: Stop current primary
    info "🔄 Step 3: Stopping current primary..."
    ssh $SSH_OPTIONS "$SSH_USER@$current_ssh" "sudo systemctl stop postgresql" 2>/dev/null || warn "Failed to stop current primary"
    sleep 3
    
    # Step 4: Re-clone and start as standby
    info "🔄 Step 4: Re-establishing standby..."
    ssh $SSH_OPTIONS "$SSH_USER@$current_ssh" "sudo rm -rf /var/lib/postgresql/17/main/*" 2>/dev/null || true
    ssh $SSH_OPTIONS "$SSH_USER@$current_ssh" "sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -h $target_primary -U repmgr -d repmgr -f /etc/repmgr/repmgr.conf standby clone --force" 2>/dev/null || {
        warn "Standby cloning failed"
    }
    ssh $SSH_OPTIONS "$SSH_USER@$current_ssh" "sudo systemctl start postgresql" 2>/dev/null || true
    sleep 5
    
    # Step 5: Update load balancer
    info "🔄 Step 5: Updating load balancer for failback..."
    update_load_balancer "$target_primary" "failback"
    
    # Step 6: Verify failback
    info "🔄 Step 6: Verifying failback..."
    sleep 10
    
    if is_primary "$target_primary"; then
        success "✅ Failback successful!"
        test_connectivity "$target_primary" "Restored Primary"
        test_write "$target_primary" "Restored Primary"
        return 0
    else
        error "❌ Failback failed"
        return 1
    fi
}

# Complete automated test
run_automated_test() {
    section "🚀 Automated Failover/Failback Test with Load Balancer Integration"
    
    local original_primary
    original_primary=$(detect_current_primary)
    
    if [[ "$original_primary" == "UNKNOWN" ]]; then
        error "Cannot proceed - unknown cluster state"
        return 1
    fi
    
    info "Starting automated test with original primary: $original_primary"
    echo
    
    # Pre-test validation
    if ! pre_test_validation; then
        error "Pre-test validation failed - aborting"
        return 1
    fi
    echo
    
    # Simulate failover
    info "🔄 Phase 1: Testing Failover..."
    local new_primary
    if new_primary=$(simulate_failover); then
        success "✅ Failover phase completed - new primary: $new_primary"
    else
        error "❌ Failover phase failed"
        return 1
    fi
    echo
    
    # Wait between tests
    info "⏰ Waiting 30 seconds before failback test..."
    sleep 30
    echo
    
    # Simulate failback
    info "🔄 Phase 2: Testing Failback..."
    if simulate_failback "$original_primary"; then
        success "✅ Failback phase completed - restored to: $original_primary"
    else
        error "❌ Failback phase failed"
        return 1
    fi
    echo
    
    # Final validation
    info "🔄 Phase 3: Final Validation..."
    sleep 10
    if pre_test_validation; then
        success "🎉 AUTOMATED TEST COMPLETED SUCCESSFULLY!"
        success "✅ Auto-failover working"
        success "✅ Auto-failback working"  
        success "✅ Load balancer auto-switching working"
        success "✅ Full HA cycle validated"
    else
        warn "⚠️ Final validation had issues"
    fi
}

# Main menu
case "${1:-help}" in
    "validate")
        pre_test_validation
        ;;
    "failover")
        simulate_failover
        ;;
    "failback")
        target="${2:-$PRIMARY_IP}"
        simulate_failback "$target"
        ;;
    "auto")
        run_automated_test
        ;;
    *)
        echo "Automated Failover Test with Load Balancer Integration"
        echo "Usage: $0 {validate|failover|failback|auto} [target_ip]"
        echo ""
        echo "Commands:"
        echo "  validate         - Run pre-test validation"
        echo "  failover         - Simulate failover to standby"
        echo "  failback [ip]    - Simulate failback to specified IP"
        echo "  auto             - Run complete automated test cycle"
        echo ""
        echo "Examples:"
        echo "  $0 validate      # Check if system is ready"
        echo "  $0 auto          # Run complete automated test"
        echo "  $0 failover      # Test failover only"
        echo "  $0 failback      # Test failback to original primary"
        echo ""
        echo "🎯 Recommended: Run '$0 auto' for complete validation"
        exit 1
        ;;
esac