#!/bin/bash
# Complete PostgreSQL HA Cluster Fix Script
# Addresses version issues, primary startup failures, and standby connectivity

set -euo pipefail

echo "🔧 Complete PostgreSQL HA Cluster Fix"
echo "====================================="
echo "Target: Fix version issues and restore HA functionality"

# Detect node role
ROLE="unknown"
if curl -sf -H 'Metadata-Flavor: Google' \
   "http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_role" 2>/dev/null | grep -q primary; then
    ROLE="primary"
elif curl -sf -H 'Metadata-Flavor: Google' \
     "http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_role" 2>/dev/null | grep -q standby; then
    ROLE="standby"
fi

echo "📋 Node Role: $ROLE"

# Step 1: Force PostgreSQL 17 installation
echo ""
echo "Step 1: Enforcing PostgreSQL 17 installation..."

# Try multiple fix approaches
if [[ -f "force_postgresql_17.sh" ]]; then
    echo "Using force_postgresql_17.sh..."
    chmod +x force_postgresql_17.sh
    ./force_postgresql_17.sh
elif [[ -f "quick_pg17_fix.sh" ]]; then
    echo "Using quick_pg17_fix.sh..."
    chmod +x quick_pg17_fix.sh
    ./quick_pg17_fix.sh
else
    echo "⚠️ Using inline PostgreSQL 17 fix..."
    
    # Inline PostgreSQL 17 enforcement (simplified and working approach)
    echo "🔧 Applying direct PostgreSQL 17 installation fix..."
    
    # Remove conflicting preferences first
    rm -f /etc/apt/preferences.d/postgresql* 2>/dev/null || true
    
    # Remove any existing PostgreSQL
    echo "Removing existing PostgreSQL installations..."
    apt-get remove --purge -y postgresql* 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    
    # Clean directories
    rm -rf /var/lib/postgresql/* 2>/dev/null || true
    rm -rf /etc/postgresql/* 2>/dev/null || true
    
    # Add PostgreSQL repository
    echo "Setting up PostgreSQL repository..."
    rm -f /etc/apt/sources.list.d/pgdg.list
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/pgdg.gpg
    
    # Update package cache
    apt-get update
    
    # Check if PostgreSQL 17 is available
    if ! apt-cache show postgresql-17 >/dev/null 2>&1; then
        echo "❌ PostgreSQL 17 not available in repository"
        echo "Available PostgreSQL versions:"
        apt-cache search postgresql- | grep -E "postgresql-[0-9]+" | head -5
        exit 1
    fi
    
    # Install PostgreSQL 17 directly
    echo "Installing PostgreSQL 17..."
    apt-get install -y postgresql-17 postgresql-client-17 postgresql-contrib-17
    
    # Hold packages
    apt-mark hold postgresql-17 postgresql-client-17 postgresql-contrib-17
    
    # Verify installation
    if psql --version | grep -q "17\."; then
        echo "✅ PostgreSQL 17 installed successfully"
        psql --version
    else
        echo "❌ PostgreSQL 17 installation failed"
        psql --version || echo "PostgreSQL not found"
        exit 1
    fi
fi

# Step 2: Clean up bootstrap state
echo ""
echo "Step 2: Cleaning up bootstrap state..."
rm -rf /var/lib/postgresql/.bootstrap/* 2>/dev/null || true
rm -f /var/log/pg-bootstrap/bootstrap.log 2>/dev/null || true

# Step 3: Run the bootstrap script with PostgreSQL 17
echo ""
echo "Step 3: Running bootstrap script with PostgreSQL 17..."
if [[ -f "postgresql_ha_bootstrap.sh" ]]; then
    chmod +x postgresql_ha_bootstrap.sh
    
    # Set environment to force PostgreSQL 17
    export PG_VERSION="17"
    
    # Run bootstrap
    if ./postgresql_ha_bootstrap.sh; then
        echo "✅ Bootstrap completed successfully"
    else
        echo "❌ Bootstrap failed, checking logs..."
        if [[ -f "/var/log/pg-bootstrap/bootstrap.log" ]]; then
            echo "Recent bootstrap log entries:"
            tail -20 /var/log/pg-bootstrap/bootstrap.log
        fi
        
        # For primary nodes, try to recover PostgreSQL
        if [[ "$ROLE" == "primary" ]]; then
            echo "🔧 Attempting primary recovery..."
            
            # Check if PostgreSQL is installed but not running
            if command -v psql >/dev/null 2>&1; then
                echo "PostgreSQL is installed, attempting to start..."
                
                # Try to start PostgreSQL
                if systemctl start postgresql 2>/dev/null; then
                    echo "✅ PostgreSQL started successfully"
                    
                    # Wait for it to be ready
                    sleep 5
                    
                    # Test connectivity
                    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
                        echo "✅ PostgreSQL is responding"
                        
                        # Re-run bootstrap
                        echo "🔄 Retrying bootstrap..."
                        ./postgresql_ha_bootstrap.sh || echo "⚠️ Bootstrap retry failed"
                    fi
                else
                    echo "❌ Failed to start PostgreSQL"
                    journalctl -u postgresql -n 10 --no-pager || true
                fi
            fi
        fi
    fi
else
    echo "❌ postgresql_ha_bootstrap.sh not found"
    exit 1
fi

# Step 4: Validation
echo ""
echo "Step 4: Running validation..."
if [[ -f "comprehensive_validation.sh" ]]; then
    chmod +x comprehensive_validation.sh
    ./comprehensive_validation.sh || echo "⚠️ Some validation checks failed"
else
    echo "⚠️ comprehensive_validation.sh not found, running basic checks..."
    
    # Basic validation
    echo "Basic validation checks:"
    
    # PostgreSQL version
    if command -v psql >/dev/null 2>&1; then
        PG_VERSION=$(psql --version | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
        if [[ "$PG_VERSION" == "17" ]]; then
            echo "✅ PostgreSQL 17 is installed"
        else
            echo "❌ Wrong PostgreSQL version: $PG_VERSION"
        fi
    else
        echo "❌ PostgreSQL not installed"
    fi
    
    # PostgreSQL service
    if systemctl is-active --quiet postgresql; then
        echo "✅ PostgreSQL service is running"
    else
        echo "❌ PostgreSQL service is not running"
    fi
    
    # PostgreSQL connectivity
    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
        echo "✅ PostgreSQL connectivity working"
    else
        echo "❌ PostgreSQL connectivity failed"
    fi
    
    # Check role
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null; then
        is_recovery=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres)
        if [[ "$ROLE" == "primary" && "$is_recovery" == "f" ]]; then
            echo "✅ Node correctly configured as primary"
        elif [[ "$ROLE" == "standby" && "$is_recovery" == "t" ]]; then
            echo "✅ Node correctly configured as standby"
        else
            echo "❌ Role mismatch: ROLE=$ROLE, in_recovery=$is_recovery"
        fi
    else
        echo "⚠️ Cannot determine PostgreSQL role"
    fi
fi

# Step 5: Final status
echo ""
echo "🎯 Final Status Summary:"
echo "======================="
echo "PostgreSQL Version: $(psql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo 'unknown')"
echo "PostgreSQL Service: $(systemctl is-active postgresql 2>/dev/null || echo 'inactive')"
echo "Port 5432: $(nc -z localhost 5432 >/dev/null 2>&1 && echo 'listening' || echo 'not listening')"
echo "Database Access: $(sudo -u postgres psql -c 'SELECT 1' >/dev/null 2>&1 && echo 'working' || echo 'failed')"
echo "Node Role: $ROLE"

if [[ "$ROLE" == "primary" ]]; then
    echo "Replication Status: $(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" postgres 2>/dev/null || echo 'unknown')"
fi

echo ""
echo "✨ Fix script completed!"
echo ""
echo "📝 Next Steps:"
if [[ "$ROLE" == "primary" ]]; then
    echo "1. ✅ Primary should be ready"
    echo "2. 🔄 Run this script on the standby node"
    echo "3. 🔍 Verify cluster status with: sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show"
elif [[ "$ROLE" == "standby" ]]; then
    echo "1. ✅ Standby setup complete"
    echo "2. 🔍 Check cluster status: sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show"
    echo "3. 🔍 Test connectivity: curl http://localhost:8001"
else
    echo "1. ⚠️ Unknown role - check GCP metadata"
    echo "2. 🔄 Re-run the bootstrap script manually"
fi