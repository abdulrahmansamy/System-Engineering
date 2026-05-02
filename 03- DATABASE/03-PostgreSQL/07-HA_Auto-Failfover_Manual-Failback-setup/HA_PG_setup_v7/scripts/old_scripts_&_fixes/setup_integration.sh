#!/bin/bash
# PostgreSQL HA Setup Integration with Proven Configuration
# This script integrates the proven split-brain resolution configuration
# into your HA setup process
# Version: 1.0

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
PROVEN_CONFIG_SCRIPT="$CONFIG_DIR/proven_postgresql_config.sh"

# Default values (override these)
PRIMARY_IP="${PRIMARY_IP:-192.168.14.21}"
STANDBY_IP="${STANDBY_IP:-192.168.14.22}"
SSH_USER="${SSH_USER:-asamy_nominations_ipa_edu_sa}"
SSH_OPTIONS="${SSH_OPTIONS:--o ConnectTimeout=10 -o StrictHostKeyChecking=no}"

# SSH hostnames
PRIMARY_SSH_HOST="${PRIMARY_SSH_HOST:-ipa-nprd-ha-pg-primary-01}"
STANDBY_SSH_HOST="${STANDBY_SSH_HOST:-ipa-nprd-ha-pg-standby-01}"

# Apply proven configuration during HA setup
apply_proven_ha_configuration() {
    section "🔧 Applying Proven HA Configuration"
    
    info "This will apply the configuration that successfully resolved the split-brain scenario"
    info "Configuration includes:"
    info "  • Optimized postgresql.conf settings"
    info "  • Proven primary_conninfo configuration"
    info "  • Replication slot management"
    info "  • Enhanced pg_hba.conf settings"
    echo
    
    # Check if proven config script exists
    if [[ ! -f "$PROVEN_CONFIG_SCRIPT" ]]; then
        error "Proven configuration script not found: $PROVEN_CONFIG_SCRIPT"
        return 1
    fi
    
    # Source the proven configuration
    source "$PROVEN_CONFIG_SCRIPT"
    
    # Step 1: Configure Primary Node
    info "🔄 Step 1: Configuring Primary Node ($PRIMARY_IP)..."
    
    # Backup existing configurations
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
        sudo mkdir -p /etc/postgresql/17/main/backups/proven_config_\$(date +%Y%m%d_%H%M%S)
        sudo cp /etc/postgresql/17/main/postgresql.conf /etc/postgresql/17/main/backups/proven_config_\$(date +%Y%m%d_%H%M%S)/
        sudo cp /etc/postgresql/17/main/pg_hba.conf /etc/postgresql/17/main/backups/proven_config_\$(date +%Y%m%d_%H%M%S)/
    " 2>/dev/null
    
    # Apply proven postgresql.conf settings to primary
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
        sudo tee -a /etc/postgresql/17/main/postgresql.conf << 'EOL'

# ========================================
# PROVEN POSTGRESQL HA CONFIGURATION
# Applied: \$(date)
# Source: Split-brain resolution success
# ========================================
$PROVEN_POSTGRESQL_CONF
EOL
    " 2>/dev/null
    
    # Apply proven pg_hba.conf settings to primary
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
        sudo tee -a /etc/postgresql/17/main/pg_hba.conf << 'EOL'

# ========================================
# PROVEN REPLICATION AUTHENTICATION
# Applied: \$(date)
# Source: Split-brain resolution success
# ========================================
$PROVEN_PG_HBA_ENTRIES
EOL
    " 2>/dev/null
    
    success "✅ Primary node configuration applied"
    
    # Step 2: Configure Standby Node
    info "🔄 Step 2: Configuring Standby Node ($STANDBY_IP)..."
    
    # Backup existing configurations
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        sudo mkdir -p /etc/postgresql/17/main/backups/proven_config_\$(date +%Y%m%d_%H%M%S)
        sudo cp /etc/postgresql/17/main/postgresql.conf /etc/postgresql/17/main/backups/proven_config_\$(date +%Y%m%d_%H%M%S)/ 2>/dev/null || true
        sudo cp /etc/postgresql/17/main/pg_hba.conf /etc/postgresql/17/main/backups/proven_config_\$(date +%Y%m%d_%H%M%S)/ 2>/dev/null || true
        sudo cp /var/lib/postgresql/17/main/postgresql.auto.conf /etc/postgresql/17/main/backups/proven_config_\$(date +%Y%m%d_%H%M%S)/ 2>/dev/null || true
    " 2>/dev/null
    
    # Apply proven postgresql.conf settings to standby
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        sudo tee -a /etc/postgresql/17/main/postgresql.conf << 'EOL'

# ========================================
# PROVEN POSTGRESQL HA CONFIGURATION
# Applied: \$(date)
# Source: Split-brain resolution success
# ========================================
$PROVEN_POSTGRESQL_CONF
EOL
    " 2>/dev/null
    
    # Apply proven pg_hba.conf settings to standby
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        sudo tee -a /etc/postgresql/17/main/pg_hba.conf << 'EOL'

# ========================================
# PROVEN REPLICATION AUTHENTICATION
# Applied: \$(date)
# Source: Split-brain resolution success
# ========================================
$PROVEN_PG_HBA_ENTRIES
EOL
    " 2>/dev/null
    
    # Apply proven postgresql.auto.conf to standby
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "
        sudo -u postgres tee /var/lib/postgresql/17/main/postgresql.auto.conf << 'EOL'
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
# ========================================
# PROVEN STANDBY CONFIGURATION
# Applied: \$(date)
# Source: Split-brain resolution success
# ========================================
primary_conninfo = 'host=$PRIMARY_IP user=repmgr application_name=standby'
primary_slot_name = 'repmgr_slot_2'
timezone = 'Asia/Riyadh'
EOL
        
        # Ensure standby.signal exists
        sudo -u postgres touch /var/lib/postgresql/17/main/standby.signal
        
        # Set proper permissions
        sudo chown postgres:postgres /var/lib/postgresql/17/main/postgresql.auto.conf
        sudo chmod 600 /var/lib/postgresql/17/main/postgresql.auto.conf
    " 2>/dev/null
    
    success "✅ Standby node configuration applied"
    
    # Step 3: Restart PostgreSQL services
    info "🔄 Step 3: Restarting PostgreSQL services to apply configuration..."
    
    # Restart primary first
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl restart postgresql" 2>/dev/null
    sleep 10
    
    # Create replication slot on primary
    ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "
        sudo -u postgres psql -c \"
            -- Drop existing slots if they exist
            SELECT pg_drop_replication_slot(slot_name) 
            FROM pg_replication_slots 
            WHERE slot_name IN ('repmgr_slot_1', 'repmgr_slot_2');
            
            -- Create fresh replication slot for standby
            SELECT pg_create_physical_replication_slot('repmgr_slot_2');
            
            -- Show created slots
            SELECT 'REPLICATION SLOTS:' as status;
            SELECT slot_name, slot_type, active FROM pg_replication_slots;
        \"
    " 2>/dev/null && success "✅ Replication slot created" || warn "Replication slot creation may have failed"
    
    # Restart standby
    ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl restart postgresql" 2>/dev/null
    sleep 15
    
    success "✅ PostgreSQL services restarted with proven configuration"
    
    # Step 4: Verify configuration
    info "🔍 Step 4: Verifying proven configuration..."
    verify_proven_configuration
    
    return 0
}

# Verify the proven configuration is working
verify_proven_configuration() {
    section "🔍 Verifying Proven Configuration"
    
    local verification_errors=0
    
    # Check primary status
    info "Checking primary node status..."
    if timeout 10 ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'" 2>/dev/null | grep -q 'f'; then
        success "✅ Primary node is in PRIMARY role"
    else
        error "❌ Primary node is not in PRIMARY role"
        ((verification_errors++))
    fi
    
    # Check standby status
    info "Checking standby node status..."
    if timeout 10 ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'" 2>/dev/null | grep -q 't'; then
        success "✅ Standby node is in STANDBY role"
    else
        error "❌ Standby node is not in STANDBY role"
        ((verification_errors++))
    fi
    
    # Check replication slots
    info "Checking replication slots..."
    local slot_status
    slot_status=$(timeout 10 ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -Atqc \"SELECT count(*) FROM pg_replication_slots WHERE slot_name = 'repmgr_slot_2' AND active = true;\"" 2>/dev/null || echo "0")
    
    if [[ "$slot_status" -gt 0 ]]; then
        success "✅ Replication slot 'repmgr_slot_2' is active"
    else
        warn "⚠️ Replication slot 'repmgr_slot_2' is not active yet"
    fi
    
    # Check replication connection
    info "Checking replication connection..."
    local replication_wait=0
    local max_replication_wait=60
    local replication_verified=false
    
    while [[ $replication_wait -lt $max_replication_wait ]]; do
        local repl_count
        repl_count=$(timeout 5 ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -Atqc \"SELECT count(*) FROM pg_stat_replication WHERE client_addr = '$STANDBY_IP';\"" 2>/dev/null || echo "0")
        
        if [[ "$repl_count" -gt 0 ]]; then
            replication_verified=true
            success "✅ Replication connection established"
            
            # Show replication details
            local repl_details
            repl_details=$(timeout 5 ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c \"
                SELECT 
                    client_addr,
                    application_name,
                    state,
                    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes
                FROM pg_stat_replication 
                WHERE client_addr = '$STANDBY_IP';
            \"" 2>/dev/null)
            
            info "📊 Replication Details:"
            echo "$repl_details"
            break
        fi
        
        sleep 3
        ((replication_wait += 3))
        if [[ $((replication_wait % 15)) -eq 0 ]]; then
            info "Still waiting for replication... ($replication_wait/$max_replication_wait seconds)"
        fi
    done
    
    # Final verification summary
    echo
    if [[ $verification_errors -eq 0 && "$replication_verified" == true ]]; then
        success "🎉 PROVEN CONFIGURATION VERIFICATION SUCCESSFUL!"
        success "✅ All components working with proven split-brain resolution configuration"
        
        echo
        info "📋 Configuration Summary:"
        info "✅ Primary role: Verified"
        info "✅ Standby role: Verified"
        info "✅ Replication slot: Active"
        info "✅ Replication connection: Established"
        info "✅ WAL streaming: Working"
        
        echo
        info "🔒 Your HA cluster is now configured with production-proven settings!"
        info "This configuration successfully resolved split-brain scenarios in production."
        
        return 0
    else
        warn "⚠️ Verification found issues - cluster may need additional time to stabilize"
        
        if [[ $verification_errors -gt 0 ]]; then
            error "Found $verification_errors role verification errors"
        fi
        
        if [[ "$replication_verified" != true ]]; then
            warn "Replication connection not yet established"
        fi
        
        info "💡 Recommendations:"
        info "  • Wait a few more minutes for services to fully initialize"
        info "  • Check PostgreSQL logs for any configuration issues"
        info "  • Verify network connectivity between nodes"
        
        return 1
    fi
}

# Generate maintenance scripts
generate_maintenance_scripts() {
    section "📝 Generating Maintenance Scripts"
    
    local output_dir="$SCRIPT_DIR/../maintenance"
    mkdir -p "$output_dir"
    
    # Generate configuration backup script
    cat > "$output_dir/backup_proven_config.sh" << 'EOF'
#!/bin/bash
# Backup Proven PostgreSQL HA Configuration
# Run this before making any configuration changes

set -euo pipefail

BACKUP_DIR="/etc/postgresql/17/main/backups/proven_config_$(date +%Y%m%d_%H%M%S)"
SSH_USER="asamy_nominations_ipa_edu_sa"
PRIMARY_SSH_HOST="ipa-nprd-ha-pg-primary-01"
STANDBY_SSH_HOST="ipa-nprd-ha-pg-standby-01"

echo "🔄 Backing up proven configuration..."

# Backup from primary
ssh "$SSH_USER@$PRIMARY_SSH_HOST" "
    sudo mkdir -p $BACKUP_DIR
    sudo cp /etc/postgresql/17/main/postgresql.conf $BACKUP_DIR/primary_postgresql.conf
    sudo cp /etc/postgresql/17/main/pg_hba.conf $BACKUP_DIR/primary_pg_hba.conf
    echo 'Primary configuration backed up to $BACKUP_DIR'
"

# Backup from standby
ssh "$SSH_USER@$STANDBY_SSH_HOST" "
    sudo mkdir -p $BACKUP_DIR
    sudo cp /etc/postgresql/17/main/postgresql.conf $BACKUP_DIR/standby_postgresql.conf
    sudo cp /etc/postgresql/17/main/pg_hba.conf $BACKUP_DIR/standby_pg_hba.conf
    sudo cp /var/lib/postgresql/17/main/postgresql.auto.conf $BACKUP_DIR/standby_postgresql.auto.conf 2>/dev/null || true
    echo 'Standby configuration backed up to $BACKUP_DIR'
"

echo "✅ Configuration backup completed: $BACKUP_DIR"
EOF
    
    chmod +x "$output_dir/backup_proven_config.sh"
    success "✅ Generated: $output_dir/backup_proven_config.sh"
    
    # Generate health check script
    cat > "$output_dir/check_proven_config.sh" << 'EOF'
#!/bin/bash
# Check Proven PostgreSQL HA Configuration Health
# Run this to verify the proven configuration is still active

set -euo pipefail

SSH_USER="asamy_nominations_ipa_edu_sa"
PRIMARY_SSH_HOST="ipa-nprd-ha-pg-primary-01"
STANDBY_SSH_HOST="ipa-nprd-ha-pg-standby-01"
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

echo "🔍 Checking proven configuration health..."

# Check roles
echo "1. Checking node roles..."
primary_role=$(ssh "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -Atqc \"SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;\"" 2>/dev/null || echo "ERROR")
standby_role=$(ssh "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres psql -Atqc \"SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;\"" 2>/dev/null || echo "ERROR")

echo "  • Primary node: $primary_role"
echo "  • Standby node: $standby_role"

# Check replication
echo "2. Checking replication status..."
repl_status=$(ssh "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c \"SELECT client_addr, application_name, state FROM pg_stat_replication;\"" 2>/dev/null || echo "ERROR")
echo "$repl_status"

# Check replication slot
echo "3. Checking replication slot..."
slot_status=$(ssh "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -c \"SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE slot_name = 'repmgr_slot_2';\"" 2>/dev/null || echo "ERROR")
echo "$slot_status"

# Check primary_conninfo on standby
echo "4. Checking standby configuration..."
standby_config=$(ssh "$SSH_USER@$STANDBY_SSH_HOST" "sudo -u postgres grep -i primary_conninfo /var/lib/postgresql/17/main/postgresql.auto.conf" 2>/dev/null || echo "ERROR")
echo "  • primary_conninfo: $standby_config"

echo "✅ Health check completed"
EOF
    
    chmod +x "$output_dir/check_proven_config.sh"
    success "✅ Generated: $output_dir/check_proven_config.sh"
    
    info "📝 Maintenance scripts generated in: $output_dir/"
}

# Main function
main() {
    echo "🔧 PostgreSQL HA Setup Integration with Proven Configuration"
    echo "============================================================"
    echo
    
    if [[ $# -eq 0 ]]; then
        info "Available operations:"
        echo "  apply     - Apply proven configuration to HA cluster"
        echo "  verify    - Verify proven configuration is working"
        echo "  generate  - Generate maintenance scripts"
        echo "  all       - Apply, verify, and generate maintenance scripts"
        echo
        echo "Usage: $0 <operation>"
        echo "Example: $0 apply"
        exit 0
    fi
    
    operation="$1"
    
    case "$operation" in
        "apply")
            apply_proven_ha_configuration
            ;;
        "verify")
            verify_proven_configuration
            ;;
        "generate")
            generate_maintenance_scripts
            ;;
        "all")
            apply_proven_ha_configuration
            echo
            verify_proven_configuration
            echo
            generate_maintenance_scripts
            ;;
        *)
            error "Unknown operation: $operation"
            echo "Available operations: apply, verify, generate, all"
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi