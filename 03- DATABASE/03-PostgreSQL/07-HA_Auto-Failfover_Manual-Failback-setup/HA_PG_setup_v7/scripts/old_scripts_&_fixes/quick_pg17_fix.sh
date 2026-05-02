#!/bin/bash
# Quick PostgreSQL 17 Installation Fix
# Addresses the package discovery and installation issues

set -euo pipefail

echo "🔧 Quick PostgreSQL 17 Installation Fix"
echo "======================================="

# Remove all PostgreSQL-related preferences that might be blocking package discovery
echo "Step 1: Cleaning up conflicting package preferences..."
rm -f /etc/apt/preferences.d/postgresql* 2>/dev/null || true

# Remove any existing PostgreSQL installations
echo "Step 2: Removing existing PostgreSQL installations..."
apt-get remove --purge -y postgresql* 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Clean directories
rm -rf /var/lib/postgresql/* 2>/dev/null || true
rm -rf /etc/postgresql/* 2>/dev/null || true

# Ensure PostgreSQL repository is properly configured
echo "Step 3: Setting up PostgreSQL repository..."
rm -f /etc/apt/sources.list.d/pgdg.list
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/pgdg.gpg

# Update package cache
echo "Step 4: Updating package cache..."
apt-get update

# Check if PostgreSQL 17 is available
echo "Step 5: Checking PostgreSQL 17 availability..."
if apt-cache show postgresql-17 >/dev/null 2>&1; then
    echo "✅ PostgreSQL 17 packages found"
    apt-cache madison postgresql-17 | head -3
else
    echo "❌ PostgreSQL 17 packages not found"
    echo "Available PostgreSQL versions:"
    apt-cache search postgresql- | grep -E "postgresql-[0-9]+" | head -10
    exit 1
fi

# Install PostgreSQL 17 without restrictive preferences
echo "Step 6: Installing PostgreSQL 17..."
apt-get install -y postgresql-17 postgresql-client-17 postgresql-contrib-17

# Verify installation
echo "Step 7: Verifying installation..."
if psql --version | grep -q "17\."; then
    echo "✅ PostgreSQL 17 installed successfully"
    psql --version
    
    # Set simple preferences to prefer 17 going forward (not blocking)
    cat > /etc/apt/preferences.d/postgresql-17-preferred <<EOF
Package: postgresql-17
Pin: version 17*
Pin-Priority: 1001

Package: postgresql-client-17
Pin: version 17*
Pin-Priority: 1001
EOF
    
    # Hold packages to prevent upgrades
    apt-mark hold postgresql-17 postgresql-client-17 postgresql-contrib-17
    echo "✅ PostgreSQL 17 packages held to prevent upgrades"
    
else
    echo "❌ PostgreSQL 17 installation verification failed"
    psql --version || echo "PostgreSQL not found"
    exit 1
fi

echo ""
echo "🎉 PostgreSQL 17 installation fix completed successfully!"
echo "📋 Next: Run the main bootstrap script"