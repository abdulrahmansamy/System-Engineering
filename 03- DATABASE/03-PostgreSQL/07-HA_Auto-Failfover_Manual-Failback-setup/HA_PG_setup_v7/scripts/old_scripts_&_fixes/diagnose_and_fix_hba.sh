#!/bin/bash
# Check and Fix pg_hba.conf - Manual Approach
# Diagnose and fix replication authentication issues

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
SSH_USER="asamy_nominations_ipa_edu_sa"
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

printf "%b" "$BLUE"
cat << "EOF"
╔══════════════════════════════════════════════════════╗
║           Diagnose pg_hba.conf Issues               ║
║          Manual Fix for Replication Auth            ║
╚══════════════════════════════════════════════════════╝
EOF
printf "%b" "$NC"

info "Timestamp: $(date)"

section "🔍 Diagnosing pg_hba.conf Issues"

# Step 1: Show current full pg_hba.conf
info "1️⃣ Current pg_hba.conf content on primary:"
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo cat /etc/postgresql/17/main/pg_hba.conf"

echo
section "🔧 Manual pg_hba.conf Fix"

# Step 2: Add specific entries manually
info "2️⃣ Adding specific replication entries manually..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
    # Create backup
    sudo cp /etc/postgresql/17/main/pg_hba.conf /etc/postgresql/17/main/pg_hba.conf.backup_manual_\$(date +%Y%m%d_%H%M%S)
    
    # Create a clean version with our entries
    sudo tee -a /etc/postgresql/17/main/pg_hba.conf << 'EOL'

# Added for replication fix - Manual entries
host    replication     postgres        192.168.14.22/32        md5
host    replication     postgres        192.168.14.21/32        md5  
host    replication     postgres        127.0.0.1/32            md5
host    replication     postgres        192.168.14.0/24         md5
EOL
    
    echo 'Manual replication entries added'
"

# Step 3: Show updated content
info "3️⃣ Updated pg_hba.conf entries (last 10 lines):"
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo tail -10 /etc/postgresql/17/main/pg_hba.conf"

# Step 4: Reload configuration
info "4️⃣ Reloading PostgreSQL configuration..."
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c 'SELECT pg_reload_conf();'"

# Step 5: Test replication connection
info "5️⃣ Testing replication connection with postgres user..."

# Get credentials
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    if PG_SUPER_PASS=$(timeout 5 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
        export PG_SUPER_PASS
    else
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

# Test from jump host (simulating standby connection)
info "Testing from current host to primary..."
if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p 5432 -U postgres -c "SELECT 1;" postgres 2>/dev/null; then
    success "✅ Basic postgres user connection works"
else
    error "❌ Basic postgres user connection failed"
fi

# Step 6: Test actual replication protocol
info "6️⃣ Testing replication protocol..."
if command -v pg_receivewal >/dev/null 2>&1; then
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" pg_receivewal -h "$PRIMARY_IP" -p 5432 -U postgres -D /tmp/test_wal_local --synchronous --no-loop >/dev/null 2>&1; then
        success "✅ Replication protocol test successful"
        rm -rf /tmp/test_wal_local 2>/dev/null || true
    else
        warn "⚠️ Replication protocol test failed from this host"
    fi
else
    info "pg_receivewal not available on this host - will test from standby"
fi

section "🎯 Manual Fix Complete!"

success "✅ Manual pg_hba.conf entries added"
success "✅ Configuration reloaded"

info "📋 Next Steps:"
info "1. Upload and run the updated complete_replication_fix.sh"
info "2. The pg_basebackup should now work properly"

info "📊 Manual Entries Added:"
info "• host replication postgres 192.168.14.22/32 md5"
info "• host replication postgres 192.168.14.21/32 md5"
info "• host replication postgres 127.0.0.1/32 md5"
info "• host replication postgres 192.168.14.0/24 md5"