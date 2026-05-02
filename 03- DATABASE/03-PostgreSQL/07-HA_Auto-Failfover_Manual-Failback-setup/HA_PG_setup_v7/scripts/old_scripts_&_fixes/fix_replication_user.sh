#!/bin/bash
# Simple fix for the remaining replication user issue

set -euo pipefail

echo "PostgreSQL Streaming Replication - Final User Fix"
echo "================================================="

# Check if replication user exists
if sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'replication';" 2>/dev/null | grep -q "^0$"; then
    echo "Creating replication user..."
    
    # Try to create the user with a simpler approach
    if sudo -u postgres createuser --replication --login replication; then
        echo "✅ Successfully created replication user"
        
        # Set the password
        if sudo -u postgres psql -c "ALTER USER replication PASSWORD 'YOUR_REPLICATION_PASSWORD';" >/dev/null 2>&1; then
            echo "✅ Password set for replication user"
        else
            echo "⚠️ Failed to set password - you may need to set it manually"
        fi
    else
        echo "❌ Failed to create replication user"
        echo "Try running: sudo -u postgres createuser --replication --login replication"
    fi
else
    echo "✅ Replication user already exists"
fi

# Verify the user has the right privileges
echo ""
echo "Current replication user status:"
sudo -u postgres psql -c "SELECT rolname, rolreplication, rolcanlogin FROM pg_roles WHERE rolname = 'replication';" 2>/dev/null || echo "No replication user found"

echo ""
echo "To set the replication user password manually, run:"
echo "sudo -u postgres psql -c \"ALTER USER replication PASSWORD 'your_password';\""