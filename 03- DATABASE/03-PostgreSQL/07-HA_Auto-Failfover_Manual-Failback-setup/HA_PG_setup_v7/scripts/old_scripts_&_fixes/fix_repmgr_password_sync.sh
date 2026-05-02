#!/bin/bash
# Fix repmgr password synchronization between primary and standby
# Run this on the PRIMARY node to sync the repmgr password with Secret Manager

set -euo pipefail

echo "🔧 PRIMARY Repmgr Password Synchronization Fix"
echo "==============================================="

# Get metadata
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id 2>/dev/null || echo "ipa-nprd-svc-db-01")
ORG_CODE=$(curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code" 2>/dev/null || echo "ipa")
ENV_CODE=$(curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code" 2>/dev/null || echo "nprd")

REPMGR_SECRET_ID="${ORG_CODE}-${ENV_CODE}-sec-repmgr-password-01"

echo "🔐 Getting repmgr password from Secret Manager..."
echo "  → Project: $PROJECT_ID"
echo "  → Secret ID: $REPMGR_SECRET_ID"

# Get access token
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | \
  jq -r '.access_token' 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
  echo "❌ Failed to get access token"
  exit 1
fi

# Get secret
URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${REPMGR_SECRET_ID}/versions/latest:access"
BODY=$(curl -sf -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$URL" 2>/dev/null || true)

if [[ -z "$BODY" ]]; then
  echo "❌ Failed to retrieve secret from Secret Manager"
  exit 1
fi

REPMGR_PASSWORD=$(echo "$BODY" | jq -r '.payload.data' | base64 -d 2>/dev/null || true)

if [[ -z "$REPMGR_PASSWORD" ]]; then
  echo "❌ Failed to decode secret"
  exit 1
fi

echo "✅ Retrieved repmgr password from Secret Manager (length: ${#REPMGR_PASSWORD} characters)"

# Update repmgr user password in PostgreSQL
echo "🔄 Updating repmgr user password in PostgreSQL..."

# Test current connection
if sudo -u postgres psql -c "\q" >/dev/null 2>&1; then
  echo "✅ PostgreSQL is accessible"
else
  echo "❌ PostgreSQL is not accessible"
  exit 1
fi

# Update the password
if sudo -u postgres psql -c "ALTER ROLE repmgr PASSWORD '$REPMGR_PASSWORD';" postgres >/dev/null 2>&1; then
  echo "✅ Updated repmgr user password in PostgreSQL"
else
  echo "❌ Failed to update repmgr user password"
  exit 1
fi

# Test the connection from primary to verify password works
echo "🧪 Testing repmgr connection locally..."

# Create a test .pgpass entry
TEST_PGPASS="/tmp/test_pgpass"
cat > "$TEST_PGPASS" <<EOF
localhost:5432:repmgr:repmgr:${REPMGR_PASSWORD}
127.0.0.1:5432:repmgr:repmgr:${REPMGR_PASSWORD}
192.168.14.21:5432:repmgr:repmgr:${REPMGR_PASSWORD}
EOF
chmod 600 "$TEST_PGPASS"

if sudo -u postgres env PGPASSFILE="$TEST_PGPASS" psql -h localhost -U repmgr -d repmgr -c "SELECT 'Password sync successful!' as status;" 2>/dev/null; then
  echo "✅ Repmgr password is working correctly on primary"
else
  echo "❌ Repmgr password test failed on primary"
  rm -f "$TEST_PGPASS"
  exit 1
fi

rm -f "$TEST_PGPASS"

echo "🎉 Repmgr password synchronization completed successfully!"
echo ""
echo "Next steps:"
echo "1. The repmgr password on the primary now matches Secret Manager"
echo "2. Run the standby bootstrap again: sudo ./postgresql_ha_bootstrap.sh"
echo "3. The standby should now be able to connect to the primary's repmgr database"