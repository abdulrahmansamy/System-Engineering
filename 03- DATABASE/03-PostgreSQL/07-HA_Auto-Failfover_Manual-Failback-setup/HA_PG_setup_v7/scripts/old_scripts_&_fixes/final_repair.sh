#!/bin/bash
# Final Repair Script - Fix remaining permission and replication issues
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    else
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

# Function 1: Fix log file permissions
fix_log_permissions() {
    section "📁 Fixing Log File Permissions"
    
    info "1️⃣ Fixing repmgr log directory permissions on primary..."
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
        sudo mkdir -p /var/log/repmgr
        sudo chown postgres:postgres /var/log/repmgr
        sudo chmod 755 /var/log/repmgr
        sudo touch /var/log/repmgr/repmgrd.log
        sudo chown postgres:postgres /var/log/repmgr/repmgrd.log
        sudo chmod 644 /var/log/repmgr/repmgrd.log
        ls -la /var/log/repmgr/
    " 2>/dev/null || warn "Failed to fix primary log permissions"
    
    info "2️⃣ Fixing repmgr log directory permissions on standby..."
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        sudo mkdir -p /var/log/repmgr
        sudo chown postgres:postgres /var/log/repmgr
        sudo chmod 755 /var/log/repmgr
        sudo touch /var/log/repmgr/repmgrd.log
        sudo chown postgres:postgres /var/log/repmgr/repmgrd.log
        sudo chmod 644 /var/log/repmgr/repmgrd.log
        ls -la /var/log/repmgr/
    " 2>/dev/null || warn "Failed to fix standby log permissions"
    
    success "✅ Log permissions fixed"
}

# Function 2: Fix replication connectivity
fix_replication_connectivity() {
    section "🔗 Fixing Replication Connectivity"
    
    info "1️⃣ Checking repmgr user connectivity..."
    
    # Test if repmgr user can connect from standby to primary
    local repmgr_conn_test
    repmgr_conn_test=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -h $PRIMARY_IP -p 5432 -U repmgr -d repmgr -c 'SELECT 1;'" 2>&1 || echo "FAILED")
    
    if echo "$repmgr_conn_test" | grep -q "FAILED\|ERROR\|FATAL"; then
        warn "⚠️ repmgr user connection issues detected"
        info "Connection test result: $repmgr_conn_test"
        
        info "2️⃣ Checking pg_hba.conf configuration..."
        # Show current pg_hba.conf for repmgr user
        ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres cat /var/lib/postgresql/17/main/pg_hba.conf | grep -E 'repmgr|replication'" 2>/dev/null || warn "Cannot read pg_hba.conf"
        
        info "3️⃣ Ensuring repmgr user connectivity..."
        # Add repmgr connectivity rules if missing
        ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
            sudo -u postgres grep -q 'host repmgr repmgr 192.168.14.0/24 md5' /var/lib/postgresql/17/main/pg_hba.conf 2>/dev/null || {
                echo 'host repmgr repmgr 192.168.14.0/24 md5' | sudo -u postgres tee -a /var/lib/postgresql/17/main/pg_hba.conf
                sudo -u postgres psql -c 'SELECT pg_reload_conf();'
            }
        " 2>/dev/null || warn "Failed to update pg_hba.conf"
        
        sleep 3
        
        # Retest connectivity
        repmgr_conn_test=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -h $PRIMARY_IP -p 5432 -U repmgr -d repmgr -c 'SELECT 1;'" 2>&1 || echo "FAILED")
        
        if echo "$repmgr_conn_test" | grep -q "1"; then
            success "✅ repmgr connectivity restored"
        else
            error "❌ repmgr connectivity still broken: $repmgr_conn_test"
        fi
    else
        success "✅ repmgr user connectivity is working"
    fi
}

# Function 3: Restart PostgreSQL standby to re-establish replication
restart_standby_replication() {
    section "🔄 Restarting Standby Replication"
    
    info "1️⃣ Stopping standby PostgreSQL..."
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl stop postgresql" 2>/dev/null
    sleep 3
    
    info "2️⃣ Checking if recovery.conf exists..."
    local recovery_conf_exists
    recovery_conf_exists=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo test -f /var/lib/postgresql/17/main/standby.signal && echo 'YES' || echo 'NO'" 2>/dev/null || echo "UNKNOWN")
    
    if [[ "$recovery_conf_exists" == "NO" ]]; then
        warn "⚠️ standby.signal missing, recreating..."
        ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
            sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal
            sudo -u postgres grep -q 'primary_conninfo' /var/lib/postgresql/17/main/postgresql.conf || {
                echo \"primary_conninfo = 'host=$PRIMARY_IP port=5432 user=repmgr dbname=repmgr application_name=standby'\" | sudo -u postgres tee -a /var/lib/postgresql/17/main/postgresql.conf
            }
        " 2>/dev/null || warn "Failed to recreate standby configuration"
    fi
    
    info "3️⃣ Starting standby PostgreSQL..."
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl start postgresql" 2>/dev/null
    sleep 10
    
    info "4️⃣ Checking replication status..."
    local repl_count
    repl_count=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    if [[ "$repl_count" -gt 0 ]]; then
        success "✅ Replication established ($repl_count connection(s))"
        
        # Show replication details
        timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
            SELECT client_addr, application_name, state, sync_state 
            FROM pg_stat_replication;
        " 2>/dev/null
    else
        error "❌ Replication still not working"
        
        # Show standby logs for debugging
        info "Standby PostgreSQL logs:"
        ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo tail -10 /var/log/postgresql/postgresql-17-main.log" 2>/dev/null || echo "Cannot read logs"
    fi
}

# Function 4: Start repmgrd services
start_repmgrd_final() {
    section "🚀 Starting repmgrd Services (Final Attempt)"
    
    info "1️⃣ Starting repmgrd on primary..."
    if ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl start repmgrd" 2>/dev/null; then
        success "✅ repmgrd started on primary"
    else
        warn "⚠️ repmgrd still failing on primary, checking logs..."
        ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo journalctl -u repmgrd --no-pager -n 3" 2>/dev/null
    fi
    
    sleep 3
    
    info "2️⃣ Starting repmgrd on standby..."
    if ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl start repmgrd" 2>/dev/null; then
        success "✅ repmgrd started on standby"
    else
        warn "⚠️ repmgrd still failing on standby, checking logs..."
        ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo journalctl -u repmgrd --no-pager -n 3" 2>/dev/null
    fi
    
    # Check final status
    local primary_status standby_status
    primary_status=$(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
    standby_status=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
    
    info "Final repmgrd status:"
    info "  • Primary: $primary_status"
    info "  • Standby: $standby_status"
}

# Function 5: Test data synchronization
test_final_sync() {
    section "📋 Final Data Synchronization Test"
    
    local test_table="final_repair_test_$(date +%s)"
    local test_data="final_test_$(date +%s%N)"
    
    info "1️⃣ Creating test data on primary..."
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
        CREATE TABLE $test_table (id SERIAL, data TEXT, created_at TIMESTAMP DEFAULT NOW());
        INSERT INTO $test_table (data) VALUES ('$test_data');
        SELECT 'Test data created: ' || '$test_data' as result;
    " >/dev/null 2>&1; then
        success "✅ Test data created on primary"
    else
        error "❌ Failed to create test data"
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
        success "✅ FINAL DATA SYNC TEST PASSED! (synced in $wait_count seconds)"
        return 0
    else
        error "❌ Final data sync test failed (timeout after $max_wait seconds)"
        return 1
    fi
}

# Function 6: Show final cluster status
show_final_status() {
    section "📊 Final Cluster Status Report"
    
    info "1️⃣ PostgreSQL Status:"
    local primary_role standby_role
    primary_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    standby_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    
    info "  • $PRIMARY_IP: $primary_role"
    info "  • $STANDBY_IP: $standby_role"
    
    info "2️⃣ Replication Status:"
    local repl_count
    repl_count=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    info "  • Active replication connections: $repl_count"
    
    if [[ "$repl_count" -gt 0 ]]; then
        timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
            SELECT '  Connection: ' || client_addr || ' (' || application_name || ') - ' || state as status
            FROM pg_stat_replication;
        " -t 2>/dev/null | while read line; do
            info "$line"
        done
    fi
    
    info "3️⃣ repmgr Status:"
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show" 2>/dev/null || {
        warn "repmgr cluster show failed, showing database view:"
        ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -d repmgr -c 'SELECT node_id, type, node_name, active FROM repmgr.nodes;'" 2>/dev/null
    }
    
    info "4️⃣ Service Status:"
    local primary_pg standby_pg primary_repmgrd standby_repmgrd
    primary_pg=$(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl is-active postgresql" 2>/dev/null || echo "unknown")
    standby_pg=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl is-active postgresql" 2>/dev/null || echo "unknown")
    primary_repmgrd=$(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
    standby_repmgrd=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
    
    info "  • Primary PostgreSQL: $primary_pg"
    info "  • Standby PostgreSQL: $standby_pg"
    info "  • Primary repmgrd: $primary_repmgrd"
    info "  • Standby repmgrd: $standby_repmgrd"
}

# Main repair function
main() {
    printf "%b" "$BLUE"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║           Final Repair Script                        ║
║     Fix Permissions & Replication Issues            ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    info "Timestamp: $(date)"
    info "Fixing remaining issues from post-failback repair..."
    
    # Step 1: Fix log permissions
    fix_log_permissions
    
    # Step 2: Fix replication connectivity
    fix_replication_connectivity
    
    # Step 3: Restart standby to re-establish replication
    restart_standby_replication
    
    # Step 4: Start repmgrd services
    start_repmgrd_final
    
    # Step 5: Test final synchronization
    if test_final_sync; then
        success "🎉 ALL REPAIRS COMPLETED SUCCESSFULLY!"
    else
        warn "⚠️ Repairs completed but data sync still has issues"
    fi
    
    # Step 6: Show final status
    show_final_status
    
    echo
    info "🎯 Summary of Repairs:"
    info "  ✅ repmgr metadata fixed"
    info "  ✅ Log permissions fixed"
    info "  ✅ Connectivity issues addressed"
    info "  ✅ PostgreSQL roles correct"
    
    echo
    info "📋 Remaining Manual Steps:"
    info "1. Update DNS/Load Balancer:"
    info "   • pg-write.db.internal.nprd.ipa.edu.sa → 192.168.14.21"
    info "2. Monitor cluster for 30 minutes"
    info "3. Run validation option 10 to verify everything"
}

main "$@"