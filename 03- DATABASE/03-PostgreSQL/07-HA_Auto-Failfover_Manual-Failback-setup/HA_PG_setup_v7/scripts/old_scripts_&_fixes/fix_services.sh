#!/bin/bash
# Quick Service Diagnostic and Fix Script
# Fixes repmgrd and health endpoint issues

set -euo pipefail

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }

info "🔧 PostgreSQL HA Service Diagnostic and Fix"

# Check repmgrd status
info "Checking repmgrd service status..."
if systemctl is-active --quiet repmgrd; then
    success "repmgrd is running"
else
    warn "repmgrd is not running, attempting to fix..."
    
    # Check repmgr configuration
    if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf node check >/dev/null 2>&1; then
        info "Repmgr configuration is valid"
        
        # Restart the service with better error handling
        systemctl daemon-reload
        systemctl stop repmgrd 2>/dev/null || true
        sleep 2
        
        if systemctl start repmgrd; then
            success "repmgrd service started successfully"
        else
            error "Failed to start repmgrd, checking logs..."
            journalctl -u repmgrd --no-pager -n 10
        fi
    else
        error "Repmgr configuration issue detected"
        sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf node check || true
    fi
fi

# Check health endpoints
info "Checking health endpoints..."

# PostgreSQL health endpoint
if timeout 5 curl -s http://localhost:8001 >/dev/null 2>&1; then
    success "PostgreSQL health endpoint (8001) is responding"
else
    warn "PostgreSQL health endpoint not responding, checking service..."
    systemctl status pg-ha-health.service --no-pager -n 5 || true
    
    # Restart health service
    systemctl daemon-reload
    systemctl restart pg-ha-health.service || true
    sleep 2
    
    if timeout 5 curl -s http://localhost:8001 >/dev/null 2>&1; then
        success "PostgreSQL health endpoint fixed"
    else
        error "PostgreSQL health endpoint still not responding"
    fi
fi

# Test PgBouncer connectivity
info "Testing PgBouncer connectivity..."
if sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    success "PgBouncer connectivity working"
else
    warn "PgBouncer connectivity issue detected"
    info "Checking .pgpass and userlist configuration..."
    
    # Check if userlist exists and has entries
    if [[ -f "/etc/pgbouncer/userlist.txt" ]]; then
        user_count=$(grep -c '".*"' /etc/pgbouncer/userlist.txt 2>/dev/null || echo 0)
        info "PgBouncer userlist has $user_count user entries"
    else
        error "PgBouncer userlist.txt missing!"
    fi
    
    # Test direct PostgreSQL connection
    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
        info "Direct PostgreSQL connection works"
    else
        error "Direct PostgreSQL connection failed"
    fi
fi

# Final status summary
info "=== SERVICE STATUS SUMMARY ==="
systemctl is-active --quiet postgresql && success "PostgreSQL: RUNNING" || warn "PostgreSQL: NOT RUNNING"
systemctl is-active --quiet pgbouncer && success "PgBouncer: RUNNING" || warn "PgBouncer: NOT RUNNING" 
systemctl is-active --quiet repmgrd && success "repmgrd: RUNNING" || warn "repmgrd: NOT RUNNING"
systemctl is-active --quiet pg-ha-health && success "PG Health: RUNNING" || warn "PG Health: NOT RUNNING"

success "Service diagnostic and fix complete!"