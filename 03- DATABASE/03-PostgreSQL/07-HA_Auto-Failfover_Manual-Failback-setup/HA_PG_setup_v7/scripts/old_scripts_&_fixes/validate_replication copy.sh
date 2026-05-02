#!/bin/bash
# =============================================================================
# Quick Replication Status Validator
# =============================================================================
# This script quickly validates that replication is working properly
# =============================================================================

set -euo pipefail

# Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
DB_DIRECT_PORT="5432"
USERNAME="postgres"
DATABASE="postgres"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    esac
}

get_credentials() {
    if [[ -z "${PG_SUPER_PASS:-}" ]]; then
        if PG_SUPER_PASS=$(timeout 10 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
            if [[ -n "$PG_SUPER_PASS" ]]; then
                export PG_SUPER_PASS
            else
                export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
            fi
        else
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

validate_replication() {
    echo "🔍 PostgreSQL Replication Status Validation"
    echo "==========================================="
    
    get_credentials
    
    log "INFO" "Checking replication connection on primary..."
    local repl_status
    repl_status=$(execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
        SELECT 
            COUNT(*) as replica_count,
            string_agg(application_name || ' (' || client_addr || ') - ' || state, ', ') as details
        FROM pg_stat_replication;
    " 2>&1)
    
    echo "$repl_status"
    
    # Check if replication is active
    local is_streaming
    is_streaming=$(execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
        SELECT COUNT(*) FROM pg_stat_replication WHERE state = 'streaming';
    " 2>&1 | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d ' \t\n\r')
    
    if [[ "$is_streaming" == "1" ]]; then
        log "SUCCESS" "Replication is ACTIVE and STREAMING!"
        
        # Test actual data replication
        log "INFO" "Testing data replication..."
        local test_table="quick_repl_test_$(date +%s)"
        local test_value="test_$(date +%s%N)"
        
        # Create test data
        execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
            CREATE TABLE $test_table (id SERIAL, data TEXT);
            INSERT INTO $test_table (data) VALUES ('$test_value');
        " >/dev/null 2>&1
        
        # Wait briefly
        sleep 3
        
        # Check on standby
        local standby_result
        standby_result=$(execute_sql "$STANDBY_IP" "$DB_DIRECT_PORT" "
            SELECT COUNT(*) FROM $test_table WHERE data = '$test_value';
        " 2>&1 | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d ' \t\n\r')
        
        if [[ "$standby_result" == "1" ]]; then
            log "SUCCESS" "Data replication test PASSED! 🎉"
            echo
            echo "✅ REPLICATION IS WORKING PERFECTLY!"
            echo "   • Primary has active streaming replica"
            echo "   • Data synchronization confirmed"
            echo "   • Your HA cluster is healthy!"
        else
            log "WARN" "Replication connection exists but data sync may be delayed"
        fi
        
        # Cleanup
        execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "DROP TABLE $test_table;" >/dev/null 2>&1 || true
        
    else
        log "ERROR" "No streaming replication found"
        
        # Show detailed status for debugging
        log "INFO" "Detailed replication information:"
        execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
            SELECT 
                application_name,
                client_addr,
                state,
                sync_state,
                backend_start,
                sent_lsn,
                write_lsn,
                flush_lsn,
                replay_lsn
            FROM pg_stat_replication;
        "
    fi
    
    # Show replication slots
    log "INFO" "Current replication slots:"
    execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
        SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;
    "
    
    # Show standby status
    log "INFO" "Standby status:"
    execute_sql "$STANDBY_IP" "$DB_DIRECT_PORT" "
        SELECT 
            pg_is_in_recovery() as in_recovery,
            pg_last_wal_receive_lsn() as receive_lsn,
            pg_last_wal_replay_lsn() as replay_lsn,
            EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) as lag_seconds;
    "
}

# Run validation
validate_replication