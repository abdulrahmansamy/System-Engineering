#!/bin/bash
# PgBouncer Health Service Fix
# Run this to fix health endpoint issues

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "=========================================="
echo "PgBouncer Health Service Fix"
echo "=========================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "Checking health service status..."

# Check if health service is running
if systemctl is-active --quiet pgbouncer-health.service; then
    info "✓ Health service is running"
else
    warn "⚠ Health service is not running, attempting to start..."
    
    # Try to start the service
    if systemctl start pgbouncer-health.service; then
        info "✓ Health service started successfully"
    else
        error "✗ Failed to start health service"
        
        # Show service status for debugging
        echo ""
        warn "Service status:"
        systemctl status pgbouncer-health.service || true
        
        echo ""
        warn "Service logs:"
        journalctl -u pgbouncer-health.service -n 10 --no-pager || true
        
        # Try to restart the service
        info "Attempting to restart health service..."
        systemctl daemon-reload
        
        if systemctl restart pgbouncer-health.service; then
            info "✓ Health service restarted successfully"
        else
            error "✗ Still unable to start health service"
        fi
    fi
fi

# Give it a moment to start
sleep 3

# Test the health endpoint
info "Testing health endpoint..."

if curl -s --connect-timeout 5 "http://localhost:8002" >/dev/null 2>&1; then
    info "✅ Health endpoint is responding!"
    
    # Show the response
    echo ""
    info "Health endpoint response:"
    curl -s "http://localhost:8002" | jq . 2>/dev/null || curl -s "http://localhost:8002"
    
else
    warn "⚠ Health endpoint is still not responding"
    
    # Check if port is listening
    if netstat -ln | grep -q ":8002"; then
        info "✓ Port 8002 is listening"
        
        # Try with different tools
        if command -v wget >/dev/null 2>&1; then
            info "Trying with wget..."
            timeout 5 wget -qO- "http://localhost:8002" || warn "wget also failed"
        fi
        
        if command -v nc >/dev/null 2>&1; then
            info "Trying raw connection..."
            echo "GET / HTTP/1.0" | timeout 3 nc localhost 8002 || warn "nc also failed"
        fi
        
    else
        error "✗ Port 8002 is not listening"
        
        # Check what's using port 8002
        info "Checking port usage..."
        lsof -i :8002 || warn "No process found on port 8002"
    fi
    
    # Manual restart attempt
    info "Attempting manual health service restart..."
    systemctl stop pgbouncer-health.service 2>/dev/null || true
    sleep 2
    
    if systemctl start pgbouncer-health.service; then
        sleep 3
        if curl -s --connect-timeout 5 "http://localhost:8002" >/dev/null 2>&1; then
            info "✅ Health endpoint now responding after restart!"
        else
            warn "⚠ Still not responding after restart"
        fi
    fi
fi

echo ""
echo "=========================================="
info "Health service check completed"
echo "=========================================="

# Final status check
echo ""
info "Final status:"
echo "• PgBouncer service: $(systemctl is-active pgbouncer 2>/dev/null || echo "inactive")"
echo "• Health service: $(systemctl is-active pgbouncer-health.service 2>/dev/null || echo "inactive")"
echo "• Port 6432 (PgBouncer): $(netstat -ln | grep -q ":6432" && echo "✓ Listening" || echo "✗ Not listening")"
echo "• Port 8002 (Health): $(netstat -ln | grep -q ":8002" && echo "✓ Listening" || echo "✗ Not listening")"

# Test PgBouncer connection
echo ""
info "Testing PgBouncer connection..."
if timeout 5 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
    info "✅ PgBouncer connection test successful"
else
    warn "⚠ PgBouncer connection test failed"
fi

echo ""
if systemctl is-active --quiet pgbouncer && systemctl is-active --quiet pgbouncer-health.service; then
    info "🎉 Both PgBouncer and health service are running!"
    info "Ready for load balancer deployment."
else
    warn "⚠ Some services may need attention, but PgBouncer core functionality should work."
fi