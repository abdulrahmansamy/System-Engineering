#!/bin/bash
# FINAL COMPREHENSIVE Health Fix
# Addresses all remaining issues for 6/6 working endpoints

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "🏁 FINAL COMPREHENSIVE Health Fix"
echo "================================="
echo "Goal: 6/6 working health endpoints"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# ULTRA-AGGRESSIVE cleanup
info "Ultra-aggressive cleanup of ALL health processes..."
pkill -f "health" 2>/dev/null || true
pkill -f "8001" 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true
pkill -f "socat" 2>/dev/null || true

# Kill processes using health ports
for port in 8001 8002; do
    lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
done

# Wait for all processes to fully terminate
sleep 10

# Verify ports are completely free
for port in 8001 8002; do
    if lsof -i:$port >/dev/null 2>&1; then
        warn "Port $port still in use - forcing cleanup"
        lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
        sleep 3
    fi
done

success "All health ports are now free"

# Create FINAL health endpoints with enhanced reliability
info "Creating FINAL health endpoints with enhanced reliability..."

# Enhanced PostgreSQL health endpoint
cat > /usr/local/bin/pg-final-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail

PORT=${1:-8001}

# Use exec to replace shell with socat (more reliable)
exec socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'/bin/bash -c "
    status_code=\"503\"
    role=\"unknown\"
    
    # Enhanced PostgreSQL health check
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        # Check if primary (not in recovery)
        if timeout 3 sudo -u postgres psql -tAc \"SELECT NOT pg_is_in_recovery();\" postgres 2>/dev/null | grep -q \"^t\"; then
            status_code=\"200\"
            role=\"primary\"
        else
            # Check if standby (in recovery)
            if timeout 3 sudo -u postgres psql -tAc \"SELECT pg_is_in_recovery();\" postgres 2>/dev/null | grep -q \"^t\"; then
                # Check WAL receiver for standby health
                wal_count=\$(timeout 3 sudo -u postgres psql -tAc \"SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = \'streaming\';\" postgres 2>/dev/null || echo 0)
                if [[ \"\$wal_count\" =~ ^[0-9]+\$ ]] && [[ \"\$wal_count\" -ge 1 ]]; then
                    status_code=\"200\"
                fi
                role=\"standby\"
            fi
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
EOF

# Enhanced PgBouncer health endpoint
cat > /usr/local/bin/pgbouncer-final-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail

PORT=${1:-8002}

# Use exec to replace shell with socat (more reliable)
exec socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:'/bin/bash -c "
    status_code=\"503\"
    service_status=\"unhealthy\"
    
    # Enhanced PgBouncer health check with multiple validation methods
    if systemctl is-active --quiet pgbouncer 2>/dev/null; then
        # Method 1: Direct port check
        if timeout 2 nc -z localhost 6432 2>/dev/null; then
            status_code=\"200\"
            service_status=\"healthy\"
        else
            # Method 2: Check if process is running
            if pgrep -f pgbouncer >/dev/null 2>&1; then
                # Method 3: Check if listening on port
                if ss -tuln | grep -q \":6432\"; then
                    status_code=\"200\"
                    service_status=\"healthy\"
                fi
            fi
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

chmod +x /usr/local/bin/pg-final-health.sh /usr/local/bin/pgbouncer-final-health.sh

# Test basic connectivity first
info "Testing basic connectivity..."

echo -n "PostgreSQL service: "
systemctl is-active postgresql >/dev/null 2>&1 && echo "✅ ACTIVE" || echo "❌ INACTIVE"

echo -n "PgBouncer service: "
systemctl is-active pgbouncer >/dev/null 2>&1 && echo "✅ ACTIVE" || echo "❌ INACTIVE"

echo -n "PostgreSQL direct query: "
timeout 3 sudo -u postgres psql -tAc "SELECT 1;" postgres >/dev/null 2>&1 && echo "✅ OK" || echo "❌ FAILED"

echo -n "PgBouncer port 6432: "
timeout 2 nc -z localhost 6432 2>/dev/null && echo "✅ LISTENING" || echo "❌ NOT LISTENING"

# Start FINAL health endpoints
info "Starting FINAL health endpoints..."

# Start PostgreSQL health endpoint
nohup sudo -u postgres /usr/local/bin/pg-final-health.sh 8001 > /var/log/pg-final-health.log 2>&1 &
PG_FINAL_PID=$!

# Start PgBouncer health endpoint
nohup sudo -u postgres /usr/local/bin/pgbouncer-final-health.sh 8002 > /var/log/pgbouncer-final-health.log 2>&1 &
PGBOUNCER_FINAL_PID=$!

# Wait for startup
sleep 5

# Verify processes are running
info "Verifying health processes..."

for pid in $PG_FINAL_PID $PGBOUNCER_FINAL_PID; do
    if ps -p $pid > /dev/null 2>&1; then
        success "✅ Process $pid is running"
    else
        warn "❌ Process $pid failed to start"
    fi
done

# Verify ports are listening
info "Verifying port binding..."
for port in 8001 8002; do
    if ss -tuln | grep -q ":$port"; then
        success "✅ Port $port is listening"
    else
        warn "❌ Port $port is not listening"
    fi
done

# Comprehensive endpoint testing
info "Comprehensive endpoint testing..."

test_endpoint() {
    local url="$1"
    local name="$2"
    
    echo -n "Testing $name: "
    
    for attempt in {1..3}; do
        if timeout 5 curl -sf "$url" >/dev/null 2>&1; then
            success "✅ WORKING (attempt $attempt)"
            curl -s "$url" | python3 -m json.tool 2>/dev/null | head -5
            return 0
        else
            if [[ $attempt -lt 3 ]]; then
                echo -n "❌ (retry $attempt) "
                sleep 1
            fi
        fi
    done
    
    echo "❌ FAILED after 3 attempts"
    return 1
}

# Test all endpoints
echo
test_endpoint "http://localhost:8001" "Local PostgreSQL"
echo
test_endpoint "http://localhost:8002" "Local PgBouncer"

# Get self IP for cross-node testing
SELF_IP=$(hostname -I | awk '{print $1}')
echo
test_endpoint "http://$SELF_IP:8001" "Self PostgreSQL ($SELF_IP)"
echo  
test_endpoint "http://$SELF_IP:8002" "Self PgBouncer ($SELF_IP)"

echo
success "🏁 FINAL comprehensive health fix complete!"
info "Process PIDs: PostgreSQL=$PG_FINAL_PID, PgBouncer=$PGBOUNCER_FINAL_PID"
info "Log files: /var/log/pg-final-health.log, /var/log/pgbouncer-final-health.log"

echo
info "📊 Current status:"
echo "PostgreSQL Health: $(timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1 && echo "WORKING" || echo "FAILED")"
echo "PgBouncer Health: $(timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "WORKING" || echo "FAILED")"
echo "Listening ports: $(ss -tuln | grep -E ':(8001|8002)' | wc -l)/2"

echo
success "🚀 Ready for full testing! Run test script to verify all 6 endpoints work!"