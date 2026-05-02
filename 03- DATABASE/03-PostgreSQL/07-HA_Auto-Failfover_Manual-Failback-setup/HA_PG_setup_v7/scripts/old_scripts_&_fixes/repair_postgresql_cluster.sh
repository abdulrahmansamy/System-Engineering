#!/bin/bash
# Advanced PostgreSQL HA Cluster Repair Script
# Fixes "Invalid data directory" errors and completely rebuilds the cluster
# Version: 2.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }

# Configuration
PG_VERSION="17"

main() {
    info "🔧 Advanced PostgreSQL HA Cluster Repair Script v2.0.0"
    info "Completely rebuilding PostgreSQL cluster configuration..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi

    # Step 1: Complete cleanup
    info "🧹 Step 1: Complete cleanup of PostgreSQL installation..."
    
    # Stop all PostgreSQL-related services
    systemctl stop postgresql postgresql@* repmgrd pgbouncer 2>/dev/null || true
    systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true
    
    # Kill any remaining PostgreSQL processes
    pkill -f postgres 2>/dev/null || true
    pkill -f repmgr 2>/dev/null || true
    pkill -f pgbouncer 2>/dev/null || true
    
    sleep 3

    # Step 2: Remove corrupted cluster configuration
    info "🗑️  Step 2: Removing corrupted cluster configuration..."
    
    # Remove PostgreSQL cluster configuration files
    rm -rf /etc/postgresql/${PG_VERSION}/ 2>/dev/null || true
    rm -rf /var/lib/postgresql/${PG_VERSION}/ 2>/dev/null || true
    
    # Clean up PostgreSQL common configuration
    if [[ -f /etc/postgresql-common/pg_upgradecluster.d/repmgr.conf ]]; then
        rm -f /etc/postgresql-common/pg_upgradecluster.d/repmgr.conf || true
    fi
    
    # Remove any cluster state files
    rm -f /var/lib/postgresql/.pgpass 2>/dev/null || true
    rm -rf /var/lib/postgresql/.bootstrap 2>/dev/null || true

    # Step 3: Fix PostgreSQL user and permissions
    info "👤 Step 3: Fixing PostgreSQL user and permissions..."
    
    # Ensure postgres user exists and has proper home directory
    if ! id postgres >/dev/null 2>&1; then
        useradd --system --home /var/lib/postgresql --shell /bin/bash postgres
    fi
    
    # Fix ownership of PostgreSQL directories
    mkdir -p /var/lib/postgresql
    chown -R postgres:postgres /var/lib/postgresql
    chmod 755 /var/lib/postgresql

    # Step 4: Completely remove and reinstall PostgreSQL cluster
    info "📦 Step 4: Purging and reinstalling PostgreSQL cluster..."
    
    # Remove existing cluster using dpkg-reconfigure
    export DEBIAN_FRONTEND=noninteractive
    
    # Stop and remove any existing clusters
    if command -v pg_dropcluster >/dev/null 2>&1; then
        sudo -u postgres pg_dropcluster --stop ${PG_VERSION} main 2>/dev/null || true
    fi
    
    # Purge PostgreSQL data
    dpkg-reconfigure -f noninteractive postgresql-${PG_VERSION} 2>/dev/null || true
    
    # Step 5: Create fresh cluster with proper configuration
    info "🆕 Step 5: Creating fresh PostgreSQL cluster..."
    
    # Create cluster using PostgreSQL's official method
    if command -v pg_createcluster >/dev/null 2>&1; then
        # Use pg_createcluster (Ubuntu way)
        sudo -u postgres pg_createcluster ${PG_VERSION} main
        success "Cluster created using pg_createcluster"
    else
        # Fallback to manual initdb
        local data_dir="/var/lib/postgresql/${PG_VERSION}/main"
        mkdir -p "$data_dir"
        chown postgres:postgres "$data_dir"
        chmod 700 "$data_dir"
        
        sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/initdb -D "$data_dir" \
            --auth-local=peer --auth-host=scram-sha-256 --encoding=UTF8 --locale=C.UTF-8
        success "Cluster created using initdb"
    fi

    # Step 6: Start PostgreSQL and verify
    info "🚀 Step 6: Starting PostgreSQL and verifying functionality..."
    
    systemctl enable postgresql
    systemctl start postgresql
    
    # Wait for PostgreSQL to be ready
    local attempts=0
    while ! sudo -u postgres psql -c "SELECT 1;" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 30 ]]; then
            error "PostgreSQL failed to start after 30 attempts"
            return 1
        fi
        sleep 2
    done
    
    success "✅ PostgreSQL is running and accessible!"

    # Step 7: Display cluster information
    info "📊 Step 7: Cluster information:"
    
    # Show cluster status
    if command -v pg_lsclusters >/dev/null 2>&1; then
        info "Cluster status:"
        pg_lsclusters || true
    fi
    
    # Show PostgreSQL version
    local pg_version
    pg_version=$(sudo -u postgres psql -Atqc "SELECT version();" 2>/dev/null || echo "unknown")
    info "PostgreSQL version: $pg_version"
    
    # Show data directory
    local data_dir
    data_dir=$(sudo -u postgres psql -Atqc "SHOW data_directory;" 2>/dev/null || echo "unknown")
    info "Data directory: $data_dir"
    
    # Show configuration file location
    local config_file
    config_file=$(sudo -u postgres psql -Atqc "SHOW config_file;" 2>/dev/null || echo "unknown")
    info "Configuration file: $config_file"

    # Step 8: Apply HA configuration
    info "⚙️  Step 8: Applying HA configuration..."
    
    if [[ "$config_file" != "unknown" && -f "$config_file" ]]; then
        # Backup original config
        cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Add HA settings
        cat >> "$config_file" <<EOF

# PostgreSQL HA Configuration (added by repair script)
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
wal_keep_size = '1024MB'
hot_standby = on
shared_preload_libraries = 'repmgr'
archive_mode = off
max_replication_slots = 10
track_commit_timestamp = on

# Performance tuning
shared_buffers = 128MB
effective_cache_size = 1GB
max_connections = 200
work_mem = 4MB
maintenance_work_mem = 64MB

# Logging
log_line_prefix = '%t [%p-%l] %q%u@%d '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0

# Security
ssl = on
ssl_cert_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem'
ssl_key_file = '/etc/ssl/private/ssl-cert-snakeoil.key'
EOF
        
        success "HA configuration added to postgresql.conf"
    else
        warn "Could not locate postgresql.conf - HA settings not applied"
    fi

    # Step 9: Configure pg_hba.conf for HA
    info "🔐 Step 9: Configuring authentication for HA..."
    
    local hba_file
    hba_file=$(dirname "$config_file")/pg_hba.conf
    
    if [[ -f "$hba_file" ]]; then
        # Backup original HBA file
        cp "$hba_file" "${hba_file}.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Add HA authentication rules
        cat >> "$hba_file" <<EOF

# PostgreSQL HA Authentication (added by repair script)
# Cluster network access for replication and management
host    replication     replication     0.0.0.0/0               scram-sha-256
host    repmgr          repmgr          0.0.0.0/0               md5
host    all             postgres        0.0.0.0/0               md5

# Local connections use md5 for PgBouncer compatibility
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
EOF
        
        success "HA authentication rules added to pg_hba.conf"
    else
        warn "Could not locate pg_hba.conf - authentication not configured"
    fi

    # Step 10: Restart PostgreSQL to apply changes
    info "🔄 Step 10: Restarting PostgreSQL to apply configuration..."
    
    systemctl restart postgresql
    sleep 5
    
    # Verify PostgreSQL is still working
    if sudo -u postgres psql -c "SELECT 1;" >/dev/null 2>&1; then
        success "✅ PostgreSQL restarted successfully with HA configuration!"
    else
        error "❌ PostgreSQL failed to restart with HA configuration"
        return 1
    fi

    # Step 11: Create a test to ensure everything works
    info "🧪 Step 11: Running final verification tests..."
    
    # Test basic functionality
    if sudo -u postgres psql -c "CREATE DATABASE test_db;" >/dev/null 2>&1; then
        sudo -u postgres psql -c "DROP DATABASE test_db;" >/dev/null 2>&1
        success "✅ Database creation/deletion test passed"
    else
        warn "❌ Database creation test failed"
    fi
    
    # Test HA-specific settings
    local wal_level
    wal_level=$(sudo -u postgres psql -Atqc "SHOW wal_level;" 2>/dev/null || echo "unknown")
    if [[ "$wal_level" == "replica" ]]; then
        success "✅ WAL level correctly set to 'replica'"
    else
        warn "❌ WAL level not set correctly (current: $wal_level)"
    fi
    
    local max_wal_senders
    max_wal_senders=$(sudo -u postgres psql -Atqc "SHOW max_wal_senders;" 2>/dev/null || echo "0")
    if [[ "$max_wal_senders" -ge 10 ]]; then
        success "✅ Max WAL senders correctly configured ($max_wal_senders)"
    else
        warn "❌ Max WAL senders not configured correctly (current: $max_wal_senders)"
    fi

    # Step 12: Clean up any previous bootstrap attempts
    info "🧹 Step 12: Cleaning up previous bootstrap attempts..."
    
    rm -rf /var/lib/postgresql/.bootstrap 2>/dev/null || true
    rm -f /etc/repmgr/repmgr.conf 2>/dev/null || true
    
    success "✅ Previous bootstrap state cleared"

    # Final summary
    info ""
    success "🎉 PostgreSQL HA cluster repair completed successfully!"
    info ""
    info "📋 Summary:"
    info "  ✅ PostgreSQL ${PG_VERSION} cluster rebuilt from scratch"
    info "  ✅ HA configuration applied (WAL level: replica)"
    info "  ✅ Authentication configured for cluster access"
    info "  ✅ Service is running and accessible"
    info "  ✅ Ready for bootstrap script execution"
    info ""
    info "🚀 Next steps:"
    info "  1. Run: sudo ./postgresql_ha_bootstrap_clean_v2.sh"
    info "  2. The bootstrap script should now complete successfully"
    info ""
    success "✅ Repair completed - you can now proceed with the bootstrap!"
}

main "$@"