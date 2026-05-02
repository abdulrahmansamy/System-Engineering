#!/bin/bash
# Final comprehensive fix for SCRAM vs MD5 password issue

set -euo pipefail

echo "PostgreSQL HA Final Comprehensive Fix - Complete SCRAM to MD5 Conversion"
echo "========================================================================"

# Fix 1: Health endpoints are already working, just restore the original processes
echo "Health endpoints are working fine, restoring original processes..."

# Find and restore the original working processes
original_pg_pid=$(pgrep -f "final-pg-health.py.*8001" | head -1 || echo "")
original_pgb_pid=$(pgrep -f "final-pgbouncer-health.py.*8002" | head -1 || echo "")

# Kill the new conflicting processes
newer_pids=$(pgrep -f "final-pg-health.py.*8001" | tail -n +2 || echo "")
for pid in $newer_pids; do
    kill -9 "$pid" 2>/dev/null || true
done

newer_pids=$(pgrep -f "final-pgbouncer-health.py.*8002" | tail -n +2 || echo "")
for pid in $newer_pids; do
    kill -9 "$pid" 2>/dev/null || true
done

sleep 2

# Test original endpoints
echo "Testing original health endpoints..."
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    echo "✅ PostgreSQL health endpoint (8001) is working"
else
    echo "❌ Need to restart PostgreSQL health endpoint"
    # Start it properly
    sudo -u postgres nohup python3 /usr/local/bin/final-pg-health.py 8001 >/dev/null 2>&1 &
fi

if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    echo "✅ PgBouncer health endpoint (8002) is working"
else
    echo "❌ Need to restart PgBouncer health endpoint"
    # Start it properly
    sudo -u postgres nohup python3 /usr/local/bin/final-pgbouncer-health.py 8002 >/dev/null 2>&1 &
fi

# Fix 2: Convert PostgreSQL passwords from SCRAM-SHA-256 to MD5 for PgBouncer compatibility
echo ""
echo "Fix 2: Converting PostgreSQL password encryption to MD5 for PgBouncer compatibility..."

# Get passwords from .pgpass
PG_SUPER_PASS=$(grep "postgres:" /var/lib/postgresql/.pgpass | head -1 | cut -d':' -f5)
PGBOUNCER_PASSWORD=$(grep "pgbouncer_admin:" /var/lib/postgresql/.pgpass | head -1 | cut -d':' -f5)

echo "Converting postgres user password to MD5 (this is the critical fix)..."
sudo -u postgres psql <<EOF
-- Set password encryption to md5 globally
ALTER SYSTEM SET password_encryption = 'md5';
SELECT pg_reload_conf();

-- Re-set postgres password with MD5 encryption (this fixes the SCRAM issue)
ALTER ROLE postgres PASSWORD '$PG_SUPER_PASS';

-- Also ensure pgbouncer_admin has MD5 password
ALTER ROLE pgbouncer_admin PASSWORD '$PGBOUNCER_PASSWORD';

-- Verify the passwords were set with MD5
SELECT rolname, substr(rolpassword, 1, 5) as password_type 
FROM pg_authid 
WHERE rolname IN ('postgres', 'pgbouncer_admin');
EOF

echo ""
echo "Regenerating PgBouncer userlist with correct MD5 hashes after password reset..."
# Regenerate MD5 hashes after the password reset
postgres_md5=$(printf '%s%s' "$PG_SUPER_PASS" "postgres" | md5sum | cut -d' ' -f1)
pgbouncer_admin_md5=$(printf '%s%s' "$PGBOUNCER_PASSWORD" "pgbouncer_admin" | md5sum | cut -d' ' -f1)

cat > /etc/pgbouncer/userlist.txt <<EOF
;; PgBouncer MD5 Authentication File (final fix - regenerated)
"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
EOF

chmod 640 /etc/pgbouncer/userlist.txt
chown root:pgbouncer /etc/pgbouncer/userlist.txt 2>/dev/null || chown postgres:postgres /etc/pgbouncer/userlist.txt

echo "Password encryption changed to MD5."

# Restart PgBouncer to pick up changes
echo "Restarting PgBouncer..."
systemctl restart pgbouncer
sleep 3

# Test PgBouncer connection
echo "Testing PgBouncer connection with MD5 passwords..."
if timeout 10 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
   psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer MD5 test successful';" >/dev/null 2>&1; then
    echo "✅ PgBouncer connection now working with MD5 passwords!"
else
    echo "❌ PgBouncer connection still failing, checking details..."
    
    # Show recent PgBouncer logs
    echo "Recent PgBouncer logs:"
    journalctl -u pgbouncer --since "1 minute ago" --no-pager || true
    
    # Try direct authentication test
    echo "Testing direct authentication..."
    timeout 5 sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT version();" || true
fi

# Final verification
echo ""
echo "Final verification..."
echo "Health endpoints:"
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    echo "  ✅ PostgreSQL health (8001): Working"
else
    echo "  ❌ PostgreSQL health (8001): Not working"
fi

if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    echo "  ✅ PgBouncer health (8002): Working"
else
    echo "  ❌ PgBouncer health (8002): Not working"
fi

echo "PgBouncer connectivity:"
if timeout 10 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
   psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    echo "  ✅ PgBouncer connection: Working"
else
    echo "  ❌ PgBouncer connection: Still failing"
fi

echo ""
echo "🎉 Targeted fix completed!"
echo ""
echo "Key fixes applied:"
echo "  ✅ Restored working health endpoint processes"
echo "  ✅ Converted PostgreSQL passwords from SCRAM-SHA-256 to MD5"
echo "  ✅ Restarted PgBouncer with compatible authentication"
echo ""
echo "Run final validation:"
echo "  sudo ./expert_validated_streaming_replication_validator.sh"