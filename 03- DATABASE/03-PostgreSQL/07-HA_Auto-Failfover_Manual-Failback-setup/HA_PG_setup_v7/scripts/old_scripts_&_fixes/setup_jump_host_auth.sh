#!/bin/bash
# Setup Authentication for Jump Host
# Creates .pgpass file with correct credentials for load balancer testing

set -euo pipefail

echo "🔧 Setting up PostgreSQL Authentication for Jump Host"
echo "===================================================="

# Get the postgres password from the primary node
echo "📋 Getting PostgreSQL credentials..."

# The password should be available on the primary node
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

echo "Attempting to get password from primary node..."

# Try to get the password from the bootstrap node's .pgpass file
POSTGRES_PASSWORD=""

# Method 1: Try to copy .pgpass from primary node
echo "   Copying .pgpass from primary node..."
if gcloud compute scp --project=ipa-nprd-svc-db-01 \
   ipa-nprd-ha-pg-primary-01:/var/lib/postgresql/.pgpass \
   /tmp/pg_primary_pgpass --zone=me-central2-a 2>/dev/null; then
    
    echo "   ✅ Retrieved .pgpass from primary node"
    
    # Extract postgres password
    POSTGRES_PASSWORD=$(grep "postgres:" /tmp/pg_primary_pgpass | cut -d: -f5 | head -1 || echo "")
    
    if [[ -n "$POSTGRES_PASSWORD" ]]; then
        echo "   ✅ Found postgres password (length: ${#POSTGRES_PASSWORD})"
    else
        echo "   ❌ Could not extract postgres password"
    fi
else
    echo "   ❌ Could not retrieve .pgpass from primary node"
fi

# Method 2: If no password found, try a default or prompt
if [[ -z "$POSTGRES_PASSWORD" ]]; then
    echo ""
    echo "⚠️  Could not automatically retrieve password."
    echo "   Please check the postgres password on the primary node:"
    echo "   gcloud compute ssh ipa-nprd-ha-pg-primary-01 --zone=me-central2-a --project=ipa-nprd-svc-db-01"
    echo "   sudo cat /var/lib/postgresql/.pgpass"
    echo ""
    read -sp "Enter postgres password: " POSTGRES_PASSWORD
    echo ""
fi

if [[ -z "$POSTGRES_PASSWORD" ]]; then
    echo "❌ No password provided. Cannot set up authentication."
    exit 1
fi

# Create .pgpass file for current user
echo "📝 Creating .pgpass file..."

cat > ~/.pgpass << EOF
# PostgreSQL HA .pgpass file for jump host
# Format: hostname:port:database:username:password

# Direct backend connections
$PRIMARY_IP:6432:*:postgres:$POSTGRES_PASSWORD
$STANDBY_IP:6432:*:postgres:$POSTGRES_PASSWORD
$PRIMARY_IP:5432:*:postgres:$POSTGRES_PASSWORD
$STANDBY_IP:5432:*:postgres:$POSTGRES_PASSWORD

# Load balancer connections
192.168.14.20:6432:*:postgres:$POSTGRES_PASSWORD
192.168.14.19:6432:*:postgres:$POSTGRES_PASSWORD

# DNS names (if used)
pg-write.db.internal.nprd.ipa.edu.sa:6432:*:postgres:$POSTGRES_PASSWORD
pg-read.db.internal.nprd.ipa.edu.sa:6432:*:postgres:$POSTGRES_PASSWORD

# Localhost connections
localhost:6432:*:postgres:$POSTGRES_PASSWORD
localhost:5432:*:postgres:$POSTGRES_PASSWORD
EOF

# Set correct permissions
chmod 600 ~/.pgpass
echo "   ✅ Created ~/.pgpass with correct permissions"

# Test the authentication
echo ""
echo "🧪 Testing Authentication..."

test_connection() {
    local host="$1"
    local port="$2"
    local name="$3"
    
    echo -n "   Testing $name ($host:$port)... "
    
    if timeout 10 psql -h "$host" -p "$port" -U postgres -d postgres -c "SELECT 'Connected successfully';" >/dev/null 2>&1; then
        echo "✅ SUCCESS"
        return 0
    else
        echo "❌ FAILED"
        return 1
    fi
}

# Test direct backend connections
test_connection "$PRIMARY_IP" "6432" "Primary PgBouncer"
test_connection "$STANDBY_IP" "6432" "Standby PgBouncer"

# Test load balancer connections
test_connection "192.168.14.20" "6432" "Write Load Balancer"
test_connection "192.168.14.19" "6432" "Read Load Balancer"

echo ""
echo "✅ Authentication setup completed!"
echo ""
echo "🚀 You can now run these tests:"
echo "   psql -h 192.168.14.20 -p 6432 -U postgres -d postgres -c \"SELECT 'Write LB', pg_is_in_recovery();\""
echo "   psql -h 192.168.14.19 -p 6432 -U postgres -d postgres -c \"SELECT 'Read LB', pg_is_in_recovery();\""

# Clean up temporary file
rm -f /tmp/pg_primary_pgpass

echo ""
echo "📋 .pgpass file created at: ~/.pgpass"
echo "   File permissions: $(ls -l ~/.pgpass | awk '{print $1}')"
echo "   File size: $(wc -l ~/.pgpass | awk '{print $1}') lines"