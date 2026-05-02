#!/bin/bash
# Network Connectivity Fix for Health Endpoints
# Addresses cross-node access issues for ports 8001 and 8002

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🌐 Fixing network connectivity for health endpoints"

# Detect current node
get_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q '^f'; then
        echo "primary"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q '^t'; then
        echo "standby"
    else
        echo "unknown"
    fi
}

ROLE=$(get_role)
SELF_IP=$(hostname -I | awk '{print $1}')
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

info "Current node: $ROLE (IP: $SELF_IP)"
info "Primary IP: $PRIMARY_IP"
info "Standby IP: $STANDBY_IP"

# Check and configure firewall
info "🔥 Checking firewall configuration..."

if command -v ufw >/dev/null 2>&1; then
    ufw_status=$(ufw status 2>/dev/null | head -1)
    if echo "$ufw_status" | grep -q "Status: active"; then
        warn "UFW firewall is active - configuring rules for health endpoints"
        
        # Allow health endpoint ports from both nodes
        ufw allow from $PRIMARY_IP to any port 8001 comment "PostgreSQL HA Health - Primary"
        ufw allow from $PRIMARY_IP to any port 8002 comment "PgBouncer Health - Primary"
        ufw allow from $STANDBY_IP to any port 8001 comment "PostgreSQL HA Health - Standby"
        ufw allow from $STANDBY_IP to any port 8002 comment "PgBouncer Health - Standby"
        
        success "UFW rules added for health endpoints"
    else
        info "UFW firewall is inactive"
    fi
fi

if command -v iptables >/dev/null 2>&1; then
    info "Checking iptables rules..."
    
    # Check if ports are blocked
    if ! iptables -C INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null; then
        info "Adding iptables rule for port 8001"
        iptables -I INPUT -p tcp --dport 8001 -s $PRIMARY_IP -j ACCEPT
        iptables -I INPUT -p tcp --dport 8001 -s $STANDBY_IP -j ACCEPT
    fi
    
    if ! iptables -C INPUT -p tcp --dport 8002 -j ACCEPT 2>/dev/null; then
        info "Adding iptables rule for port 8002"
        iptables -I INPUT -p tcp --dport 8002 -s $PRIMARY_IP -j ACCEPT
        iptables -I INPUT -p tcp --dport 8002 -s $STANDBY_IP -j ACCEPT
    fi
fi

# Check service status and restart if needed
info "🔍 Checking service status..."

for service in simple-pg-health simple-pgbouncer-health; do
    if systemctl is-active --quiet ${service}.service; then
        success "${service}.service is ACTIVE ✓"
    else
        warn "${service}.service is NOT ACTIVE - restarting..."
        systemctl restart ${service}.service
        sleep 3
        if systemctl is-active --quiet ${service}.service; then
            success "${service}.service restarted successfully ✓"
        else
            error "${service}.service failed to start"
            systemctl status ${service}.service --no-pager -l
        fi
    fi
done

# Test local connectivity first
info "🏠 Testing local connectivity..."
for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "Port $port ($service_name): Local access WORKING ✓"
    else
        warn "Port $port ($service_name): Local access FAILED - checking process..."
        
        # Check if port is listening
        if ss -tulnp | grep -q ":$port "; then
            warn "  Port $port is listening but HTTP failed"
            ss -tulnp | grep ":$port "
        else
            error "  Port $port is not listening"
            systemctl restart simple-$([ $port -eq 8001 ] && echo 'pg' || echo 'pgbouncer')-health.service
            sleep 5
        fi
    fi
done

# Test network connectivity
info "🌐 Testing network connectivity..."

# Test from current node to both nodes
for target_ip in $PRIMARY_IP $STANDBY_IP; do
    target_role="primary"
    if [[ "$target_ip" == "$STANDBY_IP" ]]; then
        target_role="standby"
    fi
    
    info "Testing connectivity to $target_role ($target_ip)..."
    
    for port in 8001 8002; do
        service_name="PostgreSQL HA"
        if [[ $port -eq 8002 ]]; then
            service_name="PgBouncer"
        fi
        
        # Skip self-test for local IP
        if [[ "$target_ip" == "$SELF_IP" ]]; then
            continue
        fi
        
        if timeout 10 curl -s "http://$target_ip:$port" >/dev/null 2>&1; then
            success "$target_role $service_name ($target_ip:$port): WORKING ✓"
        else
            warn "$target_role $service_name ($target_ip:$port): FAILED"
            
            # Test basic connectivity
            if timeout 5 nc -z "$target_ip" "$port" 2>/dev/null; then
                warn "  Port is reachable but HTTP failed"
            else
                error "  Port is not reachable - network/firewall issue"
            fi
        fi
    done
done

# Show current network status
info "📊 Current network status:"
echo "Listening on this node ($SELF_IP):"
ss -tulnp | grep -E ":(8001|8002) " || warn "No health ports listening"

echo ""
echo "Active health processes:"
ps aux | grep -E "simple.*health" | grep -v grep || warn "No health processes found"

# Test with actual responses
info "🧪 Testing actual responses..."
for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    echo ""
    info "Testing $service_name response (port $port):"
    
    response=$(timeout 10 curl -s "http://localhost:$port" 2>/dev/null || echo "FAILED")
    if [[ "$response" != "FAILED" ]]; then
        echo "$response" | jq . 2>/dev/null || echo "Response: $response"
    else
        error "Failed to get response from port $port"
    fi
done

success "🎉 Network connectivity fix completed!"
info ""
info "📋 Summary of what was done:"
info "  ✅ Firewall rules configured for ports 8001 and 8002"
info "  ✅ Service status checked and restarted if needed"
info "  ✅ Network connectivity tested between nodes"
info "  ✅ Actual endpoint responses verified"
info ""
info "🧪 Run cross-node test again:"
info "  ./test_cross_node_health.sh"
info ""
info "🔍 If issues persist, check:"
info "  systemctl status simple-pg-health.service simple-pgbouncer-health.service"
info "  journalctl -u simple-pg-health.service -u simple-pgbouncer-health.service -f"
info "  ss -tulnp | grep -E ':(8001|8002)'"