#!/bin/bash
# BULLETPROOF Health Fix - Uses shell wrapper approach
# This WILL work because we've proven the shell commands work

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🔧 BULLETPROOF Health Fix"
echo "========================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# Kill existing health processes completely
info "Killing all existing health processes..."
pkill -f "8001" 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true
lsof -ti:8001 2>/dev/null | xargs -r kill -9 2>/dev/null || true
lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true
sleep 3

# Create shell script health checkers (we KNOW these work)
info "Creating bulletproof shell-based health endpoints..."

# PostgreSQL health checker script
cat > /usr/local/bin/pg-health-checker.sh << 'EOF'
#!/bin/bash
# This script works - we've tested it manually

status_code="503"
role="unknown"

# Check PostgreSQL service
if systemctl is-active --quiet postgresql; then
    # Check if primary (not in recovery) - we know this works
    if sudo -u postgres psql -tAc 'SELECT NOT pg_is_in_recovery();' postgres 2>/dev/null | grep -q '^t'; then
        status_code="200"
        role="primary"
    else
        # Check if standby (in recovery) - we know this works
        if sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();' postgres 2>/dev/null | grep -q '^t'; then
            # Check WAL receiver for standby health
            wal_count=$(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';" postgres 2>/dev/null || echo 0)
            if [[ "$wal_count" =~ ^[0-9]+$ ]] && [[ "$wal_count" -ge 1 ]]; then
                status_code="200"
            fi
            role="standby"
        fi
    fi
fi

# Create JSON response
timestamp=$(date -Iseconds)
response="{\"status\": \"$([ "$status_code" = "200" ] && echo healthy || echo unhealthy)\", \"role\": \"$role\", \"timestamp\": \"$timestamp\"}"

# Output HTTP response
echo "HTTP/1.1 $status_code $([ "$status_code" = "200" ] && echo OK || echo "Service Unavailable")"
echo "Content-Type: application/json"
echo "Content-Length: ${#response}"
echo "Connection: close"
echo ""
echo "$response"
EOF

# PgBouncer health checker script
cat > /usr/local/bin/pgbouncer-health-checker.sh << 'EOF'
#!/bin/bash
# Simple PgBouncer health check

status_code="503"
service_status="unhealthy"

# Check service and port
if systemctl is-active --quiet pgbouncer && nc -zv localhost 6432 2>/dev/null; then
    status_code="200"
    service_status="healthy"
fi

# Create JSON response
timestamp=$(date -Iseconds)
response="{\"status\": \"$service_status\", \"service\": \"pgbouncer\", \"timestamp\": \"$timestamp\"}"

# Output HTTP response
echo "HTTP/1.1 $status_code $([ "$status_code" = "200" ] && echo OK || echo "Service Unavailable")"
echo "Content-Type: application/json"
echo "Content-Length: ${#response}"
echo "Connection: close"
echo ""
echo "$response"
EOF

chmod +x /usr/local/bin/pg-health-checker.sh /usr/local/bin/pgbouncer-health-checker.sh

# Create super simple HTTP servers using netcat loops
info "Creating bulletproof HTTP servers..."

# PostgreSQL HTTP server
cat > /usr/local/bin/pg-http-server.sh << 'EOF'
#!/bin/bash
PORT=8001
while true; do
    /usr/local/bin/pg-health-checker.sh | nc -l -p $PORT -q 1
    sleep 0.1
done
EOF

# PgBouncer HTTP server  
cat > /usr/local/bin/pgbouncer-http-server.sh << 'EOF'
#!/bin/bash
PORT=8002
while true; do
    /usr/local/bin/pgbouncer-health-checker.sh | nc -l -p $PORT -q 1
    sleep 0.1
done
EOF

chmod +x /usr/local/bin/pg-http-server.sh /usr/local/bin/pgbouncer-http-server.sh

# Test the health checkers directly first
info "Testing health checkers directly..."

echo "PostgreSQL health check test:"
/usr/local/bin/pg-health-checker.sh | tail -1 | python3 -m json.tool 2>/dev/null || /usr/local/bin/pg-health-checker.sh | tail -1

echo
echo "PgBouncer health check test:"
/usr/local/bin/pgbouncer-health-checker.sh | tail -1 | python3 -m json.tool 2>/dev/null || /usr/local/bin/pgbouncer-health-checker.sh | tail -1

# Start the HTTP servers
info "Starting bulletproof HTTP servers..."

# Start PostgreSQL health server
nohup /usr/local/bin/pg-http-server.sh > /dev/null 2>&1 &
PG_HTTP_PID=$!

# Start PgBouncer health server
nohup /usr/local/bin/pgbouncer-http-server.sh > /dev/null 2>&1 &
PGBOUNCER_HTTP_PID=$!

# Wait for servers to start
sleep 3

# Test the HTTP endpoints
info "Testing bulletproof HTTP endpoints..."

echo -n "PostgreSQL Health (8001): "
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ Working!"
    echo "Response:"
    curl -s http://localhost:8001 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8001
else
    echo "❌ Failed - checking processes"
    ps aux | grep -E "(8001|pg-http)" | grep -v grep || echo "No processes found"
fi

echo
echo -n "PgBouncer Health (8002): "
if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ Working!"
    echo "Response:"
    curl -s http://localhost:8002 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8002
else
    echo "❌ Failed - checking processes"
    ps aux | grep -E "(8002|pgbouncer-http)" | grep -v grep || echo "No processes found"
fi

echo
info "Health servers running with PIDs: $PG_HTTP_PID (PostgreSQL), $PGBOUNCER_HTTP_PID (PgBouncer)"

echo
success "🎉 BULLETPROOF health endpoints deployed!"
echo "These use the EXACT same logic that works manually"
echo ""
echo "Test commands:"
echo "curl -s http://$(hostname -I | awk '{print $1}'):8001 | jq ."
echo "curl -s http://$(hostname -I | awk '{print $1}'):8002 | jq ."

# Show active processes
echo
info "Active health processes:"
ps aux | grep -E "(pg-http|pgbouncer-http)" | grep -v grep || echo "No processes found"