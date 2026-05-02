#!/bin/bash
# Quick PgBouncer Authentication Fix
# Fixes authentication issues when passwords are out of sync

set -euo pipefail

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;92m[SUCCESS]\033[0m $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "🔧 Quick PgBouncer Authentication Fix"
echo "====================================="

# Get metadata
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null || echo "unknown")
ORG_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code' 2>/dev/null || echo "ipa")
ENV_CODE=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code' 2>/dev/null || echo "nprd")

# Get postgres password from Secret Manager
info "Getting postgres password from Secret Manager..."
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token' 2>/dev/null || echo "")

if [[ -n "$TOKEN" ]]; then
    PG_SECRET="${ORG_CODE}-${ENV_CODE}-sec-pg-superuser-password-01"
    URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
    
    if SECRET_DATA=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" 2>/dev/null); then
        if PG_SUPER_PASS=$(echo "$SECRET_DATA" | jq -r '.payload.data' | base64 -d 2>/dev/null); then
            success "✓ Retrieved postgres password (length: ${#PG_SUPER_PASS})"
        else
            error "Failed to decode postgres password"
            exit 1
        fi
    else
        error "Failed to retrieve postgres password from Secret Manager"
        exit 1
    fi
else
    error "Failed to get access token"
    exit 1
fi

# Update PgBouncer userlist.txt with correct postgres password
info "Updating PgBouncer userlist.txt..."

USERLIST_FILE="/etc/pgbouncer/userlist.txt"
cp "$USERLIST_FILE" "${USERLIST_FILE}.backup.quickfix.$(date +%Y%m%d-%H%M%S)"

# Get existing content except postgres line
grep -v '"postgres"' "$USERLIST_FILE" > "${USERLIST_FILE}.tmp" || echo ";; Updated userlist" > "${USERLIST_FILE}.tmp"

# Generate new postgres MD5 hash
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)

# Add updated postgres entry
echo "\"postgres\" \"md5${postgres_md5}\"" >> "${USERLIST_FILE}.tmp"

# Replace the file
mv "${USERLIST_FILE}.tmp" "$USERLIST_FILE"
chown pgbouncer:pgbouncer "$USERLIST_FILE"
chmod 640 "$USERLIST_FILE"

success "✓ Updated postgres entry in PgBouncer userlist"

# Update .pgpass file with postgres entries
info "Updating .pgpass file..."
PGPASS_FILE="/var/lib/postgresql/.pgpass"
cp "$PGPASS_FILE" "${PGPASS_FILE}.backup.quickfix.$(date +%Y%m%d-%H%M%S)"

# Remove existing postgres entries and add new ones
grep -v ":postgres:" "$PGPASS_FILE" > "${PGPASS_FILE}.tmp" || true

cat >> "${PGPASS_FILE}.tmp" << EOF

# Updated postgres user entries (quick fix)
localhost:5432:*:postgres:${PG_SUPER_PASS}
192.168.14.21:5432:*:postgres:${PG_SUPER_PASS}
192.168.14.22:5432:*:postgres:${PG_SUPER_PASS}
localhost:6432:*:postgres:${PG_SUPER_PASS}
192.168.14.21:6432:*:postgres:${PG_SUPER_PASS}
192.168.14.22:6432:*:postgres:${PG_SUPER_PASS}
*:5432:*:postgres:${PG_SUPER_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
EOF

mv "${PGPASS_FILE}.tmp" "$PGPASS_FILE"
chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

success "✓ Updated .pgpass file with postgres entries"

# Restart PgBouncer
info "Restarting PgBouncer..."
if systemctl restart pgbouncer; then
    success "✓ PgBouncer restarted"
    sleep 2
else
    error "Failed to restart PgBouncer"
    exit 1
fi

# Test connection
info "Testing postgres connection through PgBouncer..."
if sudo -u postgres env PGPASSFILE="$PGPASS_FILE" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'Quick fix successful!' as status;" >/dev/null 2>&1; then
    success "🎉 SUCCESS: postgres user can now connect through PgBouncer!"
    success "Authentication fix completed successfully"
else
    warn "❌ Connection still failing"
    info "Check PgBouncer logs: journalctl -u pgbouncer -n 10"
    exit 1
fi

info "Run enhanced security script again if needed: sudo ./enhanced_pgbouncer_security_fix.sh"