#!/bin/bash
# One-line fix for missing is_primary function

echo "🔧 Adding missing is_primary function..."

# Add the function after line that contains "export PGBOUNCER_PASS"
sed -i '/export PGBOUNCER_PASS/a\\n# Helper function to check if a node is primary\nis_primary() {\n    local ip="$1"\n    local result\n    result=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN '"'"'STANDBY'"'"' ELSE '"'"'PRIMARY'"'"' END;" 2>/dev/null || echo "UNKNOWN")\n    [[ "$result" == "PRIMARY" ]]\n}' failover_validation_jumphost.sh

echo "✅ Function added! You can now run the validation script."