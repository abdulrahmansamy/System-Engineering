#!/bin/bash
# =============================================================================
# PostgreSQL HA Replication Connection Fix Script
# =============================================================================
# This script addresses the specific issue where the standby is not connecting
# to the primary for replication, resulting in replica_count = 0
# =============================================================================

set -euo pipefail

# Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
DB_PORT="6432"
DB_DIRECT_PORT="5432"
USERNAME="postgres"
DATABASE="postgres"

# SSH Configuration
SSH_USER="asamy_nominations_ipa_edu_sa"
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
PRIMARY_SSH_HOST="ipa-nprd-ha-pg-primary-01"
STANDBY_SSH_HOST="ipa-nprd-ha-pg-standby-01"

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

ssh_execute() {
    local host="$1"
    local command="$2"
    local timeout="${3:-30}"
    
    timeout "$timeout" ssh $SSH_OPTIONS "$SSH_USER@$host" "$command"
}

fix_replication_connection() {
    section "Fixing PostgreSQL Replication Connection"
    
    log "INFO" "Based on diagnostics, fixing the replica connection issue..."
    
    # Step 1: Create replication slot on primary
    log "STEP" "Creating replication slot on primary"
    local slot_creation
    slot_creation=$(execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
        SELECT pg_create_physical_replication_slot('repmgr_slot_2') 
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_replication_slots WHERE slot_name = 'repmgr_slot_2'
        );
    " 2>&1)
    
    log "INFO" "Slot creation result: $slot_creation"
    
    # Step 2: Verify pg_hba.conf on primary
    log "STEP" "Checking and fixing pg_hba.conf on primary"
    ssh_execute "$PRIMARY_SSH_HOST" "
        echo 'Current pg_hba.conf replication entries:'
        sudo grep -n 'replication' /etc/postgresql/17/main/pg_hba.conf || echo 'No replication entries found'
        
        # Add replication entries if missing
        if ! sudo grep -q 'host.*replication.*postgres.*192.168.14' /etc/postgresql/17/main/pg_hba.conf; then
            echo 'Adding replication entries...'
            sudo cp /etc/postgresql/17/main/pg_hba.conf /etc/postgresql/17/main/pg_hba.conf.backup_\$(date +%Y%m%d_%H%M%S)
            
            # Add comprehensive replication entries
            sudo tee -a /etc/postgresql/17/main/pg_hba.conf << 'EOL'

# Replication entries for HA setup
host    replication     postgres        192.168.14.21/32               md5
host    replication     postgres        192.168.14.22/32               md5
host    replication     repmgr          192.168.14.21/32               md5
host    replication     repmgr          192.168.14.22/32               md5
host    replication     postgres        192.168.14.0/24                md5
host    replication     repmgr          192.168.14.0/24                md5
EOL
            
            # Reload configuration
            sudo -u postgres psql -c 'SELECT pg_reload_conf();'
            echo 'pg_hba.conf updated and reloaded'
        else
            echo 'Replication entries already exist'
        fi
    "
    
    # Step 3: Check standby configuration
    log "STEP" "Analyzing standby configuration"
    ssh_execute "$STANDBY_SSH_HOST" "
        echo 'Current standby configuration files:'
        
        # Check for recovery configuration
        if [ -f /var/lib/postgresql/17/main/standby.signal ]; then
            echo 'standby.signal exists - good'
        else
            echo 'WARNING: standby.signal missing!'
        fi
        
        # Check postgresql.auto.conf
        if [ -f /var/lib/postgresql/17/main/postgresql.auto.conf ]; then
            echo 'postgresql.auto.conf contents:'
            sudo -u postgres cat /var/lib/postgresql/17/main/postgresql.auto.conf
        else
            echo 'WARNING: postgresql.auto.conf missing!'
        fi
        
        # Check postgresql.conf for relevant settings
        echo 'Current postgresql.conf replication settings:'
        sudo grep -E '(primary_conninfo|primary_slot_name|hot_standby)' /etc/postgresql/17/main/postgresql.conf || echo 'No replication settings found'
    "
    
    # Step 4: Check standby PostgreSQL logs for errors
    log "STEP" "Checking standby PostgreSQL logs for connection errors"
    ssh_execute "$STANDBY_SSH_HOST" "
        echo 'Recent PostgreSQL log entries (last 20 lines):'
        sudo tail -20 /var/log/postgresql/postgresql-17-main.log
    "
    
    # Step 5: Test replication user connectivity
    log "STEP" "Testing replication user connectivity from standby to primary"
    ssh_execute "$STANDBY_SSH_HOST" "
        echo 'Testing postgres user replication connection...'
        sudo -u postgres env PGPASSWORD='$PG_SUPER_PASS' psql -h $PRIMARY_IP -p $DB_DIRECT_PORT -U postgres -d postgres -c 'SELECT 1;' || echo 'Postgres user connection failed'
        
        echo 'Testing repmgr user replication connection...'
        sudo -u postgres env PGPASSWORD='$PG_SUPER_PASS' psql -h $PRIMARY_IP -p $DB_DIRECT_PORT -U repmgr -d repmgr -c 'SELECT 1;' || echo 'Repmgr user connection failed'
        
        echo 'Testing replication-specific connection...'
        sudo -u postgres env PGPASSWORD='$PG_SUPER_PASS' psql -h $PRIMARY_IP -p $DB_DIRECT_PORT -U postgres replication=1 -c 'IDENTIFY_SYSTEM;' || echo 'Replication connection failed'
    "
    
    # Step 6: Fix standby configuration if needed
    log "STEP" "Configuring standby with proper connection settings"
    ssh_execute "$STANDBY_SSH_HOST" "
        # Ensure standby.signal exists
        sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal
        
        # Create or update postgresql.auto.conf with proper primary connection info
        sudo -u postgres tee /var/lib/postgresql/17/main/postgresql.auto.conf << 'EOL'
# Standby configuration
primary_conninfo = 'host=$PRIMARY_IP port=$DB_DIRECT_PORT user=postgres application_name=standby'
primary_slot_name = 'repmgr_slot_2'
hot_standby = on
EOL
        
        echo 'Standby configuration updated'
    "
    
    # Step 7: Restart standby PostgreSQL to apply changes
    log "STEP" "Restarting standby PostgreSQL to establish connection"
    ssh_execute "$STANDBY_SSH_HOST" "
        sudo systemctl restart postgresql
        echo 'PostgreSQL restarted on standby'
        
        # Wait a moment for startup
        sleep 5
        
        echo 'Checking PostgreSQL status:'
        sudo systemctl status postgresql --no-pager -l
    "
    
    # Step 8: Verify replication connection
    log "STEP" "Verifying replication connection"
    sleep 10  # Allow time for connection
    
    local replication_status
    replication_status=$(execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
        SELECT 
            application_name,
            client_addr,
            state,
            sync_state,
            backend_start
        FROM pg_stat_replication;
    " 2>&1)
    
    log "INFO" "Replication status after fix:"
    echo "$replication_status"
    
    local replica_count_raw
    replica_count_raw=$(execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "SELECT COUNT(*) FROM pg_stat_replication;" 2>&1)
    local replica_count
    replica_count=$(echo "$replica_count_raw" | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d ' \t\n\r')
    
    log "INFO" "Replica count raw output: '$replica_count_raw'"
    log "INFO" "Parsed replica count: '$replica_count'"
    
    if [[ "$replica_count" == "1" ]] || echo "$replication_status" | grep -q "streaming"; then
        log "SUCCESS" "Replication connection established! Replica count: $replica_count"
        
        # Test data replication
        log "INFO" "Testing data replication..."
        local test_table="repl_fix_test_$(date +%s)"
        local test_value="fix_test_$(date +%s%N)"
        
        # Create test data on primary
        execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
            CREATE TABLE $test_table (id SERIAL, test_data TEXT);
            INSERT INTO $test_table (test_data) VALUES ('$test_value');
        "
        
        # Wait and check on standby
        sleep 5
        local standby_check
        standby_check=$(execute_sql "$STANDBY_IP" "$DB_DIRECT_PORT" "SELECT COUNT(*) FROM $test_table WHERE test_data = '$test_value';" 2>&1 | tail -1 | tr -d ' \t\n\r')
        
        if [[ "$standby_check" == "1" ]]; then
            log "SUCCESS" "Data replication test PASSED! Data synchronized successfully."
        else
            log "WARN" "Data replication test failed, but connection is established"
        fi
        
        # Cleanup
        execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "DROP TABLE $test_table;" || true
        
    else
        log "ERROR" "Replication connection not established. Replica count: $replica_count"
        
        # Show recent logs for debugging
        log "INFO" "Checking recent standby logs for errors..."
        ssh_execute "$STANDBY_SSH_HOST" "
            echo 'Recent PostgreSQL log entries:'
            sudo tail -10 /var/log/postgresql/postgresql-17-main.log
        "
        
        return 1
    fi
}

show_final_status() {
    section "Final Cluster Status"
    
    log "INFO" "Primary node replication status:"
    execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
        SELECT 
            COUNT(*) as connected_replicas,
            string_agg(application_name || ' (' || client_addr || ')', ', ') as replica_details
        FROM pg_stat_replication;
    "
    
    log "INFO" "Standby node status:"
    execute_sql "$STANDBY_IP" "$DB_DIRECT_PORT" "
        SELECT 
            pg_is_in_recovery() as in_recovery,
            pg_last_wal_receive_lsn() as last_receive_lsn,
            pg_last_wal_replay_lsn() as last_replay_lsn,
            EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) as replay_lag_seconds;
    "
    
    log "INFO" "Replication slots:"
    execute_sql "$PRIMARY_IP" "$DB_DIRECT_PORT" "
        SELECT slot_name, active, restart_lsn FROM pg_replication_slots;
    "
}

main() {
    section "PostgreSQL Replication Connection Fixer"
    
    log "INFO" "This script will fix the replication connection issue identified in diagnostics"
    log "WARN" "This will modify PostgreSQL configuration and restart services"
    
    read -p "Continue with replication fix? (yes/NO): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "INFO" "Fix cancelled by user"
        exit 0
    fi
    
    # Get credentials
    get_credentials
    
    # Execute fix
    if fix_replication_connection; then
        log "SUCCESS" "Replication connection fix completed successfully"
        show_final_status
    else
        log "ERROR" "Replication connection fix failed"
        exit 1
    fi
}

# Run main function
main "$@"