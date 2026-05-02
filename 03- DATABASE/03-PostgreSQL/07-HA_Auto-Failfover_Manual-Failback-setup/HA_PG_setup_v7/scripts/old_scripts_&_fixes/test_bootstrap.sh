#!/bin/bash
# Test script for PostgreSQL HA bootstrap
# This script runs basic tests to verify bootstrap functionality

set -euo pipefail

echo "=== PostgreSQL HA Bootstrap Test ==="
echo "Testing bootstrap script functionality..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "❌ This test script must be run as root"
  exit 1
fi

# Test basic function availability
echo "✓ Running as root"

# Test metadata detection
echo "🔍 Testing metadata detection..."
if curl -sf -H 'Metadata-Flavor: Google' \
   'http://metadata.google.internal/computeMetadata/v1/project/project-id' >/dev/null 2>&1; then
  echo "✓ GCP metadata service accessible"
else
  echo "❌ GCP metadata service not accessible"
fi

# Test package availability
echo "🔍 Testing package management..."
if command -v apt-get >/dev/null 2>&1; then
  echo "✓ apt-get available"
else
  echo "❌ apt-get not available"
fi

# Test secret cache directory creation
SECRET_CACHE_DIR="/run/pg-secrets"
if mkdir -p "$SECRET_CACHE_DIR" 2>/dev/null; then
  echo "✓ Secret cache directory creation successful"
  rmdir "$SECRET_CACHE_DIR" 2>/dev/null || true
else
  echo "❌ Cannot create secret cache directory"
fi

# Test log directory creation
LOG_DIR="/var/log/pg-bootstrap"
if mkdir -p "$LOG_DIR" 2>/dev/null; then
  echo "✓ Log directory creation successful"
else
  echo "❌ Cannot create log directory"
fi

echo "=== Test Complete ==="
echo "If all tests passed, the bootstrap script should work correctly"