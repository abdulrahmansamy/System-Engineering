#!/bin/bash
# Quick Fix for repmgrd Service Issue
# Adds missing repmgrd_service_start_command to repmgr.conf

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🔧 Quick Fix for repmgrd Service Issue"
echo "====================================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

REPMGR_CONF="/etc/repmgr/repmgr.conf"

# Check if repmgr.conf exists
if [[ ! -f "$REPMGR_CONF" ]]; then
    error "repmgr.conf not found at $REPMGR_CONF"
    exit 1
fi

info "Checking current repmgr.conf..."

# Check if repmgrd_service_start_command is already present
if grep -q "repmgrd_service_start_command" "$REPMGR_CONF"; then
    warn "repmgrd_service_start_command already exists in repmgr.conf"
    info "Current content:"
    grep "repmgrd_service" "$REPMGR_CONF" || true
    echo
    info "The issue might be elsewhere. Let's check the exact error..."
    exit 0
fi

info "Adding missing repmgrd_service_start_command to repmgr.conf..."

# Create backup
cp "$REPMGR_CONF" "${REPMGR_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
success "Backup created: ${REPMGR_CONF}.backup.$(date +%Y%m%d_%H%M%S)"

# Add the missing configuration lines
cat >> "$REPMGR_CONF" <<'EOF'

# repmgrd service commands (required for repmgrd daemon)
repmgrd_service_start_command='sudo systemctl start repmgrd.service'
repmgrd_service_stop_command='sudo systemctl stop repmgrd.service'
EOF

success "Added repmgrd service commands to repmgr.conf"

info "Updated repmgr.conf content:"
echo "----------------------------------------"
tail -5 "$REPMGR_CONF"
echo "----------------------------------------"
echo

info "Now stopping and starting repmgrd service..."

# Stop the current failing service
systemctl stop repmgrd.service 2>/dev/null || true
sleep 2

# Reload systemd
systemctl daemon-reload

# Start the service
if systemctl start repmgrd.service; then
    success "repmgrd service started successfully!"
    sleep 3
    
    if systemctl is-active --quiet repmgrd.service; then
        success "✅ repmgrd service is now running properly!"
        
        info "Service status:"
        systemctl status repmgrd.service --no-pager --lines=5 || true
        
        info "Testing cluster status:"
        if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show; then
            success "🎉 Cluster status is working!"
        else
            warn "Cluster status check failed, but service is running"
        fi
    else
        error "❌ repmgrd service failed to stay running"
        info "Checking logs:"
        journalctl -u repmgrd.service --lines=10 --no-pager
    fi
else
    error "❌ Failed to start repmgrd service"
    info "Service status:"
    systemctl status repmgrd.service --no-pager || true
    info "Recent logs:"
    journalctl -u repmgrd.service --lines=10 --no-pager
fi

echo
info "Fix attempt complete!"