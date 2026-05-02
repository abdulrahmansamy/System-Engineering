#!/bin/bash
# One-time script to fix log file permissions for gcp-lb-manager.sh

set -euo pipefail

echo "Fixing GCP Load Balancer Manager permissions..."

# Create log directory if it doesn't exist
if [[ ! -d "/var/log/postgresql" ]]; then
    echo "Creating /var/log/postgresql directory..."
    mkdir -p /var/log/postgresql
fi

# Create log file if it doesn't exist
if [[ ! -f "/var/log/postgresql/lb-manager.log" ]]; then
    echo "Creating lb-manager.log file..."
    touch /var/log/postgresql/lb-manager.log
fi

# Set proper ownership
echo "Setting ownership to postgres:postgres..."
chown -R postgres:postgres /var/log/postgresql

# Set proper permissions
echo "Setting permissions..."
chmod 755 /var/log/postgresql
chmod 644 /var/log/postgresql/lb-manager.log

# Verify
echo ""
echo "Verification:"
ls -la /var/log/postgresql/ | grep lb-manager.log

echo ""
echo "✓ Permissions fixed successfully!"
echo ""
echo "You can now run:"
echo "  sudo -u postgres /usr/local/bin/gcp-lb-manager.sh list"
echo "  sudo -u postgres /usr/local/bin/gcp-lb-manager.sh test"
