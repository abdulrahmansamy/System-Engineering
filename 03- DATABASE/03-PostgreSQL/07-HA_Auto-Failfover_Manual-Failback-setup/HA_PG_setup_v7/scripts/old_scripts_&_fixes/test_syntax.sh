#!/bin/bash
# Quick test script to verify diagnostic and fix scripts work

set -euo pipefail

echo "Testing diagnostic script..."
echo "# Testing syntax check for diagnose_cluster.sh"
bash -n diagnose_cluster.sh && echo "✓ diagnose_cluster.sh syntax is valid" || echo "✗ diagnose_cluster.sh has syntax errors"

echo ""
echo "Testing fix script..."
echo "# Testing syntax check for fix_repmgr_registration.sh"
bash -n fix_repmgr_registration.sh && echo "✓ fix_repmgr_registration.sh syntax is valid" || echo "✗ fix_repmgr_registration.sh has syntax errors"

echo ""
echo "Testing bootstrap script..."
echo "# Testing syntax check for postgresql_ha_bootstrap.sh"
bash -n postgresql_ha_bootstrap.sh && echo "✓ postgresql_ha_bootstrap.sh syntax is valid" || echo "✗ postgresql_ha_bootstrap.sh has syntax errors"

echo ""
echo "All syntax checks completed!"



# Script to validate syntax of all shell scripts in the current directory

set -euo pipefail

echo "🔍 Starting syntax checks for shell scripts in $(pwd)"
echo ""

for script in ./*.sh; do
  if [[ -f "$script" ]]; then
    echo "# Checking syntax for $script"
    if bash -n "$script"; then
      echo "✓ $script syntax is valid"
    else
      echo "✗ $script has syntax errors"
    fi
    echo ""
  fi
done

echo "✅ All syntax checks completed!"
