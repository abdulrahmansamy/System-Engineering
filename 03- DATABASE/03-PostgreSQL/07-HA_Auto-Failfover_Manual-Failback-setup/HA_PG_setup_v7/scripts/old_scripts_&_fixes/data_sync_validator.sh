#!/bin/bash
# PostgreSQL HA Pre-Failback Data Synchronization Validator
# Ensures all data is synchronized before performing failback operations
# Version: 1.0.0

set -uo pipefail

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
DB_PORT="6432"
USERNAME="postgres"
DATABASE="postgres"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

# Get credentials from Secret Manager or use provided ones
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    # Try to get from Secret Manager (requires gcloud auth)
    info "Fetching PostgreSQL superuser password from Secret Manager..."
    
    # Add timeout to prevent hanging
    if PG_SUPER_PASS=$(timeout 10 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
        if [[ -n "$PG_SUPER_PASS" ]]; then
            export PG_SUPER_PASS
            success "Successfully fetched PostgreSQL password from Secret Manager"
        else
            warn "Secret Manager returned empty password, using default"
            export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
        fi
    else
        warn "Failed to fetch from Secret Manager (timeout or auth issue), using default password"
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

# Helper function to check if a node is primary
is_primary() {
    local ip="$1"
    local result
    result=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNKNOWN")
    [[ "$result" == "PRIMARY" ]]
}

# Detect current cluster state
detect_cluster_state() {
    section "🔍 Cluster State Detection"
    
    local primary_role standby_role
    primary_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    standby_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    
    info "Current cluster state:"
    info "  • $PRIMARY_IP (original primary): $primary_role"
    info "  • $STANDBY_IP (original standby): $standby_role"
    
    if [[ "$primary_role" == "PRIMARY" && "$standby_role" == "STANDBY" ]]; then
        success "✅ Cluster in NORMAL state"
        echo "NORMAL:$PRIMARY_IP:$STANDBY_IP"
    elif [[ "$primary_role" == "STANDBY" && "$standby_role" == "PRIMARY" ]]; then
        success "✅ Cluster in FAILOVER state"
        echo "FAILOVER:$STANDBY_IP:$PRIMARY_IP"
    else
        error "❌ Cluster in UNKNOWN/PROBLEMATIC state"
        echo "UNKNOWN:$primary_role:$standby_role"
        return 1
    fi
}

# Comprehensive data synchronization validation
validate_full_data_sync() {
    local current_primary="$1" 
    local current_standby="$2"
    local operation="${3:-validation}"
    
    section "🔄 Comprehensive Data Synchronization Validation"
    
    info "Validating data sync for $operation:"
    info "  • Current Primary: $current_primary"
    info "  • Current Standby: $current_standby"
    
    local sync_errors=0
    local start_time=$(date +%s)
    
    # 1. Node accessibility
    info "1️⃣ Verifying node accessibility..."
    for node in "$current_primary" "$current_standby"; do
        if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$node" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
            success "  ✅ Node $node is accessible"
        else
            error "  ❌ Node $node is not accessible"
            ((sync_errors++))
        fi
    done
    
    # 2. Role verification
    info "2️⃣ Verifying roles..."
    local primary_role standby_role
    primary_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNKNOWN")
    standby_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_standby" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNKNOWN")
    
    if [[ "$primary_role" == "PRIMARY" ]]; then
        success "  ✅ Primary role verified ($current_primary)"
    else
        error "  ❌ Primary role incorrect: $primary_role"
        ((sync_errors++))
    fi
    
    if [[ "$standby_role" == "STANDBY" ]]; then
        success "  ✅ Standby role verified ($current_standby)"
    else
        error "  ❌ Standby role incorrect: $standby_role"
        ((sync_errors++))
    fi
    
    # 3. Replication connection status
    info "3️⃣ Checking replication connectivity..."
    local repl_count
    repl_count=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT count(*) FROM pg_stat_replication WHERE client_addr = '$current_standby';" 2>/dev/null || echo "0")
    
    if [[ "$repl_count" -gt 0 ]]; then
        success "  ✅ Replication connection active ($repl_count connections)"
    else
        error "  ❌ No replication connection found"
        ((sync_errors++))
    fi
    
    # 4. WAL synchronization
    info "4️⃣ Checking WAL synchronization..."
    local primary_lsn standby_lsn lag_bytes
    primary_lsn=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT pg_current_wal_lsn();" 2>/dev/null || echo "UNKNOWN")
    standby_lsn=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_standby" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null || echo "UNKNOWN")
    
    if [[ "$primary_lsn" != "UNKNOWN" && "$standby_lsn" != "UNKNOWN" ]]; then
        lag_bytes=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT pg_wal_lsn_diff('$primary_lsn', '$standby_lsn');" 2>/dev/null || echo "UNKNOWN")
        
        info "  • Primary WAL LSN: $primary_lsn"
        info "  • Standby WAL LSN: $standby_lsn"
        info "  • WAL Lag: $lag_bytes bytes"
        
        local lag_numeric
        lag_numeric=$(echo "$lag_bytes" | sed 's/[^0-9]//g')
        
        if [[ -n "$lag_numeric" && "$lag_numeric" -le 1048576 ]]; then  # 1MB
            success "  ✅ WAL lag acceptable ($lag_bytes bytes)"
        else
            warn "  ⚠️ WAL lag high ($lag_bytes bytes) - waiting for improvement..."
            sleep 30
            
            # Recheck
            standby_lsn=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_standby" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null || echo "UNKNOWN")
            lag_bytes=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT pg_wal_lsn_diff('$primary_lsn', '$standby_lsn');" 2>/dev/null || echo "UNKNOWN")
            lag_numeric=$(echo "$lag_bytes" | sed 's/[^0-9]//g')
            
            if [[ -n "$lag_numeric" && "$lag_numeric" -le 1048576 ]]; then
                success "  ✅ WAL lag improved ($lag_bytes bytes)"
            else
                error "  ❌ WAL lag still too high ($lag_bytes bytes)"
                ((sync_errors++))
            fi
        fi
    else
        error "  ❌ Cannot determine WAL positions"
        ((sync_errors++))
    fi
    
    # 5. Real data synchronization test
    info "5️⃣ Testing real data synchronization..."
    local test_table="sync_validation_$(date +%s)_$$"
    local test_data="sync_test_$(date +%s%N)"
    local sync_success=true
    
    # Create test data on primary
    if timeout 15 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        DROP TABLE IF EXISTS $test_table;
        CREATE TABLE $test_table (
            id SERIAL PRIMARY KEY,
            test_data TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT NOW()
        );
        INSERT INTO $test_table (test_data) VALUES ('$test_data');
        INSERT INTO $test_table (test_data) SELECT 'batch_' || generate_series(1, 50) || '_$test_data';
    " >/dev/null 2>&1; then
        info "  • Test data created on primary (51 rows)"
    else
        error "  ❌ Failed to create test data on primary"
        sync_success=false
        ((sync_errors++))
    fi
    
    if [[ "$sync_success" == true ]]; then
        # Wait for replication
        local sync_wait=0
        local max_wait=60
        local data_synced=false
        
        while [[ $sync_wait -lt $max_wait ]]; do
            local row_count
            row_count=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_standby" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT count(*) FROM $test_table;" 2>/dev/null || echo "0")
            
            if [[ "$row_count" -ge 51 ]]; then
                data_synced=true
                success "  ✅ Data synchronized (51 rows in ${sync_wait}s)"
                break
            fi
            
            sleep 2
            ((sync_wait += 2))
            
            if [[ $((sync_wait % 10)) -eq 0 ]]; then
                info "  • Waiting for sync... (${sync_wait}s/${max_wait}s, $row_count rows)"
            fi
        done
        
        if [[ "$data_synced" != true ]]; then
            error "  ❌ Data sync timeout after ${max_wait}s"
            ((sync_errors++))
        fi
        
        # Clean up
        timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "DROP TABLE IF EXISTS $test_table;" >/dev/null 2>&1 || true
    fi
    
    # 6. Transaction blocking check
    info "6️⃣ Checking for blocking transactions..."
    local long_txns
    long_txns=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$current_primary" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "
        SELECT count(*) 
        FROM pg_stat_activity 
        WHERE state = 'active' 
        AND query_start < now() - interval '5 minutes'
        AND pid != pg_backend_pid();
    " 2>/dev/null || echo "UNKNOWN")
    
    if [[ "$long_txns" == "0" ]]; then
        success "  ✅ No long-running transactions"
    elif [[ "$long_txns" == "UNKNOWN" ]]; then
        warn "  ⚠️ Could not check transactions"
    else
        warn "  ⚠️ $long_txns long-running transactions detected"
        info "  💡 Consider waiting for these to complete"
    fi
    
    # 7. Final summary
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo
    info "🎯 Data Synchronization Validation Summary:"
    info "  • Duration: ${duration} seconds"
    info "  • Checks performed: 6 categories"
    info "  • Errors found: $sync_errors"
    
    if [[ $sync_errors -eq 0 ]]; then
        success "🎉 ALL DATA SYNCHRONIZATION CHECKS PASSED!"
        success "✅ Cluster is fully synchronized and ready for operations"
        return 0
    else
        error "❌ DATA SYNCHRONIZATION VALIDATION FAILED!"
        error "Found $sync_errors issues that must be resolved"
        return 1
    fi
}

# Main validation workflow
main() {
    printf "%b%s%b\n" "$BLUE$BOLD" "PostgreSQL HA Data Synchronization Validator" "$NC"
    echo "Ensuring complete data sync before failback operations"
    echo
    
    # Detect cluster state
    local cluster_state
    cluster_state=$(detect_cluster_state)
    local state_type=$(echo "$cluster_state" | cut -d: -f1)
    local current_primary=$(echo "$cluster_state" | cut -d: -f2) 
    local current_standby=$(echo "$cluster_state" | cut -d: -f3)
    
    if [[ "$state_type" == "UNKNOWN" ]]; then
        error "❌ Cannot proceed with unknown cluster state"
        exit 1
    fi
    
    # Perform comprehensive validation
    if validate_full_data_sync "$current_primary" "$current_standby" "$state_type"; then
        success "🎉 VALIDATION SUCCESSFUL!"
        
        if [[ "$state_type" == "FAILOVER" ]]; then
            info "💡 Cluster is ready for failback to original primary"
            info "   Run option 11 in the main validation script to perform failback"
        else
            info "💡 Cluster is in normal state with good synchronization"
        fi
        
        exit 0
    else
        error "❌ VALIDATION FAILED!"
        info "🔧 Recommended actions:"
        info "  • Wait for replication to catch up"
        info "  • Check network connectivity between nodes"
        info "  • Verify repmgr is running properly"
        info "  • Run comprehensive health check"
        exit 1
    fi
}

# Handle command line arguments
case "${1:-validate}" in
    "validate")
        main
        ;;
    "quick")
        # Quick check only
        cluster_state=$(detect_cluster_state)
        state_type=$(echo "$cluster_state" | cut -d: -f1)
        
        if [[ "$state_type" == "UNKNOWN" ]]; then
            echo "FAILED"
            exit 1
        else
            echo "OK:$state_type"
            exit 0
        fi
        ;;
    *)
        echo "Usage: $0 [validate|quick]"
        echo ""
        echo "Commands:"
        echo "  validate  - Run comprehensive data sync validation (default)"
        echo "  quick     - Quick cluster state check only"
        exit 1
        ;;
esac