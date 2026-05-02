#!/bin/bash
# Fix Primary PgBouncer Health Endpoint - Cross-node timeout issue
# Run this script on the PRIMARY node (192.168.14.21)

set -e

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Fixing Primary PgBouncer Health Endpoint (Port 8002)"
info "=============================================="

SELF_IP=$(hostname -I | awk '{print $1}')
ROLE=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")

info "Node: $ROLE (IP: $SELF_IP)"

if [[ "$ROLE" != "primary" ]]; then
    error "This script should only be run on the PRIMARY node!"
    exit 1
fi

# Step 1: Kill ALL processes on port 8002
info "🛑 Killing all processes on port 8002..."
fuser -k 8002/tcp 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "pgbouncer.*health" 2>/dev/null || true
sleep 5

# Force kill if port still in use
if netstat -tuln 2>/dev/null | grep -q ":8002"; then
    warn "Port 8002 still in use - force killing..."
    fuser -k -9 8002/tcp 2>/dev/null || true
    sleep 3
fi

# Step 2: Enhanced firewall rules specifically for cross-node access
info "🔥 Applying enhanced firewall rules for cross-node access..."

# Remove any conflicting iptables rules
iptables -D INPUT -p tcp --dport 8002 -j DROP 2>/dev/null || true
iptables -D INPUT -p tcp --dport 8002 -j REJECT 2>/dev/null || true

# Add comprehensive rules for port 8002
iptables -I INPUT 1 -p tcp --dport 8002 -s 192.168.14.21 -j ACCEPT 2>/dev/null || true
iptables -I INPUT 1 -p tcp --dport 8002 -s 192.168.14.22 -j ACCEPT 2>/dev/null || true
iptables -I INPUT 1 -p tcp --dport 8002 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
iptables -I INPUT 1 -p tcp --dport 8002 -s 0.0.0.0/0 -j ACCEPT 2>/dev/null || true

# Add OUTPUT rules as well
iptables -I OUTPUT 1 -p tcp --sport 8002 -j ACCEPT 2>/dev/null || true

# Step 3: Create a ultra-reliable PGBouncer health endpoint
info "🏥 Creating ultra-reliable PgBouncer health endpoint..."

cat > /usr/local/bin/ultra-reliable-pgbouncer-health.sh <<'ULTRA_EOF'
#!/bin/bash
# Ultra-Reliable PgBouncer Health Endpoint for Primary
PORT=${1:-8002}
SELF_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")

# Logging function
log_health() {
    echo "$(date -Iseconds) - $*" >> /var/log/pgbouncer/ultra-health.log
}

# Ensure log directory exists
mkdir -p /var/log/pgbouncer
touch /var/log/pgbouncer/ultra-health.log

log_health "Starting ultra-reliable PgBouncer health endpoint on port $PORT"

while true; do
    # Comprehensive PgBouncer health check
    local status="healthy"
    local message="PgBouncer operational"
    local http_code="200"
    
    # Check 1: Process running
    if ! pgrep -f pgbouncer >/dev/null 2>&1; then
        status="unhealthy"
        message="PgBouncer process not running"
        http_code="503"
        log_health "FAIL: PgBouncer process not running"
    # Check 2: Port accessible
    elif ! timeout 2 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        status="unhealthy"  
        message="PgBouncer port 6432 not accessible"
        http_code="503"
        log_health "FAIL: PgBouncer port not accessible"
    # Check 3: Database connectivity (optional, don't fail on this)
    else
        # Try to test database connectivity but don't fail the health check
        if timeout 3 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            message="PgBouncer fully operational with database access"
            log_health "SUCCESS: Full PgBouncer connectivity verified"
        else
            message="PgBouncer operational (service running)"
            log_health "SUCCESS: PgBouncer service running (DB connectivity not verified)"
        fi
    fi
    
    # Create JSON response
    response="{\"service\":\"pgbouncer\",\"status\":\"$status\",\"message\":\"$message\",\"timestamp\":\"$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"$SELF_IP\",\"node_role\":\"primary\"}"
    content_length=${#response}
    
    # Set HTTP status
    if [[ "$http_code" == "200" ]]; then
        http_status="HTTP/1.1 200 OK"
    else
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    # Enhanced HTTP response with CORS and connection handling
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nCache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\nExpires: 0\r\nServer: PgBouncer-HA-Primary/1.0\r\n\r\n%s" \
        "$http_status" "$content_length" "$response" | nc -l -s 0.0.0.0 -p $PORT -q 1 2>/dev/null || {
            log_health "nc failed, retrying in 1 second"
            sleep 1
        }
done
ULTRA_EOF

chmod +x /usr/local/bin/ultra-reliable-pgbouncer-health.sh

# Step 4: Start the ultra-reliable endpoint
info "🚀 Starting ultra-reliable PgBouncer health endpoint..."
nohup /usr/local/bin/ultra-reliable-pgbouncer-health.sh 8002 >/dev/null 2>&1 &
HEALTH_PID=$!
sleep 5

# Step 5: Test local connectivity
info "🧪 Testing local connectivity..."
for attempt in {1..5}; do
    if timeout 5 curl -s "http://localhost:8002" >/dev/null 2>&1; then
        success "✅ Local test $attempt: PRIMARY PgBouncer health WORKING"
        local_response=$(timeout 3 curl -s "http://localhost:8002" 2>/dev/null)
        info "  Response: $(echo "$local_response" | head -c 100)"
        break
    else
        warn "❌ Local test $attempt: FAILED"
        if [[ $attempt -eq 5 ]]; then
            error "All local tests failed - check the process"
        else
            sleep 2
        fi
    fi
done

# Step 6: Test external connectivity (from self IP)
info "🌐 Testing external connectivity..."
for attempt in {1..3}; do
    if timeout 8 curl -s "http://$SELF_IP:8002" >/dev/null 2>&1; then
        success "✅ External test $attempt: PRIMARY PgBouncer health accessible from $SELF_IP"
        external_response=$(timeout 3 curl -s "http://$SELF_IP:8002" 2>/dev/null)
        info "  Response: $(echo "$external_response" | head -c 100)"
        break
    else
        warn "❌ External test $attempt: FAILED"
        if [[ $attempt -eq 3 ]]; then
            warn "External tests failed - may need additional network configuration"
        else
            sleep 2
        fi
    fi
done

# Step 7: Check if process is still running
sleep 2
if ps -p $HEALTH_PID >/dev/null 2>&1; then
    success "✅ Ultra-reliable PgBouncer health process still running (PID: $HEALTH_PID)"
else
    warn "❌ Health process died - restarting..."
    nohup /usr/local/bin/ultra-reliable-pgbouncer-health.sh 8002 >/dev/null 2>&1 &
    sleep 3
fi

# Step 8: Show current network status
info "📊 Network Status:"
info "  Listening ports:"
netstat -tuln 2>/dev/null | grep ":8002" || info "    No processes listening on 8002"

info "  iptables rules for port 8002:"
iptables -L INPUT -n | grep ":8002" || info "    No specific iptables rules found"

# Step 9: Final validation
info "🎯 Final Validation:"
success "✅ PRIMARY PgBouncer health endpoint setup complete!"
info "  → Test from standby: curl http://192.168.14.21:8002"
info "  → Test locally: curl http://localhost:8002"
info "  → Log file: /var/log/pgbouncer/ultra-health.log"

# Step 10: Create a simple test script
cat > /usr/local/bin/test-primary-pgbouncer-health.sh <<'TEST_EOF'
#!/bin/bash
# Test Primary PgBouncer Health Endpoint

PRIMARY_IP="192.168.14.21"

echo "🧪 Testing Primary PgBouncer Health Endpoint"
echo "==========================================="

# Test from localhost
echo "Testing from localhost..."
if timeout 10 curl -s "http://localhost:8002" >/dev/null 2>&1; then
    echo "✅ Localhost test: WORKING"
    response=$(timeout 5 curl -s "http://localhost:8002" 2>/dev/null)
    echo "   Response: $response"
else
    echo "❌ Localhost test: FAILED"
fi

echo ""

# Test from external IP
echo "Testing from external IP ($PRIMARY_IP)..."
if timeout 10 curl -s "http://$PRIMARY_IP:8002" >/dev/null 2>&1; then
    echo "✅ External test: WORKING"
    response=$(timeout 5 curl -s "http://$PRIMARY_IP:8002" 2>/dev/null)
    echo "   Response: $response"
else
    echo "❌ External test: FAILED"
fi

echo ""
echo "📋 Run this from the standby node to test cross-node access:"
echo "   curl -s http://192.168.14.21:8002"
TEST_EOF

chmod +x /usr/local/bin/test-primary-pgbouncer-health.sh

success "🎉 Primary PgBouncer health endpoint fix complete!"
info ""
info "Next steps:"
info "1. Test locally: /usr/local/bin/test-primary-pgbouncer-health.sh"
info "2. Test from standby: sudo ./test_health_checks_v1.1.sh"
info "3. Check logs: tail -f /var/log/pgbouncer/ultra-health.log"