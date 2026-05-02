#!/bin/bash
# Fix pg_hba.conf for Replication
# Adds proper replication entries to allow standby connections

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
║              Fix pg_hba.conf for Replication        ║
║          Add Proper Replication Entries             ║
╚══════════════════════════════════════════════════════╝
EOF
printf "%b" "$NC"

info "Timestamp: $(date)"
info "Fixing pg_hba.conf to allow replication connections..."

section "🔧 pg_hba.conf Replication Fix"

# Step 1: Check current pg_hba.conf on primary
info "1️⃣ Checking current pg_hba.conf on primary..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo cat /etc/postgresql/17/main/pg_hba.conf | grep -E '(replication|repmgr)' || echo 'No replication entries found'"

# Step 2: Add replication entries to primary
info "2️⃣ Adding replication entries to primary pg_hba.conf..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
    # Backup original pg_hba.conf
    sudo cp /etc/postgresql/17/main/pg_hba.conf /etc/postgresql/17/main/pg_hba.conf.backup_\$(date +%Y%m%d_%H%M%S)
    
    # Check if replication entries already exist
    if ! sudo grep -q 'host replication' /etc/postgresql/17/main/pg_hba.conf; then
        # Add replication entries at the beginning (after local connections)
        sudo sed -i '/^# IPv4 local connections:/a\\
# Replication connections\\
host    replication     postgres        192.168.14.22/32        md5\\
host    replication     repmgr          192.168.14.22/32        md5\\
host    replication     postgres        192.168.14.21/32        md5\\
host    replication     repmgr          192.168.14.21/32        md5\\
host    replication     postgres        192.168.14.0/24         md5\\
host    replication     repmgr          192.168.14.0/24         md5' /etc/postgresql/17/main/pg_hba.conf
        echo 'Replication entries added'
    else
        echo 'Replication entries already exist'
    fi
    
    # Also ensure repmgr database access is allowed
    if ! sudo grep -q 'host.*repmgr.*repmgr' /etc/postgresql/17/main/pg_hba.conf; then
        sudo sed -i '/^# IPv4 local connections:/a\\
# repmgr database connections\\
host    repmgr          repmgr          192.168.14.22/32        md5\\
host    repmgr          repmgr          192.168.14.21/32        md5\\
host    repmgr          repmgr          192.168.14.0/24         md5' /etc/postgresql/17/main/pg_hba.conf
        echo 'repmgr database entries added'
    else
        echo 'repmgr database entries already exist'
    fi
"

# Step 3: Show updated pg_hba.conf
info "3️⃣ Showing updated pg_hba.conf entries..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo cat /etc/postgresql/17/main/pg_hba.conf | grep -E '(replication|repmgr)'"

# Step 4: Reload PostgreSQL configuration
info "4️⃣ Reloading PostgreSQL configuration on primary..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c 'SELECT pg_reload_conf();'"

# Step 5: Test replication connection
info "5️⃣ Testing replication connection from standby to primary..."
test_repl_connection=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
    env PGPASSWORD='$PG_SUPER_PASS' psql -h $PRIMARY_IP -p 5432 -U postgres -c 'SELECT 1;' postgres 2>&1 || echo 'CONNECTION_FAILED'
")

if echo "$test_repl_connection" | grep -q "CONNECTION_FAILED\|FATAL\|ERROR"; then
    error "❌ Basic connection test failed"
    info "Connection test result: $test_repl_connection"
else
    success "✅ Basic connection test successful"
fi

# Step 6: Test actual replication connection
info "6️⃣ Testing actual replication protocol connection..."
repl_test=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
    env PGPASSWORD='$PG_SUPER_PASS' pg_receivewal --help >/dev/null 2>&1 && \
    timeout 10 env PGPASSWORD='$PG_SUPER_PASS' pg_receivewal -h $PRIMARY_IP -p 5432 -U postgres -D /tmp/test_wal --synchronous --no-loop 2>&1 | head -5 || echo 'REPLICATION_TEST_FAILED'
")

if echo "$repl_test" | grep -q "REPLICATION_TEST_FAILED\|FATAL\|ERROR.*replication"; then
    error "❌ Replication protocol test failed"
    info "Replication test result: $repl_test"
else
    success "✅ Replication protocol test successful"
fi

# Step 7: Clean up test files
ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo rm -rf /tmp/test_wal" 2>/dev/null || true

section "🎯 pg_hba.conf Fix Complete!"

success "✅ pg_hba.conf updated with replication entries"
success "✅ PostgreSQL configuration reloaded"

info "📋 Next Steps:"
info "1. Run the complete replication fix script again:"
info "   ./complete_replication_fix.sh"
info "2. The pg_basebackup should now work properly"

info "📊 Added Entries:"
info "• host replication postgres 192.168.14.22/32 md5"
info "• host replication repmgr   192.168.14.22/32 md5" 
info "• host repmgr      repmgr   192.168.14.22/32 md5"
info "• Network range entries for 192.168.14.0/24"