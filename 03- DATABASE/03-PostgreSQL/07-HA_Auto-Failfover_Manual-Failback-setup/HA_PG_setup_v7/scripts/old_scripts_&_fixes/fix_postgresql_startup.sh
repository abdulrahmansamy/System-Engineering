#!/bin/bash
# PostgreSQL Version and Startup Fix Script
# Handles version detection and startup issues after Terraform recreate

set -euo pipefail

echo "🔧 PostgreSQL Version and Startup Fix"
echo "====================================="

# Function to detect PostgreSQL version
detect_pg_version() {
    local version
    # Try multiple methods to detect version
    if [[ -d "/usr/lib/postgresql" ]]; then
        version=$(ls /usr/lib/postgresql/ 2>/dev/null | sort -V | tail -1 || echo "")
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi
    
    # Try from psql if available
    if command -v psql >/dev/null 2>&1; then
        version=$(psql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1 || echo "")
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi
    
    # Default fallback
    echo "17"
}

# Detect current PostgreSQL version
PG_VERSION=$(detect_pg_version)
echo "🔍 Detected PostgreSQL version: $PG_VERSION"

# Define paths based on detected version
PG_CLUSTER_NAME="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
PG_CONF="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/postgresql.conf"
PG_HBA="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/pg_hba.conf"

echo "📁 PostgreSQL paths:"
echo "  → Data directory: $PG_DATA_DIR"
echo "  → Config file: $PG_CONF"
echo "  → HBA file: $PG_HBA"

# Check PostgreSQL service status
echo ""
echo "🔍 Checking PostgreSQL service status..."
if systemctl is-active --quiet postgresql; then
    echo "✅ PostgreSQL service is running"
else
    echo "❌ PostgreSQL service is not running"
    echo "🔧 Attempting to start PostgreSQL..."
    
    # Try to start the service
    if systemctl start postgresql; then
        echo "✅ PostgreSQL started successfully"
    else
        echo "❌ Failed to start PostgreSQL, checking for issues..."
        
        # Check if cluster exists
        if [[ ! -d "$PG_DATA_DIR" ]]; then
            echo "❌ PostgreSQL data directory doesn't exist: $PG_DATA_DIR"
            echo "🔧 Creating PostgreSQL cluster..."
            
            # Create the cluster
            if sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/initdb -D "$PG_DATA_DIR"; then
                echo "✅ PostgreSQL cluster created successfully"
                
                # Start the service
                if systemctl start postgresql; then
                    echo "✅ PostgreSQL started successfully after cluster creation"
                else
                    echo "❌ Still failed to start PostgreSQL"
                fi
            else
                echo "❌ Failed to create PostgreSQL cluster"
            fi
        fi
    fi
fi

# Check if PostgreSQL is listening
echo ""
echo "🔍 Checking PostgreSQL connectivity..."
sleep 2

if nc -z localhost 5432 2>/dev/null; then
    echo "✅ PostgreSQL is listening on port 5432"
else
    echo "❌ PostgreSQL is not listening on port 5432"
    echo "🔧 Checking PostgreSQL logs..."
    journalctl -u postgresql -n 10 --no-pager || true
fi

# Test database connectivity
echo ""
echo "🔍 Testing database connectivity..."
if sudo -u postgres psql -c "SELECT version();" >/dev/null 2>&1; then
    echo "✅ Database connectivity working"
    sudo -u postgres psql -c "SELECT version();" | head -2
else
    echo "❌ Database connectivity failed"
    echo "🔧 Checking PostgreSQL status..."
    systemctl status postgresql --no-pager || true
fi

# Check configuration files
echo ""
echo "🔍 Checking configuration files..."
if [[ -f "$PG_CONF" ]]; then
    echo "✅ PostgreSQL config file exists: $PG_CONF"
else
    echo "❌ PostgreSQL config file missing: $PG_CONF"
fi

if [[ -f "$PG_HBA" ]]; then
    echo "✅ PostgreSQL HBA file exists: $PG_HBA"
else
    echo "❌ PostgreSQL HBA file missing: $PG_HBA"
fi

# Show final status
echo ""
echo "📊 Final Status Summary:"
echo "========================"
echo "PostgreSQL Version: $PG_VERSION"
echo "Service Status: $(systemctl is-active postgresql || echo 'inactive')"
echo "Port 5432 Status: $(nc -z localhost 5432 >/dev/null 2>&1 && echo 'listening' || echo 'not listening')"
echo "Database Access: $(sudo -u postgres psql -c 'SELECT 1' >/dev/null 2>&1 && echo 'working' || echo 'failed')"

echo ""
echo "🎯 Next Steps:"
echo "=============="
if systemctl is-active --quiet postgresql && nc -z localhost 5432 2>/dev/null; then
    echo "✅ PostgreSQL is ready! You can now run:"
    echo "   sudo ./postgresql_ha_bootstrap.sh"
else
    echo "❌ PostgreSQL needs manual intervention"
    echo "   Check logs: journalctl -u postgresql -f"
    echo "   Check config: cat $PG_CONF"
fi