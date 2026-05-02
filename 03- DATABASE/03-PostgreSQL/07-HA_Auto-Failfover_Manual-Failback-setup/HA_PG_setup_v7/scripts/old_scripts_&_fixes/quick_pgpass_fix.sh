#!/bin/bash
# Quick .pgpass fixer for postgres user authentication

set -euo pipefail

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "🔧 Quick .pgpass fix for postgres user authentication"

# Get postgres password from Secret Manager
info "Getting postgres password from Secret Manager..."
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null || echo "unknown")
ORG_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code' 2>/dev/null || echo "ipa")
ENV_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code' 2>/dev/null || echo "nprd")

PG_SUPER_PASS=""

if [[ "$PROJECT_ID" != "unknown" ]]; then
    TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token' 2>/dev/null || echo "")
    
    if [[ -n "$TOKEN" ]]; then
        PG_SECRET="${ORG_CODE}-${ENV_CODE}-sec-pg-superuser-password-01"
        URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
        
        if SECRET_DATA=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" 2>/dev/null); then
            if PG_SUPER_PASS=$(echo "$SECRET_DATA" | jq -r '.payload.data' | base64 -d 2>/dev/null); then
                info "✓ Retrieved postgres password from Secret Manager (length: ${#PG_SUPER_PASS})"
            fi
        fi
    fi
fi

if [[ -z "$PG_SUPER_PASS" ]]; then
    error "Could not retrieve postgres password from Secret Manager"
    exit 1
fi

# Backup current .pgpass
PGPASS_FILE="/var/lib/postgresql/.pgpass"
cp "$PGPASS_FILE" "${PGPASS_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
info "✓ Backed up current .pgpass file"

# Add postgres user entries to existing .pgpass
info "Adding postgres user entries to .pgpass..."

cat >> "$PGPASS_FILE" << EOF

# PostgreSQL postgres user entries (added by quick fix)
localhost:5432:*:postgres:$PG_SUPER_PASS
192.168.14.21:5432:*:postgres:$PG_SUPER_PASS
localhost:6432:*:postgres:$PG_SUPER_PASS
192.168.14.21:6432:*:postgres:$PG_SUPER_PASS
*:5432:*:postgres:$PG_SUPER_PASS
*:6432:*:postgres:$PG_SUPER_PASS
EOF

chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

info "✓ Added postgres user entries to .pgpass"

# Update PgBouncer userlist.txt with postgres user
info "Updating PgBouncer userlist.txt..."
USERLIST_FILE="/etc/pgbouncer/userlist.txt"

if [[ -f "$USERLIST_FILE" ]]; then
    # Generate MD5 hash for postgres user
    POSTGRES_MD5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
    
    # Check if postgres entry already exists
    if grep -q '"postgres"' "$USERLIST_FILE"; then
        # Update existing entry
        sed -i "s/\"postgres\" \".*\"/\"postgres\" \"md5${POSTGRES_MD5}\"/" "$USERLIST_FILE"
        info "✓ Updated existing postgres entry in userlist.txt"
    else
        # Add new entry
        echo "\"postgres\" \"md5${POSTGRES_MD5}\"" >> "$USERLIST_FILE"
        info "✓ Added postgres entry to userlist.txt"
    fi
    
    chown pgbouncer:pgbouncer "$USERLIST_FILE"
    chmod 640 "$USERLIST_FILE"
else
    warn "PgBouncer userlist.txt not found"
fi

# Restart PgBouncer
info "Restarting PgBouncer..."
if systemctl restart pgbouncer; then
    info "✓ PgBouncer restarted"
    sleep 2
else
    error "Failed to restart PgBouncer"
fi

# Test the connection
info "Testing postgres user connection through PgBouncer..."
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer postgres connection working!' as test;" >/dev/null 2>&1; then
    info "✅ SUCCESS: postgres user can now connect through PgBouncer!"
else
    warn "❌ Connection still failing - check PgBouncer logs"
    info "PgBouncer status: $(systemctl is-active pgbouncer)"
    info "Recent PgBouncer logs:"
    journalctl -u pgbouncer -n 5 --no-pager || true
fi

info "🎉 Quick fix completed! Run validation script again."