#!/bin/bash
# Quick patch for missing is_primary function
# Version: 1.0.0

echo "🔧 Quick Patch: Adding missing is_primary function"
echo "=================================================="

# Add the missing function after the PgBouncer password section
if ! grep -q "^is_primary()" failover_validation_jumphost.sh; then
    # Find the line with PGBOUNCER_PASS and add the function after it
    sed -i '/^fi$/a\\n# Helper function to check if a node is primary\nis_primary() {\n    local ip="$1"\n    local result\n    result=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN '"'"'STANDBY'"'"' ELSE '"'"'PRIMARY'"'"' END;" 2>/dev/null || echo "UNKNOWN")\n    [[ "$result" == "PRIMARY" ]]\n}' failover_validation_jumphost.sh
    echo "✅ Added is_primary function to failover_validation_jumphost.sh"
else
    echo "ℹ️ is_primary function already exists in failover_validation_jumphost.sh"
fi

echo "🎯 Patch completed! You can now run the validation script."