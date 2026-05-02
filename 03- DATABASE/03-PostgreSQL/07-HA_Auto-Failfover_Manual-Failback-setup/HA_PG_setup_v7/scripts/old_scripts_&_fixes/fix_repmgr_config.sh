#!/bin/bash
# Quick repmgr Configuration Fix Script
# Adds missing service commands to existing repmgr.conf

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }

info "🔧 Fixing repmgr configuration with missing service commands"

REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"

if [[ ! -f "$REPMGR_CONF_FILE" ]]; then
    warn "repmgr.conf not found at $REPMGR_CONF_FILE"
    exit 1
fi

# Check if service commands are already present
if grep -q "repmgrd_service_start_command" "$REPMGR_CONF_FILE"; then
    info "Service commands already exist in repmgr.conf"
else
    info "Adding missing service commands to repmgr.conf"
    
    # Backup the original
    cp "$REPMGR_CONF_FILE" "${REPMGR_CONF_FILE}.backup"
    
    # Add service commands after the log_level line
    sed -i '/^log_level=INFO/a\\n# Service commands (required for repmgrd daemon)\nrepmgrd_service_start_command='\''sudo systemctl start repmgrd.service'\''\nrepmgrd_service_stop_command='\''sudo systemctl stop repmgrd.service'\''\nservice_start_command='\''sudo systemctl start postgresql'\''\nservice_stop_command='\''sudo systemctl stop postgresql'\''\nservice_restart_command='\''sudo systemctl restart postgresql'\''\nservice_reload_command='\''sudo systemctl reload postgresql'\''' "$REPMGR_CONF_FILE"
    
    success "Service commands added to repmgr.conf"
fi

info "Current repmgr.conf content:"
echo "----------------------------------------"
cat "$REPMGR_CONF_FILE"
echo "----------------------------------------"

# Stop existing repmgrd service
info "Stopping repmgrd service..."
systemctl stop repmgrd 2>/dev/null || true

# Reload systemd and restart
info "Restarting repmgrd service with new configuration..."
systemctl daemon-reload

if systemctl start repmgrd; then
    success "repmgrd service started successfully!"
    
    # Wait a moment and check status
    sleep 3
    if systemctl is-active --quiet repmgrd; then
        success "repmgrd is running and healthy!"
        
        # Test repmgr cluster connectivity
        if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show >/dev/null 2>&1; then
            success "repmgr cluster connectivity confirmed"
            echo ""
            echo "=== REPMGR CLUSTER STATUS ==="
            sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show
        else
            warn "repmgr cluster connectivity issue"
        fi
    else
        warn "repmgrd started but not running properly"
        info "Checking logs..."
        journalctl -u repmgrd --no-pager -n 5
    fi
else
    warn "Failed to start repmgrd service"
    info "Checking logs..."
    journalctl -u repmgrd --no-pager -n 10
fi

info "repmgr configuration fix complete!"