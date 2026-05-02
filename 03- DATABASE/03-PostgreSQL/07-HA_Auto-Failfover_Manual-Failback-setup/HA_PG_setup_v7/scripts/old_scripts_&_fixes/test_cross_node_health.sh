#!/bin/bash
# Cross-Node Health Endpoint Test
# Tests connectivity between PostgreSQL HA nodes

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🌐 Testing cross-node health endpoint connectivity"

# Node IPs (adjust these if different)
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

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

CURRENT_ROLE=$(get_role)
CURRENT_IP=$(hostname -I | awk '{print $1}')
info "Current node: $CURRENT_ROLE (IP: $CURRENT_IP)"

# Test function
test_endpoint() {
    local ip=$1
    local port=$2
    local node_name=$3
    local service_name=$4
    
    info "Testing $node_name $service_name ($ip:$port)..."
    
    if timeout 10 curl -s "http://$ip:$port" >/dev/null 2>&1; then
        success "$node_name $service_name: RESPONDING ✓"
        
        # Get and display response
        local response=$(timeout 5 curl -s "http://$ip:$port" 2>/dev/null)
        if command -v jq >/dev/null 2>&1; then
            echo "$response" | jq . 2>/dev/null || echo "  Raw response: $response"
        else
            echo "  Response: $(echo "$response" | head -c 200)"
        fi
        echo ""
        return 0
    else
        error "$node_name $service_name: NOT RESPONDING"
        
        # Try to determine the issue
        if timeout 3 nc -z "$ip" "$port" 2>/dev/null; then
            warn "  Port is reachable but HTTP request failed"
        else
            error "  Port is not reachable (network/firewall issue)"
        fi
        echo ""
        return 1
    fi
}

# Test matrix
declare -A tests=(
    ["$PRIMARY_IP:8001"]="Primary PostgreSQL-HA"
    ["$PRIMARY_IP:8002"]="Primary PgBouncer"
    ["$STANDBY_IP:8001"]="Standby PostgreSQL-HA"
    ["$STANDBY_IP:8002"]="Standby PgBouncer"
)

# Run tests
info "🧪 Running comprehensive cross-node health endpoint tests..."
echo ""

total_tests=0
passed_tests=0

for endpoint in "${!tests[@]}"; do
    ip=$(echo "$endpoint" | cut -d':' -f1)
    port=$(echo "$endpoint" | cut -d':' -f2)
    description="${tests[$endpoint]}"
    
    total_tests=$((total_tests + 1))
    
    if test_endpoint "$ip" "$port" "$(echo "$description" | cut -d' ' -f1)" "$(echo "$description" | cut -d' ' -f2)"; then
        passed_tests=$((passed_tests + 1))
    fi
done

# Summary
echo "========================================"
info "🏁 Cross-Node Health Test Summary"
echo "========================================"
success "Passed: $passed_tests/$total_tests tests"

if [[ $passed_tests -eq $total_tests ]]; then
    success "🎉 ALL TESTS PASSED - Health endpoints are working perfectly!"
    info ""
    info "✅ Your PostgreSQL HA cluster health endpoints are ready for:"
    info "  • Load balancer integration"
    info "  • Cross-node monitoring"
    info "  • Automated health checks"
    info "  • Production deployment"
elif [[ $passed_tests -gt 0 ]]; then
    warn "⚠️  PARTIAL SUCCESS - Some endpoints are working"
    info ""
    info "🔧 Troubleshooting suggestions:"
    info "  • Check firewall rules for ports 8001 and 8002"
    info "  • Verify systemd services: systemctl status python-*-health.service"
    info "  • Check service logs: journalctl -u python-pg-health.service"
else
    error "❌ ALL TESTS FAILED - Health endpoints need attention"
    info ""
    info "🔧 Troubleshooting steps:"
    info "  1. Run: sudo ./check_health_status.sh"
    info "  2. Check if services are running: systemctl status python-*-health.service"
    info "  3. Verify Python scripts exist: ls -la /usr/local/bin/python-*-health.py"
    info "  4. Check firewall: sudo ufw status"
fi

echo ""
info "📊 Additional monitoring commands:"
info "  systemctl status python-pg-health.service python-pgbouncer-health.service"
info "  journalctl -u python-pg-health.service -u python-pgbouncer-health.service -f"
info "  ss -tulnp | grep -E ':(8001|8002)'"