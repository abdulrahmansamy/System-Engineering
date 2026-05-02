#!/bin/bash
# Quick fix for primary pg_hba.conf to allow standby connections
# Run this on the PRIMARY node only

set -euo pipefail

STANDBY_IP="192.168.14.22"
REPMGR_USER="repmgr"
REPMGR_DB="repmgr"

# Find pg_hba.conf file
PG_HBA="/etc/postgresql/17/main/pg_hba.conf"
if [[ ! -f "$PG_HBA" ]]; then
    PG_HBA="/var/lib/postgresql/17/main/pg_hba.conf"
fi

if [[ ! -f "$PG_HBA" ]]; then
    echo "ERROR: Cannot find pg_hba.conf"
    exit 1
fi

echo "Adding standby authentication entries to $PG_HBA"

# Check if standby IP is already configured
if grep -q "$STANDBY_IP" "$PG_HBA"; then
    echo "Standby IP already in pg_hba.conf, updating entries..."
    # Remove existing standby entries
    sed -i "/${STANDBY_IP}/d" "$PG_HBA"
fi

# Add standby authentication entries with MD5 for repmgr
cat >> "$PG_HBA" <<EOF
# Standby node authentication entries - Added by fix script
host    ${REPMGR_DB}    ${REPMGR_USER}  ${STANDBY_IP}/32                md5
host    replication     replication     ${STANDBY_IP}/32                scram-sha-256
host    replication     ${REPMGR_USER}  ${STANDBY_IP}/32                md5
host    all             postgres        ${STANDBY_IP}/32                md5
host    all             pgbouncer_admin ${STANDBY_IP}/32                md5

EOF

echo "✓ Added standby authentication entries"

# Reload PostgreSQL
systemctl reload postgresql

echo "✓ PostgreSQL configuration reloaded"
echo "✓ Standby should now be able to connect"

# Test the configuration
echo "Testing repmgr connection from standby perspective..."
if sudo -u postgres psql -h localhost -U "$REPMGR_USER" -d "$REPMGR_DB" -c "SELECT 'Primary repmgr connection test successful' as status;" 2>/dev/null; then
    echo "✓ Local repmgr connection test passed"
else
    echo "✗ Local repmgr connection test failed"
fi

echo "Primary pg_hba.conf fix complete!"