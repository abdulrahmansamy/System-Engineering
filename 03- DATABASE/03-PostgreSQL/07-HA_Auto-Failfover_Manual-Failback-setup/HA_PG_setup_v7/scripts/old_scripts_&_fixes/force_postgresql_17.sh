#!/bin/bash
# PostgreSQL Version 17 Enforcement Script
# Forcefully removes PostgreSQL 18 and installs PostgreSQL 17

set -euo pipefail

echo "🔧 PostgreSQL Version 17 Enforcement"
echo "===================================="

# Function to detect current PostgreSQL version
detect_pg_version() {
    if command -v psql >/dev/null 2>&1; then
        psql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1 || echo "none"
    else
        echo "none"
    fi
}

# Current version check
CURRENT_VERSION=$(detect_pg_version)
echo "🔍 Current PostgreSQL version: $CURRENT_VERSION"

if [[ "$CURRENT_VERSION" == "17" ]]; then
    echo "✅ PostgreSQL 17 is already installed correctly"
    exit 0
fi

if [[ "$CURRENT_VERSION" != "none" && "$CURRENT_VERSION" != "17" ]]; then
    echo "❌ Wrong PostgreSQL version detected: $CURRENT_VERSION"
    echo "🔧 Forcefully removing and reinstalling with PostgreSQL 17..."
    
    # Stop all PostgreSQL services
    echo "🛑 Stopping PostgreSQL services..."
    systemctl stop postgresql* 2>/dev/null || true
    systemctl disable postgresql* 2>/dev/null || true
    
    # Remove all PostgreSQL packages
    echo "🗑️ Removing all PostgreSQL packages..."
    apt-get remove --purge -y postgresql* 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    
    # Clean up directories
    echo "🧹 Cleaning up PostgreSQL directories..."
    rm -rf /var/lib/postgresql/* 2>/dev/null || true
    rm -rf /etc/postgresql/* 2>/dev/null || true
    rm -rf /var/log/postgresql/* 2>/dev/null || true
    
    # Remove repository preferences that may cause issues
    rm -f /etc/apt/preferences.d/postgresql* 2>/dev/null || true
fi

# Set up package preferences for PostgreSQL 17
echo "📋 Setting package preferences for PostgreSQL 17..."
cat > /etc/apt/preferences.d/postgresql-17-only <<EOF
# Force PostgreSQL 17 installation only
Package: postgresql-17
Pin: version 17*
Pin-Priority: 1001

Package: postgresql-client-17  
Pin: version 17*
Pin-Priority: 1001

Package: postgresql-17-repmgr
Pin: version *
Pin-Priority: 1001

# Block PostgreSQL 18 and other versions
Package: postgresql-18*
Pin: version *
Pin-Priority: -10

Package: postgresql-16*
Pin: version *
Pin-Priority: -10

Package: postgresql-15*
Pin: version *
Pin-Priority: -10

Package: postgresql-common
Pin: version *
Pin-Priority: 1000
EOF

echo "✅ Package preferences set to force PostgreSQL 17"

# Update package cache
echo "🔄 Updating package cache..."
apt-get update

# Install PostgreSQL 17 with explicit version constraints
echo "📦 Installing PostgreSQL 17 with version constraints..."
export DEBIAN_FRONTEND=noninteractive

# Install packages one by one with explicit versions
apt-get install -y --no-install-recommends \
    postgresql-common \
    postgresql-client-common

# Check available PostgreSQL 17 packages
echo "🔍 Available PostgreSQL 17 packages:"
apt-cache madison postgresql-17 | head -3

# Install PostgreSQL 17 specifically
apt-get install -y --no-install-recommends \
    postgresql-17 \
    postgresql-client-17 \
    postgresql-contrib-17

# Hold the packages to prevent upgrades
echo "🔒 Holding PostgreSQL 17 packages..."
apt-mark hold postgresql-17 postgresql-client-17 postgresql-contrib-17

# Verify installation
FINAL_VERSION=$(detect_pg_version)
echo "✅ Final PostgreSQL version: $FINAL_VERSION"

if [[ "$FINAL_VERSION" != "17" ]]; then
    echo "❌ FAILED: PostgreSQL 17 installation failed - got version $FINAL_VERSION"
    echo "🔧 Available PostgreSQL packages:"
    dpkg -l | grep postgresql
    exit 1
fi

# Create and start default cluster
echo "🏗️ Creating PostgreSQL 17 cluster..."
if [[ ! -d "/var/lib/postgresql/17/main" ]]; then
    sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/17/main
fi

# Enable and start PostgreSQL
echo "🚀 Starting PostgreSQL 17..."
systemctl enable postgresql
systemctl start postgresql

# Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
sleep 5

# Test connectivity
if sudo -u postgres psql -c "SELECT version();" >/dev/null 2>&1; then
    echo "✅ PostgreSQL 17 is running and accessible"
    sudo -u postgres psql -c "SELECT version();" | head -2
else
    echo "❌ PostgreSQL 17 connectivity test failed"
    systemctl status postgresql
    exit 1
fi

echo ""
echo "🎉 PostgreSQL 17 enforcement completed successfully!"
echo "📊 Final status:"
echo "   Version: $(detect_pg_version)"
echo "   Service: $(systemctl is-active postgresql)"
echo "   Port 5432: $(nc -z localhost 5432 >/dev/null 2>&1 && echo 'listening' || echo 'not listening')"