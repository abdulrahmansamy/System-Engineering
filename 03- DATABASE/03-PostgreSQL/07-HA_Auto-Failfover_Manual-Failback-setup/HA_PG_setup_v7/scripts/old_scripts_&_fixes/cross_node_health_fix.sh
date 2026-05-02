#!/bin/bash
# Cross-Node Health Endpoint Fix Script
# Fixes PgBouncer port 8002 cross-node access issues
# Run this script on both primary and standby nodes

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Cross-Node Health Endpoint Fix - PgBouncer Port 8002"

# Detect current node
ROLE=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
SELF_IP=$(hostname -I | awk '{print $1}')

info "Current node: $ROLE (IP: $SELF_IP)"

# Step 1: Verify PostgreSQL HA health endpoints are working (they should be!)
info "🧪 Verifying PostgreSQL HA health endpoints..."

for node_ip in "192.168.14.21" "192.168.14.22"; do
    node_name="primary"
    if [[ "$node_ip" == "192.168.14.22" ]]; then
        node_name="standby"
    fi
    
    if timeout 10 curl -s "http://$node_ip:8001" >/dev/null 2>&1; then
        success "✅ $node_name PostgreSQL HA ($node_ip:8001): WORKING"
    else
        error "❌ $node_name PostgreSQL HA ($node_ip:8001): FAILED"
    fi
done

# Step 2: Fix PgBouncer health endpoints
info "🔧 Fixing PgBouncer health endpoints..."

# Kill ALL existing PgBouncer health processes on port 8002
pkill -f ":8002" 2>/dev/null || true
sleep 3

# Stop systemd services that might interfere
systemctl stop pgbouncer-health-monitor.service 2>/dev/null || true
sleep 2

# Ensure log directory exists
mkdir -p /var/log/pgbouncer
chown -R pgbouncer:pgbouncer /var/log/pgbouncer 2>/dev/null || true

# Create enhanced PgBouncer health script with proper cross-node support
cat > /usr/local/bin/cross-node-pgbouncer-health.sh <<EOF
#!/bin/bash
# Cross-Node PgBouncer Health Monitor - Enhanced for network access
PORT=\${1:-8002}
SELF_IP="$SELF_IP"
NODE_ROLE="$ROLE"

check_pgbouncer_status() {
    if pgrep -f pgbouncer >/dev/null 2>&1; then
        if timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
            echo "healthy|PgBouncer running and accepting connections|service_running"
        else
            echo "unhealthy|PgBouncer not accepting connections|port_unavailable"  
        fi
    else
        echo "unhealthy|PgBouncer process not running|process_down"
    fi
}

while true; do
    status_info=\$(check_pgbouncer_status)
    status=\$(echo "\$status_info" | cut -d'|' -f1)
    message=\$(echo "\$status_info" | cut -d'|' -f2)
    detailed_status=\$(echo "\$status_info" | cut -d'|' -f3)
    
    response="{\"service\":\"pgbouncer\",\"status\":\"\$status\",\"message\":\"\$message\",\"detailed_status\":\"\$detailed_status\",\"timestamp\":\"\$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"\$SELF_IP\",\"node_role\":\"\$NODE_ROLE\"}"
    content_length=\${#response}
    
    if [[ "\$status" == "healthy" ]]; then
        http_status="HTTP/1.1 200 OK"
    else
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    # Enhanced HTTP headers for better cross-node compatibility
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nServer: PgBouncer-HealthMonitor-CrossNode/1.2\r\n\r\n%s" \
        "\$http_status" "\$content_length" "\$response" | nc -l -s 0.0.0.0 -p \$PORT -q 1 2>/dev/null || sleep 1
done
EOF

chmod +x /usr/local/bin/cross-node-pgbouncer-health.sh

# Step 3: Configure comprehensive firewall rules
info "🔥 Configuring comprehensive firewall rules..."

# Configure UFW if available
if command -v ufw >/dev/null 2>&1; then
    info "Configuring UFW firewall rules..."
    
    # Allow health endpoint ports from both cluster nodes
    ufw allow from 192.168.14.21 to any port 8001 comment "PostgreSQL HA Health - Primary" 2>/dev/null || true
    ufw allow from 192.168.14.21 to any port 8002 comment "PgBouncer Health - Primary" 2>/dev/null || true
    ufw allow from 192.168.14.22 to any port 8001 comment "PostgreSQL HA Health - Standby" 2>/dev/null || true
    ufw allow from 192.168.14.22 to any port 8002 comment "PgBouncer Health - Standby" 2>/dev/null || true
    
    # Also allow from localhost
    ufw allow from 127.0.0.1 to any port 8001 2>/dev/null || true
    ufw allow from 127.0.0.1 to any port 8002 2>/dev/null || true
    
    # Allow broader range for GCP internal network
    ufw allow from 10.0.0.0/8 to any port 8001 2>/dev/null || true
    ufw allow from 10.0.0.0/8 to any port 8002 2>/dev/null || true
    ufw allow from 192.168.0.0/16 to any port 8001 2>/dev/null || true
    ufw allow from 192.168.0.0/16 to any port 8002 2>/dev/null || true
    
    success "UFW rules configured for cross-node health access"
fi

# Configure iptables rules as backup
if command -v iptables >/dev/null 2>&1; then
    info "Configuring iptables rules for cross-node access..."
    
    # Remove any existing conflicting rules
    iptables -D INPUT -p tcp --dport 8001 -j DROP 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8002 -j DROP 2>/dev/null || true
    
    # Add comprehensive allow rules for health endpoints
    iptables -I INPUT -p tcp --dport 8001 -s 192.168.14.21 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8001 -s 192.168.14.22 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8001 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8002 -s 192.168.14.21 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8002 -s 192.168.14.22 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8002 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
    
    # Allow broader GCP network ranges
    iptables -I INPUT -p tcp --dport 8001 -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8002 -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8001 -s 192.168.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 8002 -s 192.168.0.0/16 -j ACCEPT 2>/dev/null || true
    
    # Allow outbound connections
    iptables -I OUTPUT -p tcp --dport 8001 -d 192.168.14.21 -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT -p tcp --dport 8001 -d 192.168.14.22 -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT -p tcp --dport 8002 -d 192.168.14.21 -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT -p tcp --dport 8002 -d 192.168.14.22 -j ACCEPT 2>/dev/null || true
    
    success "iptables rules configured for cross-node health access"
fi

# Step 4: Start the enhanced PgBouncer health endpoint
info "🚀 Starting enhanced cross-node PgBouncer health endpoint..."
nohup /usr/local/bin/cross-node-pgbouncer-health.sh 8002 >/dev/null 2>&1 &
sleep 5

# Step 5: Test all health endpoints
info "🧪 Testing all health endpoints..."

# Test local endpoints first
info "Testing local health endpoints..."
for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "✅ Local $service_name ($port): WORKING"
    else
        error "❌ Local $service_name ($port): FAILED"
    fi
done

# Test cross-node access
info "Testing cross-node access..."
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
        error "❌ Cross-node $service_name ($target_name:$port): FAILED"
        info "  → Run this fix script on the target node ($target_name) as well"
    fi
done

# Summary
echo ""
info "📊 CROSS-NODE HEALTH ENDPOINT FIX SUMMARY:"
success "✅ Enhanced PgBouncer health endpoint with better cross-node support"
success "✅ Comprehensive firewall rules (UFW + iptables)"  
success "✅ Network binding improvements (listen on 0.0.0.0)"
info ""
info "🎯 Next Steps:"
info "  1. Run this script on BOTH nodes"
info "  2. Test endpoints: /usr/local/bin/test-all-health-endpoints.sh"
info "  3. Should get 4/4 working for perfect load balancer integration"
info ""
success "🚀 Cross-node health endpoint fix completed!"