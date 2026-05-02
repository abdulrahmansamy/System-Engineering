#!/bin/bash
# Quick test version of the GCP Load Balancer Updater
# This version skips Secret Manager for faster testing
# Version: 1.0.0-test

# Don't exit on errors - let the script continue and report issues  
set -uo pipefail

# Configuration
PROJECT_ID="ipa-nprd-svc-db-01"
REGION="me-central2"
ZONE_A="${REGION}-a"

# PostgreSQL nodes
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PRIMARY_INSTANCE="ipa-nprd-ha-pg-primary-01"
STANDBY_INSTANCE="ipa-nprd-ha-pg-standby-01"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }

# Use default password for testing (skip Secret Manager)
export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'

# Check if node is PostgreSQL primary
is_primary() {
    local ip="$1"
    local result
    result=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p 6432 -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    [[ "$result" == "PRIMARY" ]]
}

# Detect current primary
detect_current_primary() {
    info "Detecting current PostgreSQL primary..."
    
    if is_primary "$PRIMARY_IP"; then
        echo "$PRIMARY_IP"
        info "Current primary: $PRIMARY_IP ($PRIMARY_INSTANCE)"
    elif is_primary "$STANDBY_IP"; then
        echo "$STANDBY_IP"
        info "Current primary: $STANDBY_IP ($STANDBY_INSTANCE)"
    else
        error "Cannot determine current primary!"
        return 1
    fi
}

# Show current status
show_status() {
    info "Current PostgreSQL HA Status:"
    
    # Check node roles
    local primary_role standby_role
    primary_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p 6432 -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    standby_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p 6432 -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    
    info "  • $PRIMARY_IP ($PRIMARY_INSTANCE): $primary_role"
    info "  • $STANDBY_IP ($STANDBY_INSTANCE): $standby_role"
    
    # Simple check if gcloud is working
    if command -v gcloud >/dev/null 2>&1; then
        info "gcloud CLI: Available"
        if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
            info "gcloud auth: Active"
        else
            warn "gcloud auth: No active account"
        fi
    else
        warn "gcloud CLI: Not available"
    fi
}

# Test database connectivity
test_db_connectivity() {
    info "Testing database connectivity..."
    
    # Test primary
    if timeout 3 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p 6432 -U postgres -d postgres -c "SELECT current_timestamp, pg_is_in_recovery() as is_standby;" >/dev/null 2>&1; then
        success "✅ Primary ($PRIMARY_IP) - Connection successful"
    else
        error "❌ Primary ($PRIMARY_IP) - Connection failed"
    fi
    
    # Test standby
    if timeout 3 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p 6432 -U postgres -d postgres -c "SELECT current_timestamp, pg_is_in_recovery() as is_standby;" >/dev/null 2>&1; then
        success "✅ Standby ($STANDBY_IP) - Connection successful"
    else
        error "❌ Standby ($STANDBY_IP) - Connection failed"
    fi
    
    # Test write DNS
    if timeout 3 env PGPASSWORD="$PG_SUPER_PASS" psql -h "pg-write.db.internal.nprd.ipa.edu.sa" -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        success "✅ Write DNS - Connection successful"
    else
        error "❌ Write DNS - Connection failed"
    fi
    
    # Test read DNS
    if timeout 3 env PGPASSWORD="$PG_SUPER_PASS" psql -h "pg-read.db.internal.nprd.ipa.edu.sa" -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        success "✅ Read DNS - Connection successful"
    else
        error "❌ Read DNS - Connection failed"
    fi
}

# Test write operations
test_write_operations() {
    info "Testing write operations on all endpoints..."
    
    local test_table="failover_validation_$(date +%s)_$$"
    
    # Test write to primary IP
    info "Testing write to Primary IP ($PRIMARY_IP)..."
    if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p 6432 -U postgres -d postgres -c "CREATE TABLE $test_table (id int, test_time timestamp DEFAULT now()); INSERT INTO $test_table (id) VALUES (1); DROP TABLE $test_table;" >/dev/null 2>&1; then
        success "✅ Write to Primary IP - Successful"
    else
        error "❌ Write to Primary IP - Failed"
    fi
    
    # Test write to Write DNS
    info "Testing write to Write DNS..."
    local test_table2="${test_table}_dns"
    if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "pg-write.db.internal.nprd.ipa.edu.sa" -p 6432 -U postgres -d postgres -c "CREATE TABLE $test_table2 (id int, test_time timestamp DEFAULT now()); INSERT INTO $test_table2 (id) VALUES (1); DROP TABLE $test_table2;" >/dev/null 2>&1; then
        success "✅ Write to Write DNS - Successful"
    else
        error "❌ Write to Write DNS - Failed"
    fi
}

# Check replication status
check_replication() {
    info "Checking replication status..."
    
    # Find current primary
    local current_primary=""
    if is_primary "$PRIMARY_IP"; then
        current_primary="$PRIMARY_IP"
    elif is_primary "$STANDBY_IP"; then
        current_primary="$STANDBY_IP"
    else
        error "Cannot determine current primary for replication check"
        return 1
    fi
    
    info "Current primary: $current_primary"
    
    # Check replication connections
    local repl_count
    repl_count=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p 6432 -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    if [[ "$repl_count" -gt 0 ]]; then
        success "✅ Replication active: $repl_count standby connected"
        
        # Show replication details
        info "Replication details:"
        timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p 6432 -U postgres -d postgres -c "SELECT client_addr, application_name, state, write_lag, flush_lag, replay_lag FROM pg_stat_replication;" 2>/dev/null || warn "Could not get replication details"
    else
        warn "⚠️ No replication connections found"
    fi
}

# Check repmgrd status
check_repmgrd_status() {
    info "Checking repmgrd daemon status..."
    
    # This requires SSH access to check service status
    # For now, we'll check if we can detect the cluster properly
    info "Note: Full repmgrd status check requires SSH access to nodes"
    info "We can infer repmgrd health from cluster behavior"
}

# Comprehensive validation
run_full_validation() {
    info "🚀 Running comprehensive HA validation..."
    echo
    
    info "1️⃣ System Status Check"
    show_status
    echo
    
    info "2️⃣ Primary Detection"
    detect_current_primary
    echo
    
    info "3️⃣ Database Connectivity"
    test_db_connectivity
    echo
    
    info "4️⃣ Write Operations Test"
    test_write_operations
    echo
    
    info "5️⃣ Replication Status"
    check_replication
    echo
    
    info "6️⃣ repmgrd Status"
    check_repmgrd_status
    echo
    
    info "🎯 Validation Summary:"
    info "✅ If all tests pass, your HA setup is ready for auto-failover"
    info "✅ Auto load balancer switching can be enabled"
    info "⚠️ For full auto-failover test, use the main failover validation script"
}

# Main menu
case "${1:-}" in
    "status")
        show_status
        ;;
    "detect")
        detect_current_primary
        ;;
    "test")
        test_db_connectivity
        ;;
    "write")
        test_write_operations
        ;;
    "replication")
        check_replication
        ;;
    "validate")
        run_full_validation
        ;;
    "all")
        show_status
        echo
        detect_current_primary
        echo
        test_db_connectivity
        ;;
    *)
        echo "Usage: $0 {status|detect|test|write|replication|validate|all}"
        echo ""
        echo "Commands:"
        echo "  status       - Show current cluster status"
        echo "  detect       - Detect current primary node"  
        echo "  test         - Test database connectivity"
        echo "  write        - Test write operations"
        echo "  replication  - Check replication status"
        echo "  validate     - Run comprehensive validation"
        echo "  all          - Run basic tests (status + detect + test)"
        echo ""
        echo "Examples:"
        echo "  $0 validate     # Complete validation before auto-failover"
        echo "  $0 status       # Quick status check"
        echo "  $0 write        # Test write operations"
        echo "  $0 replication  # Check replication health"
        exit 1
        ;;
esac