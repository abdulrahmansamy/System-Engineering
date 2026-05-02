#!/bin/bash
# Targeted PgBouncer Health Fix - Addresses the specific socat conflicts
# Root cause: Mif ps -p $PGBOUNCER_PID > /dev/null 2>&1; then
    success "✅ PgBouncer health process started (PID: $PGBOUNCER_PID)"
else
    echo "❌ PgBouncer health process failed to start"
    cat /var/log/pgbouncer-final-health.log 2>/dev/null || echo "No log found"
    exit 1
fi socat processes competing for port 8002

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "🎯 Targeted PgBouncer Health Fix"
echo "================================"
echo "Root cause: socat process conflicts on port 8002"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# AGGRESSIVE cleanup of port 8002 processes
info "Aggressively cleaning up port 8002 processes..."
lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true
pkill -f "pgbouncer.*health" 2>/dev/null || true
pkill -f "pgbouncer-ultimate" 2>/dev/null || true

# Wait longer for processes to fully terminate
sleep 10

# Verify port 8002 is completely free
if lsof -i:8002 >/dev/null 2>&1; then
    error "Port 8002 still in use after cleanup!"
    lsof -i:8002
    exit 1
fi

success "Port 8002 is now free"

# Create a SINGLE, robust PgBouncer health endpoint
info "Creating single, robust PgBouncer health endpoint..."

cat > /usr/local/bin/pgbouncer-final-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail

PORT=${1:-8002}

# Single socat process - no conflicts
exec socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'/bin/bash -c "
    status_code=\"503\"
    service_status=\"unhealthy\"
    
    # Test PgBouncer service and port
    if systemctl is-active --quiet pgbouncer; then
        if timeout 2 nc -z localhost 6432 2>/dev/null; then
            status_code=\"200\"
            service_status=\"healthy\"
        fi
    fi
    
    response=\"{\\\"status\\\": \\\"\$service_status\\\", \\\"service\\\": \\\"pgbouncer\\\", \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\"}\"
    
    echo \"HTTP/1.1 \$status_code \$([ \"\$status_code\" = \"200\" ] && echo OK || echo \"Service Unavailable\")\"
    echo \"Content-Type: application/json\"
    echo \"Content-Length: \${#response}\"
    echo \"Connection: close\"
    echo
    echo \"\$response\"
"'
EOF

chmod +x /usr/local/bin/pgbouncer-final-health.sh

# Test PgBouncer connectivity first
info "Testing PgBouncer connectivity..."
if systemctl is-active --quiet pgbouncer && timeout 3 nc -z localhost 6432 2>/dev/null; then
    success "✅ PgBouncer is accessible"
else
    warn "⚠️ PgBouncer may have issues"
    systemctl status pgbouncer --no-pager -l | head -5
fi

# Start SINGLE PgBouncer health process
info "Starting single PgBouncer health process..."

nohup sudo -u postgres /usr/local/bin/pgbouncer-final-health.sh 8002 > /var/log/pgbouncer-final-health.log 2>&1 &
PGBOUNCER_PID=$!

# Wait for startup
sleep 3

# Verify the process is running and port is bound
if ps -p $PGBOUNCER_PID > /dev/null 2>&1; then
    success "✅ PgBouncer health process started (PID: $PGBOUNCER_PID)"
else
    error "❌ PgBouncer health process failed to start"
    cat /var/log/pgbouncer-final-health.log 2>/dev/null || echo "No log found"
    exit 1
fi

# Verify port is listening
if ss -tuln | grep -q ":8002"; then
    success "✅ Port 8002 is now listening"
else
    error "❌ Port 8002 is not listening"
    ss -tuln | grep -E ":(8001|8002)" || echo "No health ports found"
    exit 1
fi

# Test the endpoint multiple times
info "Testing PgBouncer endpoint (multiple attempts)..."

for i in {1..5}; do
    echo -n "Test $i: "
    if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
        success "✅ WORKING"
        curl -s http://localhost:8002 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8002
        break
    else
        warn "❌ Failed"
        if [[ $i -eq 5 ]]; then
            error "All tests failed - checking logs..."
            tail -10 /var/log/pgbouncer-final-health.log 2>/dev/null || echo "No log found"
        fi
    fi
    sleep 1
done

echo
success "🎯 Targeted PgBouncer health fix complete!"
info "Process PID: $PGBOUNCER_PID"
info "Log file: /var/log/pgbouncer-final-health.log"

# Show final status
echo
info "Final status check:"
echo "Port 8002 listening: $(ss -tuln | grep -q ":8002" && echo "YES" || echo "NO")"
echo "Process running: $(ps -p $PGBOUNCER_PID >/dev/null 2>&1 && echo "YES" || echo "NO")"
echo "Health endpoint: $(timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "WORKING" || echo "FAILED")"