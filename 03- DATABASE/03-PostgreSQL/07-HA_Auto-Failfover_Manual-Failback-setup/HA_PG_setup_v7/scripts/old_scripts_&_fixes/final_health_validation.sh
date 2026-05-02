#!/bin/bash
# Comprehensive Health Endpoint Test - Final Validation
# Run this script on either node to test all endpoints

set -e

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_colored() {
    local color=$1
    shift
    printf "${color}%s${NC}\n" "$*"
}

echo "🏥 COMPREHENSIVE HEALTH ENDPOINT VALIDATION"
echo "=========================================="
echo ""

# Get current node info
CURRENT_IP=$(hostname -I | awk '{print $1}')
CURRENT_ROLE=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")

info "Running from: $CURRENT_ROLE node (IP: $CURRENT_IP)"
echo ""

# Define endpoints
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

test_endpoint_comprehensive() {
    local ip=$1
    local port=$2
    local name=$3
    local service=$4
    local expected_responses=()
    
    printf "%-35s " "$name ($service):"
    
    # Test with multiple attempts and capture detailed info
    local success_count=0
    local total_attempts=3
    local responses=()
    local response_times=()
    
    for attempt in {1..3}; do
        local start_time=$(date +%s%3N)
        local response=""
        local http_code=""
        
        if response=$(timeout 8 curl -s -w "HTTPSTATUS:%{http_code}" "http://$ip:$port" 2>/dev/null); then
            local end_time=$(date +%s%3N)
            local response_time=$((end_time - start_time))
            
            # Extract HTTP status code
            http_code=$(echo "$response" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
            response_body=$(echo "$response" | sed 's/HTTPSTATUS:[0-9]*$//')
            
            if [[ "$http_code" == "200" ]] && [[ -n "$response_body" ]] && echo "$response_body" | jq . >/dev/null 2>&1; then
                success_count=$((success_count + 1))
                responses+=("$response_body")
                response_times+=("${response_time}ms")
            fi
        fi
    done
    
    # Determine result
    if [[ $success_count -ge 2 ]]; then
        print_colored "$GREEN" "✅ WORKING ($success_count/$total_attempts)"
        
        # Show detailed response info
        if [[ ${#responses[@]} -gt 0 ]]; then
            local sample_response="${responses[0]}"
            
            # Extract key information
            if command -v jq >/dev/null 2>&1; then
                local status_val=$(echo "$sample_response" | jq -r '.status // "unknown"' 2>/dev/null)
                local role_val=$(echo "$sample_response" | jq -r '.role // .service // "unknown"' 2>/dev/null)
                local message_val=$(echo "$sample_response" | jq -r '.message // "No message"' 2>/dev/null)
                local node_ip_val=$(echo "$sample_response" | jq -r '.node_ip // "unknown"' 2>/dev/null)
                
                printf "    ${BLUE}Status:${NC} %s  ${BLUE}Role/Service:${NC} %s  ${BLUE}Node IP:${NC} %s\n" "$status_val" "$role_val" "$node_ip_val"
                printf "    ${BLUE}Message:${NC} %s\n" "$message_val"
                printf "    ${BLUE}Response Times:${NC} %s\n" "${response_times[*]}"
            else
                printf "    ${BLUE}Response:${NC} %s\n" "$(echo "$sample_response" | head -c 80)..."
            fi
        fi
        return 0
    elif [[ $success_count -gt 0 ]]; then
        print_colored "$YELLOW" "⚠️  UNSTABLE ($success_count/$total_attempts)"
        return 1
    else
        print_colored "$RED" "❌ FAILED (0/$total_attempts)"
        return 2
    fi
}

echo "=== PostgreSQL HA Health Endpoints (Port 8001) ==="
test_endpoint_comprehensive "$PRIMARY_IP" "8001" "Primary" "PostgreSQL-HA"
primary_pg_result=$?

test_endpoint_comprehensive "$STANDBY_IP" "8001" "Standby" "PostgreSQL-HA"
standby_pg_result=$?

echo ""
echo "=== PgBouncer Health Endpoints (Port 8002) ==="
test_endpoint_comprehensive "$PRIMARY_IP" "8002" "Primary" "PgBouncer"
primary_pgb_result=$?

test_endpoint_comprehensive "$STANDBY_IP" "8002" "Standby" "PgBouncer"
standby_pgb_result=$?

echo ""
echo "=== Localhost Endpoints (from current node) ==="
test_endpoint_comprehensive "localhost" "8001" "Local PostgreSQL HA" "PostgreSQL-HA"
local_pg_result=$?

test_endpoint_comprehensive "localhost" "8002" "Local PgBouncer" "PgBouncer"
local_pgb_result=$?

echo ""
echo "=== DETAILED SUMMARY ==="

# Count results
declare -A result_counts
result_counts[working]=0
result_counts[unstable]=0
result_counts[failed]=0

for result in $primary_pg_result $standby_pg_result $primary_pgb_result $standby_pgb_result $local_pg_result $local_pgb_result; do
    case $result in
        0) result_counts[working]=$((result_counts[working] + 1)) ;;
        1) result_counts[unstable]=$((result_counts[unstable] + 1)) ;;
        2) result_counts[failed]=$((result_counts[failed] + 1)) ;;
    esac
done

total_endpoints=6
working=${result_counts[working]}
unstable=${result_counts[unstable]}
failed=${result_counts[failed]}

echo "📊 Results Summary:"
printf "   ${GREEN}✅ Working: %d/%d${NC}\n" $working $total_endpoints
if [[ $unstable -gt 0 ]]; then
    printf "   ${YELLOW}⚠️  Unstable: %d/%d${NC}\n" $unstable $total_endpoints
fi
if [[ $failed -gt 0 ]]; then
    printf "   ${RED}❌ Failed: %d/%d${NC}\n" $failed $total_endpoints
fi

echo ""

# Overall assessment
if [[ $working -eq $total_endpoints ]]; then
    print_colored "$GREEN" "🎉 PERFECT! ALL 6/6 HEALTH ENDPOINTS WORKING!"
    print_colored "$GREEN" "✅ Ready for production load balancer integration!"
elif [[ $working -ge 5 ]]; then
    print_colored "$GREEN" "🚀 EXCELLENT! $working/$total_endpoints endpoints working!"
    print_colored "$YELLOW" "Minor tweaking may improve remaining endpoints"
elif [[ $working -ge 4 ]]; then
    print_colored "$YELLOW" "🔧 GOOD! $working/$total_endpoints endpoints working!"
    print_colored "$YELLOW" "Some endpoints need attention"
elif [[ $working -ge 2 ]]; then
    print_colored "$YELLOW" "⚠️  PARTIAL SUCCESS! $working/$total_endpoints endpoints working"
    print_colored "$RED" "Several endpoints need troubleshooting"
else
    print_colored "$RED" "❌ MAJOR ISSUES! Only $working/$total_endpoints endpoints working"
    print_colored "$RED" "Significant troubleshooting required"
fi

echo ""
echo "=== LOAD BALANCER CONFIGURATION ==="
echo "For your load balancer health checks, use these endpoints:"
echo ""
echo "🔍 PostgreSQL HA Health Checks (Port 8001):"
echo "   Primary:  http://192.168.14.21:8001"
echo "   Standby:  http://192.168.14.22:8001"
echo ""
echo "🔍 PgBouncer Health Checks (Port 8002):"
echo "   Primary:  http://192.168.14.21:8002"  
echo "   Standby:  http://192.168.14.22:8002"

echo ""
echo "=== TROUBLESHOOTING COMMANDS ==="
echo "If any endpoints are failing, try these commands:"
echo ""
echo "🔧 On Primary Node (192.168.14.21):"
echo "   sudo /usr/local/bin/clean_restart_health.sh"
echo "   sudo /usr/local/bin/fix_primary_pgbouncer_health.sh"
echo ""
echo "🔧 On Standby Node (192.168.14.22):"
echo "   sudo /usr/local/bin/clean_restart_health.sh"
echo ""
echo "🧪 Test individual endpoints:"
echo "   curl -s http://192.168.14.21:8001 | jq ."
echo "   curl -s http://192.168.14.21:8002 | jq ."
echo "   curl -s http://192.168.14.22:8001 | jq ."
echo "   curl -s http://192.168.14.22:8002 | jq ."

echo ""
echo "=== CLUSTER STATUS ==="

# Check PostgreSQL cluster status
echo "🔍 PostgreSQL Cluster Status:"
if timeout 5 sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null; then
    echo ""
else
    warn "Could not retrieve cluster status"
fi

# Check service status
echo "🔍 Service Status on Current Node:"
for service in postgresql pgbouncer repmgrd; do
    if systemctl is-active --quiet $service 2>/dev/null; then
        printf "   ✅ %s: ${GREEN}running${NC}\n" "$service"
    else
        printf "   ❌ %s: ${RED}not running${NC}\n" "$service"
    fi
done

echo ""
print_colored "$BLUE" "=== VALIDATION COMPLETE ==="

# Return appropriate exit code
if [[ $working -eq $total_endpoints ]]; then
    exit 0  # Perfect
elif [[ $working -ge 4 ]]; then
    exit 1  # Good enough for production
else
    exit 2  # Needs significant work
fi