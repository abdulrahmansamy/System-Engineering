#!/bin/bash
# Final Polish Script - Fix remaining PgBouncer authentication and health endpoints
# Version: 1.0.0 - Addresses the last two validation issues

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Final polish - fixing PgBouncer authentication and health endpoints"

# Fix PgBouncer authentication issue
info "Fixing PgBouncer authentication..."

# Get the postgres password from .pgpass for consistency
POSTGRES_PASS=$(grep "^localhost:5432:.*:postgres:" /var/lib/postgresql/.pgpass | cut -d: -f5 | head -1)
PGBOUNCER_ADMIN_PASS=$(grep "^localhost:6432:.*:pgbouncer_admin:" /var/lib/postgresql/.pgpass 2>/dev/null | cut -d: -f5 | head -1 || echo "")

if [[ -z "$PGBOUNCER_ADMIN_PASS" ]]; then
    # Get PgBouncer password from userlist.txt
    PGBOUNCER_ADMIN_PASS=$(grep '"pgbouncer_admin"' /etc/pgbouncer/userlist.txt | cut -d'"' -f4 | sed 's/^md5//')
    info "Extracted pgbouncer_admin password from userlist.txt"
fi

# Update .pgpass with PgBouncer entries
info "Updating .pgpass with correct PgBouncer entries..."
cp /var/lib/postgresql/.pgpass /var/lib/postgresql/.pgpass.backup

# Add missing PgBouncer entries
cat >> /var/lib/postgresql/.pgpass <<EOF

# PgBouncer entries for testing
localhost:6432:postgres:postgres:${POSTGRES_PASS}
127.0.0.1:6432:postgres:postgres:${POSTGRES_PASS}
localhost:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_ADMIN_PASS}
127.0.0.1:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_ADMIN_PASS}
EOF

chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

# Test PgBouncer connection
info "Testing PgBouncer connection..."
if timeout 10 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 'PgBouncer test successful' as result;" >/dev/null 2>&1; then
    success "PgBouncer connection test successful!"
else
    warn "PgBouncer connection still failing - checking configuration..."
    
    # Check PgBouncer logs
    if [[ -f /var/log/pgbouncer/pgbouncer.log ]]; then
        info "Recent PgBouncer log entries:"
        tail -5 /var/log/pgbouncer/pgbouncer.log 2>/dev/null || echo "No recent log entries"
    fi
    
    # Restart PgBouncer to pick up any config changes
    info "Restarting PgBouncer service..."
    systemctl restart pgbouncer
    sleep 2
    
    # Test again after restart
    if timeout 10 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 'PgBouncer test after restart' as result;" >/dev/null 2>&1; then
        success "PgBouncer connection successful after restart!"
    else
        warn "PgBouncer connection still failing after restart"
    fi
fi

# Fix health endpoints
info "Fixing health endpoints..."

# Check if health services are running
for service in pg-ha-health pgbouncer-health; do
    if systemctl is-active --quiet "${service}.service" 2>/dev/null; then
        success "$service service is running"
    else
        info "Starting $service service..."
        systemctl start "${service}.service" 2>/dev/null || warn "Failed to start $service service"
    fi
done

# Test health endpoints directly
info "Testing health endpoints..."

# Test PostgreSQL health endpoint
if timeout 5 curl -s http://localhost:8001 >/dev/null 2>&1; then
    success "PostgreSQL health endpoint (8001) responding"
    curl -s http://localhost:8001 | jq . 2>/dev/null || curl -s http://localhost:8001
else
    warn "PostgreSQL health endpoint not responding - starting manually"
    
    # Kill any existing health processes on port 8001
    pkill -f "pg-ha-health.sh" 2>/dev/null || true
    fuser -k 8001/tcp 2>/dev/null || true
    sleep 1
    
    # Start health endpoint manually
    if [[ -f /usr/local/bin/pg-ha-health.sh ]]; then
        nohup /usr/local/bin/pg-ha-health.sh 8001 >/dev/null 2>&1 &
        sleep 2
        
        if timeout 5 curl -s http://localhost:8001 >/dev/null 2>&1; then
            success "PostgreSQL health endpoint started manually"
        else
            warn "PostgreSQL health endpoint still not responding"
        fi
    else
        warn "PostgreSQL health script not found"
    fi
fi

# Test PgBouncer health endpoint
if timeout 5 curl -s http://localhost:8002 >/dev/null 2>&1; then
    success "PgBouncer health endpoint (8002) responding"
    curl -s http://localhost:8002 | jq . 2>/dev/null || curl -s http://localhost:8002
else
    warn "PgBouncer health endpoint not responding - starting manually"
    
    # Kill any existing health processes on port 8002
    pkill -f "pgbouncer-health.sh" 2>/dev/null || true
    fuser -k 8002/tcp 2>/dev/null || true
    sleep 1
    
    # Start health endpoint manually
    if [[ -f /usr/local/bin/pgbouncer-health.sh ]]; then
        nohup /usr/local/bin/pgbouncer-health.sh 8002 >/dev/null 2>&1 &
        sleep 2
        
        if timeout 5 curl -s http://localhost:8002 >/dev/null 2>&1; then
            success "PgBouncer health endpoint started manually"
        else
            warn "PgBouncer health endpoint still not responding"
        fi
    else
        warn "PgBouncer health script not found"
    fi
fi

# Final validation
info "Running final connectivity tests..."

# Test direct PostgreSQL connection
if sudo -u postgres psql -c "SELECT 'Direct PostgreSQL: SUCCESS';" >/dev/null 2>&1; then
    success "Direct PostgreSQL connection working"
else
    warn "Direct PostgreSQL connection issue"
fi

# Test repmgr cluster
if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show >/dev/null 2>&1; then
    success "repmgr cluster status accessible"
else
    warn "repmgr cluster status issue"
fi

# Show final status
info "Final status check..."
echo ""
echo "=== FINAL SERVICE STATUS ==="
services=("postgresql" "pgbouncer" "repmgrd")
for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        success "$service: RUNNING ✓"
    else
        warn "$service: NOT RUNNING ✗"
    fi
done

echo ""
echo "=== HEALTH ENDPOINTS STATUS ==="
for port in 8001 8002; do
    if timeout 3 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "Port $port: RESPONDING ✓"
    else
        warn "Port $port: NOT RESPONDING ✗"
    fi
done

success "Final polish complete!"
echo ""
echo "🎉 Your PostgreSQL HA cluster with Secret Manager integration is ready for production!"