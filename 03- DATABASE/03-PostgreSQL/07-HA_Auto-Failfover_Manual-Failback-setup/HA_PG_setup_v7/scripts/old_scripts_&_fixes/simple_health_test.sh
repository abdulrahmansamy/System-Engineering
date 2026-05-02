#!/bin/bash
# Simple Health Endpoint Test
# Tests the minimal bulletproof health endpoints

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

echo "🧪 SIMPLE HEALTH ENDPOINT TEST"
echo "=============================="
echo

# Test function
test_endpoint() {
    local url="$1"
    local name="$2"
    local timeout="${3:-3}"
    
    echo -n "Testing $name ($url): "
    
    if response=$(timeout $timeout curl -sf "$url" 2>/dev/null); then
        if echo "$response" | jq . >/dev/null 2>&1; then
            echo "✅ WORKING"
            echo "  Response: $(echo "$response" | jq -c .)"
            return 0
        else
            echo "❌ INVALID_JSON"
            echo "  Raw response: $response"
            return 1
        fi  
    else
        echo "❌ FAILED"
        return 1
    fi
}

# Get local IP
SELF_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")
info "Testing from: $(hostname) ($SELF_IP)"

echo
info "=== LOCAL ENDPOINT TESTS ==="

# Test local endpoints
working_local=0
test_endpoint "http://localhost:8001" "PostgreSQL Local" && working_local=$((working_local+1)) || true
test_endpoint "http://localhost:8002" "PgBouncer Local" && working_local=$((working_local+1)) || true

echo
info "=== SELF-IP ENDPOINT TESTS ==="

# Test self-IP endpoints  
working_self=0
test_endpoint "http://$SELF_IP:8001" "PostgreSQL Self-IP" && working_self=$((working_self+1)) || true
test_endpoint "http://$SELF_IP:8002" "PgBouncer Self-IP" && working_self=$((working_self+1)) || true

echo
info "=== CROSS-NODE ENDPOINT TESTS ==="

# Test cross-node endpoints
working_cross=0

# Determine other node IP based on current node
if [[ "$SELF_IP" == "192.168.14.21" ]]; then
    OTHER_IP="192.168.14.22"
    OTHER_NAME="standby"
elif [[ "$SELF_IP" == "192.168.14.22" ]]; then
    OTHER_IP="192.168.14.21" 
    OTHER_NAME="primary"
else
    OTHER_IP=""
    OTHER_NAME="unknown"
fi

if [[ -n "$OTHER_IP" ]]; then
    test_endpoint "http://$OTHER_IP:8001" "PostgreSQL $OTHER_NAME" 5 && working_cross=$((working_cross+1)) || true
    test_endpoint "http://$OTHER_IP:8002" "PgBouncer $OTHER_NAME" 5 && working_cross=$((working_cross+1)) || true
else
    info "Cross-node testing skipped (unknown network topology)"
fi

echo
info "=== SUMMARY ==="
echo "Local endpoints:    $working_local/2 working"  
echo "Self-IP endpoints:  $working_self/2 working"
if [[ -n "$OTHER_IP" ]]; then
    echo "Cross-node endpoints: $working_cross/2 working"
    total_working=$((working_local + working_self + working_cross))
    total_possible=6
else
    total_working=$((working_local + working_self))  
    total_possible=4
fi

echo
echo "OVERALL RESULT: $total_working/$total_possible endpoints working"

if [[ $total_working -eq $total_possible ]]; then
    success "🎉 ALL HEALTH ENDPOINTS WORKING!"
    success "✅ Ready for production load balancer integration"
elif [[ $working_local -eq 2 ]]; then
    success "✅ Local endpoints working - minimal success achieved"
    if [[ $working_cross -lt 2 && -n "$OTHER_IP" ]]; then
        error "❌ Cross-node connectivity issues detected"
        info "This may be due to firewall rules or network configuration"
    fi
else
    error "❌ Local endpoints not working - service issues detected"
    info "Check service status with: systemctl status minimal-pg-health.service"
fi

echo
info "Next steps:"
if [[ $total_working -eq $total_possible ]]; then
    echo "1. ✅ Health endpoints are ready"
    echo "2. ✅ Configure GCP Load Balancer health checks"
    echo "3. ✅ Point health checks to ports 8001/8002"
else
    echo "1. Fix any failing endpoints shown above"
    echo "2. Re-run this test until all endpoints work"
    echo "3. Check network/firewall for cross-node issues"
fi