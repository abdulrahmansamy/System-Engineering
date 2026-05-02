#!/bin/bash
# Emergency Health Endpoint Fix Script
# Run this if health endpoints are not working after deployment
# Usage: sudo ./emergency_health_fix.sh

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🚑 Emergency Health Endpoint Fix"
info "================================"

# Detect current role
ROLE=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
SELF_IP=$(hostname -I | awk '{print $1}')

info "Node: $ROLE (IP: $SELF_IP)"

# Step 1: Kill all existing health processes
info "🔧 Cleaning up existing health processes..."
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "health" 2>/dev/null || true
sleep 3

# Step 2: Stop conflicting services
systemctl stop postgresql-ha-health.service 2>/dev/null || true
systemctl stop pgbouncer-health-monitor.service 2>/dev/null || true
systemctl stop pg-ha-health.service 2>/dev/null || true
systemctl stop pgbouncer-health.service 2>/dev/null || true
sleep 2

# Step 3: Create simple, working health endpoints
info "🏥 Creating emergency health endpoints..."

# PostgreSQL HA Health Endpoint (Port 8001)
cat > /tmp/emergency-pg-health.sh <<EOF
#!/bin/bash
PORT=8001
ROLE="$ROLE"
SELF_IP="$SELF_IP"

while true; do
    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
        pg_role=\$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
        
        if [[ "\$pg_role" == "\$ROLE" ]]; then
            status="healthy"
            message="PostgreSQL \$ROLE operational"
            http_code="200"
        else
            status="unhealthy" 
            message="Role mismatch"
            http_code="503"
        fi
    else
        status="unhealthy"
        message="PostgreSQL not accessible"
        http_code="503"
    fi
    
    response="{\"status\":\"\$status\",\"service\":\"postgresql-ha\",\"role\":\"\$ROLE\",\"message\":\"\$message\",\"timestamp\":\"\$(date -Iseconds)\",\"node_ip\":\"\$SELF_IP\"}"
    content_length=\${#response}
    
    if [[ "\$http_code" == "200" ]]; then
        http_status="HTTP/1.1 200 OK"
    else
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s" \
        "\$http_status" "\$content_length" "\$response" | nc -l -s 0.0.0.0 -p \$PORT -q 1 2>/dev/null || sleep 1
done
EOF

# PgBouncer Health Endpoint (Port 8002)
cat > /tmp/emergency-pgbouncer-health.sh <<EOF
#!/bin/bash
PORT=8002
SELF_IP="$SELF_IP"

while true; do
    if pgrep -f pgbouncer >/dev/null 2>&1 && timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        status="healthy"
        message="PgBouncer operational"
        http_code="200"
    else
        status="unhealthy"
        message="PgBouncer not accessible"
        http_code="503"
    fi
    
    response="{\"service\":\"pgbouncer\",\"status\":\"\$status\",\"message\":\"\$message\",\"timestamp\":\"\$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"\$SELF_IP\"}"
    content_length=\${#response}
    
    if [[ "\$http_code" == "200" ]]; then
        http_status="HTTP/1.1 200 OK"
    else
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s" \
        "\$http_status" "\$content_length" "\$response" | nc -l -s 0.0.0.0 -p \$PORT -q 1 2>/dev/null || sleep 1
done
EOF

chmod +x /tmp/emergency-pg-health.sh /tmp/emergency-pgbouncer-health.sh

# Step 4: Start emergency health endpoints
info "🚀 Starting emergency health endpoints..."
nohup /tmp/emergency-pg-health.sh >/dev/null 2>&1 &
nohup /tmp/emergency-pgbouncer-health.sh >/dev/null 2>&1 &
sleep 5

# Step 5: Configure firewall rules
info "🔥 Ensuring firewall rules are in place..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow from 192.168.14.21 to any port 8001 2>/dev/null || true
    ufw allow from 192.168.14.21 to any port 8002 2>/dev/null || true
    ufw allow from 192.168.14.22 to any port 8001 2>/dev/null || true
    ufw allow from 192.168.14.22 to any port 8002 2>/dev/null || true
    ufw allow from 127.0.0.1 to any port 8001 2>/dev/null || true
    ufw allow from 127.0.0.1 to any port 8002 2>/dev/null || true
fi

if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8002 -j ACCEPT 2>/dev/null || true
fi

# Step 6: Test the endpoints
info "🧪 Testing emergency health endpoints..."
sleep 3

# Test PostgreSQL HA endpoint
if timeout 10 curl -s "http://localhost:8001" >/dev/null 2>&1; then
    success "✅ PostgreSQL HA Health (8001): WORKING"
    response=$(timeout 5 curl -s "http://localhost:8001" 2>/dev/null || echo "{}")
    if command -v jq >/dev/null 2>&1 && echo "$response" | jq . >/dev/null 2>&1; then
        status_val=$(echo "$response" | jq -r '.status // "unknown"')
        role_val=$(echo "$response" | jq -r '.role // "unknown"')  
        info "  → Status: $status_val, Role: $role_val"
    fi
else
    error "❌ PostgreSQL HA Health (8001): FAILED"
fi

# Test PgBouncer endpoint
if timeout 10 curl -s "http://localhost:8002" >/dev/null 2>&1; then
    success "✅ PgBouncer Health (8002): WORKING"
    response=$(timeout 5 curl -s "http://localhost:8002" 2>/dev/null || echo "{}")
    if command -v jq >/dev/null 2>&1 && echo "$response" | jq . >/dev/null 2>&1; then
        service_val=$(echo "$response" | jq -r '.service // "unknown"')
        status_val=$(echo "$response" | jq -r '.status // "unknown"')
        info "  → Service: $service_val, Status: $status_val"
    fi
else
    error "❌ PgBouncer Health (8002): FAILED"
fi

# Step 7: Test cross-node connectivity
info "🔗 Testing cross-node connectivity..."
if [[ "$ROLE" == "primary" ]]; then
    target_ip="192.168.14.22"
    target_name="standby"
else
    target_ip="192.168.14.21"
    target_name="primary"
fi

for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    if timeout 15 curl -s "http://$target_ip:$port" >/dev/null 2>&1; then
        success "✅ Cross-node $service_name ($target_name:$port): WORKING"
    else
        warn "❌ Cross-node $service_name ($target_name:$port): FAILED"
        info "  → Ensure this fix script is run on both nodes"
    fi
done

info ""
info "🎯 EMERGENCY FIX COMPLETE"
info "========================="
info "Health endpoints are now running as background processes."
info "Test all endpoints: /usr/local/bin/test-all-health-endpoints.sh"
info ""
success "Emergency health endpoint fix completed!"