#!/bin/bash
# =============================================================================
# PostgreSQL HA Replication Troubleshooting Script
# =============================================================================
# This script specifically addresses the replication lag and synchronization 
# issues observed in the HA testing suite
# =============================================================================

set -euo pipefail

# Configuration (same as main script)
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
DB_PORT="6432"
DB_DIRECT_PORT="5432"
USERNAME="postgres"
DATABASE="postgres"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
    esac
}

section() {
    printf "\n${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}${BOLD} %s ${NC}\n" "$*"
    printf "${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}\n\n"
}

get_credentials() {
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

execute_sql() {
    local host="$1"
    local port="$2"
    local sql="$3"
    
    timeout 30 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -c "$sql" 2>&1
}

test_connectivity() {
    local host="$1"
    local port="$2"
    
    timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -c "SELECT 1;" >/dev/null 2>&1
}

analyze_replication_issue() {
    section "Replication Issue Analysis"
    
    log "INFO" "Analyzing replication configuration and status..."
    
    # Check connectivity to both nodes
    log "STEP" "Verifying connectivity"
    local primary_reachable=false
    local standby_reachable=false
    
    if test_connectivity "$PRIMARY_IP" "$DB_PORT"; then
        log "SUCCESS" "Primary node ($PRIMARY_IP:$DB_PORT) is reachable"
        primary_reachable=true
    else
        log "ERROR" "Primary node ($PRIMARY_IP:$DB_PORT) is NOT reachable"
    fi
    
    if test_connectivity "$STANDBY_IP" "$DB_PORT"; then
        log "SUCCESS" "Standby node ($STANDBY_IP:$DB_PORT) is reachable"
        standby_reachable=true
    else
        log "ERROR" "Standby node ($STANDBY_IP:$DB_PORT) is NOT reachable"
    fi
    
    if [[ "$primary_reachable" != true ]] || [[ "$standby_reachable" != true ]]; then
        log "ERROR" "Cannot proceed with replication analysis - connectivity issues"
        return 1
    fi
    
    # Determine actual roles
    log "STEP" "Determining actual node roles"
    local primary_role
    local standby_role
    
    primary_role=$(execute_sql "$PRIMARY_IP" "$DB_PORT" "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    standby_role=$(execute_sql "$STANDBY_IP" "$DB_PORT" "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    
    log "INFO" "Node $PRIMARY_IP role: $primary_role"
    log "INFO" "Node $STANDBY_IP role: $standby_role"
    
    # Determine which is actually primary/standby
    local actual_primary=""
    local actual_standby=""
    
    if [[ "$primary_role" == "PRIMARY" ]] && [[ "$standby_role" == "STANDBY" ]]; then
        actual_primary="$PRIMARY_IP"
        actual_standby="$STANDBY_IP"
        log "SUCCESS" "Cluster roles are as expected"
    elif [[ "$primary_role" == "STANDBY" ]] && [[ "$standby_role" == "PRIMARY" ]]; then
        actual_primary="$STANDBY_IP"
        actual_standby="$PRIMARY_IP"
        log "WARN" "Cluster roles are swapped (failover state)"
    else
        log "ERROR" "Invalid cluster state: Primary=$primary_role, Standby=$standby_role"
        return 1
    fi
    
    log "INFO" "Actual primary: $actual_primary"
    log "INFO" "Actual standby: $actual_standby"
    
    # Analyze replication status on primary
    log "STEP" "Analyzing replication status on primary ($actual_primary)"
    local repl_count
    repl_count=$(execute_sql "$actual_primary" "$DB_PORT" "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    
    log "INFO" "Number of connected replicas: $repl_count"
    
    if [[ "$repl_count" == "0" ]]; then
        log "ERROR" "No replicas connected to primary - this explains the replication lag issue!"
        
        # Check replication slots
        log "INFO" "Checking replication slots..."
        local slots_info
        slots_info=$(execute_sql "$actual_primary" "$DB_PORT" "
            SELECT 
                slot_name,
                slot_type,
                database,
                active,
                temporary,
                restart_lsn,
                confirmed_flush_lsn
            FROM pg_replication_slots;
        " 2>&1)
        
        echo "$slots_info"
        
        # Check pg_hba.conf for replication entries
        log "INFO" "This suggests either:"
        log "INFO" "  1. Standby is not configured to connect to primary"
        log "INFO" "  2. Authentication issues (pg_hba.conf)"
        log "INFO" "  3. Network connectivity issues"
        log "INFO" "  4. Standby PostgreSQL service is down"
        
    else
        log "SUCCESS" "Replicas are connected, analyzing detailed status..."
        
        # Get detailed replication status
        local detailed_repl
        detailed_repl=$(execute_sql "$actual_primary" "$DB_PORT" "
            SELECT 
                application_name,
                client_addr,
                client_hostname,
                client_port,
                backend_start,
                state,
                sent_lsn,
                write_lsn,
                flush_lsn,
                replay_lsn,
                write_lag,
                flush_lag,
                replay_lag,
                sync_state,
                pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) as send_lag_bytes,
                pg_wal_lsn_diff(sent_lsn, write_lsn) as write_lag_bytes,
                pg_wal_lsn_diff(write_lsn, flush_lsn) as flush_lag_bytes,
                pg_wal_lsn_diff(flush_lsn, replay_lsn) as replay_lag_bytes
            FROM pg_stat_replication;
        " 2>&1)
        
        echo "$detailed_repl"
    fi
    
    # Analyze standby status
    log "STEP" "Analyzing standby status ($actual_standby)"
    
    # Check if standby is in recovery
    local recovery_status
    recovery_status=$(execute_sql "$actual_standby" "$DB_PORT" "
        SELECT 
            pg_is_in_recovery() as in_recovery,
            pg_last_wal_receive_lsn() as last_receive_lsn,
            pg_last_wal_replay_lsn() as last_replay_lsn,
            pg_last_xact_replay_timestamp() as last_replay_timestamp,
            EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) as replay_lag_seconds;
    " 2>&1)
    
    log "INFO" "Standby recovery status:"
    echo "$recovery_status"
    
    # Check standby configuration
    log "INFO" "Checking standby configuration..."
    local standby_config
    standby_config=$(execute_sql "$actual_standby" "$DB_PORT" "
        SELECT 
            name, 
            setting, 
            source 
        FROM pg_settings 
        WHERE name IN (
            'primary_conninfo',
            'primary_slot_name',
            'hot_standby',
            'wal_receiver_status_interval',
            'max_standby_streaming_delay'
        );
    " 2>&1)
    
    echo "$standby_config"
    
    # Test actual LAG calculation
    log "STEP" "Testing LAG calculation"
    
    local primary_lsn
    primary_lsn=$(execute_sql "$actual_primary" "$DB_PORT" "SELECT pg_current_wal_lsn();" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    log "INFO" "Primary current LSN: '$primary_lsn'"
    
    local standby_lsn
    standby_lsn=$(execute_sql "$actual_standby" "$DB_PORT" "SELECT pg_last_wal_replay_lsn();" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    log "INFO" "Standby replay LSN: '$standby_lsn'"
    
    if [[ -n "$primary_lsn" ]] && [[ -n "$standby_lsn" ]] && [[ "$primary_lsn" != "UNREACHABLE" ]] && [[ "$standby_lsn" != "UNREACHABLE" ]]; then
        local lag_calculation
        lag_calculation=$(execute_sql "$actual_primary" "$DB_PORT" "SELECT pg_wal_lsn_diff('$primary_lsn', '$standby_lsn');" 2>&1)
        log "INFO" "LAG calculation result: '$lag_calculation'"
        
        # Extract just the numeric value
        local lag_numeric
        lag_numeric=$(echo "$lag_calculation" | tail -1 | tr -d ' \t\n\r' | sed 's/[^0-9\-]//g')
        log "INFO" "LAG numeric value: '$lag_numeric'"
        
        if [[ -z "$lag_numeric" ]]; then
            log "ERROR" "Failed to extract numeric lag value - this is the issue!"
            log "INFO" "Raw calculation output: '$lag_calculation'"
        elif [[ "$lag_numeric" -eq 0 ]]; then
            log "SUCCESS" "Replication is perfectly in sync (0 bytes lag)"
        else
            log "INFO" "Replication lag: $lag_numeric bytes"
        fi
    else
        log "ERROR" "Failed to get LSN values for lag calculation"
        log "ERROR" "Primary LSN: '$primary_lsn'"
        log "ERROR" "Standby LSN: '$standby_lsn'"
    fi
}

test_simple_replication() {
    section "Simple Replication Test"
    
    log "INFO" "Testing end-to-end replication with a simple table..."
    
    # Determine roles first
    local primary_role
    local standby_role
    
    primary_role=$(execute_sql "$PRIMARY_IP" "$DB_PORT" "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    standby_role=$(execute_sql "$STANDBY_IP" "$DB_PORT" "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null | tail -1 | tr -d ' \t\n\r')
    
    local actual_primary=""
    local actual_standby=""
    
    if [[ "$primary_role" == "PRIMARY" ]] && [[ "$standby_role" == "STANDBY" ]]; then
        actual_primary="$PRIMARY_IP"
        actual_standby="$STANDBY_IP"
    elif [[ "$primary_role" == "STANDBY" ]] && [[ "$standby_role" == "PRIMARY" ]]; then
        actual_primary="$STANDBY_IP"
        actual_standby="$PRIMARY_IP"
    else
        log "ERROR" "Cannot determine primary/standby roles"
        return 1
    fi
    
    log "INFO" "Using primary: $actual_primary, standby: $actual_standby"
    
    # Create test table
    local test_table="repl_test_$(date +%s)"
    local test_value="test_data_$(date +%s%N)"
    
    log "STEP" "Creating test table on primary..."
    local create_result
    create_result=$(execute_sql "$actual_primary" "$DB_PORT" "
        DROP TABLE IF EXISTS $test_table;
        CREATE TABLE $test_table (
            id SERIAL PRIMARY KEY,
            test_value TEXT,
            created_at TIMESTAMP DEFAULT NOW()
        );
        INSERT INTO $test_table (test_value) VALUES ('$test_value');
        SELECT COUNT(*) as rows_inserted FROM $test_table;
    " 2>&1)
    
    log "INFO" "Test table creation result:"
    echo "$create_result"
    
    # Wait for replication
    log "STEP" "Waiting for replication (checking every 2 seconds for 30 seconds)..."
    
    local max_attempts=15
    local attempt=1
    local found=false
    
    while [[ $attempt -le $max_attempts ]]; do
        log "INFO" "Attempt $attempt/$max_attempts - Checking standby..."
        
        # Check if table exists and has data
        local standby_check
        standby_check=$(execute_sql "$actual_standby" "$DB_PORT" "
            SELECT 
                EXISTS (
                    SELECT FROM information_schema.tables 
                    WHERE table_name = '$test_table'
                ) as table_exists,
                COALESCE((
                    SELECT COUNT(*) FROM $test_table 
                    WHERE test_value = '$test_value'
                ), 0) as matching_rows;
        " 2>&1)
        
        log "INFO" "Standby check result:"
        echo "$standby_check"
        
        # Parse the result
        if echo "$standby_check" | grep -q "t.*1"; then
            log "SUCCESS" "Replication successful! Table exists and data is replicated."
            found=true
            break
        else
            log "INFO" "Data not yet replicated, waiting 2 seconds..."
            sleep 2
        fi
        
        ((attempt++))
    done
    
    if [[ "$found" != true ]]; then
        log "ERROR" "Replication test failed - data did not replicate within 30 seconds"
        
        # Additional debugging
        log "INFO" "Checking if table at least exists on standby..."
        local table_exists
        table_exists=$(execute_sql "$actual_standby" "$DB_PORT" "
            SELECT EXISTS (
                SELECT FROM information_schema.tables 
                WHERE table_name = '$test_table'
            );
        " 2>&1)
        
        log "INFO" "Table exists check: $table_exists"
        
        # Check current lag
        log "INFO" "Checking current replication lag..."
        local current_lag
        current_lag=$(execute_sql "$actual_standby" "$DB_PORT" "
            SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) as lag_seconds;
        " 2>&1)
        
        log "INFO" "Current replay lag: $current_lag seconds"
    fi
    
    # Cleanup
    log "STEP" "Cleaning up test table..."
    execute_sql "$actual_primary" "$DB_PORT" "DROP TABLE IF EXISTS $test_table;" >/dev/null 2>&1 || true
    
    return $([[ "$found" == true ]] && echo 0 || echo 1)
}

suggest_fixes() {
    section "Suggested Fixes"
    
    log "INFO" "Based on the analysis, here are potential fixes:"
    echo
    echo "1. 🔍 If no replicas are connected to primary:"
    echo "   - Check standby PostgreSQL service: sudo systemctl status postgresql"
    echo "   - Check standby logs: sudo tail -f /var/log/postgresql/postgresql-17-main.log"
    echo "   - Verify primary_conninfo in standby recovery.conf/postgresql.auto.conf"
    echo
    echo "2. 🔐 If authentication issues:"
    echo "   - Check pg_hba.conf on primary for replication entries"
    echo "   - Verify passwords and user permissions"
    echo "   - Test: psql -h $PRIMARY_IP -p $DB_DIRECT_PORT -U postgres -c 'SELECT 1;'"
    echo
    echo "3. 🔄 If replication slot issues:"
    echo "   - Check slots: SELECT * FROM pg_replication_slots;"
    echo "   - Drop inactive slots: SELECT pg_drop_replication_slot('slot_name');"
    echo "   - Create new slot: SELECT pg_create_physical_replication_slot('new_slot');"
    echo
    echo "4. 📊 If lag calculation issues:"
    echo "   - The script may be parsing empty or malformed LSN values"
    echo "   - Check if both nodes return valid LSN values"
    echo "   - Enable debug mode for more detailed output"
    echo
    echo "5. 🛠️ To enable debug mode:"
    echo "   export DEBUG_MODE=true"
    echo "   export VERBOSE_SQL=true"
    echo "   ./automated_ha_failover_tester.sh"
    echo
}

main() {
    section "PostgreSQL HA Replication Troubleshooter"
    
    log "INFO" "Starting replication troubleshooting analysis..."
    
    # Get credentials
    get_credentials
    
    # Run analysis
    if analyze_replication_issue; then
        log "SUCCESS" "Replication analysis completed"
    else
        log "ERROR" "Replication analysis failed"
    fi
    
    echo
    
    # Run simple test
    if test_simple_replication; then
        log "SUCCESS" "Simple replication test passed"
    else
        log "ERROR" "Simple replication test failed"
    fi
    
    echo
    
    # Provide suggestions
    suggest_fixes
}

# Run main function
main "$@"