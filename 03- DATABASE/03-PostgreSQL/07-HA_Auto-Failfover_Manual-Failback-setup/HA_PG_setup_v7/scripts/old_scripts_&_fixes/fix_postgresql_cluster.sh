#!/bin/bash
# PostgreSQL HA Cluster Fix Script - Resolves common initialization issues
# This script fixes the "Invalid data directory" error and reconfigures the cluster
# Version: 1.0.0

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
PG_CLUSTER_NAME="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"

main() {
    info "🔧 PostgreSQL HA Cluster Fix Script"
    info "Resolving cluster configuration issues..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi

    # Step 1: Stop PostgreSQL services
    info "Stopping PostgreSQL services..."
    systemctl stop postgresql repmgrd pgbouncer 2>/dev/null || true
    systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true

    # Step 2: Check current cluster status
    info "Checking current PostgreSQL cluster status..."
    
    if pg_lsclusters | grep -q "^${PG_VERSION}"; then
        info "Found existing PostgreSQL cluster configuration:"
        pg_lsclusters | grep "^${PG_VERSION}"
        
        # Drop existing cluster if corrupted
        if pg_lsclusters | grep "^${PG_VERSION}" | grep -q "down"; then
            warn "Cluster is down, attempting to drop and recreate..."
            sudo -u postgres pg_dropcluster --stop "${PG_VERSION}" main 2>/dev/null || true
        fi
    else
        info "No existing cluster configuration found"
    fi

    # Step 3: Recreate cluster with proper configuration
    info "Creating fresh PostgreSQL cluster..."
    
    # Ensure the postgres user owns the data directory
    mkdir -p "/var/lib/postgresql/${PG_VERSION}"
    chown -R postgres:postgres "/var/lib/postgresql"
    
    # Create cluster using pg_createcluster (Ubuntu way)
    if ! pg_lsclusters | grep -q "^${PG_VERSION}.*main.*online"; then
        sudo -u postgres pg_createcluster "${PG_VERSION}" main --start
        success "PostgreSQL cluster created successfully"
    else
        success "PostgreSQL cluster already exists and is online"
    fi

    # Step 4: Start PostgreSQL and verify
    info "Starting PostgreSQL service..."
    systemctl start postgresql
    sleep 3

    # Verify PostgreSQL is working
    if sudo -u postgres psql -c "SELECT version();" >/dev/null 2>&1; then
        success "PostgreSQL is running and accessible"
        
        # Show cluster info
        info "Cluster information:"
        pg_lsclusters | grep "^${PG_VERSION}" || true
        
        # Show data directory
        local data_dir_real
        data_dir_real=$(sudo -u postgres psql -Atqc "SHOW data_directory;" 2>/dev/null || echo "unknown")
        info "Data directory: $data_dir_real"
        
        # Update PG_DATA_DIR variable for repmgr config if needed
        if [[ "$data_dir_real" != "unknown" && "$data_dir_real" != "$PG_DATA_DIR" ]]; then
            warn "Data directory differs from expected path"
            info "Expected: $PG_DATA_DIR"
            info "Actual: $data_dir_real"
            info "Updating configuration files..."
            
            # Update repmgr configuration if it exists
            if [[ -f /etc/repmgr/repmgr.conf ]]; then
                sed -i "s|data_directory=.*|data_directory='${data_dir_real}'|" /etc/repmgr/repmgr.conf
                success "Updated repmgr configuration with correct data directory"
            fi
        fi
        
    else
        error "PostgreSQL failed to start properly"
        return 1
    fi

    # Step 5: Apply HA configuration
    info "Applying HA configuration to postgresql.conf..."
    
    local pg_conf_file
    pg_conf_file=$(sudo -u postgres psql -Atqc "SHOW config_file;" 2>/dev/null)
    
    if [[ -f "$pg_conf_file" ]]; then
        # Backup existing config
        cp "$pg_conf_file" "${pg_conf_file}.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Add HA settings if not already present
        if ! grep -q "# PostgreSQL HA Configuration" "$pg_conf_file"; then
            cat >> "$pg_conf_file" <<EOF

# PostgreSQL HA Configuration (added by fix script)
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
EOF
            success "Added HA configuration to postgresql.conf"
        else
            info "HA configuration already present in postgresql.conf"
        fi
    else
        warn "Could not locate postgresql.conf file"
    fi

    # Step 6: Restart PostgreSQL to apply changes
    info "Restarting PostgreSQL to apply configuration changes..."
    systemctl restart postgresql
    sleep 5

    # Step 7: Test final configuration
    info "Testing final configuration..."
    
    if sudo -u postgres psql -c "SELECT 1;" >/dev/null 2>&1; then
        success "✅ PostgreSQL is working correctly!"
        
        # Show key settings
        info "Key PostgreSQL settings:"
        echo "  WAL Level: $(sudo -u postgres psql -Atqc "SHOW wal_level;" 2>/dev/null || echo 'unknown')"
        echo "  Max WAL Senders: $(sudo -u postgres psql -Atqc "SHOW max_wal_senders;" 2>/dev/null || echo 'unknown')"
        echo "  Hot Standby: $(sudo -u postgres psql -Atqc "SHOW hot_standby;" 2>/dev/null || echo 'unknown')"
        echo "  Shared Preload Libraries: $(sudo -u postgres psql -Atqc "SHOW shared_preload_libraries;" 2>/dev/null || echo 'unknown')"
        
        info ""
        success "🎉 PostgreSQL HA cluster fix completed successfully!"
        info "You can now re-run the bootstrap script:"
        info "  sudo ./postgresql_ha_bootstrap_clean_v2.sh"
        
    else
        error "❌ PostgreSQL configuration test failed"
        return 1
    fi
}

main "$@"