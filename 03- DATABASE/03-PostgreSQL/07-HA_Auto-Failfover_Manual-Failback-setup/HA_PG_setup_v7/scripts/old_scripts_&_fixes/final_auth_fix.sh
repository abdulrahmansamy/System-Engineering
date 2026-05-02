#!/bin/bash
# Simple Password Sync Fix for PgBouncer
# Ensures userlist.txt has correct password hashes

set -euo pipefail

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
success() { echo -e "\033[0;92m[SUCCESS]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "🔧 Final PgBouncer Authentication Fix"
echo "===================================="

# Get passwords from Secret Manager
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null)
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')

# Get postgres password
PG_SECRET="ipa-nprd-sec-pg-superuser-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${PG_SECRET}/versions/latest:access"
PG_SUPER_PASS=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

# Get repmgr password  
REPMGR_SECRET="ipa-nprd-sec-repmgr-password-01"
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${REPMGR_SECRET}/versions/latest:access"
REPMGR_PASSWORD=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" | jq -r '.payload.data' | base64 -d)

info "✓ Retrieved passwords from Secret Manager"

# Update userlist.txt with correct MD5 hashes
postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)

cat > "/etc/pgbouncer/userlist.txt" <<EOF
;; PgBouncer Final Authentication Fix
;; Generated: $(date)

"postgres" "md5${postgres_md5}"
"repmgr" "md5${repmgr_md5}"

EOF

chown pgbouncer:pgbouncer "/etc/pgbouncer/userlist.txt"
chmod 640 "/etc/pgbouncer/userlist.txt"

# Restart PgBouncer to reload userlist
systemctl restart pgbouncer
sleep 2

# Test connection
if sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'Final authentication fix successful!' as status;" >/dev/null 2>&1; then
    success "🎉 SUCCESS: PgBouncer authentication fixed!"
    success "postgres user can now connect through PgBouncer"
else
    error "Authentication test still failing"
    info "Check: journalctl -u pgbouncer -n 5"
fi

info "✅ Authentication fix completed - run validation: sudo ./comprehensive_validation.sh"