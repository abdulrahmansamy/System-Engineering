#!/bin/bash
# Debug Replication Connection Issue
# Investigate where standby is actually trying to connect

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
║        Debug Replication Connection Issue            ║
║          Where is standby connecting?                ║
╚══════════════════════════════════════════════════════╝
EOF
printf "%b" "$NC"

section "🔍 Investigating Connection Issue"

info "1️⃣ Checking replication slots on PRIMARY (192.168.14.21)..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c \"SELECT slot_name, active, restart_lsn FROM pg_replication_slots;\"" 2>/dev/null

info "2️⃣ Checking replication slots on STANDBY (192.168.14.22) - just in case..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -c \"SELECT slot_name, active, restart_lsn FROM pg_replication_slots;\"" 2>/dev/null

section "📋 Standby Configuration Analysis"

info "3️⃣ Checking standby's primary_conninfo configuration..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres grep -n 'primary_conninfo\|primary_slot_name' /var/lib/postgresql/17/main/postgresql.conf" 2>/dev/null || warn "Cannot read postgresql.conf"

info "4️⃣ Checking standby's recovery configuration..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
echo 'Recovery signal file:'
sudo -u postgres ls -la /var/lib/postgresql/17/main/standby.signal 2>/dev/null || echo 'standby.signal does not exist'

echo 'PostgreSQL recovery status:'
sudo -u postgres psql -c \"SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();\""

section "🌐 Network Connectivity Test"

info "5️⃣ Testing direct connection from standby to primary repmgr database..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -h $PRIMARY_IP -p 5432 -U repmgr -d repmgr -c \"SELECT current_database(), current_setting('server_version'), pg_is_in_recovery();\"" 2>/dev/null || warn "Direct repmgr connection failed"

info "6️⃣ Testing replication slot query from standby to primary..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -h $PRIMARY_IP -p 5432 -U repmgr -d repmgr -c \"SELECT slot_name FROM pg_replication_slots WHERE slot_name = 'repmgr_slot_2';\"" 2>/dev/null || warn "Replication slot query failed"

section "🔧 Manual Replication Setup"

info "7️⃣ Let's try to fix this by recreating the standby configuration..."

# Stop standby
info "Stopping standby PostgreSQL..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl stop postgresql" 2>/dev/null
sleep 3

# Clear and recreate configuration
info "8️⃣ Recreating standby configuration from scratch..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
# Remove old recovery settings
sudo -u postgres cp /var/lib/postgresql/17/main/postgresql.conf /var/lib/postgresql/17/main/postgresql.conf.backup
sudo -u postgres grep -v 'primary_conninfo\|primary_slot_name\|restore_command\|archive_cleanup_command' /var/lib/postgresql/17/main/postgresql.conf > /tmp/pg_clean.conf
sudo -u postgres mv /tmp/pg_clean.conf /var/lib/postgresql/17/main/postgresql.conf

# Add correct recovery configuration
cat << 'EOL' | sudo -u postgres tee -a /var/lib/postgresql/17/main/postgresql.conf
# Replication configuration
primary_conninfo = 'host=192.168.14.21 port=5432 user=repmgr dbname=repmgr application_name=standby connect_timeout=10'
primary_slot_name = 'repmgr_slot_2'
promote_trigger_file = '/tmp/postgresql.trigger'
EOL

# Ensure standby.signal exists
sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal

echo 'New configuration added:'
sudo -u postgres tail -5 /var/lib/postgresql/17/main/postgresql.conf
" 2>/dev/null || warn "Configuration update failed"

# Start standby
info "9️⃣ Starting standby PostgreSQL with new configuration..."
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl start postgresql" 2>/dev/null
sleep 10

section "✅ Testing Results"

info "🔍 Checking replication slot status on primary..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c \"SELECT slot_name, active, restart_lsn FROM pg_replication_slots;\"" 2>/dev/null

info "🔍 Checking replication connections..."
repl_count=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")

if [[ "$repl_count" -gt 0 ]]; then
    success "🎉 REPLICATION WORKING! ($repl_count connection(s))"
    
    # Show details
    timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
        SELECT 
            client_addr,
            application_name,
            state,
            sync_state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes
        FROM pg_stat_replication;
    " 2>/dev/null
    
    # Test data sync
    info "Testing data synchronization..."
    test_table="debug_test_$(date +%s)"
    test_data="debug_$(date +%s%N)"
    
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "
        CREATE TABLE $test_table (data TEXT);
        INSERT INTO $test_table VALUES ('$test_data');
    " >/dev/null 2>&1; then
        sleep 5
        if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT data FROM $test_table WHERE data = '$test_data';" 2>/dev/null | grep -q "$test_data"; then
            success "🎉 DATA SYNC WORKING!"
        else
            warn "⚠️ Replication connection exists but data not syncing yet"
        fi
        # Cleanup
        timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "DROP TABLE $test_table;" >/dev/null 2>&1 || true
    fi
else
    error "❌ Still no replication connections"
    
    # Show last standby logs
    info "Latest standby logs:"
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo tail -10 /var/log/postgresql/postgresql-17-main.log" 2>/dev/null || echo "Cannot read logs"
fi

section "📊 Final Status"

info "Replication connections: $repl_count"
info "Primary PostgreSQL: $(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl is-active postgresql" 2>/dev/null)"
info "Standby PostgreSQL: $(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl is-active postgresql" 2>/dev/null)"

if [[ "$repl_count" -gt 0 ]]; then
    success "🎉 PROBLEM SOLVED!"
    info "Now you can run the comprehensive health check (option 10) in the validation script"
else
    warn "⚠️ Issue persists - may need deeper investigation"
fi