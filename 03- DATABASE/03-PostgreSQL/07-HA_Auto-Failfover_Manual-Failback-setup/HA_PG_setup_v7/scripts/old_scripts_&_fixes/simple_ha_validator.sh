#!/bin/bash
# =============================================================================
# PostgreSQL HA Simplified Unified Validator
# =============================================================================
# Version: 3.0.1 - Simplified Ultimate HA Testing Suite (No BC required)
# 
# This simplified unified validator provides comprehensive automated testing
# for PostgreSQL HA scenarios with basic system dependencies only.
# =============================================================================

SCRIPT_VERSION="3.0.1"
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
FAILOVER_TIMEOUT=300
FAILBACK_TIMEOUT=600
MAX_RETRY_ATTEMPTS=3

# Debug Configuration
DEBUG_MODE="${DEBUG_MODE:-true}"
VERBOSE_SQL="${VERBOSE_SQL:-true}"

# Colors and Enhanced Logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Global State Tracking
CLUSTER_STATE="UNKNOWN"
CURRENT_PRIMARY=""
CURRENT_STANDBY=""
SCENARIO_RESULTS=()
TEST_START_TIME=""

# =============================================================================
# LOGGING SYSTEM
# =============================================================================

log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="$*"
    
    # Log to file
    echo "[$level] [$timestamp] $message" >> "/tmp/ha_simple_validator_$(date +%Y%m%d).log"
    
    case "$level" in
        "INFO")    printf "${GREEN}[INFO]${NC}     [$timestamp] %s\n" "$message" ;;
        "WARN")    printf "${YELLOW}[WARN]${NC}     [$timestamp] %s\n" "$message" ;;
        "ERROR")   printf "${RED}[ERROR]${NC}    [$timestamp] %s\n" "$message" ;;
        "SUCCESS") printf "${GREEN}[✅ SUCCESS]${NC} [$timestamp] %s\n" "$message" ;;
        "STEP")    printf "${BLUE}${BOLD}[STEP]${NC}     [$timestamp] %s\n" "$message" ;;
        "SCENARIO") printf "${PURPLE}${BOLD}[SCENARIO]${NC}  [$timestamp] %s\n" "$message" ;;
        "METRIC")  printf "${CYAN}[METRIC]${NC}   [$timestamp] %s\n" "$message" ;;
        "DEBUG") 
            if [[ "$DEBUG_MODE" == "true" ]]; then
                printf "${CYAN}[DEBUG]${NC}    [$timestamp] %s\n" "$message"
            fi
            ;;
    esac
}

section() {
    local title="$*"
    printf "\n${CYAN}${BOLD}═══════════════════════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}${BOLD} $title ${NC}\n"
    printf "${CYAN}${BOLD}═══════════════════════════════════════════════════════════════════════${NC}\n\n"
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
}

# =============================================================================
# DATABASE OPERATIONS
# =============================================================================

execute_sql() {
    local host="$1"
    local port="$2"
    local sql="$3"
    local timeout="${4:-$DEFAULT_TIMEOUT}"
    
    log "DEBUG" "Executing SQL on $host:$port - SQL: $sql"
    
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
    
    log "DEBUG" "SQL execution result - Exit code: $exit_code"
    
    if [[ $exit_code -eq 0 ]]; then
        echo "$output"
        return 0
    else
        log "DEBUG" "SQL execution failed - Host: $host, Port: $port, Error: $output"
        return $exit_code
    fi
}

get_node_role() {
    local host="$1"
    local port="${2:-$DB_PORT}"
    
    log "DEBUG" "Getting node role for $host:$port"
    
    # Try multiple ports and methods to detect role
    local role="UNREACHABLE"
    
    # First try the configured port
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -Atqc "SELECT 1;" >/dev/null 2>&1; then
        
        role=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
            -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
            -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    fi
    
    # If failed, try direct port 5432
    if [[ "$role" == "UNREACHABLE" && "$port" != "5432" ]]; then
        log "DEBUG" "Trying direct port 5432 for $host"
        if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
            -h "$host" -p "5432" -U "$USERNAME" -d "$DATABASE" \
            -Atqc "SELECT 1;" >/dev/null 2>&1; then
            
            role=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
                -h "$host" -p "5432" -U "$USERNAME" -d "$DATABASE" \
                -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
        fi
    fi
    
    log "DEBUG" "Node $host:$port role: $role"
    echo "$role"
}

test_connectivity() {
    local host="$1"
    local port="${2:-$DB_PORT}"
    local timeout="${3:-10}"
    
    log "DEBUG" "Testing connectivity to $host:$port (timeout: ${timeout}s)"
    
    # Try the specified port first
    if timeout "$timeout" env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -c "SELECT 1;" >/dev/null 2>&1; then
        log "DEBUG" "Connectivity test to $host:$port: SUCCESS"
        return 0
    fi
    
    # If failed and not using direct port, try direct port 5432
    if [[ "$port" != "5432" ]]; then
        log "DEBUG" "Trying direct port 5432 for $host"
        if timeout "$timeout" env PGPASSWORD="$PG_SUPER_PASS" psql \
            -h "$host" -p "5432" -U "$USERNAME" -d "$DATABASE" \
            -c "SELECT 1;" >/dev/null 2>&1; then
            log "DEBUG" "Connectivity test to $host:5432: SUCCESS"
            return 0
        fi
    fi
    
    log "DEBUG" "Connectivity test to $host:$port: FAILED"
    return 1
}

# =============================================================================
# CLUSTER STATE MANAGEMENT
# =============================================================================

detect_cluster_state() {
    log "INFO" "Detecting current cluster state..."
    
    local primary_role=$(get_node_role "$PRIMARY_IP")
    local standby_role=$(get_node_role "$STANDBY_IP")
    
    if [[ "$primary_role" == "PRIMARY" && "$standby_role" == "STANDBY" ]]; then
        CLUSTER_STATE="NORMAL"
        CURRENT_PRIMARY="$PRIMARY_IP"
        CURRENT_STANDBY="$STANDBY_IP"
    elif [[ "$primary_role" == "STANDBY" && "$standby_role" == "PRIMARY" ]]; then
        CLUSTER_STATE="FAILED_OVER"
        CURRENT_PRIMARY="$STANDBY_IP"
        CURRENT_STANDBY="$PRIMARY_IP"
    elif [[ "$primary_role" == "PRIMARY" && "$standby_role" == "UNREACHABLE" ]]; then
        CLUSTER_STATE="STANDBY_DOWN"
        CURRENT_PRIMARY="$PRIMARY_IP"
        CURRENT_STANDBY=""
    elif [[ "$primary_role" == "UNREACHABLE" && "$standby_role" == "PRIMARY" ]]; then
        CLUSTER_STATE="PRIMARY_DOWN"
        CURRENT_PRIMARY="$STANDBY_IP"
        CURRENT_STANDBY=""
    else
        CLUSTER_STATE="BROKEN"
        CURRENT_PRIMARY=""
        CURRENT_STANDBY=""
    fi
    
    log "INFO" "Cluster state: $CLUSTER_STATE"
    log "INFO" "Current primary: ${CURRENT_PRIMARY:-NONE}"
    log "INFO" "Current standby: ${CURRENT_STANDBY:-NONE}"
}

# =============================================================================
# HEALTH CHECKS
# =============================================================================

comprehensive_health_check() {
    section "Comprehensive Health Check"
    
    local health_score=0
    local checks_passed=0
    local total_checks=8
    
    # Check 1: Node connectivity
    log "STEP" "Checking node connectivity..."
    if test_connectivity "$PRIMARY_IP" && test_connectivity "$STANDBY_IP"; then
        log "SUCCESS" "Both nodes are reachable"
        health_score=$((health_score + 15))
        ((checks_passed++))
    else
        log "ERROR" "Node connectivity issues detected"
    fi
    
    # Check 2: Role consistency
    log "STEP" "Verifying role consistency..."
    detect_cluster_state
    if [[ "$CLUSTER_STATE" == "NORMAL" || "$CLUSTER_STATE" == "FAILED_OVER" ]]; then
        log "SUCCESS" "Cluster roles are consistent"
        health_score=$((health_score + 15))
        ((checks_passed++))
    else
        log "ERROR" "Cluster role inconsistency: $CLUSTER_STATE"
    fi
    
    # Check 3: Replication status
    log "STEP" "Checking replication status..."
    if [[ -n "$CURRENT_PRIMARY" && -n "$CURRENT_STANDBY" ]]; then
        local repl_count
        repl_count=$(execute_sql "$CURRENT_PRIMARY" "$DB_DIRECT_PORT" "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d ' \t\n\r')
        
        if [[ "$repl_count" == "1" ]]; then
            log "SUCCESS" "Replication is active"
            health_score=$((health_score + 20))
            ((checks_passed++))
        else
            log "ERROR" "Replication not active (replica count: ${repl_count:-0})"
        fi
    else
        log "ERROR" "Cannot check replication - cluster issues"
    fi
    
    # Check 4: Data synchronization
    log "STEP" "Testing data synchronization..."
    if [[ -n "$CURRENT_PRIMARY" && -n "$CURRENT_STANDBY" ]]; then
        if test_simple_data_sync "$CURRENT_PRIMARY" "$CURRENT_STANDBY"; then
            log "SUCCESS" "Data synchronization working"
            health_score=$((health_score + 15))
            ((checks_passed++))
        else
            log "ERROR" "Data synchronization failed"
        fi
    else
        log "ERROR" "Cannot test sync - cluster issues"
    fi
    
    # Check 5: DNS resolution
    log "STEP" "Checking DNS resolution..."
    local dns_checks=0
    for dns in "$WRITE_DNS" "$READ_DNS"; do
        if nslookup "$dns" >/dev/null 2>&1; then
            ((dns_checks++))
        fi
    done
    
    if [[ $dns_checks -eq 2 ]]; then
        log "SUCCESS" "DNS resolution working"
        health_score=$((health_score + 10))
        ((checks_passed++))
    else
        log "ERROR" "DNS resolution issues"
    fi
    
    # Check 6: Load balancer connectivity
    log "STEP" "Checking load balancer connectivity..."
    local lb_checks=0
    if test_connectivity "$WRITE_DNS" "$DB_PORT" 5; then ((lb_checks++)); fi
    if test_connectivity "$READ_DNS" "$DB_PORT" 5; then ((lb_checks++)); fi
    
    if [[ $lb_checks -eq 2 ]]; then
        log "SUCCESS" "Load balancer connectivity working"
        health_score=$((health_score + 10))
        ((checks_passed++))
    else
        log "ERROR" "Load balancer issues"
    fi
    
    # Check 7: Replication slots
    log "STEP" "Checking replication slots..."
    if [[ -n "$CURRENT_PRIMARY" ]]; then
        local slots_count
        slots_count=$(execute_sql "$CURRENT_PRIMARY" "$DB_DIRECT_PORT" "SELECT COUNT(*) FROM pg_replication_slots WHERE active;" 2>/dev/null | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d ' \t\n\r')
        
        if [[ "$slots_count" -ge "1" ]]; then
            log "SUCCESS" "Replication slots configured"
            health_score=$((health_score + 10))
            ((checks_passed++))
        else
            log "ERROR" "No active replication slots"
        fi
    else
        log "ERROR" "Cannot check slots - no primary"
    fi
    
    # Check 8: System resources
    log "STEP" "Checking system resources..."
    local resource_checks=0
    
    for ssh_host in "$PRIMARY_SSH_HOST" "$STANDBY_SSH_HOST"; do
        local disk_usage
        disk_usage=$(ssh $SSH_OPTIONS "$SSH_USER@$ssh_host" "df /var/lib/postgresql | tail -1 | awk '{print \$5}' | sed 's/%//'" 2>/dev/null || echo "100")
        
        if [[ "$disk_usage" -lt 85 ]]; then
            ((resource_checks++))
        else
            log "WARN" "High disk usage on $ssh_host: ${disk_usage}%"
        fi
    done
    
    if [[ $resource_checks -eq 2 ]]; then
        log "SUCCESS" "System resources adequate"
        health_score=$((health_score + 5))
        ((checks_passed++))
    else
        log "ERROR" "System resource issues"
    fi
    
    # Calculate health percentage
    local max_score=100
    local health_percentage=$((health_score * 100 / max_score))
    
    log "METRIC" "Health Check Summary:"
    log "METRIC" "  Checks passed: $checks_passed/$total_checks"
    log "METRIC" "  Health score: $health_score/$max_score ($health_percentage%)"
    
    if [[ $health_percentage -ge 90 ]]; then
        log "SUCCESS" "Cluster health: EXCELLENT"
        return 0
    elif [[ $health_percentage -ge 75 ]]; then
        log "SUCCESS" "Cluster health: GOOD"
        return 0
    elif [[ $health_percentage -ge 50 ]]; then
        log "WARN" "Cluster health: FAIR"
        return 1
    else
        log "ERROR" "Cluster health: POOR"
        return 2
    fi
}

# =============================================================================
# TESTING FUNCTIONS
# =============================================================================

test_simple_data_sync() {
    local primary_host="$1"
    local standby_host="$2"
    
    local test_table="sync_test_$(date +%s)_$$"
    local test_data="data_$(date +%s%N)"
    
    log "DEBUG" "Testing sync: $test_table with: $test_data"
    
    # Create test data
    if ! execute_sql "$primary_host" "$DB_PORT" "
        CREATE TABLE $test_table (id SERIAL, data TEXT, ts TIMESTAMP DEFAULT NOW());
        INSERT INTO $test_table (data) VALUES ('$test_data');
    " >/dev/null 2>&1; then
        return 1
    fi
    
    # Wait for replication
    local attempts=0
    local max_attempts=15
    
    while [[ $attempts -lt $max_attempts ]]; do
        if execute_sql "$standby_host" "$DB_PORT" "SELECT data FROM $test_table WHERE data = '$test_data';" 2>/dev/null | grep -q "$test_data"; then
            # Cleanup
            execute_sql "$primary_host" "$DB_PORT" "DROP TABLE $test_table;" >/dev/null 2>&1 || true
            return 0
        fi
        
        sleep 2
        ((attempts++))
    done
    
    # Cleanup on failure
    execute_sql "$primary_host" "$DB_PORT" "DROP TABLE $test_table;" >/dev/null 2>&1 || true
    return 1
}

# =============================================================================
# FAILOVER SCENARIOS
# =============================================================================

scenario_planned_failover() {
    section "Scenario: Planned Failover"
    SCENARIO_RESULTS+=("PLANNED_FAILOVER:RUNNING")
    
    local start_time=$(date +%s)
    log "SCENARIO" "Starting planned failover..."
    
    # Pre-validation
    log "STEP" "Pre-failover validation"
    if ! comprehensive_health_check; then
        log "ERROR" "Pre-failover health check failed"
        SCENARIO_RESULTS+=("PLANNED_FAILOVER:FAILED")
        return 1
    fi
    
    # Execute failover
    log "STEP" "Executing planned failover"
    if execute_planned_failover; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "SUCCESS" "Planned failover completed in ${duration}s"
        SCENARIO_RESULTS+=("PLANNED_FAILOVER:SUCCESS:${duration}s")
        
        detect_cluster_state
        return 0
    else
        SCENARIO_RESULTS+=("PLANNED_FAILOVER:FAILED")
        return 1
    fi
}

scenario_automatic_failback() {
    section "Scenario: Automatic Failback"
    SCENARIO_RESULTS+=("AUTOMATIC_FAILBACK:RUNNING")
    
    local start_time=$(date +%s)
    log "SCENARIO" "Starting automatic failback..."
    
    # Verify state
    detect_cluster_state
    if [[ "$CLUSTER_STATE" != "FAILED_OVER" ]]; then
        log "ERROR" "Not in failed-over state for failback"
        SCENARIO_RESULTS+=("AUTOMATIC_FAILBACK:FAILED")
        return 1
    fi
    
    # Execute failback
    log "STEP" "Executing failback"
    if execute_automatic_failback; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "SUCCESS" "Failback completed in ${duration}s"
        SCENARIO_RESULTS+=("AUTOMATIC_FAILBACK:SUCCESS:${duration}s")
        
        detect_cluster_state
        return 0
    else
        SCENARIO_RESULTS+=("AUTOMATIC_FAILBACK:FAILED")
        return 1
    fi
}

# =============================================================================
# FAILOVER IMPLEMENTATIONS
# =============================================================================

execute_planned_failover() {
    log "INFO" "Executing planned failover..."
    
    # Graceful shutdown
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl stop postgresql" || return 1
    sleep 5
    
    # Promote standby
    if ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf standby promote --force" 2>/dev/null; then
        return 0
    fi
    
    # Fallback promotion
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -c \"SELECT pg_promote();\""
}

execute_automatic_failback() {
    log "INFO" "Executing automatic failback..."
    
    # Stop repmgrd
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl stop repmgrd" 2>/dev/null || true
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl stop repmgrd" 2>/dev/null || true
    
    # Promote original primary
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c \"SELECT pg_promote();\"" || return 1
    
    # Stop current primary
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl stop postgresql"
    sleep 5
    
    # Re-clone standby
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        sudo rm -rf /var/lib/postgresql/17/main
        sudo mkdir -p /var/lib/postgresql/17/main
        sudo chown postgres:postgres /var/lib/postgresql/17/main
        sudo chmod 700 /var/lib/postgresql/17/main
        
        sudo -u postgres env PGPASSWORD='$PG_SUPER_PASS' pg_basebackup \\
            -h $PRIMARY_IP -p 5432 -U postgres \\
            -D /var/lib/postgresql/17/main \\
            -v -P --no-password -X stream --checkpoint=fast --write-recovery-conf
        
        sudo systemctl start postgresql
    " || return 1
    
    # Restart repmgrd
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl start repmgrd" 2>/dev/null || true
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl start repmgrd" 2>/dev/null || true
    
    sleep 15
    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

run_all_scenarios() {
    section "Running All Scenarios"
    
    TEST_START_TIME=$(date +%s)
    local scenarios_passed=0
    local total_scenarios=2
    
    detect_cluster_state
    
    # Scenario 1: Planned Failover
    if scenario_planned_failover; then
        ((scenarios_passed++))
    fi
    
    # Scenario 2: Failback
    if scenario_automatic_failback; then
        ((scenarios_passed++))
    fi
    
    # Final health check
    comprehensive_health_check
    
    log "METRIC" "Scenarios Summary:"
    log "METRIC" "  Passed: $scenarios_passed/$total_scenarios"
    log "METRIC" "  Success rate: $((scenarios_passed * 100 / total_scenarios))%"
    log "METRIC" "  Duration: $(($(date +%s) - TEST_START_TIME)) seconds"
    
    if [[ $scenarios_passed -eq $total_scenarios ]]; then
        log "SUCCESS" "All scenarios completed successfully!"
        return 0
    else
        log "ERROR" "Some scenarios failed"
        return 1
    fi
}

show_simple_menu() {
    echo
    printf "${PURPLE}${BOLD}PostgreSQL HA Simplified Validator v${SCRIPT_VERSION}${NC}\n"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🏥 HEALTH & DIAGNOSTICS"
    echo "1.  🔍 Comprehensive health check"
    echo "2.  📊 Cluster state detection"
    echo ""
    echo "🎯 SCENARIOS"
    echo "3.  📋 Planned failover scenario"
    echo "4.  🔄 Automatic failback scenario"
    echo ""
    echo "🚀 COMPREHENSIVE TESTING"
    echo "5.  🎪 Run all scenarios (full suite)"
    echo "6.  🔁 Complete cycle (failover + failback)"
    echo ""
    echo "📈 UTILITIES"
    echo "7.  🧹 Reset cluster to normal state"
    echo "8.  📋 Show test results"
    echo "9.  ❌ Exit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

main() {
    section "PostgreSQL HA Simplified Validator"
    log "INFO" "Version: $SCRIPT_VERSION"
    log "INFO" "Timestamp: $(date)"
    
    get_credentials
    detect_cluster_state
    
    while true; do
        show_simple_menu
        read -p "Enter your choice (1-9): " choice
        
        case $choice in
            1)
                comprehensive_health_check
                ;;
            2)
                detect_cluster_state
                ;;
            3)
                scenario_planned_failover
                ;;
            4)
                scenario_automatic_failback
                ;;
            5)
                echo
                read -p "⚠️  Run all scenarios? This tests complete HA functionality. Continue? (yes/NO): " confirm
                if [[ "$confirm" == "yes" ]]; then
                    run_all_scenarios
                else
                    log "INFO" "All scenarios test cancelled"
                fi
                ;;
            6)
                echo
                read -p "⚠️  Run complete cycle? This includes failover and failback. Continue? (yes/NO): " confirm
                if [[ "$confirm" == "yes" ]]; then
                    scenario_planned_failover && scenario_automatic_failback
                else
                    log "INFO" "Complete cycle cancelled"
                fi
                ;;
            7)
                echo
                read -p "⚠️  Reset to normal state? Continue? (yes/NO): " confirm
                if [[ "$confirm" == "yes" ]]; then
                    if [[ "$CLUSTER_STATE" == "FAILED_OVER" ]]; then
                        scenario_automatic_failback
                    fi
                    log "SUCCESS" "Reset completed"
                else
                    log "INFO" "Reset cancelled"
                fi
                ;;
            8)
                log "INFO" "Test Results:"
                for result in "${SCENARIO_RESULTS[@]}"; do
                    log "METRIC" "  $result"
                done
                ;;
            9)
                log "INFO" "Exiting validator"
                break
                ;;
            *)
                log "ERROR" "Invalid choice. Please select 1-9."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

# Execute main function
main "$@"