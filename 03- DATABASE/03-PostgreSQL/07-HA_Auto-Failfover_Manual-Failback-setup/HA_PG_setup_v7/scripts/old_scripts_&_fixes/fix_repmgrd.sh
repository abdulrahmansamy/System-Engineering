#!/bin/bash
# repmgrd Service Diagnostic and Fix Script
# Quick script to diagnose and fix repmgrd service issues

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "=== repmgrd Service Diagnostic and Fix ==="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# Step 1: Check current service status
info "Checking current repmgrd service status..."
systemctl status repmgrd.service --no-pager || true
echo

# Step 2: Check if PostgreSQL is running
info "Checking PostgreSQL status..."
if systemctl is-active --quiet postgresql; then
    success "PostgreSQL is running"
else
    error "PostgreSQL is not running - repmgrd requires PostgreSQL to be active"
    info "Starting PostgreSQL..."
    systemctl start postgresql
    sleep 3
fi
echo

# Step 3: Check repmgr configuration
info "Checking repmgr configuration..."
if [[ -f /etc/repmgr/repmgr.conf ]]; then
    success "repmgr.conf exists"
    info "Configuration summary:"
    grep -E "^(node_id|node_name|conninfo|data_directory)" /etc/repmgr/repmgr.conf || true
else
    error "repmgr.conf not found at /etc/repmgr/repmgr.conf"
    exit 1
fi
echo

# Step 4: Check if node is registered with repmgr
info "Checking repmgr cluster status..."
if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show >&/dev/null; then
    success "Node is registered with repmgr cluster"
    sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show
else
    warn "Node may not be properly registered with repmgr cluster"
fi
echo

# Step 5: Check .pgpass file
info "Checking .pgpass file..."
if [[ -f /var/lib/postgresql/.pgpass ]]; then
    success ".pgpass file exists"
    info "Permissions: $(ls -la /var/lib/postgresql/.pgpass | awk '{print $1, $3, $4}')"
    if [[ $(stat -c %a /var/lib/postgresql/.pgpass) == "600" ]]; then
        success ".pgpass has correct permissions (600)"
    else
        warn ".pgpass permissions need fixing"
        chmod 600 /var/lib/postgresql/.pgpass
        chown postgres:postgres /var/lib/postgresql/.pgpass
        success "Fixed .pgpass permissions"
    fi
else
    error ".pgpass file not found"
fi
echo

# Step 6: Test database connectivity
info "Testing database connectivity for repmgr user..."
if sudo -u postgres psql -c "SELECT 1;" >&/dev/null; then
    success "Database connectivity working"
else
    error "Database connectivity failed"
fi
echo

# Step 7: Check systemd service file
info "Checking systemd service file..."
if [[ -f /etc/systemd/system/repmgrd.service ]]; then
    success "repmgrd.service file exists"
    info "Service file content:"
    cat /etc/systemd/system/repmgrd.service
else
    error "repmgrd.service file not found"
fi
echo

# Step 8: Check logs
info "Checking recent repmgrd logs..."
journalctl -u repmgrd.service --lines=20 --no-pager || true
echo

# Step 9: Try to fix the service
info "Attempting to fix and restart repmgrd service..."

# Stop the service first
systemctl stop repmgrd.service 2>/dev/null || true
sleep 2

# Reload systemd daemon
systemctl daemon-reload

# Ensure PostgreSQL is stable
sleep 2

# Start the service
if systemctl start repmgrd.service; then
    success "repmgrd service started"
    sleep 3
    
    if systemctl is-active --quiet repmgrd.service; then
        success "repmgrd service is running successfully"
        systemctl status repmgrd.service --no-pager --lines=5
    else
        error "repmgrd service failed to stay running"
        warn "Recent logs:"
        journalctl -u repmgrd.service --lines=10 --no-pager
    fi
else
    error "Failed to start repmgrd service"
    warn "Service status:"
    systemctl status repmgrd.service --no-pager || true
fi

echo
info "Diagnostic complete. Check the output above for any issues."
echo

# Final status check
info "Final service status check..."
if systemctl is-active --quiet repmgrd.service; then
    success "✅ repmgrd service is now running"
else
    error "❌ repmgrd service is still not running"
    warn "Manual intervention may be required"
    echo
    info "You can check detailed logs with:"
    info "  sudo journalctl -u repmgrd.service -f"
    echo
    info "You can check repmgr cluster status with:"
    info "  sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show"
fi