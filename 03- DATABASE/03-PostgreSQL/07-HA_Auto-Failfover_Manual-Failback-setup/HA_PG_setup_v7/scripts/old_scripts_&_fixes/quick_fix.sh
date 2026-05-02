#!/bin/bash
# Quick fix script to install PostgreSQL 17 and run bootstrap
# This addresses the immediate issue where PostgreSQL is not installed

set -euo pipefail

echo "=== PostgreSQL 17 Quick Fix and Bootstrap ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "❌ This script must be run as root"
  exit 1
fi

# Install prerequisites
echo "📦 Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wget ca-certificates gnupg lsb-release curl jq netcat-openbsd socat

# Add PostgreSQL official repository
echo "📦 Adding PostgreSQL 17 repository..."
if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
  echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update
fi

# Install PostgreSQL 17
echo "📦 Installing PostgreSQL 17..."
apt-get install -y postgresql-17 postgresql-client-17 postgresql-contrib-17 postgresql-17-repmgr

echo "✓ PostgreSQL 17 installed successfully"

# Run the bootstrap script
echo "🚀 Running PostgreSQL HA bootstrap..."
if [[ -f "/home/asamy_nominations_ipa_edu_sa/postgresql_ha_bootstrap.sh" ]]; then
  /home/asamy_nominations_ipa_edu_sa/postgresql_ha_bootstrap.sh
elif [[ -f "./postgresql_ha_bootstrap.sh" ]]; then
  ./postgresql_ha_bootstrap.sh
else
  echo "❌ Bootstrap script not found"
  exit 1
fi

echo "=== Quick Fix Complete ==="