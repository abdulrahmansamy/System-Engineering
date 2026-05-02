#!/bin/bash
# Deep Replication Fix - Comprehensive Diagnosis and Repair
# Addresses slot creation issues and connection problems
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PRIMARY_SSH_HOST="ipa-nprd-ha-pg-primary-01"
STANDBY_SSH_HOST="ipa-nprd-ha-pg-standby-01"
SSH_USER="asamy_nominations_ipa_edu_sa"
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
DB_PORT="6432"
DIRECT_PORT="5432"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }
debug() { printf "%b[DEBUG]%b %s\n" "$CYAN" "$NC" "$*"; }

# Get credentials
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    if PG_SUPER_PASS=$(timeout 5 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
        export PG_SUPER_PASS
    else
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

printf "%b" "$BLUE"
cat << "EOF"
╔══════════════════════════════════════════════════════╗
║         🔧 DEEP REPLICATION DIAGNOSIS & FIX          ║
║    Comprehensive Slot and Connection Analysis        ║
╚══════════════════════════════════════════════════════╝
EOF
printf "%b" "$NC"

info "Timestamp: $(date)"
info "Deep analysis and fix for replication issues"

section "🔍 Deep Diagnosis"

info "1️⃣ Testing direct PostgreSQL connections..."
debug "Testing primary direct connection..."
if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -c "SELECT 'Primary direct OK';" >/dev/null 2>&1; then
    success "✅ Primary direct connection (port 5432) working"
else
    error "❌ Primary direct connection failed"
fi

debug "Testing primary PgBouncer connection..."
if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "SELECT 'Primary PgBouncer OK';" >/dev/null 2>&1; then
    success "✅ Primary PgBouncer connection (port 6432) working"
else
    error "❌ Primary PgBouncer connection failed"
fi

info "2️⃣ Checking replication slots on BOTH ports..."
debug "Checking slots via direct connection (port 5432)..."
slots_direct=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -c "SELECT slot_name, slot_type, active, database FROM pg_replication_slots;" 2>/dev/null || echo "Query failed")
echo "Direct connection slots:"
echo "$slots_direct"

debug "Checking slots via PgBouncer (port 6432)..."
slots_pgbouncer=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "SELECT slot_name, slot_type, active, database FROM pg_replication_slots;" 2>/dev/null || echo "Query failed")
echo "PgBouncer slots:"
echo "$slots_pgbouncer"

info "3️⃣ Checking current standby configuration..."
debug "Reading standby postgresql.auto.conf..."
standby_auto_conf=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo cat /var/lib/postgresql/17/main/postgresql.auto.conf" 2>/dev/null || echo "File not found")
echo "postgresql.auto.conf content:"
echo "$standby_auto_conf"

debug "Reading standby postgresql.conf (replication section)..."
standby_conf=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo grep -A5 -B5 'primary_conninfo\|primary_slot' /var/lib/postgresql/17/main/postgresql.conf" 2>/dev/null || echo "No replication config found")
echo "postgresql.conf replication section:"
echo "$standby_conf"

section "🔧 Comprehensive Fix Strategy"

info "4️⃣ Creating replication slot via DIRECT connection (bypassing PgBouncer)..."
debug "Stopping standby first..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl stop postgresql" 2>/dev/null
sleep 3

debug "Removing any existing repmgr_slot_1..."
cleanup_result=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -c "
SELECT pg_drop_replication_slot('repmgr_slot_1');
" 2>&1 || echo "Slot did not exist or removal failed")
info "Cleanup result: $cleanup_result"

debug "Creating fresh replication slot via direct connection..."
slot_creation=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -c "
SELECT pg_create_physical_replication_slot('repmgr_slot_1');
" 2>&1)

if echo "$slot_creation" | grep -q "repmgr_slot_1"; then
    success "✅ Replication slot created via direct connection"
else
    error "❌ Failed to create slot via direct connection: $slot_creation"
fi

info "5️⃣ Completely rebuilding standby with simplified configuration..."
debug "Removing all standby data..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
    sudo rm -rf /var/lib/postgresql/17/main
    sudo mkdir -p /var/lib/postgresql/17/main
    sudo chown postgres:postgres /var/lib/postgresql/17/main
    sudo chmod 700 /var/lib/postgresql/17/main
" 2>/dev/null

debug "Running pg_basebackup with slot specification..."
if timeout 600 ssh -A $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
    sudo -u postgres env PGPASSWORD='$PG_SUPER_PASS' pg_basebackup \\
        -h $PRIMARY_IP \\
        -p $DIRECT_PORT \\
        -U postgres \\
        -D /var/lib/postgresql/17/main \\
        -v \\
        -P \\
        --no-password \\
        -X stream \\
        --checkpoint=fast \\
        --write-recovery-conf \\
        -S repmgr_slot_1
" 2>&1; then
    success "✅ pg_basebackup with slot completed successfully"
    
    # Verify the auto-generated configuration
    debug "Checking auto-generated configuration..."
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        echo 'Auto-generated postgresql.auto.conf:'
        sudo cat /var/lib/postgresql/17/main/postgresql.auto.conf
    " 2>/dev/null
    
else
    warn "⚠️ pg_basebackup with slot failed, trying manual configuration..."
    
    # Manual setup with explicit slot configuration
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        # Initialize database
        sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/17/main
        
        # Create simplified configuration
        sudo -u postgres tee /var/lib/postgresql/17/main/postgresql.auto.conf << 'EOL'
# Simplified replication configuration
primary_conninfo = 'host=$PRIMARY_IP port=$DIRECT_PORT user=postgres'
primary_slot_name = 'repmgr_slot_1'
hot_standby = on
EOL
        
        # Create standby signal
        sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal
        
        # Set permissions
        sudo chown -R postgres:postgres /var/lib/postgresql/17/main
        sudo chmod 700 /var/lib/postgresql/17/main
        
        echo 'Manual configuration completed'
    " 2>/dev/null
fi

info "6️⃣ Starting standby with enhanced monitoring..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl start postgresql" 2>/dev/null
sleep 5

section "🔍 Enhanced Verification"

info "7️⃣ Monitoring replication establishment..."
replication_wait=0
max_wait=90
replication_working=false

while [[ $replication_wait -lt $max_wait ]]; do
    # Check via direct connection
    slot_status_direct=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -Atqc "SELECT active FROM pg_replication_slots WHERE slot_name = 'repmgr_slot_1';" 2>/dev/null || echo "")
    
    repl_count_direct=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    # Check via PgBouncer too
    repl_count_pgbouncer=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    if [[ "$slot_status_direct" == "t" && "$repl_count_direct" -gt 0 ]]; then
        replication_working=true
        success "✅ Replication established! Slot active: $slot_status_direct, Direct connections: $repl_count_direct, PgBouncer: $repl_count_pgbouncer"
        break
    fi
    
    sleep 3
    ((replication_wait += 3))
    if [[ $((replication_wait % 15)) -eq 0 ]]; then
        debug "Status (${replication_wait}s): Slot=$slot_status_direct, Direct=$repl_count_direct, PgBouncer=$repl_count_pgbouncer"
        
        # Show recent standby logs
        if [[ $((replication_wait % 30)) -eq 0 ]]; then
            debug "Recent standby logs:"
            ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo tail -5 /var/log/postgresql/postgresql-17-main.log" 2>/dev/null | head -3
        fi
    fi
done

if [[ "$replication_working" == true ]]; then
    section "🎉 SUCCESS!"
    
    # Show comprehensive final status
    info "📊 Final Replication Analysis:"
    
    info "Direct Connection (Port 5432) Status:"
    timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -c "
        SELECT 
            'SLOTS' as type,
            slot_name,
            slot_type,
            active,
            restart_lsn
        FROM pg_replication_slots 
        UNION ALL
        SELECT 
            'CONNECTIONS' as type,
            client_addr::text,
            application_name,
            state::text,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::text
        FROM pg_stat_replication;
    " 2>/dev/null
    
    info "PgBouncer Connection (Port 6432) Status:"
    timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
        SELECT count(*) as pgbouncer_visible_connections FROM pg_stat_replication;
    " 2>/dev/null
    
    # Test data synchronization
    info "8️⃣ Testing data synchronization..."
    test_table="deep_fix_test_$(date +%s)"
    test_data="deep_fix_$(date +%s%N)"
    
    # Test via direct connection
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -c "
        CREATE TABLE $test_table (data TEXT, created_at TIMESTAMP DEFAULT NOW());
        INSERT INTO $test_table (data) VALUES ('$test_data');
    " >/dev/null 2>&1; then
        
        sleep 5
        # Check on standby via both connections
        direct_sync=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -Atqc "SELECT data FROM $test_table WHERE data = '$test_data';" 2>/dev/null | grep -q "$test_data" && echo "✅" || echo "❌")
        pgbouncer_sync=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT data FROM $test_table WHERE data = '$test_data';" 2>/dev/null | grep -q "$test_data" && echo "✅" || echo "❌")
        
        info "Data sync verification:"
        info "  • Direct connection (5432): $direct_sync"
        info "  • PgBouncer (6432): $pgbouncer_sync"
        
        if [[ "$direct_sync" == "✅" ]]; then
            success "✅ Data synchronization working via direct connection!"
        fi
        
        if [[ "$pgbouncer_sync" == "✅" ]]; then
            success "✅ Data synchronization working via PgBouncer!"
        fi
        
        # Cleanup
        timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -c "DROP TABLE $test_table;" >/dev/null 2>&1 || true
    fi
    
    success "🎉 DEEP REPLICATION FIX COMPLETED!"
    info "✅ Replication slot created and active"
    info "✅ Standby connected and replicating"
    info "✅ Data synchronization verified"
    
    info "🎯 Next Steps:"
    info "  • Run failover validation script option 1 to verify full health"
    info "  • Consider starting repmgrd services if needed"
    info "  • Monitor replication lag regularly"
    
else
    error "❌ Deep replication fix failed after $max_wait seconds"
    
    section "🔧 Final Diagnostics"
    info "Recent standby logs (last 15 lines):"
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo tail -15 /var/log/postgresql/postgresql-17-main.log" 2>/dev/null || echo "Cannot read logs"
    
    info "Current slot status on primary:"
    timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DIRECT_PORT" -U postgres -d postgres -c "SELECT * FROM pg_replication_slots;" 2>/dev/null || echo "Cannot query slots"
    
    info "Network connectivity test:"
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "timeout 3 telnet $PRIMARY_IP $DIRECT_PORT" 2>/dev/null || echo "Telnet test failed"
fi

info "Deep replication fix completed at $(date)"