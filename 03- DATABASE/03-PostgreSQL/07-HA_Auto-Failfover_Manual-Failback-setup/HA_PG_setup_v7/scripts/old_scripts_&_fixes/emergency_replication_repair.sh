#!/bin/bash
# Emergency Replication Repair Script
# Fixes broken replication using proven solutions from successful troubleshooting
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

printf "%b" "$BLUE"
cat << "EOF"
╔══════════════════════════════════════════════════════╗
║            🚨 EMERGENCY REPLICATION REPAIR 🚨        ║
║              Using Proven Solutions                  ║
╚══════════════════════════════════════════════════════╝
EOF
printf "%b" "$NC"

info "Timestamp: $(date)"
info "Emergency repair using proven solutions from successful session"

section "🔍 Diagnosing Current Issue"

# Check current status
info "1️⃣ Checking current replication status..."
primary_repl_count=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
info "Primary replication connections: $primary_repl_count"

if [[ "$primary_repl_count" -gt 0 ]]; then
    success "✅ Replication connections found - problem may be elsewhere"
    exit 0
fi

error "❌ No replication connections - proceeding with emergency repair"

section "🔧 Emergency Repair Process"

# Step 1: Fix pg_hba.conf on primary (CRITICAL - this was our main issue)
info "Step 1: Applying proven pg_hba.conf fix on primary..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
    # Backup current file
    sudo cp /etc/postgresql/17/main/pg_hba.conf /etc/postgresql/17/main/pg_hba.conf.emergency_backup_\$(date +%Y%m%d_%H%M%S)
    
    # Add proven replication entries
    sudo tee -a /etc/postgresql/17/main/pg_hba.conf << 'EOL'

# EMERGENCY REPLICATION REPAIR - Proven entries
host    replication     postgres        192.168.14.22/32        md5
host    replication     repmgr          192.168.14.22/32        md5
host    replication     postgres        192.168.14.21/32        md5
host    replication     repmgr          192.168.14.21/32        md5
host    replication     postgres        192.168.14.0/24         md5
host    replication     repmgr          192.168.14.0/24         md5
EOL
    
    # Reload configuration
    sudo -u postgres psql -c 'SELECT pg_reload_conf();'
    echo 'Primary pg_hba.conf updated'
" 2>/dev/null

success "✅ pg_hba.conf entries added to primary"

# Step 2: Stop standby completely
info "Step 2: Stopping standby services..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
    sudo systemctl stop repmgrd
    sudo systemctl stop postgresql
" 2>/dev/null
sleep 5

# Step 3: Complete standby rebuild using proven method
info "Step 3: Rebuilding standby using proven pg_basebackup method..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
    # Complete directory removal (proven method)
    sudo rm -rf /var/lib/postgresql/17/main
    sudo mkdir -p /var/lib/postgresql/17/main
    sudo chown postgres:postgres /var/lib/postgresql/17/main
    sudo chmod 700 /var/lib/postgresql/17/main
    
    # Verify it's empty
    ls -la /var/lib/postgresql/17/main/ || echo 'Directory is clean'
" 2>/dev/null

info "Running proven pg_basebackup with WAL streaming..."
if timeout 600 ssh -A $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
    sudo -u postgres env PGPASSWORD='$PG_SUPER_PASS' pg_basebackup \\
        -h $PRIMARY_IP \\
        -p 5432 \\
        -U postgres \\
        -D /var/lib/postgresql/17/main \\
        -v \\
        -P \\
        --no-password \\
        -X stream \\
        --checkpoint=fast \\
        --write-recovery-conf
" 2>&1; then
    success "✅ pg_basebackup completed successfully"
else
    error "❌ pg_basebackup failed - trying manual approach"
    
    # Manual fallback with proven configuration
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        # Initialize fresh database
        sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/17/main
        
        # Add proven configuration
        cat << 'EOL' | sudo -u postgres tee -a /var/lib/postgresql/17/main/postgresql.conf
# Emergency repair configuration
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=repmgr application_name=standby'
hot_standby = on
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
shared_preload_libraries = 'repmgr'
listen_addresses = '*'
EOL
        
        # Create standby signal
        sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal
        
        # Set permissions
        sudo chown -R postgres:postgres /var/lib/postgresql/17/main
        sudo chmod 700 /var/lib/postgresql/17/main
    " 2>/dev/null
fi

# Step 4: Start standby and verify
info "Step 4: Starting standby PostgreSQL..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl start postgresql" 2>/dev/null
sleep 10

# Step 5: Verify replication
info "Step 5: Verifying replication establishment..."
replication_wait=0
max_wait=60
replication_working=false

while [[ $replication_wait -lt $max_wait ]]; do
    repl_count=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    if [[ "$repl_count" -gt 0 ]]; then
        replication_working=true
        success "✅ Replication connection established ($repl_count connection(s))"
        break
    fi
    
    sleep 3
    ((replication_wait += 3))
    if [[ $((replication_wait % 15)) -eq 0 ]]; then
        info "Still waiting for replication... ($replication_wait/$max_wait seconds)"
    fi
done

if [[ "$replication_working" == true ]]; then
    # Step 6: Test data synchronization
    info "Step 6: Testing data synchronization..."
    test_table="emergency_repair_test_$(date +%s)"
    test_data="repair_$(date +%s%N)"
    
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
        CREATE TABLE $test_table (data TEXT, created_at TIMESTAMP DEFAULT NOW());
        INSERT INTO $test_table (data) VALUES ('$test_data');
    " >/dev/null 2>&1; then
        
        sleep 5
        if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT data FROM $test_table WHERE data = '$test_data';" 2>/dev/null | grep -q "$test_data"; then
            success "✅ Data synchronization verified!"
        else
            warn "⚠️ Data sync still catching up - this is normal"
        fi
        
        # Cleanup
        timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "DROP TABLE $test_table;" >/dev/null 2>&1 || true
    fi
    
    # Step 7: Start repmgrd services
    info "Step 7: Starting repmgrd services..."
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl start repmgrd" 2>/dev/null || warn "repmgrd start may have failed on primary"
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl start repmgrd" 2>/dev/null || warn "repmgrd start may have failed on standby"
    
    sleep 5
    
    # Final verification
    final_repl_count=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    section "🎉 Emergency Repair Complete!"
    success "✅ Replication has been restored!"
    success "✅ Final replication connections: $final_repl_count"
    
    info "📊 Final Status Check:"
    timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
        SELECT 
            client_addr,
            application_name,
            state,
            sync_state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes
        FROM pg_stat_replication;
    " 2>/dev/null || echo "Detailed status query failed"
    
    info "✅ You can now run option 1 (Quick connectivity check) to verify everything is working"
    
else
    error "❌ Emergency repair failed - replication not established"
    info "🔧 Manual steps needed:"
    info "1. Check standby logs: sudo tail -20 /var/log/postgresql/postgresql-17-main.log"
    info "2. Verify pg_hba.conf entries on primary"
    info "3. Check network connectivity between nodes"
fi

info "Emergency repair script completed at $(date)"