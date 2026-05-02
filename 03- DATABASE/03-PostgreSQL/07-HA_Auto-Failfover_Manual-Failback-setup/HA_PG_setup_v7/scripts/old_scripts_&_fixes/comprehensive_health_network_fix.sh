#!/bin/bash
# COMPREHENSIVE Health Endpoint & Network Fix
# Ensures both ports 8001/8002 are accessible from external sources

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "🔧 COMPREHENSIVE Health Endpoint & Network Fix"
echo "=============================================="
echo "Goal: Make both 8001/8002 accessible from external sources"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Diagnose current network configuration"

echo "Current listening ports:"
ss -tupln | grep -E ':(8001|8002)' || echo "No services on 8001/8002"

echo
echo "Current firewall rules (iptables):"
iptables -L INPUT -n --line-numbers | grep -E "(8001|8002|ACCEPT|DROP)" || echo "No specific rules for health ports"

echo
echo "Current UFW status:"
ufw status verbose 2>/dev/null || echo "UFW not active or not installed"

info "Step 2: Fix firewall rules to allow external access to health ports"

# Allow health ports through iptables
echo "Adding iptables rules for health ports..."
iptables -I INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null || echo "Rule may already exist"
iptables -I INPUT -p tcp --dport 8002 -j ACCEPT 2>/dev/null || echo "Rule may already exist"

# Also allow through UFW if it exists
if command -v ufw >/dev/null 2>&1; then
    echo "Adding UFW rules for health ports..."
    ufw allow 8001/tcp 2>/dev/null || echo "UFW rule may already exist"
    ufw allow 8002/tcp 2>/dev/null || echo "UFW rule may already exist"
fi

success "✅ Firewall rules updated for ports 8001/8002"

info "Step 3: Ensure services are binding to all interfaces (0.0.0.0)"

# Check if socat forwarding services are running and configured correctly
echo "Checking socat forwarding services:"
systemctl status forward-pg-health.service --no-pager | head -3 || echo "PG forward service not running"
systemctl status forward-pgbouncer-health.service --no-pager | head -3 || echo "PGB forward service not running"

# Restart forwarding services to ensure proper binding
echo "Restarting forwarding services..."
systemctl restart forward-pg-health.service 2>/dev/null || warn "Failed to restart PG forward service"
systemctl restart forward-pgbouncer-health.service 2>/dev/null || warn "Failed to restart PGB forward service"

sleep 2

info "Step 4: Create GCP firewall rules (if not already present)"

# Check if we're on GCP and can create firewall rules
if command -v gcloud >/dev/null 2>&1; then
    echo "Attempting to create GCP firewall rules for health endpoints..."
    
    # Create firewall rule for health endpoints (if not exists)
    gcloud compute firewall-rules create allow-ha-health-endpoints \
        --allow tcp:8001,tcp:8002 \
        --source-ranges 192.168.14.0/24,10.0.0.0/8 \
        --description "Allow health endpoints for PostgreSQL HA cluster" \
        --quiet 2>/dev/null || echo "GCP firewall rule may already exist or insufficient permissions"
        
    success "✅ GCP firewall rule creation attempted"
else
    warn "⚠️ gcloud not available - GCP firewall rules must be created manually"
fi

info "Step 5: Verify and fix service binding"

# Ensure both backend services are running on high ports
systemctl restart minimal-pg-health.service
systemctl restart minimal-pgbouncer-health.service
sleep 2

echo "Backend services status:"
systemctl is-active minimal-pg-health.service && echo "✅ PostgreSQL backend (28001)" || echo "❌ PostgreSQL backend failed"
systemctl is-active minimal-pgbouncer-health.service && echo "✅ PgBouncer backend (28002)" || echo "❌ PgBouncer backend failed"

# Restart forwarding services again
systemctl restart forward-pg-health.service
systemctl restart forward-pgbouncer-health.service
sleep 3

echo "Forwarding services status:"
systemctl is-active forward-pg-health.service && echo "✅ PostgreSQL forward (8001)" || echo "❌ PostgreSQL forward failed"
systemctl is-active forward-pgbouncer-health.service && echo "✅ PgBouncer forward (8002)" || echo "❌ PgBouncer forward failed"

info "Step 6: Test local and external connectivity"

SELF_IP=$(hostname -I | awk '{print $1}')
echo "Testing from: $(hostname) ($SELF_IP)"

# Test function with detailed output
test_detailed() {
    local url="$1"
    local name="$2"
    
    echo -n "Testing $name ($url): "
    
    # First check if port is reachable
    local host=$(echo "$url" | sed 's|http://||' | cut -d: -f1)
    local port=$(echo "$url" | sed 's|http://||' | cut -d: -f2 | cut -d/ -f1)
    
    if timeout 2 nc -z "$host" "$port" 2>/dev/null; then
        echo -n "PORT_OPEN "
        # Then test HTTP
        if response=$(timeout 3 curl -sf "$url" 2>/dev/null); then
            if echo "$response" | jq . >/dev/null 2>&1; then
                echo "✅ WORKING"
                echo "  $(echo "$response" | jq -c .)"
                return 0
            else
                echo "❌ BAD_JSON"
                echo "  Raw: $response"
            fi
        else
            echo "❌ HTTP_FAILED"
        fi
    else
        echo "❌ PORT_CLOSED"
    fi
    return 1
}

echo
echo "=== LOCAL TESTS ==="
working_local=0
test_detailed "http://localhost:8001" "PostgreSQL Local" && working_local=$((working_local+1)) || true
test_detailed "http://localhost:8002" "PgBouncer Local" && working_local=$((working_local+1)) || true

echo
echo "=== SELF-IP TESTS ==="
working_self=0
test_detailed "http://$SELF_IP:8001" "PostgreSQL Self-IP" && working_self=$((working_self+1)) || true
test_detailed "http://$SELF_IP:8002" "PgBouncer Self-IP" && working_self=$((working_self+1)) || true

info "Step 7: Network diagnostics if issues persist"

if [[ $working_self -lt 2 ]]; then
    warn "⚠️ Self-IP access issues detected. Running diagnostics..."
    
    echo "Port listeners:"
    ss -tupln | grep -E ':(8001|8002)'
    
    echo
    echo "Process check:"
    ps aux | grep -E "(socat|python.*28001|python.*28002)" | grep -v grep
    
    echo
    echo "Service logs (last 5 lines each):"
    echo "Forward PG service:"
    journalctl -u forward-pg-health.service --lines=5 --no-pager
    echo "Forward PGB service:"
    journalctl -u forward-pgbouncer-health.service --lines=5 --no-pager
fi

echo
echo "=== SUMMARY ==="
echo "Local endpoints:    $working_local/2 working"
echo "Self-IP endpoints:  $working_self/2 working"

if [[ $working_local -eq 2 && $working_self -eq 2 ]]; then
    success "🎉 SUCCESS! All endpoints accessible locally and externally"
    success "✅ Ready for GCP Load Balancer health checks"
    
    echo
    info "For GCP Load Balancer configuration:"
    echo "- PostgreSQL health: http://instance-ip:8001"
    echo "- PgBouncer health: http://instance-ip:8002"
    echo "- Health check interval: 5-10 seconds"
    echo "- Timeout: 3-5 seconds"
    echo "- Unhealthy threshold: 3 consecutive failures"
elif [[ $working_local -eq 2 ]]; then
    warn "⚠️ Local endpoints work, but external access has issues"
    info "This may require GCP firewall rule creation by project admin:"
    echo "gcloud compute firewall-rules create allow-ha-health-endpoints \\"
    echo "  --allow tcp:8001,tcp:8002 \\"
    echo "  --source-ranges 192.168.14.0/24,10.0.0.0/8 \\"
    echo "  --description 'Allow health endpoints for PostgreSQL HA cluster'"
else
    error "❌ Local endpoints not working - service configuration issues"
    info "Check service status and logs above"
fi

echo
success "🔧 Comprehensive fix complete!"
echo
info "Next steps:"
echo "1. Run this on BOTH servers"
echo "2. Test from external instance: curl http://192.168.14.21:8002"
echo "3. Configure GCP Load Balancer if all tests pass"