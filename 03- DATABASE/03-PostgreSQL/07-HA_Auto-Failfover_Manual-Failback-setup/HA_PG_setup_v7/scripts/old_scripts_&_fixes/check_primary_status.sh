#!/bin/bash
# Primary PostgreSQL Diagnostic and Bootstrap Script
# Run this on the PRIMARY node first

set -euo pipefail

echo "🔍 PostgreSQL Primary Node Diagnostic"
echo "======================================"

# Check PostgreSQL service status
echo "1. Checking PostgreSQL service status..."
if systemctl is-active --quiet postgresql; then
    echo "✅ PostgreSQL service is running"
else
    echo "❌ PostgreSQL service is NOT running"
    echo "🔧 Starting PostgreSQL service..."
    systemctl start postgresql || echo "❌ Failed to start PostgreSQL"
fi

# Check if PostgreSQL is accepting connections
echo ""
echo "2. Testing PostgreSQL connectivity..."
if sudo -u postgres psql -c "SELECT version();" >/dev/null 2>&1; then
    echo "✅ PostgreSQL is accepting connections"
else
    echo "❌ PostgreSQL is not accepting connections"
    echo "🔧 Checking configuration..."
    
    # Check if data directory exists
    PG_DATA_DIR="/var/lib/postgresql/17/main"
    if [[ -d "$PG_DATA_DIR" ]]; then
        echo "✅ Data directory exists: $PG_DATA_DIR"
    else
        echo "❌ Data directory missing: $PG_DATA_DIR"
        echo "🔧 Need to initialize PostgreSQL cluster"
    fi
fi

# Check listen_addresses
echo ""
echo "3. Checking PostgreSQL configuration..."
if sudo -u postgres psql -Atqc "SHOW listen_addresses;" 2>/dev/null; then
    listen_addr=$(sudo -u postgres psql -Atqc "SHOW listen_addresses;" 2>/dev/null || echo "unknown")
    echo "   → listen_addresses: $listen_addr"
    if [[ "$listen_addr" != "*" ]]; then
        echo "⚠️  listen_addresses should be '*' for HA cluster"
    fi
else
    echo "❌ Cannot query PostgreSQL configuration"
fi

# Check if repmgr components exist
echo ""
echo "4. Checking repmgr components..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='repmgr';" postgres 2>/dev/null | grep -q 1; then
    echo "✅ repmgr database exists"
else
    echo "❌ repmgr database does not exist"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='repmgr';" postgres 2>/dev/null | grep -q 1; then
    echo "✅ repmgr user exists"
else
    echo "❌ repmgr user does not exist"
fi

# Check ports
echo ""
echo "5. Checking network connectivity..."
if ss -ln | grep -q ":5432"; then
    echo "✅ PostgreSQL is listening on port 5432"
else
    echo "❌ PostgreSQL is not listening on port 5432"
fi

# Quick fix recommendations
echo ""
echo "🚀 QUICK FIX RECOMMENDATIONS:"
echo "=============================="

if ! systemctl is-active --quiet postgresql; then
    echo "1. Start PostgreSQL: sudo systemctl start postgresql"
fi

if ! sudo -u postgres psql -c "SELECT 1;" >/dev/null 2>&1; then
    echo "2. PostgreSQL needs proper configuration"
    echo "   Run the bootstrap script on PRIMARY FIRST:"
    echo "   sudo ./postgresql_ha_bootstrap.sh"
fi

# Check if this is really the primary
echo ""
echo "6. Verifying this is the primary node..."
ROLE=$(curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_role" 2>/dev/null || echo "unknown")
echo "   → Metadata role: $ROLE"

if [[ "$ROLE" == "primary" ]]; then
    echo "✅ This node is configured as PRIMARY"
    echo ""
    echo "🎯 SOLUTION: Run the PRIMARY bootstrap first:"
    echo "   sudo ./postgresql_ha_bootstrap.sh"
    echo ""
    echo "   Then run the STANDBY bootstrap on the other node."
else
    echo "⚠️  This node is NOT configured as primary (role: $ROLE)"
    echo "    Make sure you're running this on the correct primary node!"
fi