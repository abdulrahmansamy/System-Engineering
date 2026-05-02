#!/bin/bash
# Fix PgBouncer monitor_user authentication issues
# Run this on both primary and standby nodes if monitor_user cannot connect through PgBouncer

set -euo pipefail

echo "=== Fixing PgBouncer monitor_user Authentication ==="

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

# Get monitor password from Secret Manager cache or prompt
if [[ -f /run/pg-secrets/pg_monitor ]]; then
    MONITOR_PASS=$(cat /run/pg-secrets/pg_monitor)
    info "Loaded monitor password from cache"
else
    read -sp "Enter monitor_user password: " MONITOR_PASS
    echo
fi

# Generate MD5 hash for monitor_user
info "Generating MD5 hash for monitor_user..."
MONITOR_MD5=$(printf '%s%s' "$MONITOR_PASS" "monitor_user" | md5sum | cut -d' ' -f1)

# Update PostgreSQL password to MD5
info "Converting monitor_user password to MD5 in PostgreSQL..."
if sudo -u postgres psql <<EOF
SET password_encryption = 'md5';
ALTER USER monitor_user PASSWORD '${MONITOR_PASS}';
SET password_encryption = 'scram-sha-256';
EOF
then
    info "✓ PostgreSQL password updated"
else
    error "Failed to update PostgreSQL password"
    exit 1
fi

# Update PgBouncer userlist
info "Updating PgBouncer userlist with MD5 hash..."
USERLIST_FILE="/etc/pgbouncer/userlist.txt"

# Backup existing userlist
cp "$USERLIST_FILE" "${USERLIST_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Update or add monitor_user entry
if grep -q "^\"monitor_user\"" "$USERLIST_FILE"; then
    sed -i "s/^\"monitor_user\" \"md5.*\"/\"monitor_user\" \"md5${MONITOR_MD5}\"/" "$USERLIST_FILE"
    info "✓ Updated existing monitor_user entry"
else
    echo "\"monitor_user\" \"md5${MONITOR_MD5}\"" >> "$USERLIST_FILE"
    info "✓ Added monitor_user entry"
fi

# Ensure proper permissions
chown postgres:pgbouncer "$USERLIST_FILE"
chmod 640 "$USERLIST_FILE"

# Grant necessary database permissions
info "Granting database permissions to monitor_user..."
sudo -u postgres psql <<EOF
-- Ensure monitor_user has necessary permissions
GRANT CONNECT ON DATABASE postgres TO monitor_user;
GRANT CONNECT ON DATABASE template1 TO monitor_user;
GRANT USAGE ON SCHEMA public TO monitor_user;
GRANT pg_monitor TO monitor_user;
GRANT pg_read_all_stats TO monitor_user;
EOF

# Update .pgpass file
info "Updating .pgpass file..."
PGPASS_FILE="/var/lib/postgresql/.pgpass"
if ! grep -q "^.*:6432:.*:monitor_user:" "$PGPASS_FILE"; then
    echo "*:6432:*:monitor_user:${MONITOR_PASS}" >> "$PGPASS_FILE"
    info "✓ Added monitor_user to .pgpass"
fi

# Reload PgBouncer
info "Reloading PgBouncer..."
if systemctl reload pgbouncer; then
    info "✓ PgBouncer reloaded"
else
    warn "PgBouncer reload failed, trying restart..."
    systemctl restart pgbouncer
fi

# Wait for PgBouncer to be ready
sleep 3

# Test connection
info "Testing monitor_user connection through PgBouncer..."
if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
   psql -h localhost -p 6432 -U monitor_user -d postgres -c "SELECT 'Connection successful' AS test;" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ SUCCESS: monitor_user can now connect through PgBouncer${NC}"
    exit 0
else
    error "✗ FAILED: monitor_user still cannot connect through PgBouncer"
    
    # Additional diagnostics
    echo ""
    echo "=== Diagnostics ==="
    echo "1. Check PgBouncer logs:"
    echo "   tail -20 /var/log/pgbouncer/pgbouncer.log"
    echo ""
    echo "2. Verify userlist entry:"
    echo "   grep monitor_user /etc/pgbouncer/userlist.txt"
    echo ""
    echo "3. Test direct PostgreSQL connection:"
    echo "   sudo -u postgres psql -U monitor_user -d postgres -c 'SELECT 1;'"
    
    exit 1
fi
