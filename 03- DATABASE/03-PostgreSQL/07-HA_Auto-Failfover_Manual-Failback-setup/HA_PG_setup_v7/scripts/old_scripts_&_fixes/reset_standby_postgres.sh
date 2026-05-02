#!/bin/bash
# Aggressive PostgreSQL Reset for Standby Node
# This script completely resets PostgreSQL on the standby node

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
echo "Aggressive PostgreSQL Reset for Standby"
echo "========================================="

# Stop all PostgreSQL related processes
info "Stopping all PostgreSQL processes..."
sudo pkill -f postgres || true
sudo pkill -f postgresql || true
sudo pkill -f repmgr || true
sudo systemctl stop postgresql || true
sudo systemctl stop repmgrd || true

sleep 3

# Remove corrupted data directories
info "Removing corrupted data directories..."
PG_DATA_DIR="/var/lib/postgresql/17/main"
sudo rm -rf "$PG_DATA_DIR"/* 2>/dev/null || true
sudo rm -rf /var/lib/postgresql/.bootstrap/ 2>/dev/null || true

# Ensure proper ownership
sudo mkdir -p "$PG_DATA_DIR"
sudo chown -R postgres:postgres /var/lib/postgresql/
sudo chmod 700 "$PG_DATA_DIR"

# Initialize fresh PostgreSQL cluster
info "Initializing fresh PostgreSQL cluster..."
sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D "$PG_DATA_DIR" \
  --locale=C.UTF-8 \
  --encoding=UTF8 \
  --auth-local=peer \
  --auth-host=scram-sha-256

# Start PostgreSQL
info "Starting PostgreSQL..."
sudo systemctl start postgresql
sleep 5

# Verify it's working
if sudo -u postgres psql -Atqc 'SELECT version()' postgres >/dev/null 2>&1; then
    info "✅ PostgreSQL is working properly"
    
    # Show version
    PG_VERSION=$(sudo -u postgres psql -Atqc 'SELECT version()' postgres)
    info "PostgreSQL Version: $PG_VERSION"
    
    info "✅ Standby node is ready for bootstrap"
else
    error "❌ PostgreSQL initialization failed"
    info "Checking logs..."
    sudo tail -20 /var/log/postgresql/postgresql-17-main.log || true
    exit 1
fi

echo ""
echo "========================================="
echo "PostgreSQL Reset Complete!"
echo "========================================="
echo ""
echo "Now you can run:"
echo "  sudo ./fix_password_sync.sh"
echo "  sudo ./postgresql_ha_bootstrap.sh"