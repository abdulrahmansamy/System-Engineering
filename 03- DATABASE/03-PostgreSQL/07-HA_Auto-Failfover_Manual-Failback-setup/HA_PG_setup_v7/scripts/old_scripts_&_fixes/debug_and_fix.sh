#!/bin/bash
# Comprehensive Health Endpoint Debug and Fix Script
# This script will diagnose and fix all health endpoint issues

set -e

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🚑 Comprehensive Health Endpoint Debug & Fix"
info "=============================================="

# Get node info
ROLE=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
SELF_IP=$(hostname -I | awk '{print $1}')

info "Node: $ROLE (IP: $SELF_IP)"

# Step 1: Complete cleanup
info "🧹 Complete cleanup of all health processes..."
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "pg_health" 2>/dev/null || true
pkill -f "pgbouncer_health" 2>/dev/null || true
sleep 3

# Stop any systemd services
systemctl stop postgresql-ha-health.service 2>/dev/null || true
systemctl stop pgbouncer-health-monitor.service 2>/dev/null || true
sleep 2

# Step 2: Debug network connectivity
info "🔍 Debugging network and firewall..."

# Check if ports are already in use
if netstat -tuln | grep -q ":8001 "; then
    warn "Port 8001 already in use"
    netstat -tuln | grep ":8001"
fi

if netstat -tuln | grep -q ":8002 "; then
    warn "Port 8002 already in use"
    netstat -tuln | grep ":8002"
fi

# Step 3: Configure comprehensive firewall rules
info "🔥 Configuring comprehensive firewall rules..."

# iptables rules (be very permissive for health endpoints)
iptables -D INPUT -p tcp --dport 8001 -j DROP 2>/dev/null || true
iptables -D INPUT -p tcp --dport 8002 -j DROP 2>/dev/null || true
iptables -I INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 8002 -j ACCEPT 2>/dev/null || true

# UFW rules if available
if command -v ufw >/dev/null 2>&1; then
    ufw allow 8001 2>/dev/null || true
    ufw allow 8002 2>/dev/null || true
fi

info "✓ Firewall configured"

# Step 4: Create and test PostgreSQL health endpoint
info "🏥 Creating PostgreSQL health endpoint (port 8001)..."

# Create a robust PostgreSQL health script
cat > /tmp/debug_pg_health.sh << 'PGEOF'
#!/bin/bash
SELF_IP=$(hostname -I | awk '{print $1}')

while true; do
    # Test PostgreSQL connectivity
    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
        # Get role
        role=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
        
        # Build response
        response="{\"status\":\"healthy\",\"service\":\"postgresql-ha\",\"role\":\"$role\",\"message\":\"PostgreSQL $role operational\",\"timestamp\":\"$(date -Iseconds)\",\"node_ip\":\"$SELF_IP\"}"
        http_status="HTTP/1.1 200 OK"
    else
        response="{\"status\":\"unhealthy\",\"service\":\"postgresql-ha\",\"role\":\"unknown\",\"message\":\"PostgreSQL not accessible\",\"timestamp\":\"$(date -Iseconds)\",\"node_ip\":\"$SELF_IP\"}"
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    content_length=${#response}
    
    # Send HTTP response with proper headers
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nServer: PostgreSQL-HA-Debug/1.0\r\n\r\n%s" \
        "$http_status" "$content_length" "$response" | nc -l -s 0.0.0.0 -p 8001 -q 1 2>/dev/null || sleep 1
done
PGEOF

chmod +x /tmp/debug_pg_health.sh

# Start PostgreSQL health endpoint
nohup /tmp/debug_pg_health.sh >/dev/null 2>&1 &
PG_HEALTH_PID=$!
sleep 3

# Test PostgreSQL health endpoint
if timeout 10 curl -s http://localhost:8001 >/dev/null 2>&1; then
    success "✅ PostgreSQL health endpoint (8001) is working"
    response=$(timeout 5 curl -s http://localhost:8001 2>/dev/null)
    info "Response: $response"
else
    error "❌ PostgreSQL health endpoint (8001) failed"
    info "Checking process..."
    if ps -p $PG_HEALTH_PID >/dev/null 2>&1; then
        info "Process is running but not responding - may be firewall issue"
    else
        error "Process died - checking for errors"
    fi
fi

# Step 5: Create and test PgBouncer health endpoint  
info "🏥 Creating PgBouncer health endpoint (port 8002)..."

cat > /tmp/debug_pgbouncer_health.sh << 'PGBEOF'
#!/bin/bash
SELF_IP=$(hostname -I | awk '{print $1}')

while true; do
    # Test PgBouncer connectivity
    if pgrep -f pgbouncer >/dev/null 2>&1 && timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        response="{\"service\":\"pgbouncer\",\"status\":\"healthy\",\"message\":\"PgBouncer operational\",\"timestamp\":\"$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"$SELF_IP\"}"
        http_status="HTTP/1.1 200 OK"
    else
        response="{\"service\":\"pgbouncer\",\"status\":\"unhealthy\",\"message\":\"PgBouncer not accessible\",\"timestamp\":\"$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"$SELF_IP\"}"
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    content_length=${#response}
    
    # Send HTTP response
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nServer: PgBouncer-HA-Debug/1.0\r\n\r\n%s" \
        "$http_status" "$content_length" "$response" | nc -l -s 0.0.0.0 -p 8002 -q 1 2>/dev/null || sleep 1
done
PGBEOF

chmod +x /tmp/debug_pgbouncer_health.sh

# Start PgBouncer health endpoint
nohup /tmp/debug_pgbouncer_health.sh >/dev/null 2>&1 &
PGB_HEALTH_PID=$!
sleep 3

# Test PgBouncer health endpoint
if timeout 10 curl -s http://localhost:8002 >/dev/null 2>&1; then
    success "✅ PgBouncer health endpoint (8002) is working"
    response=$(timeout 5 curl -s http://localhost:8002 2>/dev/null)
    info "Response: $response"
else
    error "❌ PgBouncer health endpoint (8002) failed"
    info "Checking process..."
    if ps -p $PGB_HEALTH_PID >/dev/null 2>&1; then
        info "Process is running but not responding - may be firewall issue"
    else
        error "Process died - checking for errors"
    fi
fi

# Step 6: Test cross-node connectivity
info "🔗 Testing cross-node connectivity..."

if [[ "$ROLE" == "primary" ]]; then
    target_ip="192.168.14.22"
    target_name="standby"
else
    target_ip="192.168.14.21"
    target_name="primary"
fi

# Test if we can reach the other node on basic ports
if timeout 5 bash -c "</dev/tcp/$target_ip/5432" 2>/dev/null; then
    success "✅ Can reach $target_name PostgreSQL port (5432)"
else
    warn "❌ Cannot reach $target_name PostgreSQL port (5432)"
fi

if timeout 5 bash -c "</dev/tcp/$target_ip/6432" 2>/dev/null; then
    success "✅ Can reach $target_name PgBouncer port (6432)"
else
    warn "❌ Cannot reach $target_name PgBouncer port (6432)"
fi

# Test health endpoints on other node
for port in 8001 8002; do
    service_name="PostgreSQL"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    if timeout 15 curl -s "http://$target_ip:$port" >/dev/null 2>&1; then
        success "✅ Can reach $target_name $service_name health ($port)"
    else
        warn "❌ Cannot reach $target_name $service_name health ($port)"
        info "  → This is expected if the fix script hasn't been run on $target_name yet"
    fi
done

# Step 7: Final status report
info ""
info "📊 FINAL STATUS REPORT"
info "======================"

# Test all local endpoints
local_working=0
for port in 8001 8002; do
    if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "✅ Local port $port: WORKING"
        local_working=$((local_working + 1))
    else
        error "❌ Local port $port: FAILED"
    fi
done

# Test external interface
external_working=0
for port in 8001 8002; do
    if timeout 10 curl -s "http://$SELF_IP:$port" >/dev/null 2>&1; then
        success "✅ External port $port: WORKING"
        external_working=$((external_working + 1))
    else
        error "❌ External port $port: FAILED"
    fi
done

info ""
info "Summary for $ROLE node ($SELF_IP):"
info "  → Local endpoints: $local_working/2 working"
info "  → External endpoints: $external_working/2 working"

if [[ $local_working -eq 2 && $external_working -eq 2 ]]; then
    success "🎉 ALL ENDPOINTS WORKING ON THIS NODE!"
    info "Run this script on the other node, then test with:"
    info "  sudo ./test_health_checks_v1.1.sh"
elif [[ $local_working -eq 2 ]]; then
    warn "🔧 Local endpoints work, but external access has issues"
    info "This might be a firewall problem. Check iptables and UFW rules."
else
    error "❌ Some endpoints failed - check the logs above"
fi

info ""
success "🚀 Debug and fix script completed!"