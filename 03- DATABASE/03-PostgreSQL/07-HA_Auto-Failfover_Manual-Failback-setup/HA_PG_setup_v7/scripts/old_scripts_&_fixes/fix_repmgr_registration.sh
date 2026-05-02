#!/bin/bash
# Manual Repmgr Registration Fix Script
# Use this script to manually fix repmgr registration issues

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Get metadata
get_metadata() {
  local key="$1" default="$2"
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "$default"
}

echo "========================================="
echo "Repmgr Registration Fix Script"
echo "========================================="

# Get configuration
ROLE=$(get_metadata pg_role unknown)
REPMGR_USER=$(get_metadata repmgr_user repmgr)
REPMGR_DB=$(get_metadata repmgr_db repmgr)
REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"

info "Node role: $ROLE"
info "Repmgr user: $REPMGR_USER"
info "Repmgr database: $REPMGR_DB"

# Check if PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
  error "PostgreSQL is not running. Please start it first:"
  echo "  sudo systemctl start postgresql"
  exit 1
fi

# Check if we can connect
if ! sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
  error "Cannot connect to PostgreSQL"
  exit 1
fi

info "PostgreSQL is running and accessible"

case "$ROLE" in
  primary)
    info "Fixing primary node registration..."
    
    # Check if repmgr user exists
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REPMGR_USER}'" postgres | grep -q 1; then
      info "Creating repmgr user..."
      # Get password from Secret Manager or use fallback
      repmgr_password=$(get_metadata repmgr_password "defaultPassword")
      sudo -u postgres psql -c "CREATE ROLE ${REPMGR_USER} WITH LOGIN SUPERUSER PASSWORD '${repmgr_password}';" postgres
    fi
    
    # Check if repmgr database exists
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${REPMGR_DB}'" postgres | grep -q 1; then
      info "Creating repmgr database..."
      sudo -u postgres createdb -O ${REPMGR_USER} ${REPMGR_DB}
    fi
    
    # Setup pgpass
    info "Setting up .pgpass file..."
    pgpass="/var/lib/postgresql/.pgpass"
    repmgr_password=$(get_metadata repmgr_password "defaultPassword")
    self_ip=$(hostname -I | awk '{print $1}')
    
    cat > "$pgpass" <<EOF
localhost:5432:${REPMGR_DB}:${REPMGR_USER}:${repmgr_password}
${self_ip}:5432:${REPMGR_DB}:${REPMGR_USER}:${repmgr_password}
localhost:5432:replication:${REPMGR_USER}:${repmgr_password}
${self_ip}:5432:replication:${REPMGR_USER}:${repmgr_password}
EOF
    
    chown postgres:postgres "$pgpass"
    chmod 600 "$pgpass"
    
    # Clear any existing repmgr tables
    info "Clearing existing repmgr tables..."
    sudo -u postgres psql -d "$REPMGR_DB" -c "DROP TABLE IF EXISTS repmgr.nodes CASCADE;" || true
    sudo -u postgres psql -d "$REPMGR_DB" -c "DROP SCHEMA IF EXISTS repmgr CASCADE;" || true
    
    # Register primary
    info "Registering primary node..."
    if sudo -u postgres env PGPASSFILE="$pgpass" repmgr -f "$REPMGR_CONF_FILE" primary register --force; then
      info "✓ Primary registration successful"
      
      # Show cluster status
      info "Cluster status:"
      sudo -u postgres env PGPASSFILE="$pgpass" repmgr -f "$REPMGR_CONF_FILE" cluster show
      
      # Restart repmgrd
      info "Restarting repmgrd service..."
      systemctl restart repmgrd
      
      info "✓ Primary node fix completed successfully"
    else
      error "Primary registration failed"
      exit 1
    fi
    ;;
    
  standby)
    info "For standby nodes, ensure primary is registered first, then run:"
    echo "  sudo -u postgres repmgr -f $REPMGR_CONF_FILE standby register --force"
    ;;
    
  witness)
    info "For witness nodes, ensure primary is registered first, then run:"
    echo "  sudo -u postgres repmgr -f $REPMGR_CONF_FILE witness register --force"
    ;;
    
  *)
    error "Unknown role: $ROLE"
    exit 1
    ;;
esac

echo "========================================="
echo "Fix script completed"
echo "========================================="