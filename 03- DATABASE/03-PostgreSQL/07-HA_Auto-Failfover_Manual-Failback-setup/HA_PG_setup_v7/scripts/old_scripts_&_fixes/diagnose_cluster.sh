#!/bin/bash
# PostgreSQL HA Cluster Diagnostic Script
# This script helps troubleshoot repmgr cluster issues

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

# Get metadata
get_metadata() {
  local key="$1" default="$2"
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "$default"
}

echo "========================================="
echo "PostgreSQL HA Cluster Diagnostics"
echo "========================================="

# Basic system info
info "System Information:"
echo "  Hostname: $(hostname)"
echo "  Date: $(date)"
echo "  Role: $(get_metadata pg_role unknown)"
echo "  Primary Host: $(get_metadata repmgr_primary_host unknown)"

# PostgreSQL status
echo ""
info "PostgreSQL Status:"
if systemctl is-active --quiet postgresql; then
  echo "  ✓ PostgreSQL service is running"
  
  # Check if we can connect
  if sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
    echo "  ✓ PostgreSQL is accepting connections"
    
    # Get version and recovery status
    version=$(sudo -u postgres psql -Atqc 'SELECT version()' postgres | head -1)
    recovery=$(sudo -u postgres psql -Atqc 'SELECT pg_is_in_recovery()' postgres)
    echo "  Version: $version"
    echo "  In Recovery: $recovery"
    
    # Check listen addresses
    listen_addr=$(sudo -u postgres psql -Atqc "SHOW listen_addresses" postgres)
    echo "  Listen Addresses: $listen_addr"
    
  else
    echo "  ✗ PostgreSQL is not accepting connections"
  fi
else
  echo "  ✗ PostgreSQL service is not running"
fi

# Repmgr status
echo ""
info "Repmgr Status:"
if command -v repmgr >/dev/null 2>&1; then
  echo "  ✓ repmgr is installed"
  
  # Check repmgr config
  if [[ -f /etc/repmgr/repmgr.conf ]]; then
    echo "  ✓ repmgr.conf exists"
    echo "  Config excerpt:"
    grep -E '^(node_id|node_name|conninfo)' /etc/repmgr/repmgr.conf | sed 's/^/    /' || true
  else
    echo "  ✗ repmgr.conf not found"
  fi
  
  # Check repmgrd service
  if systemctl is-active --quiet repmgrd; then
    echo "  ✓ repmgrd service is running"
  else
    echo "  ✗ repmgrd service is not running"
    echo "  Service status:"
    systemctl status repmgrd --no-pager -l | head -10 | sed 's/^/    /' || true
  fi
  
  # Try cluster show
  echo ""
  debug "Attempting repmgr cluster show..."
  if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null; then
    echo "  ✓ Cluster status available"
  else
    echo "  ✗ Cluster status not available"
    echo "  Error details:"
    sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>&1 | head -5 | sed 's/^/    /' || true
  fi
else
  echo "  ✗ repmgr is not installed"
fi

# Database users and permissions
echo ""
info "Database Users and Permissions:"
if sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
  echo "  Checking repmgr user..."
  repmgr_user=$(get_metadata repmgr_user repmgr)
  repmgr_db=$(get_metadata repmgr_db repmgr)
  
  # Check if repmgr user exists
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${repmgr_user}'" postgres | grep -q 1; then
    echo "    ✓ User '$repmgr_user' exists"
    
    # Check user attributes
    user_attrs=$(sudo -u postgres psql -tAc "SELECT rolsuper, rolreplication, rolcanlogin FROM pg_roles WHERE rolname='${repmgr_user}'" postgres)
    echo "    User attributes: $user_attrs"
  else
    echo "    ✗ User '$repmgr_user' does not exist"
  fi
  
  # Check if repmgr database exists
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${repmgr_db}'" postgres | grep -q 1; then
    echo "    ✓ Database '$repmgr_db' exists"
  else
    echo "    ✗ Database '$repmgr_db' does not exist"
  fi
else
  echo "  ✗ Cannot connect to PostgreSQL"
fi

# Network connectivity
echo ""
info "Network Connectivity:"
primary_host=$(get_metadata repmgr_primary_host unknown)
if [[ "$primary_host" != "unknown" && "$primary_host" != "$(hostname -I | awk '{print $1}')" ]]; then
  echo "  Testing connection to primary: $primary_host"
  
  # Test port 5432
  if timeout 5 bash -c "</dev/tcp/$primary_host/5432" 2>/dev/null; then
    echo "    ✓ Port 5432 is reachable"
    
    # Test PostgreSQL connection
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h "$primary_host" -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
      echo "    ✓ PostgreSQL connection successful"
    else
      echo "    ✗ PostgreSQL connection failed"
    fi
  else
    echo "    ✗ Port 5432 is not reachable"
  fi
else
  echo "  This appears to be the primary node"
fi

# Authentication files
echo ""
info "Authentication Files:"
if [[ -f /var/lib/postgresql/.pgpass ]]; then
  echo "  ✓ .pgpass file exists"
  echo "  Entries (passwords hidden):"
  sed 's/:[^:]*$/:*****/' /var/lib/postgresql/.pgpass | sed 's/^/    /' || true
else
  echo "  ✗ .pgpass file not found"
fi

# Health endpoint
echo ""
info "Health Endpoint:"
health_port=$(get_metadata pg_health_port 8001)
if timeout 5 curl -s "http://localhost:${health_port}" >/dev/null 2>&1; then
  echo "  ✓ Health endpoint responding on port $health_port"
  health_response=$(curl -s "http://localhost:${health_port}" | jq -r '.' 2>/dev/null || curl -s "http://localhost:${health_port}")
  echo "  Response: $health_response"
else
  echo "  ✗ Health endpoint not responding on port $health_port"
fi

# Log files
echo ""
info "Recent Log Entries:"
if [[ -f /var/log/pg-bootstrap/bootstrap.log ]]; then
  echo "  Bootstrap log (last 5 lines):"
  tail -5 /var/log/pg-bootstrap/bootstrap.log | sed 's/^/    /' || true
fi

if [[ -f /var/log/repmgr/repmgrd.log ]]; then
  echo "  Repmgrd log (last 5 lines):"
  tail -5 /var/log/repmgr/repmgrd.log | sed 's/^/    /' || true
fi

echo ""
echo "========================================="
echo "Diagnostics Complete"
echo "========================================="