#!/bin/bash
# Comprehensive repmgrd Fix Script
# Fixes sudo permission issues and uses working service configuration

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Comprehensive repmgrd fix - removing sudo dependencies and using working configuration"

REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"

# Stop existing broken service
info "Stopping broken repmgrd service..."
systemctl stop repmgrd 2>/dev/null || true

# Fix the repmgr configuration by removing problematic sudo commands
info "Fixing repmgr configuration..."
if [[ -f "$REPMGR_CONF_FILE" ]]; then
    # Backup
    cp "$REPMGR_CONF_FILE" "${REPMGR_CONF_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
    
    # Remove all service command lines that use sudo
    sed -i '/^repmgrd_service_start_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^repmgrd_service_stop_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^service_start_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^service_stop_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^service_restart_command=/d' "$REPMGR_CONF_FILE"
    sed -i '/^service_reload_command=/d' "$REPMGR_CONF_FILE"
    
    success "Removed problematic sudo service commands from repmgr.conf"
else
    error "repmgr.conf not found!"
    exit 1
fi

# Create the working systemd service (matches postgresql_ha_bootstrap.sh)
info "Creating working repmgrd systemd service..."
cat > /etc/systemd/system/repmgrd.service <<'EOF'
[Unit]
Description=PostgreSQL replication manager daemon
After=postgresql.service
Requires=postgresql.service

[Service]
Type=forking
User=postgres
Group=postgres
Environment=PGPASSFILE=/var/lib/postgresql/.pgpass
ExecStart=/usr/bin/repmgr -f /etc/repmgr/repmgr.conf -p /var/run/postgresql/repmgrd.pid --daemonize daemon start
ExecStop=/usr/bin/repmgr -f /etc/repmgr/repmgr.conf daemon stop
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/var/run/postgresql/repmgrd.pid
KillMode=mixed
KillSignal=SIGINT
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF

success "Created working systemd service configuration"

# Ensure PostgreSQL runtime directory exists and has proper permissions
info "Ensuring proper permissions..."
mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 755 /var/run/postgresql

# Reload systemd
systemctl daemon-reload
systemctl enable repmgrd.service

info "Starting fixed repmgrd service..."
if systemctl start repmgrd.service; then
    success "repmgrd service started successfully!"
    
    # Wait and check status
    sleep 3
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
            warn "repmgr cluster connectivity issue"
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

info "Comprehensive repmgrd fix complete!"
echo ""
echo "=== SUMMARY ==="
info "✓ Removed sudo commands from repmgr.conf"
info "✓ Updated systemd service to working configuration"  
info "✓ Fixed permissions on /var/run/postgresql"
info "✓ Used forking service type with proper PID file"

# Show final configuration
echo ""
echo "=== CURRENT REPMGR CONFIGURATION ==="
cat "$REPMGR_CONF_FILE" | grep -v "^#" | grep -v "^$"