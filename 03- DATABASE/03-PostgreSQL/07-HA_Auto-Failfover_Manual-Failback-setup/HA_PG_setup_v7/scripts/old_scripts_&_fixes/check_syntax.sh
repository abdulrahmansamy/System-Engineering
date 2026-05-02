#!/bin/bash
# Syntax checker and fixer for PostgreSQL HA bootstrap script

set -euo pipefail

echo "🔍 Checking syntax for postgresql_ha_bootstrap.sh..."

if bash -n postgresql_ha_bootstrap.sh; then
    echo "✅ postgresql_ha_bootstrap.sh syntax is valid!"
else
    echo "❌ postgresql_ha_bootstrap.sh has syntax errors"
    echo ""
    echo "Running detailed syntax check..."
    bash -n postgresql_ha_bootstrap.sh 2>&1 | head -10
fi

echo ""
echo "Checking line endings and common issues..."

# Check for Windows line endings
if grep -q $'\r' postgresql_ha_bootstrap.sh; then
    echo "⚠️  Found Windows line endings (\\r\\n) - converting to Unix format"
    sed -i 's/\r$//' postgresql_ha_bootstrap.sh
else
    echo "✅ Line endings are correct (Unix format)"
fi

# Check for common bash syntax issues
echo "Checking for common syntax issues..."

# Check for unmatched quotes
if ! awk '
{
    for(i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if(c == "\"" && substr($0, i-1, 1) != "\\") {
            if(!in_double) in_double = 1
            else in_double = 0
        }
        if(c == "'" && substr($0, i-1, 1) != "\\") {
            if(!in_single) in_single = 1
            else in_single = 0
        }
    }
}
END {
    if(in_double) {print "Unmatched double quote"; exit 1}
    if(in_single) {print "Unmatched single quote"; exit 1}
}' postgresql_ha_bootstrap.sh; then
    echo "⚠️  Found unmatched quotes"
else
    echo "✅ Quotes are properly matched"
fi

echo ""
echo "Final syntax check..."
if bash -n postgresql_ha_bootstrap.sh; then
    echo "🎉 All syntax issues fixed!"
else
    echo "❌ Still has syntax errors - manual review needed"
fi