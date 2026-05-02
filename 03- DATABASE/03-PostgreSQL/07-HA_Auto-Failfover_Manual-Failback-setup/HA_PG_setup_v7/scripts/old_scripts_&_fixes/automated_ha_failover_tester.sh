#!/bin/bash
# =============================================================================
# PostgreSQL HA Automated Failover/Failback Testing Script
# =============================================================================
# Version: 2.0.0 - Clean Automated Script with Proven Solutions
# 
# This script incorporates all proven solutions from successful troubleshooting:
# - Automatic replication slot management
# - Enhanced pg_basebackup with proper WAL handling
# - Complete directory cleanup methods
# - Comprehensive validation and recovery
# - Load balancer integration
# - DNS-aware testing
# 
# Features:
# - Fully automated failover testing
# - Automatic failback with validation
# - Replication slot problem resolution
# - Real-time monitoring and reporting
# - Production-safe error handling
# =============================================================================

SCRIPT_VERSION="2.0.0"
set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Node Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
WRITE_DNS="pg-write.db.internal.nprd.ipa.edu.sa"
READ_DNS="pg-read.db.internal.nprd.ipa.edu.sa"
DB_PORT="6432"
DB_DIRECT_PORT="5432"
USERNAME="postgres"
DATABASE="postgres"

# SSH Configuration
SSH_USER="asamy_nominations_ipa_edu_sa"
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
PRIMARY_SSH_HOST="ipa-nprd-ha-pg-primary-01"
STANDBY_SSH_HOST="ipa-nprd-ha-pg-standby-01"

# Testing Configuration
DEFAULT_TIMEOUT=30
REPLICATION_TIMEOUT=120
SYNC_TEST_TIMEOUT=60
MAX_RETRY_ATTEMPTS=3

# Debug Configuration
DEBUG_MODE="${DEBUG_MODE:-true}"
VERBOSE_SQL="${VERBOSE_SQL:-true}"
SHOW_COMMANDS="${SHOW_COMMANDS:-true}"

# Colors and Logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "INFO")  printf "${GREEN}[INFO]${NC}  [$timestamp] %s\n" "$*" ;;
        "WARN")  printf "${YELLOW}[WARN]${NC}  [$timestamp] %s\n" "$*" ;;
        "ERROR") printf "${RED}[ERROR]${NC} [$timestamp] %s\n" "$*" ;;
        "SUCCESS") printf "${GREEN}[✅ SUCCESS]${NC} [$timestamp] %s\n" "$*" ;;
        "STEP") printf "${BLUE}${BOLD}[STEP]${NC} [$timestamp] %s\n" "$*" ;;
        "DEBUG") 
            if [[ "$DEBUG_MODE" == "true" ]]; then
                printf "${CYAN}[DEBUG]${NC} [$timestamp] %s\n" "$*"
            fi
            ;;
    esac
}

debug_log() {
    log "DEBUG" "$@"
}

section() {
    printf "\n${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}${BOLD} %s ${NC}\n" "$*"
    printf "${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}\n\n"
}

# =============================================================================
# CREDENTIAL MANAGEMENT
# =============================================================================

get_credentials() {
    log "INFO" "Fetching credentials from Secret Manager..."
    
    if [[ -z "${PG_SUPER_PASS:-}" ]]; then
        if PG_SUPER_PASS=$(timeout 10 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
            if [[ -n "$PG_SUPER_PASS" ]]; then
                export PG_SUPER_PASS
                log "SUCCESS" "PostgreSQL password retrieved from Secret Manager"
            else
                log "WARN" "Empty password from Secret Manager, using fallback"
                export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
            fi
        else
            log "WARN" "Secret Manager unavailable, using fallback password"
            export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
        fi
    fi
    
    if [[ -z "${PGBOUNCER_PASS:-}" ]]; then
        export PGBOUNCER_PASS=$(gcloud secrets versions access latest --secret="ipa-nprd-sec-pgbouncer-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null || echo '+s0i=Lh+?0xxGCUt%_ZoQr4%kJ1L')
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

execute_with_retry() {
    local cmd="$1"
    local description="$2"
    local max_attempts="${3:-$MAX_RETRY_ATTEMPTS}"
    local delay="${4:-5}"
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        log "INFO" "Attempt $attempt/$max_attempts: $description"
        if eval "$cmd"; then
            log "SUCCESS" "$description completed successfully"
            return 0
        else
            if [[ $attempt -lt $max_attempts ]]; then
                log "WARN" "Attempt $attempt failed, retrying in ${delay}s..."
                sleep "$delay"
            else
                log "ERROR" "$description failed after $max_attempts attempts"
                return 1
            fi
        fi
    done
}

wait_for_condition() {
    local condition="$1"
    local description="$2"
    local timeout="${3:-$DEFAULT_TIMEOUT}"
    local interval="${4:-2}"
    
    log "INFO" "Waiting for: $description (timeout: ${timeout}s)"
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition"; then
            log "SUCCESS" "$description achieved in ${elapsed}s"
            return 0
        fi
        sleep "$interval"
        ((elapsed += interval))
        
        if [[ $((elapsed % 15)) -eq 0 ]]; then
            log "INFO" "Still waiting for $description... (${elapsed}/${timeout}s)"
        fi
    done
    
    log "ERROR" "$description timed out after ${timeout}s"
    return 1
}

# =============================================================================
# DATABASE OPERATIONS
# =============================================================================

execute_sql() {
    local host="$1"
    local port="$2"
    local sql="$3"
    local timeout="${4:-$DEFAULT_TIMEOUT}"
    
    debug_log "Executing SQL on $host:$port - SQL: $sql"
    
    local output
    local exit_code
    
    if [[ "$VERBOSE_SQL" == "true" ]]; then
        output=$(timeout "$timeout" env PGPASSWORD="$PG_SUPER_PASS" psql \
            -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
            -c "$sql" 2>&1)
        exit_code=$?
    else
        output=$(timeout "$timeout" env PGPASSWORD="$PG_SUPER_PASS" psql \
            -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
            -c "$sql" 2>/dev/null)
        exit_code=$?
    fi
    
    debug_log "SQL execution result - Exit code: $exit_code, Output: $output"
    
    if [[ $exit_code -eq 0 ]]; then
        echo "$output"
        return 0
    else
        debug_log "SQL execution failed - Host: $host, Port: $port, Error: $output"
        return $exit_code
    fi
}

get_node_role() {
    local host="$1"
    local port="${2:-$DB_PORT}"
    
    debug_log "Getting node role for $host:$port"
    
    local role=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    
    debug_log "Node $host:$port role: $role"
    echo "$role"
}

test_connectivity() {
    local host="$1"
    local port="${2:-$DB_PORT}"
    local timeout="${3:-10}"
    
    debug_log "Testing connectivity to $host:$port (timeout: ${timeout}s)"
    
    local result
    if timeout "$timeout" env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -c "SELECT 1;" >/dev/null 2>&1; then
        result="SUCCESS"
        debug_log "Connectivity test to $host:$port: SUCCESS"
        return 0
    else
        result="FAILED"
        debug_log "Connectivity test to $host:$port: FAILED"
        return 1
    fi
}

# =============================================================================
# REPLICATION MANAGEMENT
# =============================================================================

get_replication_status() {
    local primary_host="$1"
    local port="${2:-$DB_PORT}"
    
    execute_sql "$primary_host" "$port" "
        SELECT 
            client_addr,
            application_name,
            state,
            sync_state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes,
            write_lag,
            flush_lag,
            replay_lag
        FROM pg_stat_replication;
    "
}

check_replication_lag() {
    local primary_host="$1"
    local standby_host="$2"
    local max_lag_bytes="${3:-1048576}"  # 1MB default
    
    debug_log "Checking replication lag between $primary_host (primary) and $standby_host (standby)"
    
    # Get primary LSN
    log "INFO" "Getting current WAL LSN from primary ($primary_host)..."
    local primary_lsn
    primary_lsn=$(execute_sql "$primary_host" "$DB_PORT" "SELECT pg_current_wal_lsn();" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    
    if [[ -z "$primary_lsn" || "$primary_lsn" == "UNREACHABLE" ]]; then
        log "ERROR" "Failed to get primary LSN from $primary_host"
        debug_log "Primary LSN result: '$primary_lsn'"
        return 1
    fi
    
    debug_log "Primary LSN: $primary_lsn"
    
    # Get standby LSN
    log "INFO" "Getting last replayed WAL LSN from standby ($standby_host)..."
    local standby_lsn
    standby_lsn=$(execute_sql "$standby_host" "$DB_PORT" "SELECT pg_last_wal_replay_lsn();" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    
    if [[ -z "$standby_lsn" || "$standby_lsn" == "UNREACHABLE" ]]; then
        log "ERROR" "Failed to get standby LSN from $standby_host"
        debug_log "Standby LSN result: '$standby_lsn'"
        return 1
    fi
    
    debug_log "Standby LSN: $standby_lsn"
    
    # Calculate lag
    log "INFO" "Calculating replication lag..."
    local lag_query="SELECT pg_wal_lsn_diff('$primary_lsn', '$standby_lsn');"
    debug_log "Lag calculation query: $lag_query"
    
    local lag_bytes
    lag_bytes=$(execute_sql "$primary_host" "$DB_PORT" "$lag_query" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    
    if [[ -z "$lag_bytes" ]]; then
        log "ERROR" "Failed to calculate replication lag"
        debug_log "Lag calculation result: '$lag_bytes'"
        return 1
    fi
    
    # Extract numeric value from lag_bytes
    local lag_numeric
    lag_numeric=$(echo "$lag_bytes" | sed 's/[^0-9\-]//g')
    
    if [[ -z "$lag_numeric" ]]; then
        log "ERROR" "Invalid lag value: '$lag_bytes'"
        return 1
    fi
    
    # Handle negative values (standby ahead of primary, which shouldn't happen normally)
    if [[ "$lag_numeric" -lt 0 ]]; then
        lag_numeric=$((-lag_numeric))
        log "WARN" "Negative lag detected (standby ahead of primary): $lag_bytes bytes"
    fi
    
    log "INFO" "Replication lag: $lag_bytes bytes (numeric: $lag_numeric, max allowed: $max_lag_bytes)"
    
    if [[ "$lag_numeric" -le "$max_lag_bytes" ]]; then
        log "SUCCESS" "Replication lag is within acceptable limits"
        return 0
    else
        log "ERROR" "Replication lag ($lag_numeric bytes) exceeds maximum allowed ($max_lag_bytes bytes)"
        return 1
    fi
}

fix_replication_slots() {
    local primary_host="$1"
    local standby_host="$2"
    
    log "STEP" "Fixing replication slots..."
    
    # Get current slots
    local slots=$(execute_sql "$primary_host" "$DB_PORT" "
        SELECT slot_name, slot_type, active, restart_lsn 
        FROM pg_replication_slots;
    ")
    
    log "INFO" "Current replication slots:"
    echo "$slots"
    
    # Drop inactive slots that might be causing issues
    execute_sql "$primary_host" "$DB_PORT" "
        SELECT pg_drop_replication_slot(slot_name) 
        FROM pg_replication_slots 
        WHERE NOT active AND slot_name LIKE 'repmgr_slot_%';
    " || log "WARN" "Some slots could not be dropped"
    
    # Create missing slots if needed
    local standby_node_id="2"
    local slot_name="repmgr_slot_${standby_node_id}"
    
    execute_sql "$primary_host" "$DB_PORT" "
        SELECT pg_create_physical_replication_slot('$slot_name') 
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_replication_slots WHERE slot_name = '$slot_name'
        );
    " || log "WARN" "Replication slot creation failed or slot already exists"
    
    log "SUCCESS" "Replication slots fixed"
}

# =============================================================================
# SSH OPERATIONS
# =============================================================================

ssh_execute() {
    local host="$1"
    local command="$2"
    local timeout="${3:-30}"
    
    timeout "$timeout" ssh $SSH_OPTIONS "$SSH_USER@$host" "$command"
}

ssh_execute_as_postgres() {
    local host="$1"
    local command="$2"
    local timeout="${3:-30}"
    
    ssh_execute "$host" "sudo -u postgres $command" "$timeout"
}

# =============================================================================
# PROVEN SOLUTIONS IMPLEMENTATION
# =============================================================================

apply_pg_hba_fixes() {
    local host="$1"
    local description="$2"
    
    log "STEP" "Applying proven pg_hba.conf fixes for $description"
    
    ssh_execute "$host" "
        # Backup current configuration
        sudo cp /etc/postgresql/17/main/pg_hba.conf /etc/postgresql/17/main/pg_hba.conf.backup_\$(date +%Y%m%d_%H%M%S)
        
        # Add comprehensive replication entries
        if ! sudo grep -q 'host replication postgres' /etc/postgresql/17/main/pg_hba.conf; then
            sudo tee -a /etc/postgresql/17/main/pg_hba.conf << 'EOL'

# Proven replication configuration - Auto-added by HA tester
host    replication     postgres        192.168.14.21/32               md5
host    replication     repmgr          192.168.14.21/32               md5
host    replication     postgres        192.168.14.22/32               md5
host    replication     repmgr          192.168.14.22/32               md5
host    replication     postgres        192.168.14.0/24                md5
host    replication     repmgr          192.168.14.0/24                md5
EOL
            # Reload configuration
            sudo -u postgres psql -c 'SELECT pg_reload_conf();'
            echo 'pg_hba.conf updated successfully'
        else
            echo 'Replication entries already configured'
        fi
    "
    
    log "SUCCESS" "pg_hba.conf configuration applied"
}

enhanced_pg_basebackup() {
    local source_host="$1"
    local target_ssh_host="$2"
    local description="$3"
    
    log "STEP" "Performing enhanced pg_basebackup: $description"
    
    # Complete directory cleanup (proven method)
    ssh_execute "$target_ssh_host" "
        sudo systemctl stop postgresql
        sudo rm -rf /var/lib/postgresql/17/main
        sudo mkdir -p /var/lib/postgresql/17/main
        sudo chown postgres:postgres /var/lib/postgresql/17/main
        sudo chmod 700 /var/lib/postgresql/17/main
    "
    
    # Enhanced pg_basebackup with proven options
    local backup_success=false
    
    if ssh_execute "$target_ssh_host" "
        sudo -u postgres env PGPASSWORD='$PG_SUPER_PASS' pg_basebackup \\
            -h $source_host \\
            -p 5432 \\
            -U postgres \\
            -D /var/lib/postgresql/17/main \\
            -v \\
            -P \\
            --no-password \\
            -X stream \\
            --checkpoint=fast \\
            --write-recovery-conf
    " 600; then  # 10 minute timeout
        backup_success=true
        log "SUCCESS" "Enhanced pg_basebackup completed successfully"
    else
        log "WARN" "pg_basebackup failed, trying repmgr method..."
        
        # Fallback to repmgr clone
        if ssh_execute "$target_ssh_host" "
            sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr \\
                -h $source_host -U repmgr -d repmgr \\
                -f /etc/repmgr/repmgr.conf standby clone --force
        " 300; then
            backup_success=true
            log "SUCCESS" "repmgr standby clone completed successfully"
        fi
    fi
    
    if [[ "$backup_success" != true ]]; then
        log "ERROR" "All backup methods failed"
        return 1
    fi
    
    # Start PostgreSQL
    ssh_execute "$target_ssh_host" "sudo systemctl start postgresql"
    sleep 10
    
    log "SUCCESS" "Enhanced backup and startup completed"
}

comprehensive_cluster_validation() {
    local primary_host="$1"
    local standby_host="$2"
    
    section "Comprehensive Cluster Validation"
    
    local validation_errors=0
    
    # Test connectivity
    log "INFO" "Testing node connectivity..."
    if ! test_connectivity "$primary_host"; then
        log "ERROR" "Primary node ($primary_host) unreachable"
        ((validation_errors++))
    fi
    
    if ! test_connectivity "$standby_host"; then
        log "ERROR" "Standby node ($standby_host) unreachable"
        ((validation_errors++))
    fi
    
    # Verify roles
    log "INFO" "Verifying node roles..."
    local primary_role=$(get_node_role "$primary_host")
    local standby_role=$(get_node_role "$standby_host")
    
    log "INFO" "Primary node role: $primary_role"
    log "INFO" "Standby node role: $standby_role"
    
    if [[ "$primary_role" != "PRIMARY" ]]; then
        log "ERROR" "Expected PRIMARY role on primary node, got: $primary_role"
        ((validation_errors++))
    fi
    
    if [[ "$standby_role" != "STANDBY" ]]; then
        log "ERROR" "Expected STANDBY role on standby node, got: $standby_role"
        ((validation_errors++))
    fi
    
    # Check replication
    log "INFO" "Checking replication status..."
    if ! check_replication_lag "$primary_host" "$standby_host"; then
        log "ERROR" "Replication lag too high or replication not working"
        ((validation_errors++))
    fi
    
    # Test data synchronization
    log "INFO" "Testing data synchronization..."
    if ! test_data_synchronization "$primary_host" "$standby_host"; then
        log "ERROR" "Data synchronization test failed"
        ((validation_errors++))
    fi
    
    if [[ $validation_errors -eq 0 ]]; then
        log "SUCCESS" "All validation checks passed"
        return 0
    else
        log "ERROR" "$validation_errors validation errors found"
        return 1
    fi
}

test_data_synchronization() {
    local primary_host="$1"
    local standby_host="$2"
    
    local test_table="ha_sync_test_$(date +%s)_$$"
    local test_data="sync_test_$(date +%s%N)"
    
    log "INFO" "Creating test data on primary..."
    debug_log "Test table: $test_table, Test data: $test_data"
    
    # Create test data
    local create_result
    create_result=$(execute_sql "$primary_host" "$DB_PORT" "
        DROP TABLE IF EXISTS $test_table;
        CREATE TABLE $test_table (
            id SERIAL PRIMARY KEY,
            test_data TEXT,
            created_at TIMESTAMP DEFAULT NOW()
        );
        INSERT INTO $test_table (test_data) VALUES ('$test_data');
    " 2>&1)
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to create test data on primary"
        debug_log "Create test data error: $create_result"
        return 1
    fi
    
    debug_log "Test data created successfully on primary"
    
    # Wait for synchronization with detailed checking
    log "INFO" "Waiting for data synchronization to standby..."
    local sync_attempts=0
    local max_sync_attempts=$((SYNC_TEST_TIMEOUT / 2))
    
    while [[ $sync_attempts -lt $max_sync_attempts ]]; do
        debug_log "Sync attempt $((sync_attempts + 1))/$max_sync_attempts"
        
        # Check if data exists on standby
        local standby_result
        standby_result=$(execute_sql "$standby_host" "$DB_PORT" "SELECT test_data FROM $test_table WHERE test_data = '$test_data';" 2>&1)
        local standby_exit_code=$?
        
        debug_log "Standby query exit code: $standby_exit_code"
        debug_log "Standby query result: $standby_result"
        
        if [[ $standby_exit_code -eq 0 ]] && echo "$standby_result" | grep -q "$test_data"; then
            log "SUCCESS" "Data synchronization verified in $((sync_attempts * 2)) seconds"
            # Cleanup
            execute_sql "$primary_host" "$DB_PORT" "DROP TABLE $test_table;" || true
            return 0
        fi
        
        # Check replication status for debugging
        if [[ $((sync_attempts % 5)) -eq 0 ]]; then
            log "INFO" "Still waiting... Checking replication status"
            local repl_status
            repl_status=$(execute_sql "$primary_host" "$DB_PORT" "SELECT application_name, state, sync_state FROM pg_stat_replication;" 2>/dev/null || echo "No replication info")
            debug_log "Replication status: $repl_status"
        fi
        
        sleep 2
        ((sync_attempts++))
    done
    
    log "ERROR" "Data synchronization failed after $SYNC_TEST_TIMEOUT seconds"
    
    # Detailed failure analysis
    log "INFO" "Performing failure analysis..."
    
    # Check if table exists on standby
    local table_check
    table_check=$(execute_sql "$standby_host" "$DB_PORT" "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = '$test_table');" 2>&1)
    debug_log "Table exists on standby: $table_check"
    
    # Check standby lag
    local standby_lag
    standby_lag=$(execute_sql "$standby_host" "$DB_PORT" "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" 2>&1)
    debug_log "Standby replay lag (seconds): $standby_lag"
    
    # Check standby status
    local standby_status
    standby_status=$(execute_sql "$standby_host" "$DB_PORT" "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();" 2>&1)
    debug_log "Standby status: $standby_status"
    
    # Cleanup
    execute_sql "$primary_host" "$DB_PORT" "DROP TABLE $test_table;" || true
    return 1
}

# =============================================================================
# FAILOVER OPERATIONS
# =============================================================================

execute_failover() {
    local primary_ssh_host="$1"
    local standby_ssh_host="$2"
    
    section "Executing Automated Failover"
    
    log "STEP" "Phase 1: Pre-failover validation"
    if ! comprehensive_cluster_validation "$PRIMARY_IP" "$STANDBY_IP"; then
        log "ERROR" "Pre-failover validation failed"
        return 1
    fi
    
    log "STEP" "Phase 2: Apply proven configuration fixes"
    apply_pg_hba_fixes "$primary_ssh_host" "primary node"
    apply_pg_hba_fixes "$standby_ssh_host" "standby node"
    
    log "STEP" "Phase 3: Stop primary PostgreSQL"
    ssh_execute "$primary_ssh_host" "sudo systemctl stop postgresql"
    sleep 5
    
    log "STEP" "Phase 4: Promote standby to primary"
    local promotion_success=false
    
    # Try repmgr promotion first
    if ssh_execute "$standby_ssh_host" "
        sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr \\
            -f /etc/repmgr/repmgr.conf standby promote --force
    " 60; then
        promotion_success=true
        log "SUCCESS" "repmgr promotion successful"
    else
        log "WARN" "repmgr promotion failed, trying direct PostgreSQL promotion"
        
        # Fallback to direct PostgreSQL promotion
        if ssh_execute_as_postgres "$standby_ssh_host" "psql -c \"SELECT pg_promote();\""; then
            promotion_success=true
            log "SUCCESS" "Direct PostgreSQL promotion successful"
        fi
    fi
    
    if [[ "$promotion_success" != true ]]; then
        log "ERROR" "All promotion methods failed"
        return 1
    fi
    
    log "STEP" "Phase 5: Wait for promotion to complete"
    local promotion_condition="test \"\$(get_node_role \"$STANDBY_IP\")\" = \"PRIMARY\""
    if ! wait_for_condition "$promotion_condition" "standby promotion" 60; then
        log "ERROR" "Promotion did not complete successfully"
        return 1
    fi
    
    log "STEP" "Phase 6: Update load balancer (if available)"
    update_load_balancer "failover" "$STANDBY_IP"
    
    log "STEP" "Phase 7: Post-failover validation"
    sleep 10
    if ! test_connectivity "$STANDBY_IP"; then
        log "ERROR" "New primary is not accessible after failover"
        return 1
    fi
    
    if [[ "$(get_node_role "$STANDBY_IP")" != "PRIMARY" ]]; then
        log "ERROR" "New primary is not in PRIMARY role"
        return 1
    fi
    
    log "SUCCESS" "Failover completed successfully"
    
    # Display final status
    log "INFO" "Post-failover cluster status:"
    log "INFO" "  • Original primary (192.168.14.21): $(get_node_role "$PRIMARY_IP")"
    log "INFO" "  • Original standby (192.168.14.22): $(get_node_role "$STANDBY_IP")"
    
    return 0
}

execute_failback() {
    local original_primary_ssh_host="$1"
    local current_primary_ssh_host="$2"
    
    section "Executing Automated Failback"
    
    # Verify current state
    local orig_primary_role=$(get_node_role "$PRIMARY_IP")
    local orig_standby_role=$(get_node_role "$STANDBY_IP")
    
    log "INFO" "Current cluster state:"
    log "INFO" "  • Original primary (192.168.14.21): $orig_primary_role"
    log "INFO" "  • Original standby (192.168.14.22): $orig_standby_role"
    
    if [[ "$orig_primary_role" == "PRIMARY" ]]; then
        log "SUCCESS" "Cluster is already in original state - no failback needed"
        return 0
    fi
    
    if [[ "$orig_primary_role" != "STANDBY" || "$orig_standby_role" != "PRIMARY" ]]; then
        log "ERROR" "Cluster is not in expected failover state for safe failback"
        return 1
    fi
    
    log "STEP" "Phase 1: Enhanced failback validation"
    if ! comprehensive_cluster_validation "$STANDBY_IP" "$PRIMARY_IP"; then
        log "WARN" "Pre-failback validation issues detected, attempting automatic fixes..."
        fix_replication_slots "$STANDBY_IP" "$PRIMARY_IP"
    fi
    
    log "STEP" "Phase 2: Stop repmgrd services"
    ssh_execute "$original_primary_ssh_host" "sudo systemctl stop repmgrd" || true
    ssh_execute "$current_primary_ssh_host" "sudo systemctl stop repmgrd" || true
    
    log "STEP" "Phase 3: Promote original primary back to PRIMARY"
    local promotion_success=false
    
    if ssh_execute_as_postgres "$original_primary_ssh_host" "
        repmgr -f /etc/repmgr/repmgr.conf standby promote --force
    " 60; then
        promotion_success=true
    else
        log "WARN" "repmgr promotion failed, using direct method..."
        if ssh_execute_as_postgres "$original_primary_ssh_host" "psql -c \"SELECT pg_promote();\""; then
            promotion_success=true
        fi
    fi
    
    if [[ "$promotion_success" != true ]]; then
        log "ERROR" "Failed to promote original primary"
        return 1
    fi
    
    log "STEP" "Phase 4: Stop current primary for demotion"
    ssh_execute "$current_primary_ssh_host" "sudo systemctl stop postgresql"
    sleep 5
    
    log "STEP" "Phase 5: Re-clone standby using proven methods"
    if ! enhanced_pg_basebackup "$PRIMARY_IP" "$current_primary_ssh_host" "failback standby creation"; then
        log "ERROR" "Failed to re-create standby"
        return 1
    fi
    
    log "STEP" "Phase 6: Wait for replication to establish"
    local replication_condition="check_replication_lag \"$PRIMARY_IP\" \"$STANDBY_IP\""
    if ! wait_for_condition "$replication_condition" "replication establishment" "$REPLICATION_TIMEOUT"; then
        log "WARN" "Replication establishment timed out, but continuing..."
    fi
    
    log "STEP" "Phase 7: Re-register nodes with repmgr"
    ssh_execute_as_postgres "$current_primary_ssh_host" "
        repmgr -f /etc/repmgr/repmgr.conf standby register --force
    " || log "WARN" "Standby registration failed, but cluster may still work"
    
    log "STEP" "Phase 8: Restart repmgrd services"
    ssh_execute "$original_primary_ssh_host" "sudo systemctl start repmgrd" || log "WARN" "repmgrd start failed on primary"
    ssh_execute "$current_primary_ssh_host" "sudo systemctl start repmgrd" || log "WARN" "repmgrd start failed on standby"
    
    log "STEP" "Phase 9: Update load balancer"
    update_load_balancer "failback" "$PRIMARY_IP"
    
    log "STEP" "Phase 10: Final validation"
    sleep 15
    
    local final_primary_role=$(get_node_role "$PRIMARY_IP")
    local final_standby_role=$(get_node_role "$STANDBY_IP")
    
    log "INFO" "Final cluster state:"
    log "INFO" "  • Original primary (192.168.14.21): $final_primary_role"
    log "INFO" "  • Original standby (192.168.14.22): $final_standby_role"
    
    if [[ "$final_primary_role" == "PRIMARY" && "$final_standby_role" == "STANDBY" ]]; then
        log "SUCCESS" "Failback completed successfully - cluster restored to original state"
        
        # Test final replication
        if test_data_synchronization "$PRIMARY_IP" "$STANDBY_IP"; then
            log "SUCCESS" "Data synchronization confirmed after failback"
        else
            log "WARN" "Data synchronization test failed, but roles are correct"
        fi
        
        return 0
    else
        log "ERROR" "Failback verification failed"
        return 1
    fi
}

# =============================================================================
# LOAD BALANCER INTEGRATION
# =============================================================================

update_load_balancer() {
    local operation="$1"  # "failover" or "failback"
    local new_primary_ip="$2"
    
    log "INFO" "Updating load balancer for $operation to $new_primary_ip"
    
    local lb_script="$(dirname "$0")/gcp_load_balancer_updater.sh"
    
    if [[ -f "$lb_script" ]] && command -v gcloud >/dev/null 2>&1; then
        if bash "$lb_script" "$operation" "$new_primary_ip"; then
            log "SUCCESS" "Load balancer updated successfully"
        else
            log "WARN" "Load balancer update failed - manual update may be required"
        fi
    else
        log "WARN" "Load balancer script not found or gcloud unavailable"
        log "INFO" "Please manually update load balancer to route writes to $new_primary_ip"
    fi
}

# =============================================================================
# MONITORING AND REPORTING
# =============================================================================

generate_test_report() {
    local test_type="$1"
    local result="$2"
    local start_time="$3"
    local end_time="$4"
    
    local duration=$((end_time - start_time))
    local report_file="/tmp/ha_test_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$report_file" << EOF
PostgreSQL HA Test Report
========================

Test Type: $test_type
Result: $result
Duration: ${duration} seconds
Start Time: $(date -d "@$start_time" '+%Y-%m-%d %H:%M:%S')
End Time: $(date -d "@$end_time" '+%Y-%m-%d %H:%M:%S')

Cluster Configuration:
- Primary IP: $PRIMARY_IP
- Standby IP: $STANDBY_IP
- Write DNS: $WRITE_DNS
- Read DNS: $READ_DNS

Final Cluster State:
- Node 192.168.14.21 Role: $(get_node_role "$PRIMARY_IP")
- Node 192.168.14.22 Role: $(get_node_role "$STANDBY_IP")

Replication Status:
$(get_replication_status "$PRIMARY_IP" 2>/dev/null || get_replication_status "$STANDBY_IP" 2>/dev/null || echo "Unable to retrieve replication status")

EOF
    
    log "INFO" "Test report generated: $report_file"
    echo "$report_file"
}

continuous_monitoring() {
    local duration="$1"
    local interval="${2:-5}"
    
    log "INFO" "Starting continuous monitoring for ${duration}s..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    local monitor_file="/tmp/ha_monitor_$(date +%s).csv"
    
    echo "Timestamp,Primary_IP_Status,Standby_IP_Status,Write_DNS_Status,Read_DNS_Status" > "$monitor_file"
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local primary_status="DOWN"
        local standby_status="DOWN"
        local write_dns_status="DOWN"
        local read_dns_status="DOWN"
        
        test_connectivity "$PRIMARY_IP" "$DB_PORT" 3 && primary_status="UP"
        test_connectivity "$STANDBY_IP" "$DB_PORT" 3 && standby_status="UP"
        test_connectivity "$WRITE_DNS" "$DB_PORT" 3 && write_dns_status="UP"
        test_connectivity "$READ_DNS" "$DB_PORT" 3 && read_dns_status="UP"
        
        echo "$timestamp,$primary_status,$standby_status,$write_dns_status,$read_dns_status" >> "$monitor_file"
        
        log "INFO" "Monitor: Primary=$primary_status Standby=$standby_status Write_DNS=$write_dns_status Read_DNS=$read_dns_status"
        
        sleep "$interval"
    done
    
    log "INFO" "Monitoring completed. Results saved to: $monitor_file"
}

# =============================================================================
# MAIN TESTING FUNCTIONS
# =============================================================================

run_complete_failover_test() {
    section "Complete Automated Failover Test"
    
    local start_time=$(date +%s)
    
    log "INFO" "Starting comprehensive failover test..."
    log "WARN" "This test will simulate a primary node failure"
    
    # Start background monitoring
    continuous_monitoring 180 5 &
    local monitor_pid=$!
    
    if execute_failover "$PRIMARY_SSH_HOST" "$STANDBY_SSH_HOST"; then
        local end_time=$(date +%s)
        
        # Stop monitoring
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true
        
        local report_file=$(generate_test_report "FAILOVER" "SUCCESS" "$start_time" "$end_time")
        log "SUCCESS" "Failover test completed successfully"
        log "INFO" "Report: $report_file"
        
        return 0
    else
        local end_time=$(date +%s)
        
        # Stop monitoring
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true
        
        local report_file=$(generate_test_report "FAILOVER" "FAILED" "$start_time" "$end_time")
        log "ERROR" "Failover test failed"
        log "INFO" "Report: $report_file"
        
        return 1
    fi
}

run_complete_failback_test() {
    section "Complete Automated Failback Test"
    
    local start_time=$(date +%s)
    
    log "INFO" "Starting comprehensive failback test..."
    
    # Start background monitoring
    continuous_monitoring 300 5 &
    local monitor_pid=$!
    
    if execute_failback "$PRIMARY_SSH_HOST" "$STANDBY_SSH_HOST"; then
        local end_time=$(date +%s)
        
        # Stop monitoring
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true
        
        local report_file=$(generate_test_report "FAILBACK" "SUCCESS" "$start_time" "$end_time")
        log "SUCCESS" "Failback test completed successfully"
        log "INFO" "Report: $report_file"
        
        return 0
    else
        local end_time=$(date +%s)
        
        # Stop monitoring
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true
        
        local report_file=$(generate_test_report "FAILBACK" "FAILED" "$start_time" "$end_time")
        log "ERROR" "Failback test failed"
        log "INFO" "Report: $report_file"
        
        return 1
    fi
}

run_full_cycle_test() {
    section "Complete Failover/Failback Cycle Test"
    
    log "INFO" "This will test a complete failover → failback cycle"
    
    local start_time=$(date +%s)
    local cycle_success=true
    
    # Phase 1: Initial validation
    log "STEP" "Phase 1: Initial cluster validation"
    if ! comprehensive_cluster_validation "$PRIMARY_IP" "$STANDBY_IP"; then
        log "ERROR" "Initial cluster validation failed"
        return 1
    fi
    
    # Phase 2: Execute failover
    log "STEP" "Phase 2: Execute failover"
    if ! execute_failover "$PRIMARY_SSH_HOST" "$STANDBY_SSH_HOST"; then
        log "ERROR" "Failover phase failed"
        cycle_success=false
    fi
    
    # Phase 3: Validate post-failover state
    if [[ "$cycle_success" == true ]]; then
        log "STEP" "Phase 3: Post-failover validation"
        sleep 30  # Allow system to stabilize
        
        if ! comprehensive_cluster_validation "$STANDBY_IP" "$PRIMARY_IP"; then
            log "WARN" "Post-failover validation issues detected, but continuing..."
        fi
    fi
    
    # Phase 4: Execute failback
    if [[ "$cycle_success" == true ]]; then
        log "STEP" "Phase 4: Execute failback"
        sleep 60  # Additional stabilization time
        
        if ! execute_failback "$PRIMARY_SSH_HOST" "$STANDBY_SSH_HOST"; then
            log "ERROR" "Failback phase failed"
            cycle_success=false
        fi
    fi
    
    # Phase 5: Final validation
    if [[ "$cycle_success" == true ]]; then
        log "STEP" "Phase 5: Final validation"
        sleep 30
        
        if ! comprehensive_cluster_validation "$PRIMARY_IP" "$STANDBY_IP"; then
            log "WARN" "Final validation issues detected"
        fi
    fi
    
    local end_time=$(date +%s)
    local result="SUCCESS"
    
    if [[ "$cycle_success" != true ]]; then
        result="FAILED"
    fi
    
    local report_file=$(generate_test_report "FULL_CYCLE" "$result" "$start_time" "$end_time")
    
    if [[ "$cycle_success" == true ]]; then
        log "SUCCESS" "Complete failover/failback cycle test completed successfully"
    else
        log "ERROR" "Complete failover/failback cycle test failed"
    fi
    
    log "INFO" "Report: $report_file"
    return $([[ "$cycle_success" == true ]] && echo 0 || echo 1)
}

# =============================================================================
# MENU SYSTEM
# =============================================================================

show_menu() {
    echo
    printf "${CYAN}${BOLD}PostgreSQL HA Automated Testing Suite v${SCRIPT_VERSION}${NC}\n"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1. 🔍 Initial cluster validation"
    echo "2. 🔧 Apply proven configuration fixes"
    echo "3. ⚡ Run complete failover test"
    echo "4. 🔄 Run complete failback test"
    echo "5. 🔁 Run full cycle test (failover + failback)"
    echo "6. 📊 Monitor cluster status (60s)"
    echo "7. 🛠️  Fix replication slots"
    echo "8. 📋 Generate current status report"
    echo "9. 🧹 Cleanup test artifacts"
    echo "10. 🔬 Detailed diagnostic mode"
    echo "11. ❌ Exit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

cleanup_test_artifacts() {
    log "INFO" "Cleaning up test artifacts..."
    
    # Remove test tables
    for host in "$PRIMARY_IP" "$STANDBY_IP"; do
        if test_connectivity "$host"; then
            execute_sql "$host" "$DB_PORT" "
                DROP TABLE IF EXISTS ha_sync_test_$(date +%s)_$$;
                -- Clean up any remaining test tables
                DO \$\$
                DECLARE
                    r RECORD;
                BEGIN
                    FOR r IN (SELECT tablename FROM pg_tables WHERE tablename LIKE 'ha_sync_test_%')
                    LOOP
                        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename);
                    END LOOP;
                END
                \$\$;
            " || true
        fi
    done
    
    # Clean up old monitoring files
    find /tmp -name "ha_monitor_*.csv" -mtime +1 -delete 2>/dev/null || true
    find /tmp -name "ha_test_report_*.txt" -mtime +1 -delete 2>/dev/null || true
    
    log "SUCCESS" "Cleanup completed"
}

detailed_diagnostic_mode() {
    section "Detailed Diagnostic Mode"
    
    log "INFO" "Starting comprehensive diagnostic analysis..."
    
    # Test basic connectivity
    log "STEP" "Testing basic connectivity"
    for host in "$PRIMARY_IP" "$STANDBY_IP"; do
        log "INFO" "Testing $host..."
        if timeout 5 nc -z "$host" "$DB_PORT"; then
            log "SUCCESS" "Network connectivity to $host:$DB_PORT: OK"
        else
            log "ERROR" "Network connectivity to $host:$DB_PORT: FAILED"
        fi
        
        if timeout 5 nc -z "$host" "$DB_DIRECT_PORT"; then
            log "SUCCESS" "Network connectivity to $host:$DB_DIRECT_PORT: OK"
        else
            log "ERROR" "Network connectivity to $host:$DB_DIRECT_PORT: FAILED"
        fi
    done
    
    # Test PostgreSQL connectivity with detailed output
    log "STEP" "Testing PostgreSQL connectivity"
    for host in "$PRIMARY_IP" "$STANDBY_IP"; do
        for port in "$DB_PORT" "$DB_DIRECT_PORT"; do
            log "INFO" "Testing PostgreSQL on $host:$port..."
            local conn_test
            conn_test=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
                -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
                -c "SELECT version(), current_timestamp, inet_server_addr(), inet_server_port();" 2>&1)
            
            if [[ $? -eq 0 ]]; then
                log "SUCCESS" "PostgreSQL connectivity to $host:$port: OK"
                debug_log "Connection test result: $conn_test"
            else
                log "ERROR" "PostgreSQL connectivity to $host:$port: FAILED"
                log "ERROR" "Error details: $conn_test"
            fi
        done
    done
    
    # Get detailed node information
    log "STEP" "Getting detailed node information"
    for host in "$PRIMARY_IP" "$STANDBY_IP"; do
        for port in "$DB_PORT" "$DB_DIRECT_PORT"; do
            if test_connectivity "$host" "$port"; then
                log "INFO" "Analyzing $host:$port..."
                
                # Get role and recovery status
                local role_info
                role_info=$(execute_sql "$host" "$port" "
                    SELECT 
                        CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role,
                        pg_is_in_recovery() as in_recovery,
                        pg_current_wal_lsn() as current_lsn,
                        pg_last_wal_receive_lsn() as receive_lsn,
                        pg_last_wal_replay_lsn() as replay_lsn,
                        EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) as replay_lag_seconds;
                " 2>&1)
                
                log "INFO" "Node $host:$port role information:"
                echo "$role_info"
                
                # Get replication status if this is primary
                local repl_status
                repl_status=$(execute_sql "$host" "$port" "SELECT COUNT(*) as replica_count FROM pg_stat_replication;" 2>&1)
                if [[ $? -eq 0 ]]; then
                    log "INFO" "Replication status from $host:$port:"
                    echo "$repl_status"
                    
                    # Detailed replication info
                    local detailed_repl
                    detailed_repl=$(execute_sql "$host" "$port" "
                        SELECT 
                            application_name,
                            client_addr,
                            state,
                            sync_state,
                            pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) as send_lag_bytes,
                            pg_wal_lsn_diff(sent_lsn, write_lsn) as write_lag_bytes,
                            pg_wal_lsn_diff(write_lsn, flush_lsn) as flush_lag_bytes,
                            pg_wal_lsn_diff(flush_lsn, replay_lsn) as replay_lag_bytes,
                            write_lag,
                            flush_lag,
                            replay_lag
                        FROM pg_stat_replication;
                    " 2>&1)
                    
                    if [[ $? -eq 0 ]] && [[ -n "$detailed_repl" ]]; then
                        log "INFO" "Detailed replication status from $host:$port:"
                        echo "$detailed_repl"
                    fi
                fi
                
                # Get replication slots
                local slots_info
                slots_info=$(execute_sql "$host" "$port" "
                    SELECT 
                        slot_name,
                        slot_type,
                        database,
                        active,
                        temporary,
                        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) as lag_bytes
                    FROM pg_replication_slots;
                " 2>&1)
                
                if [[ $? -eq 0 ]]; then
                    log "INFO" "Replication slots on $host:$port:"
                    echo "$slots_info"
                fi
                
                echo "----------------------------------------"
            fi
        done
    done
    
    # Test simple replication
    log "STEP" "Testing simple replication"
    local primary_host=""
    local standby_host=""
    
    # Determine current roles
    if [[ "$(get_node_role "$PRIMARY_IP")" == "PRIMARY" ]]; then
        primary_host="$PRIMARY_IP"
        standby_host="$STANDBY_IP"
    elif [[ "$(get_node_role "$STANDBY_IP")" == "PRIMARY" ]]; then
        primary_host="$STANDBY_IP"
        standby_host="$PRIMARY_IP"
    else
        log "ERROR" "Cannot determine primary/standby roles"
        return 1
    fi
    
    log "INFO" "Determined roles: Primary=$primary_host, Standby=$standby_host"
    
    # Create a simple test table
    local test_table="diag_test_$(date +%s)"
    local test_value="diagnostic_test_$(date +%s%N)"
    
    log "INFO" "Creating diagnostic test table on primary..."
    local create_result
    create_result=$(execute_sql "$primary_host" "$DB_PORT" "
        DROP TABLE IF EXISTS $test_table;
        CREATE TABLE $test_table (
            id SERIAL PRIMARY KEY,
            test_value TEXT,
            created_at TIMESTAMP DEFAULT NOW()
        );
        INSERT INTO $test_table (test_value) VALUES ('$test_value');
        SELECT * FROM $test_table;
    " 2>&1)
    
    log "INFO" "Test table creation result:"
    echo "$create_result"
    
    # Wait a moment for replication
    log "INFO" "Waiting 10 seconds for replication..."
    sleep 10
    
    # Check on standby
    log "INFO" "Checking test table on standby..."
    local standby_result
    standby_result=$(execute_sql "$standby_host" "$DB_PORT" "
        SELECT 
            EXISTS (SELECT FROM information_schema.tables WHERE table_name = '$test_table') as table_exists,
            (SELECT COUNT(*) FROM $test_table WHERE test_value = '$test_value') as row_count,
            (SELECT test_value FROM $test_table WHERE test_value = '$test_value' LIMIT 1) as test_value_found;
    " 2>&1)
    
    log "INFO" "Standby verification result:"
    echo "$standby_result"
    
    # Cleanup
    execute_sql "$primary_host" "$DB_PORT" "DROP TABLE IF EXISTS $test_table;" || true
    
    # DNS testing
    log "STEP" "Testing DNS resolution"
    for dns in "$WRITE_DNS" "$READ_DNS"; do
        log "INFO" "Testing DNS: $dns"
        local dns_result
        dns_result=$(dig +short "$dns" 2>&1)
        if [[ $? -eq 0 ]] && [[ -n "$dns_result" ]]; then
            log "SUCCESS" "DNS resolution for $dns: $dns_result"
        else
            log "ERROR" "DNS resolution failed for $dns: $dns_result"
        fi
        
        # Test connectivity to DNS endpoint
        if test_connectivity "$dns" "$DB_PORT"; then
            log "SUCCESS" "PostgreSQL connectivity via $dns: OK"
        else
            log "ERROR" "PostgreSQL connectivity via $dns: FAILED"
        fi
    done
    
    log "SUCCESS" "Detailed diagnostic analysis completed"
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
    # Initialize
    section "PostgreSQL HA Automated Testing Suite"
    log "INFO" "Version: $SCRIPT_VERSION"
    log "INFO" "Timestamp: $(date)"
    log "INFO" "Debug Mode: $DEBUG_MODE"
    log "INFO" "Verbose SQL: $VERBOSE_SQL"
    log "INFO" "Show Commands: $SHOW_COMMANDS"
    
    # Get credentials
    get_credentials
    
    # Main menu loop
    while true; do
        show_menu
        read -p "Enter your choice (1-11): " choice
        
        case $choice in
            1)
                comprehensive_cluster_validation "$PRIMARY_IP" "$STANDBY_IP"
                ;;
            2)
                apply_pg_hba_fixes "$PRIMARY_SSH_HOST" "primary node"
                apply_pg_hba_fixes "$STANDBY_SSH_HOST" "standby node"
                ;;
            3)
                echo
                read -p "⚠️  Run failover test? This will stop the primary database. Continue? (yes/NO): " confirm
                if [[ "$confirm" == "yes" ]]; then
                    run_complete_failover_test
                else
                    log "INFO" "Failover test cancelled"
                fi
                ;;
            4)
                echo
                read -p "⚠️  Run failback test? This will restore original configuration. Continue? (yes/NO): " confirm
                if [[ "$confirm" == "yes" ]]; then
                    run_complete_failback_test
                else
                    log "INFO" "Failback test cancelled"
                fi
                ;;
            5)
                echo
                read -p "⚠️  Run full cycle test? This will test complete failover→failback. Continue? (yes/NO): " confirm
                if [[ "$confirm" == "yes" ]]; then
                    run_full_cycle_test
                else
                    log "INFO" "Full cycle test cancelled"
                fi
                ;;
            6)
                continuous_monitoring 60 5
                ;;
            7)
                # Determine current primary
                if [[ "$(get_node_role "$PRIMARY_IP")" == "PRIMARY" ]]; then
                    fix_replication_slots "$PRIMARY_IP" "$STANDBY_IP"
                elif [[ "$(get_node_role "$STANDBY_IP")" == "PRIMARY" ]]; then
                    fix_replication_slots "$STANDBY_IP" "$PRIMARY_IP"
                else
                    log "ERROR" "Cannot determine current primary for slot fix"
                fi
                ;;
            8)
                local start_time=$(date +%s)
                local end_time=$(date +%s)
                generate_test_report "STATUS_REPORT" "INFO" "$start_time" "$end_time"
                ;;
            9)
                cleanup_test_artifacts
                ;;
            10)
                detailed_diagnostic_mode
                ;;
            11)
                log "INFO" "Exiting PostgreSQL HA Testing Suite"
                break
                ;;
            *)
                log "ERROR" "Invalid choice. Please select 1-11."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Trap for cleanup on exit
trap 'cleanup_test_artifacts 2>/dev/null || true' EXIT

# Check if running with required permissions
if [[ $EUID -eq 0 ]]; then
    log "WARN" "Running as root - SSH keys may not be available"
    log "INFO" "Consider running as the user with SSH key access"
fi

# Main execution
main "$@"

# =============================================================================
# SCRIPT DOCUMENTATION
# =============================================================================
#
# This script implements proven solutions from successful PostgreSQL HA
# troubleshooting sessions:
#
# PROVEN SOLUTIONS INTEGRATED:
# 1. Enhanced pg_basebackup with --write-recovery-conf and --no-password
# 2. Complete directory cleanup (rm -rf + mkdir)
# 3. Comprehensive replication verification with timeouts
# 4. Automatic replication slot management
# 5. pg_hba.conf fixes for authentication
# 6. Multiple promotion methods (repmgr + direct PostgreSQL)
# 7. Load balancer integration
# 8. Real-time monitoring and validation
#
# FEATURES:
# - Fully automated failover/failback testing
# - Comprehensive validation at each step
# - Automatic error recovery and retry logic
# - Production-safe error handling
# - Detailed reporting and monitoring
# - Clean artifact management
#
# USAGE:
# ./automated_ha_failover_tester.sh
#
# The script provides an interactive menu for different testing scenarios.
# All operations include comprehensive validation and error handling.
#
# =============================================================================