#!/bin/bash
# Quick Deployment Script for PostgreSQL HA Cluster
# Run this script on both primary and standby nodes

set -euo pipefail

info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: ✓ $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"; }

echo "=============================================="
echo "PostgreSQL HA Quick Deployment"  
echo "=============================================="

# Check if we're root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

# Ensure we have the bootstrap script
if [[ ! -f "./postgresql_ha_bootstrap_clean.sh" ]]; then
    error "Bootstrap script not found: ./postgresql_ha_bootstrap_clean.sh"
    exit 1
fi

# Make bootstrap script executable
chmod +x ./postgresql_ha_bootstrap_clean.sh

# Get node information
SELF_IP=$(hostname -I | awk '{print $1}')
HOSTNAME=$(hostname)

info "Starting deployment on $HOSTNAME ($SELF_IP)"

# Auto-detect role based on hostname
if [[ "$HOSTNAME" == *"primary"* ]]; then
    ROLE="primary"
elif [[ "$HOSTNAME" == *"standby"* ]]; then
    ROLE="standby"
else
    warn "Could not auto-detect role from hostname: $HOSTNAME"
    info "Please ensure hostname contains 'primary' or 'standby'"
    exit 1
fi

info "Detected role: $ROLE"

# Clean up any previous failed attempts
info "Cleaning up any previous bootstrap attempts..."
rm -rf /var/lib/postgresql/.bootstrap 2>/dev/null || true
systemctl stop postgresql 2>/dev/null || true
systemctl stop pgbouncer 2>/dev/null || true
systemctl stop repmgrd 2>/dev/null || true

# Kill any health endpoint processes
fuser -k 8001/tcp 2>/dev/null || true
fuser -k 8002/tcp 2>/dev/null || true
pkill -f "health" 2>/dev/null || true

sleep 3

# Run the bootstrap script
info "Running PostgreSQL HA bootstrap script..."
if ./postgresql_ha_bootstrap_clean.sh; then
    success "Bootstrap completed successfully!"
else
    error "Bootstrap failed - check logs at /var/log/pg-bootstrap/bootstrap.log"
    exit 1
fi

# Wait a moment for services to stabilize
sleep 10

# Quick health check
info "Performing quick health checks..."

# Check PostgreSQL
if systemctl is-active --quiet postgresql; then
    success "PostgreSQL service is running"
    
    # Check if we can connect
    if sudo -u postgres psql -c "SELECT version();" >/dev/null 2>&1; then
        success "PostgreSQL is accepting connections"
        
        # Check role
        ACTUAL_ROLE=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null)
        info "PostgreSQL role: $ACTUAL_ROLE"
    else
        warn "PostgreSQL not accepting connections"
    fi
else
    error "PostgreSQL service is not running"
fi

# Check PgBouncer
if systemctl is-active --quiet pgbouncer; then
    success "PgBouncer service is running"
    
    if nc -z localhost 6432 2>/dev/null; then
        success "PgBouncer is listening on port 6432"
    else
        warn "PgBouncer not listening on port 6432"
    fi
else
    error "PgBouncer service is not running"
fi

# Test health endpoints
info "Testing health endpoints..."
for port in 8001 8002; do
    if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "Health endpoint on port $port is responding"
        
        # Get status
        if command -v jq >/dev/null 2>&1; then
            STATUS=$(timeout 5 curl -s "http://localhost:$port" | jq -r '.status' 2>/dev/null || echo "unknown")
            SERVICE=$(timeout 5 curl -s "http://localhost:$port" | jq -r '.service' 2>/dev/null || echo "unknown")
            info "  → $SERVICE: $STATUS"
        fi
    else
        warn "Health endpoint on port $port is not responding"
    fi
done

# Show cluster status if repmgr is available
if command -v repmgr >/dev/null 2>&1 && [[ -f /etc/repmgr/repmgr.conf ]]; then
    info "Cluster status:"
    sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null || warn "Could not show cluster status"
fi

echo ""
echo "=============================================="
echo "Deployment Summary"
echo "=============================================="
success "Node: $HOSTNAME ($SELF_IP)"
success "Role: $ROLE"
success "Deployment completed!"

info "Next steps:"
info "1. Verify health endpoints from external hosts:"
info "   curl http://$SELF_IP:8001"
info "   curl http://$SELF_IP:8002"
info ""
info "2. Check logs if needed:"
info "   tail -f /var/log/pg-bootstrap/bootstrap.log"
info ""
info "3. Monitor services:"
info "   systemctl status postgresql pgbouncer repmgrd"

if [[ "$ROLE" == "standby" ]]; then
    info ""
    info "4. For standby nodes, verify replication:"
    info "   sudo -u postgres psql -c \"SELECT pg_is_in_recovery();\""
fi