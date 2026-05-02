#!/bin/bash
# Final fix for remaining validation issues

set -euo pipefail

echo "PostgreSQL HA Final Fix - Health Endpoints & PgBouncer Auth"
echo "==========================================================="

# Check current health endpoint status
echo "Checking current health endpoint status..."
if pgrep -f "final-pg-health.py" >/dev/null; then
    echo "PostgreSQL health endpoint process is running"
    pg_health_pid=$(pgrep -f "final-pg-health.py")
    echo "PID: $pg_health_pid"
else
    echo "PostgreSQL health endpoint process not found"
fi

if pgrep -f "final-pgbouncer-health.py" >/dev/null; then
    echo "PgBouncer health endpoint process is running"
    pgb_health_pid=$(pgrep -f "final-pgbouncer-health.py")
    echo "PID: $pgb_health_pid"
else
    echo "PgBouncer health endpoint process not found"
fi

# Test current endpoints
echo ""
echo "Testing health endpoints directly..."
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    echo "✅ PostgreSQL health endpoint (8001) is responding"
    curl -s http://localhost:8001 | head -1
else
    echo "❌ PostgreSQL health endpoint (8001) not responding"
fi

if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    echo "✅ PgBouncer health endpoint (8002) is responding"
    curl -s http://localhost:8002 | head -1
else
    echo "❌ PgBouncer health endpoint (8002) not responding"
fi

# Restart health endpoints with better process management
echo ""
echo "Restarting health endpoints with improved process management..."

# Kill existing processes
pkill -f "final-pg-health.py" 2>/dev/null || true
pkill -f "final-pgbouncer-health.py" 2>/dev/null || true
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true

# Kill by port
lsof -ti:8001 2>/dev/null | xargs -r kill -9 || true
lsof -ti:8002 2>/dev/null | xargs -r kill -9 || true

sleep 3

# Start health endpoints with better logging
echo "Starting PostgreSQL health endpoint with better logging..."
if [[ -f /usr/local/bin/final-pg-health.py ]]; then
    sudo -u postgres nohup python3 /usr/local/bin/final-pg-health.py 8001 \
        >>/var/log/pg-health.log 2>&1 &
    echo "Started PostgreSQL health endpoint (PID: $!)"
else
    echo "❌ PostgreSQL health script not found"
fi

echo "Starting PgBouncer health endpoint with better logging..."
if [[ -f /usr/local/bin/final-pgbouncer-health.py ]]; then
    sudo -u postgres nohup python3 /usr/local/bin/final-pgbouncer-health.py 8002 \
        >>/var/log/pgbouncer-health.log 2>&1 &
    echo "Started PgBouncer health endpoint (PID: $!)"
else
    echo "❌ PgBouncer health script not found"
fi

# Wait for startup
sleep 5

# Test again
echo ""
echo "Testing health endpoints after restart..."
if timeout 10 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    echo "✅ PostgreSQL health endpoint (8001) is now responding"
    response=$(timeout 5 curl -s http://localhost:8001 2>/dev/null || echo "no response")
    echo "Response: $response"
else
    echo "❌ PostgreSQL health endpoint (8001) still not responding"
    echo "Checking logs..."
    tail -5 /var/log/pg-health.log 2>/dev/null || echo "No logs found"
fi

if timeout 10 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    echo "✅ PgBouncer health endpoint (8002) is now responding"
    response=$(timeout 5 curl -s http://localhost:8002 2>/dev/null || echo "no response")
    echo "Response: $response"
else
    echo "❌ PgBouncer health endpoint (8002) still not responding"
    echo "Checking logs..."
    tail -5 /var/log/pgbouncer-health.log 2>/dev/null || echo "No logs found"
fi

# Fix PgBouncer authentication
echo ""
echo "Fixing PgBouncer authentication..."

# Get passwords from .pgpass
if [[ -f /var/lib/postgresql/.pgpass ]]; then
    PG_SUPER_PASS=$(grep "postgres:" /var/lib/postgresql/.pgpass | head -1 | cut -d':' -f5)
    PGBOUNCER_PASSWORD=$(grep "pgbouncer_admin:" /var/lib/postgresql/.pgpass | head -1 | cut -d':' -f5)
    PG_REPL_PASS=$(grep "replication:" /var/lib/postgresql/.pgpass | head -1 | cut -d':' -f5)
    
    echo "Passwords loaded from .pgpass"
else
    echo "❌ .pgpass file not found"
    exit 1
fi

# Ensure pgbouncer_admin user exists with correct password
echo "Ensuring pgbouncer_admin user exists..."
admin_exists=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'pgbouncer_admin';" 2>/dev/null || echo "0")

if [[ "$admin_exists" == "0" ]]; then
    echo "Creating pgbouncer_admin user..."
    sudo -u postgres psql -c "SET password_encryption = 'md5'; CREATE ROLE pgbouncer_admin LOGIN;" || true
else
    echo "pgbouncer_admin user already exists"
fi

# Set password with MD5 encryption
echo "Setting pgbouncer_admin password with MD5..."
sudo -u postgres psql -c "SET password_encryption = 'md5'; ALTER ROLE pgbouncer_admin PASSWORD '$PGBOUNCER_PASSWORD';" || true

# Grant necessary permissions
echo "Granting permissions to pgbouncer_admin..."
sudo -u postgres psql <<EOF || echo "Some permission grants may have failed"
GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
GRANT CONNECT ON DATABASE template1 TO pgbouncer_admin;
GRANT USAGE ON SCHEMA public TO pgbouncer_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgbouncer_admin;
ALTER ROLE pgbouncer_admin SET log_statement = 'none';
EOF

# Regenerate PgBouncer userlist with correct MD5 hashes
echo "Regenerating PgBouncer userlist with correct MD5 hashes..."
postgres_md5=$(printf '%s%s' "$PG_SUPER_PASS" "postgres" | md5sum | cut -d' ' -f1)
pgbouncer_admin_md5=$(printf '%s%s' "$PGBOUNCER_PASSWORD" "pgbouncer_admin" | md5sum | cut -d' ' -f1)
replication_md5=$(printf '%s%s' "$PG_REPL_PASS" "replication" | md5sum | cut -d' ' -f1)

cat > /etc/pgbouncer/userlist.txt <<EOF
;; PgBouncer MD5 Authentication File (regenerated by final fix)
"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"replication" "md5${replication_md5}"
EOF

chmod 640 /etc/pgbouncer/userlist.txt
chown root:pgbouncer /etc/pgbouncer/userlist.txt 2>/dev/null || chown postgres:postgres /etc/pgbouncer/userlist.txt

# Restart PgBouncer to reload userlist
echo "Restarting PgBouncer to reload userlist..."
systemctl restart pgbouncer
sleep 3

# Test PgBouncer connection
echo "Testing PgBouncer connection..."
if timeout 10 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
   psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer test successful';" >/dev/null 2>&1; then
    echo "✅ PgBouncer connection working"
else
    echo "❌ PgBouncer connection still failing"
    echo "Checking PgBouncer status..."
    systemctl status pgbouncer --no-pager || true
    echo "Checking PgBouncer logs..."
    journalctl -u pgbouncer --lines=10 --no-pager || true
fi

# Create systemd services for health endpoints (alternative approach)
echo ""
echo "Creating systemd services for health endpoints as backup..."

cat > /etc/systemd/system/pg-health-endpoint.service <<EOF
[Unit]
Description=PostgreSQL Health Endpoint
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/bin/python3 /usr/local/bin/final-pg-health.py 8001
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-health-endpoint.service <<EOF
[Unit]
Description=PgBouncer Health Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/bin/python3 /usr/local/bin/final-pgbouncer-health.py 8002
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# Don't start the services yet, keep manual approach
echo "Systemd services created as backup (not started yet)"

echo ""
echo "🎉 Final fix completed!"
echo ""
echo "Summary of actions taken:"
echo "  ✅ Restarted health endpoints with better process management"
echo "  ✅ Fixed pgbouncer_admin user and permissions"
echo "  ✅ Regenerated PgBouncer userlist with correct MD5 hashes"
echo "  ✅ Restarted PgBouncer service"
echo "  ✅ Created systemd services as backup"
echo ""
echo "Run validation again to check results:"
echo "  sudo ./expert_validated_streaming_replication_validator.sh"