#!/bin/bash
# Fix standby to use replication slot
# Run this on the STANDBY node to activate the replication slot

set -euo pipefail

echo "=== Fixing Standby to Use Replication Slot ==="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

# Detect PostgreSQL version and paths
PG_VERSION="17"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"

# Check if this is actually a standby
info "Checking if this is a standby node..."
if ! sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
    error "This is not a standby node (not in recovery mode)"
    exit 1
fi

info "✓ Confirmed this is a standby node"

# Check current primary_slot_name
info "Checking current replication slot configuration..."
current_slot=$(sudo -u postgres psql -Atqc "SHOW primary_slot_name;" 2>/dev/null || echo "")

if [[ "$current_slot" == "pgstandby1" ]]; then
    info "✓ Replication slot already configured correctly"
    exit 0
fi

if [[ -z "$current_slot" || "$current_slot" == "" ]]; then
    warn "Replication slot not configured, will add it now"
else
    warn "Current slot: $current_slot (will change to pgstandby1)"
fi

# Backup postgresql.auto.conf
info "Backing up postgresql.auto.conf..."
cp "${PG_DATA_DIR}/postgresql.auto.conf" "${PG_DATA_DIR}/postgresql.auto.conf.backup.$(date +%Y%m%d_%H%M%S)"

# Add or update primary_slot_name in postgresql.auto.conf
info "Updating postgresql.auto.conf with replication slot..."

if grep -q "primary_slot_name" "${PG_DATA_DIR}/postgresql.auto.conf"; then
    # Replace existing entry
    sed -i "s/^primary_slot_name.*/primary_slot_name = 'pgstandby1'/" "${PG_DATA_DIR}/postgresql.auto.conf"
    info "✓ Updated existing primary_slot_name entry"
else
    # Add new entry
    echo "primary_slot_name = 'pgstandby1'" >> "${PG_DATA_DIR}/postgresql.auto.conf"
    info "✓ Added primary_slot_name entry"
fi

# Restart PostgreSQL to apply changes
info "Restarting PostgreSQL to apply replication slot configuration..."
systemctl restart postgresql

# Wait for PostgreSQL to be ready
info "Waiting for PostgreSQL to restart..."
sleep 5

retry_count=0
while ! sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; do
    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge 30 ]]; then
        error "PostgreSQL failed to start after restart"
        exit 1
    fi
    sleep 2
done

info "✓ PostgreSQL restarted successfully"

# Verify replication slot is now active
info "Verifying replication slot configuration..."
sleep 5  # Give replication a moment to reconnect

new_slot=$(sudo -u postgres psql -Atqc "SHOW primary_slot_name;" 2>/dev/null || echo "")
if [[ "$new_slot" == "pgstandby1" ]]; then
    echo -e "${GREEN}✓ SUCCESS: Replication slot configured: $new_slot${NC}"
else
    error "Failed to configure replication slot. Current value: $new_slot"
    exit 1
fi

# Check if slot is active on primary
info "Checking if replication slot is active on primary..."
PRIMARY_HOST=$(sudo -u postgres psql -Atqc "SELECT conninfo FROM pg_stat_wal_receiver;" 2>/dev/null | grep -oP 'host=\K[^ ]+' || echo "")

if [[ -n "$PRIMARY_HOST" ]]; then
    info "Primary host: $PRIMARY_HOST"
    
    # Test connection to primary
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
       psql -h "$PRIMARY_HOST" -U postgres -Atqc "SELECT slot_name, active FROM pg_replication_slots WHERE slot_name = 'pgstandby1';" 2>/dev/null; then
        echo ""
        echo -e "${GREEN}✓ Replication slot status verified on primary${NC}"
    else
        warn "Could not verify slot status on primary (may need credentials)"
    fi
else
    warn "Could not determine primary host"
fi

# Show replication status
info "Current replication status:"
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_wal_receiver;" 2>/dev/null || true

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Replication Slot Configuration Complete              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "1. Verify on PRIMARY that slot is active:"
echo "   sudo -u postgres psql -c \"SELECT slot_name, active FROM pg_replication_slots;\""
echo ""
echo "2. Check replication lag:"
echo "   sudo -u postgres psql -c \"SELECT now() - pg_last_xact_replay_timestamp() AS lag;\""
