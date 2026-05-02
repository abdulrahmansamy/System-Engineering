#!/bin/bash
# Quick Health Endpoint Fix
# Run on both servers to fix the health endpoints

set -euo pipefail

echo "🔧 Quick Health Endpoint Fix"
echo "============================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

echo "🔄 Restarting health services..."

# Stop services
systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true
pkill -f "health.sh" 2>/dev/null || true
sleep 2

# Reload daemon
systemctl daemon-reload

# Start services
systemctl start pg-ha-health.service
systemctl start pgbouncer-health.service

# Wait for services to start
sleep 5

echo "🧪 Testing health endpoints..."

# Test PostgreSQL health
if timeout 10 curl -sf http://localhost:8001 | jq . 2>/dev/null; then
    echo "✅ PostgreSQL health endpoint working!"
else
    echo "❌ PostgreSQL health endpoint still not working"
fi

# Test PgBouncer health  
if timeout 10 curl -sf http://localhost:8002 | jq . 2>/dev/null; then
    echo "✅ PgBouncer health endpoint working!"
else
    echo "❌ PgBouncer health endpoint still not working"
fi

echo
echo "🎉 Health endpoint fix complete!"
echo "📊 Service status:"
echo "PostgreSQL Health: $(systemctl is-active pg-ha-health.service)"
echo "PgBouncer Health:  $(systemctl is-active pgbouncer-health.service)"