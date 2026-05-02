#!/bin/bash
# Final repmgrd Fix Script - Correct Command Syntax
# Fixes the repmgr daemon service with proper command line arguments

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Final repmgrd fix with correct command syntax"

# Stop existing broken service
info "Stopping broken repmgrd service..."
systemctl stop repmgrd 2>/dev/null || true

# Create the correct systemd service (based on working postgresql_ha_bootstrap.sh)
info "Creating correct repmgrd systemd service..."
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

success "Created correct systemd service configuration"

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

info "Final repmgrd fix complete!"
echo ""
echo "=== SUMMARY ==="
info "✓ Used Type=simple instead of forking"
info "✓ Removed --daemonize flag (not supported)"  
info "✓ Removed -p PID file argument (causes confusion)"
info "✓ Used correct repmgr daemon start/stop syntax"