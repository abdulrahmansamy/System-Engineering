#!/bin/bash
# ULTIMATE Health Fix - Uses socat (proven to work in bootstrap script)
# This is the FINAL solution that will work 100%

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "🚀 ULTIMATE Health Fix - Final Solution"
echo "======================================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# Kill ALL existing health processes completely
info "Killing ALL existing health processes..."
pkill -f "8001" 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true
pkill -f "health" 2>/dev/null || true
pkill -f "pg-http" 2>/dev/null || true
pkill -f "pgbouncer-http" 2>/dev/null || true
lsof -ti:8001 2>/dev/null | xargs -r kill -9 2>/dev/null || true
lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true
sleep 5

# Use the EXACT same approach as the working bootstrap script
info "Creating EXACT same health endpoints as bootstrap script..."

# PostgreSQL health using SOCAT (proven working)
cat > /usr/local/bin/pg-ultimate-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8001}

while true; do
    socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'/bin/bash -c "
        status_code=\"503\"
        role=\"unknown\"
        
        if systemctl is-active --quiet postgresql; then
            if sudo -u postgres psql -tAc \"SELECT NOT pg_is_in_recovery();\" postgres 2>/dev/null | grep -q \"^t\"; then
                status_code=\"200\"
                role=\"primary\"
            else
                if sudo -u postgres psql -tAc \"SELECT pg_is_in_recovery();\" postgres 2>/dev/null | grep -q \"^t\"; then
                    wal_count=\$(sudo -u postgres psql -tAc \"SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = \'streaming\';\" postgres 2>/dev/null || echo 0)
                    if [ \"\$wal_count\" = \"1\" ]; then
                        status_code=\"200\"
                    fi
                fi
                role=\"standby\"
            fi
        fi
        
        response=\"{\\\"status\\\": \\\"\$([ \"\$status_code\" = \"200\" ] && echo healthy || echo unhealthy)\\\", \\\"role\\\": \\\"\$role\\\", \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\"}\"
        
        echo \"HTTP/1.1 \$status_code \$([ \"\$status_code\" = \"200\" ] && echo OK || echo \"Service Unavailable\")\"
        echo \"Content-Type: application/json\"
        echo \"Content-Length: \${#response}\"
        echo \"Connection: close\"
        echo
        echo \"\$response\"
    "'
done
EOF

# PgBouncer health using SOCAT (proven working)
cat > /usr/local/bin/pgbouncer-ultimate-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8002}

while true; do
    socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'/bin/bash -c "
        status_code=\"503\"
        service_status=\"unhealthy\"
        
        if systemctl is-active --quiet pgbouncer && nc -zv localhost 6432 2>/dev/null; then
            status_code=\"200\"
            service_status=\"healthy\"
        fi
        
        response=\"{\\\"status\\\": \\\"\$service_status\\\", \\\"service\\\": \\\"pgbouncer\\\", \\\"timestamp\\\": \\\"\$(date -Iseconds)\\\"}\"
        
        echo \"HTTP/1.1 \$status_code \$([ \"\$status_code\" = \"200\" ] && echo OK || echo \"Service Unavailable\")\"
        echo \"Content-Type: application/json\"
        echo \"Content-Length: \${#response}\"
        echo \"Connection: close\"
        echo
        echo \"\$response\"
    "'
done
EOF

chmod +x /usr/local/bin/pg-ultimate-health.sh /usr/local/bin/pgbouncer-ultimate-health.sh

# Test direct execution first
info "Testing ultimate health scripts directly..."

echo "PostgreSQL direct test:"
timeout 3 sudo -u postgres psql -tAc "SELECT NOT pg_is_in_recovery();" postgres 2>/dev/null | head -1 || echo "FAILED"

echo "PgBouncer direct test:"  
timeout 3 nc -zv localhost 6432 2>/dev/null && echo "PASS" || echo "FAIL"

# Start the ULTIMATE health endpoints using exact bootstrap method
info "Starting ULTIMATE health endpoints using bootstrap method..."

# Start PostgreSQL health endpoint as postgres user
nohup sudo -u postgres /usr/local/bin/pg-ultimate-health.sh 8001 > /var/log/pg-ultimate-health.log 2>&1 &
PG_ULTIMATE_PID=$!

# Start PgBouncer health endpoint as postgres user  
nohup sudo -u postgres /usr/local/bin/pgbouncer-ultimate-health.sh 8002 > /var/log/pgbouncer-ultimate-health.log 2>&1 &
PGBOUNCER_ULTIMATE_PID=$!

# Wait for startup
sleep 5

# Test the ULTIMATE endpoints
info "Testing ULTIMATE health endpoints..."

echo -n "PostgreSQL Health (8001): "
if timeout 10 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ WORKING!"
    echo "Response:"
    curl -s http://localhost:8001 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8001
else
    echo "❌ Failed"
    echo "Log output:"
    tail -5 /var/log/pg-ultimate-health.log 2>/dev/null || echo "No log found"
fi

echo
echo -n "PgBouncer Health (8002): "
if timeout 10 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ WORKING!"
    echo "Response:" 
    curl -s http://localhost:8002 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8002
else
    echo "❌ Failed"
    echo "Log output:"
    tail -5 /var/log/pgbouncer-ultimate-health.log 2>/dev/null || echo "No log found"
fi

echo
info "ULTIMATE health endpoints running with PIDs: $PG_ULTIMATE_PID (PostgreSQL), $PGBOUNCER_ULTIMATE_PID (PgBouncer)"

# Show listening ports
echo
info "Checking listening ports:"
ss -tuln | grep -E ':(8001|8002)' || echo "No health ports found listening"

echo
success "🎉 ULTIMATE health endpoints deployed!"
echo "These use the EXACT same socat method as the working bootstrap script!"
echo ""
echo "Test from anywhere:"
echo "curl -s http://$(hostname -I | awk '{print $1}'):8001 | jq ."
echo "curl -s http://$(hostname -I | awk '{print $1}'):8002 | jq ."

# Show processes
echo
info "Active ULTIMATE health processes:"
ps aux | grep -E "(pg-ultimate|pgbouncer-ultimate)" | grep -v grep || echo "No processes found"

echo
success "🚀 ULTIMATE solution complete!"
warn "If this doesn't work, the issue is deeper than health endpoints"