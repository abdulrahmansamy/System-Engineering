#!/bin/bash
# Quick fix for PgBouncer setup - Creates user and fixes permissions
# Run this script with sudo on both PostgreSQL servers

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
echo "PgBouncer Quick Fix"
echo "=========================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# Create pgbouncer user if it doesn't exist
if ! id -u pgbouncer >/dev/null 2>&1; then
    info "Creating pgbouncer system user..."
    useradd --system --home-dir /var/lib/pgbouncer --shell /bin/false pgbouncer
    info "✓ Created pgbouncer system user"
else
    info "✓ pgbouncer user already exists"
fi

# Create directories
info "Creating PgBouncer directories..."
mkdir -p /var/lib/pgbouncer /var/log/pgbouncer /etc/pgbouncer

# Set proper ownership
info "Setting proper permissions..."
chown -R pgbouncer:pgbouncer /etc/pgbouncer /var/lib/pgbouncer /var/log/pgbouncer

# Fix permissions on existing files
if [[ -f /etc/pgbouncer/pgbouncer.ini ]]; then
    chown pgbouncer:pgbouncer /etc/pgbouncer/pgbouncer.ini
    chmod 640 /etc/pgbouncer/pgbouncer.ini
    info "✓ Fixed pgbouncer.ini permissions"
fi

if [[ -f /etc/pgbouncer/userlist.txt ]]; then
    chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
    chmod 640 /etc/pgbouncer/userlist.txt
    info "✓ Fixed userlist.txt permissions"
fi

# Install socat for better health check reliability
info "Installing socat for health checks..."
apt-get update >/dev/null 2>&1
apt-get install -y socat >/dev/null 2>&1
info "✓ socat installed"

# Create runtime directory
mkdir -p /var/run/pgbouncer
chown pgbouncer:pgbouncer /var/run/pgbouncer

# Try to start PgBouncer if systemd service exists
if [[ -f /etc/systemd/system/pgbouncer.service ]]; then
    info "Reloading systemd and starting PgBouncer..."
    systemctl daemon-reload
    
    if systemctl start pgbouncer; then
        info "✓ PgBouncer started successfully"
    else
        warn "⚠ Failed to start PgBouncer - check configuration"
        systemctl status pgbouncer || true
    fi
    
    # Try to start health service
    if [[ -f /etc/systemd/system/pgbouncer-health.service ]]; then
        if systemctl start pgbouncer-health.service; then
            info "✓ PgBouncer health service started"
        else
            warn "⚠ Failed to start health service"
        fi
    fi
fi

# Test basic functionality
info "Testing PgBouncer functionality..."

sleep 2

if systemctl is-active --quiet pgbouncer; then
    info "✅ PgBouncer service is running"
    
    # Test connection
    if timeout 5 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        info "✅ PgBouncer is accepting connections on port 6432"
    else
        warn "⚠ PgBouncer is not accepting connections"
    fi
    
    # Test health endpoint
    if timeout 5 curl -s "http://localhost:8002" >/dev/null 2>&1; then
        info "✅ Health endpoint is responding on port 8002"
    else
        warn "⚠ Health endpoint is not responding"
    fi
    
else
    error "❌ PgBouncer service is not running"
fi

echo ""
echo "=========================================="
info "Quick fix completed!"
echo "=========================================="
echo ""
echo "Status:"
echo "• PgBouncer user: $(id pgbouncer 2>/dev/null && echo "✓ Created" || echo "✗ Failed")"
echo "• PgBouncer service: $(systemctl is-active pgbouncer 2>/dev/null || echo "inactive")"
echo "• Health service: $(systemctl is-active pgbouncer-health.service 2>/dev/null || echo "inactive")"
echo ""

if systemctl is-active --quiet pgbouncer; then
    info "🎉 PgBouncer is ready! You can now proceed with load balancer deployment."
else
    warn "⚠ Please check PgBouncer configuration and try restarting manually:"
    echo "  sudo systemctl start pgbouncer"
    echo "  sudo systemctl status pgbouncer"
fi