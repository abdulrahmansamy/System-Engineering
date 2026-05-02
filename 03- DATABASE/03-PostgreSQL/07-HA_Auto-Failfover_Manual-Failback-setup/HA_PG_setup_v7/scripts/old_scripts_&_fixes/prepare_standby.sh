#!/bin/bash
# Quick Standby Node Startup Script
# This script prepares the standby node for bootstrap

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "========================================="
echo "Quick Standby Node Startup"
echo "========================================="

# Kill any stuck processes
info "Stopping any stuck processes..."
sudo pkill -f postgresql_ha_bootstrap || true
sudo pkill -f repmgr || true

# Start PostgreSQL service (needed for password sync)
info "Starting PostgreSQL service..."
sudo systemctl start postgresql || true
sudo systemctl enable postgresql || true

# Wait a moment for startup
sleep 3

# Check if PostgreSQL is running
if sudo systemctl is-active --quiet postgresql; then
    info "✅ PostgreSQL service is running"
else
    warn "⚠️  PostgreSQL service is not running, trying to fix..."
    
    # Try to install PostgreSQL if not installed
    if ! command -v psql >/dev/null 2>&1; then
        info "Installing PostgreSQL..."
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update
        sudo apt-get install -y postgresql-17 postgresql-client-17
    fi
    
    # Try to start again
    sudo systemctl start postgresql || true
    sleep 3
    
    if sudo systemctl is-active --quiet postgresql; then
        info "✅ PostgreSQL service is now running"
    else
        error "❌ Could not start PostgreSQL service"
        exit 1
    fi
fi

# Check if we can connect
if sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
    info "✅ PostgreSQL is accepting connections"
else
    warn "⚠️  PostgreSQL is not accepting connections, checking data directory..."
    
    # Check if PostgreSQL data directory exists and is initialized
    PG_DATA_DIR="/var/lib/postgresql/17/main"
    if [[ ! -f "$PG_DATA_DIR/PG_VERSION" ]]; then
        info "PostgreSQL data directory not initialized, initializing..."
        
        # Stop PostgreSQL
        sudo systemctl stop postgresql || true
        
        # Remove any corrupted data
        sudo rm -rf "$PG_DATA_DIR"/* 2>/dev/null || true
        
        # Initialize the database cluster
        sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D "$PG_DATA_DIR" --locale=C.UTF-8 --encoding=UTF8
        
        # Start PostgreSQL
        sudo systemctl start postgresql
        sleep 5
        
        if sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
            info "✅ PostgreSQL is now accepting connections after initialization"
        else
            error "❌ PostgreSQL still not accepting connections after initialization"
            info "Checking PostgreSQL logs..."
            sudo tail -20 /var/log/postgresql/postgresql-17-main.log || true
            exit 1
        fi
    else
        warn "Data directory exists but PostgreSQL not responding"
        info "Checking PostgreSQL status and logs..."
        sudo systemctl status postgresql --no-pager -l || true
        sudo tail -10 /var/log/postgresql/postgresql-17-main.log || true
        exit 1
    fi
fi

info "✅ Standby node is ready for password sync and bootstrap"

echo ""
echo "Now run:"
echo "  sudo ./fix_password_sync.sh"
echo "  sudo ./postgresql_ha_bootstrap.sh"