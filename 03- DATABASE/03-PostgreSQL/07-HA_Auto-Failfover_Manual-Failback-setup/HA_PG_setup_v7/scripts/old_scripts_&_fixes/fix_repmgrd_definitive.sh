#!/bin/bash
# Definitive repmgrd Fix Script - Uses sudo with NOPASSWD for postgres user
# This is the final solution that addresses both repmgr requirements

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Definitive repmgrd fix - using sudo with NOPASSWD for postgres user"

REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"

# Stop existing broken service
info "Stopping broken repmgrd service..."
systemctl stop repmgrd 2>/dev/null || true

# Create sudoers rule for postgres user to run systemctl commands without password
info "Creating sudoers rule for postgres user..."
cat > /etc/sudoers.d/postgres-repmgrd <<'EOF'
# Allow postgres user to run systemctl commands for repmgrd without password
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl start repmgrd.service
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl stop repmgrd.service
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl start postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl stop postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl restart postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl reload postgresql
EOF

chmod 440 /etc/sudoers.d/postgres-repmgrd
success "Created sudoers rule for postgres user"

# Fix the repmgr configuration by adding the service commands WITH sudo (but postgres can run them)
info "Adding service commands with sudo to repmgr.conf..."
if [[ -f "$REPMGR_CONF_FILE" ]]; then
    # Backup
    cp "$REPMGR_CONF_FILE" "${REPMGR_CONF_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
    
    # Remove any existing service command lines first
    sed -i '/^repmgrd_service_start_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^repmgrd_service_stop_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^service_start_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^service_stop_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^service_restart_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^service_reload_command=/d' "$REPMGR_CONF_FILE"
    
    # Add the required service commands AFTER the log_level line (with sudo, but postgres can run them)
    sed -i '/^log_level=INFO/a\\n# Service commands (required for repmgrd daemon)\nrepmgrd_service_start_command='\''sudo systemctl start repmgrd.service'\''\nrepmgrd_service_stop_command='\''sudo systemctl stop repmgrd.service'\''\nservice_start_command='\''sudo systemctl start postgresql'\''\nservice_stop_command='\''sudo systemctl stop postgresql'\''\nservice_restart_command='\''sudo systemctl restart postgresql'\''\nservice_reload_command='\''sudo systemctl reload postgresql'\''' "$REPMGR_CONF_FILE"
    
    success "Added service commands with sudo to repmgr.conf"
else
    error "repmgr.conf not found!"
    exit 1
fi

# Create the correct systemd service that runs as postgres user
info "Creating repmgrd systemd service running as postgres user..."
cat > /etc/systemd/system/repmgrd.service <<'EOF'
[Unit]
Description=PostgreSQL replication manager daemon
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=postgres
Group=postgres
Environment=PGPASSFILE=/var/lib/postgresql/.pgpass
ExecStart=/usr/bin/repmgr -f /etc/repmgr/repmgr.conf daemon start
ExecStop=/usr/bin/repmgr -f /etc/repmgr/repmgr.conf daemon stop
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

success "Created systemd service running as postgres user"

# Ensure proper permissions
info "Ensuring proper permissions..."
mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 755 /var/run/postgresql

# Create repmgr log directory
mkdir -p /var/log/repmgr
chown postgres:postgres /var/log/repmgr
chmod 755 /var/log/repmgr

# Reload systemd
systemctl daemon-reload
systemctl enable repmgrd.service

info "Starting fixed repmgrd service..."
if systemctl start repmgrd.service; then
    success "repmgrd service started successfully!"
    
    # Wait and check status
    sleep 5
    if systemctl is-active --quiet repmgrd; then
        success "repmgrd is running and healthy!"
        
        # Show status
        info "Service status:"
        systemctl status repmgrd --no-pager -l || true
        
        # Test cluster connectivity
        if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show >/dev/null 2>&1; then
            success "repmgr cluster connectivity confirmed"
            echo ""
            echo "=== REPMGR CLUSTER STATUS ==="
            sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show || true
        else
            warn "repmgr cluster connectivity issue (may be normal if standby not ready)"
        fi
    else
        warn "repmgrd service not running properly"
        info "Checking logs..."
        journalctl -u repmgrd --no-pager -n 10
    fi
else
    error "Failed to start repmgrd service"
    info "Checking logs..."
    journalctl -u repmgrd --no-pager -n 10
fi

info "Definitive repmgrd fix complete!"
echo ""
echo "=== SUMMARY ==="
info "✓ Created sudoers rule for postgres user (can run systemctl without password)"
info "✓ Added service commands WITH sudo to repmgr.conf"  
info "✓ Service runs as postgres user (repmgr requirement)"
info "✓ postgres user can execute sudo commands (sudoers rule)"

# Show final configuration
echo ""
echo "=== CURRENT REPMGR CONFIGURATION ==="
cat "$REPMGR_CONF_FILE" | grep -v "^#" | grep -v "^$"