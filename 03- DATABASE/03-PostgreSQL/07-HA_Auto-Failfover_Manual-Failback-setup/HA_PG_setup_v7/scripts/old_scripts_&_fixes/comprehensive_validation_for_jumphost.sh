#!/bin/bash
# Comprehensive PostgreSQL HA Cluster Validation from External Instance
# Run this from ipa-nprd-psql-01 to validate the entire setup

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
header() { echo -e "${CYAN}[HEADER]${NC} $*"; }

# Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
WRITE_LB_IP="192.168.14.20"
READ_LB_IP="192.168.14.19"
WRITE_DNS="pg-write.db.internal.nprd.ipa.edu.sa"
READ_DNS="pg-read.db.internal.nprd.ipa.edu.sa"

echo "🎯 PostgreSQL HA Cluster Validation"
echo "===================================="
echo "Testing from: $(hostname)"
echo "Date: $(date)"
echo

# Test counter
total_tests=0
passed_tests=0

test_result() {
    local test_name="$1"
    local result="$2"
    total_tests=$((total_tests + 1))
    if [ "$result" = "PASS" ]; then
        success "✅ $test_name"
        passed_tests=$((passed_tests + 1))
    else
        error "❌ $test_name"
    fi
}

header "1. NETWORK CONNECTIVITY TESTS"
echo "==============================="

info "Testing basic connectivity to PostgreSQL servers..."

# Test ping connectivity
if ping -c 2 -W 2 $PRIMARY_IP >/dev/null 2>&1; then
    test_result "Ping Primary ($PRIMARY_IP)" "PASS"
else
    test_result "Ping Primary ($PRIMARY_IP)" "FAIL"
fi

if ping -c 2 -W 2 $STANDBY_IP >/dev/null 2>&1; then
    test_result "Ping Standby ($STANDBY_IP)" "PASS"
else
    test_result "Ping Standby ($STANDBY_IP)" "FAIL"
fi

if ping -c 2 -W 2 $WRITE_LB_IP >/dev/null 2>&1; then
    test_result "Ping Write LB ($WRITE_LB_IP)" "PASS"
else
    test_result "Ping Write LB ($WRITE_LB_IP)" "FAIL"
fi

if ping -c 2 -W 2 $READ_LB_IP >/dev/null 2>&1; then
    test_result "Ping Read LB ($READ_LB_IP)" "PASS"
else
    test_result "Ping Read LB ($READ_LB_IP)" "FAIL"
fi

echo

header "2. PORT CONNECTIVITY TESTS"
echo "==========================="

info "Testing port connectivity using telnet/timeout..."

# Function to test port connectivity
test_port() {
    local host="$1"
    local port="$2"
    local name="$3"
    
    if timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        test_result "$name ($host:$port)" "PASS"
    else
        test_result "$name ($host:$port)" "FAIL"
    fi
}

# Test PostgreSQL direct connections
test_port $PRIMARY_IP 5432 "PostgreSQL Primary Direct"
test_port $STANDBY_IP 5432 "PostgreSQL Standby Direct"

# Test PgBouncer direct connections
test_port $PRIMARY_IP 6432 "PgBouncer Primary Direct"
test_port $STANDBY_IP 6432 "PgBouncer Standby Direct"

# Test Load Balancer connections
test_port $WRITE_LB_IP 6432 "Load Balancer Write Endpoint"
test_port $READ_LB_IP 6432 "Load Balancer Read Endpoint"

echo

header "3. HEALTH ENDPOINT TESTS"
echo "========================="

info "Testing HTTP health endpoints..."

# Function to test HTTP endpoint
test_http() {
    local url="$1"
    local name="$2"
    local expected_key="$3"
    
    if response=$(timeout 5 curl -sf "$url" 2>/dev/null); then
        if echo "$response" | python3 -m json.tool >/dev/null 2>&1; then
            if echo "$response" | grep -q "\"$expected_key\""; then
                test_result "$name" "PASS"
                echo "    Response: $(echo "$response" | python3 -m json.tool 2>/dev/null | head -3)"
            else
                test_result "$name (missing $expected_key)" "FAIL"
            fi
        else
            test_result "$name (invalid JSON)" "FAIL"
        fi
    else
        test_result "$name" "FAIL"
    fi
}

# Test health endpoints
test_http "http://$PRIMARY_IP:8001" "PostgreSQL Primary Health" "role"
test_http "http://$STANDBY_IP:8001" "PostgreSQL Standby Health" "role" 
test_http "http://$PRIMARY_IP:8002" "PgBouncer Primary Health" "service"
test_http "http://$STANDBY_IP:8002" "PgBouncer Standby Health" "service"

echo

header "4. DNS RESOLUTION TESTS" 
echo "========================"

info "Testing DNS resolution using dig/host..."

# Function to test DNS resolution
test_dns() {
    local fqdn="$1"
    local expected_ip="$2"
    local name="$3"
    
    # Try multiple DNS resolution methods
    resolved_ip=""
    
    # Method 1: Try dig
    if command -v dig >/dev/null 2>&1; then
        resolved_ip=$(dig +short "$fqdn" 2>/dev/null | head -1)
    fi
    
    # Method 2: Try host
    if [ -z "$resolved_ip" ] && command -v host >/dev/null 2>&1; then
        resolved_ip=$(host "$fqdn" 2>/dev/null | awk '/has address/ { print $4 }' | head -1)
    fi
    
    # Method 3: Try getent
    if [ -z "$resolved_ip" ] && command -v getent >/dev/null 2>&1; then
        resolved_ip=$(getent hosts "$fqdn" 2>/dev/null | awk '{ print $1 }' | head -1)
    fi
    
    if [ -n "$resolved_ip" ] && [ "$resolved_ip" = "$expected_ip" ]; then
        test_result "$name ($fqdn → $resolved_ip)" "PASS"
    elif [ -n "$resolved_ip" ]; then
        test_result "$name ($fqdn → $resolved_ip, expected $expected_ip)" "FAIL"
    else
        test_result "$name ($fqdn - no resolution)" "FAIL"
    fi
}

# Test DNS records
test_dns "$WRITE_DNS" "$WRITE_LB_IP" "Write Endpoint DNS"
test_dns "$READ_DNS" "$READ_LB_IP" "Read Endpoint DNS"

echo

header "5. POSTGRESQL CONNECTIVITY TESTS"
echo "=================================="

info "Testing PostgreSQL connections..."

# Function to test PostgreSQL connection
test_pg_connection() {
    local host="$1"
    local port="$2"
    local name="$3"
    
    # Test without password (will fail but show if connection is accepted)
    if timeout 10 psql -h "$host" -p "$port" -U postgres -d postgres -c "SELECT version();" 2>/dev/null >/dev/null; then
        test_result "$name PostgreSQL Connection" "PASS"
    else
        # Check if it's just authentication failure vs connection failure
        local error_output
        error_output=$(timeout 10 psql -h "$host" -p "$port" -U postgres -d postgres -c "SELECT 1;" 2>&1 || true)
        
        if echo "$error_output" | grep -q "password authentication failed"; then
            test_result "$name PostgreSQL Connection (auth required)" "PASS"
            info "    Connection established - authentication required"
        elif echo "$error_output" | grep -q "Connection refused\|could not connect\|timeout"; then
            test_result "$name PostgreSQL Connection" "FAIL"
        else
            test_result "$name PostgreSQL Connection (unknown)" "FAIL"
            warn "    Error: $(echo "$error_output" | head -1)"
        fi
    fi
}

# Test direct PostgreSQL connections
test_pg_connection $PRIMARY_IP 5432 "Primary Direct"
test_pg_connection $STANDBY_IP 5432 "Standby Direct"

# Test PgBouncer connections
test_pg_connection $PRIMARY_IP 6432 "Primary PgBouncer"
test_pg_connection $STANDBY_IP 6432 "Standby PgBouncer"

# Test Load Balancer connections
test_pg_connection $WRITE_LB_IP 6432 "Write Load Balancer"
test_pg_connection $READ_LB_IP 6432 "Read Load Balancer"

echo

header "6. ADVANCED TESTS"
echo "=================="

info "Testing advanced functionality..."

# Test role detection via health endpoints
info "Checking PostgreSQL roles via health endpoints..."
primary_role=$(timeout 5 curl -sf "http://$PRIMARY_IP:8001" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('role','unknown'))" 2>/dev/null || echo "unknown")
standby_role=$(timeout 5 curl -sf "http://$STANDBY_IP:8001" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('role','unknown'))" 2>/dev/null || echo "unknown")

if [ "$primary_role" = "primary" ] && [ "$standby_role" = "standby" ]; then
    test_result "Role Detection (Primary=$primary_role, Standby=$standby_role)" "PASS"
elif [ "$primary_role" = "standby" ] && [ "$standby_role" = "primary" ]; then
    test_result "Role Detection (SWAPPED: Primary=$primary_role, Standby=$standby_role)" "PASS"
    warn "    Roles appear to be swapped - may indicate failover occurred"
else
    test_result "Role Detection (Primary=$primary_role, Standby=$standby_role)" "FAIL"
fi

# Test load balancer health
info "Testing load balancer responsiveness..."
write_lb_time=$(timeout 5 bash -c "time echo >/dev/tcp/$WRITE_LB_IP/6432" 2>&1 | grep real | awk '{print $2}' || echo "timeout")
read_lb_time=$(timeout 5 bash -c "time echo >/dev/tcp/$READ_LB_IP/6432" 2>&1 | grep real | awk '{print $2}' || echo "timeout")

if [ "$write_lb_time" != "timeout" ]; then
    test_result "Write Load Balancer Response Time" "PASS"
    info "    Response time: $write_lb_time"
else
    test_result "Write Load Balancer Response Time" "FAIL"
fi

if [ "$read_lb_time" != "timeout" ]; then
    test_result "Read Load Balancer Response Time" "PASS"  
    info "    Response time: $read_lb_time"
else
    test_result "Read Load Balancer Response Time" "FAIL"
fi

echo

header "7. SUMMARY REPORT"
echo "=================="

success_rate=$((passed_tests * 100 / total_tests))

echo "📊 Test Results Summary:"
echo "------------------------"
echo "Total Tests: $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $((total_tests - passed_tests))"
echo "Success Rate: $success_rate%"
echo

if [ $success_rate -ge 90 ]; then
    success "🎉 EXCELLENT! PostgreSQL HA cluster is fully operational"
    echo "✅ Ready for production workloads"
elif [ $success_rate -ge 75 ]; then
    warn "⚠️  GOOD: PostgreSQL HA cluster is mostly functional"
    echo "🔧 Minor issues may need attention"
elif [ $success_rate -ge 50 ]; then
    warn "⚠️  PARTIAL: PostgreSQL HA cluster has significant issues"
    echo "🚨 Investigation required before production use"
else
    error "❌ CRITICAL: PostgreSQL HA cluster has major problems"
    echo "🛠️ Major troubleshooting required"
fi

echo

header "8. CONNECTION EXAMPLES"
echo "======================="

echo "📋 Ready-to-use connection strings:"
echo
echo "Direct connections:"
echo "  Primary:  psql -h $PRIMARY_IP -p 5432 -U your_user -d your_db"
echo "  Standby:  psql -h $STANDBY_IP -p 5432 -U your_user -d your_db"
echo
echo "PgBouncer connections:"
echo "  Primary:  psql -h $PRIMARY_IP -p 6432 -U your_user -d your_db"
echo "  Standby:  psql -h $STANDBY_IP -p 6432 -U your_user -d your_db"
echo
echo "Load Balancer connections (RECOMMENDED):"
echo "  Write:    psql -h $WRITE_LB_IP -p 6432 -U your_user -d your_db"
echo "  Read:     psql -h $READ_LB_IP -p 6432 -U your_user -d your_db"
echo
echo "DNS-based connections:"
echo "  Write:    psql -h $WRITE_DNS -p 6432 -U your_user -d your_db"
echo "  Read:     psql -h $READ_DNS -p 6432 -U your_user -d your_db"

echo
success "🔍 Validation complete! $(date)"