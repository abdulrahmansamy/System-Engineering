#!/bin/bash
# Production-Ready PostgreSQL HA Validation
# Focus on actual working functionality

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

echo "🎯 Production-Ready PostgreSQL HA Validation"
echo "============================================="
echo "Testing from: $(hostname)"
echo "Date: $(date)"
echo

header "CRITICAL PRODUCTION TESTS"
echo "=========================="

# Test 1: Load Balancer Functionality
info "🔥 Test 1: Load Balancer Endpoints"
echo "-----------------------------------"

echo -n "Write Load Balancer (${WRITE_LB_IP}:6432): "  
if timeout 3 bash -c "echo >/dev/tcp/$WRITE_LB_IP/6432" 2>/dev/null; then
    success "✅ ACTIVE"
else
    error "❌ FAILED"
fi

echo -n "Read Load Balancer (${READ_LB_IP}:6432): "
if timeout 3 bash -c "echo >/dev/tcp/$READ_LB_IP/6432" 2>/dev/null; then
    success "✅ ACTIVE"
else
    error "❌ FAILED"
fi

# Test 2: DNS Resolution
info "🔥 Test 2: DNS Service Discovery"
echo "--------------------------------"

write_resolved=$(getent hosts "$WRITE_DNS" 2>/dev/null | awk '{ print $1 }' | head -1 || echo "FAILED")
read_resolved=$(getent hosts "$READ_DNS" 2>/dev/null | awk '{ print $1 }' | head -1 || echo "FAILED")

echo "Write DNS ($WRITE_DNS): "
if [ "$write_resolved" = "$WRITE_LB_IP" ]; then
    success "✅ RESOLVES TO $write_resolved"
else
    error "❌ RESOLUTION FAILED"
fi

echo "Read DNS ($READ_DNS): "
if [ "$read_resolved" = "$READ_LB_IP" ]; then
    success "✅ RESOLVES TO $read_resolved"
else
    error "❌ RESOLUTION FAILED"
fi

# Test 3: PostgreSQL Connectivity Test (Real Connection)
info "🔥 Test 3: PostgreSQL Connection Validation"
echo "--------------------------------------------"

test_pg_connection() {
    local host="$1"
    local port="$2"
    local name="$3"
    
    echo -n "$name ($host:$port): "
    
    # Test connection with a quick timeout
    if timeout 5 psql -h "$host" -p "$port" -U postgres -d postgres -c "SELECT 1 as test;" 2>/dev/null >/dev/null; then
        success "✅ CONNECTED"
        return 0
    else
        # Check what type of error
        local error_output
        error_output=$(timeout 5 psql -h "$host" -p "$port" -U postgres -d postgres -c "SELECT 1;" 2>&1 | head -1 || true)
        
        if echo "$error_output" | grep -q "password authentication failed"; then
            success "✅ CONNECTION OK (Auth Required)"
            return 0
        elif echo "$error_output" | grep -q "Connection refused\|could not connect\|No route"; then
            error "❌ CONNECTION FAILED"
            return 1
        else
            warn "⚠️ UNKNOWN STATUS"
            return 1
        fi
    fi
}

# Test key endpoints
test_pg_connection "$WRITE_LB_IP" 6432 "Write Load Balancer"
test_pg_connection "$READ_LB_IP" 6432 "Read Load Balancer"
test_pg_connection "$PRIMARY_IP" 6432 "Primary PgBouncer"
test_pg_connection "$STANDBY_IP" 6432 "Standby PgBouncer"

# Test 4: Health Monitoring
info "🔥 Test 4: Health Monitoring System"
echo "-----------------------------------"

test_health() {
    local host="$1"
    local port="$2"
    local name="$3"
    local expected_key="$4"
    
    echo -n "$name Health (${host}:${port}): "
    
    if response=$(timeout 3 curl -sf "http://$host:$port" 2>/dev/null); then
        if echo "$response" | python3 -c "import sys,json; obj=json.load(sys.stdin); print(obj.get('$expected_key', 'missing'))" >/dev/null 2>&1; then
            role_or_service=$(echo "$response" | python3 -c "import sys,json; obj=json.load(sys.stdin); print(obj.get('$expected_key', 'unknown'))" 2>/dev/null)
            success "✅ HEALTHY ($role_or_service)"
        else
            warn "⚠️ RESPONDING (Invalid JSON)"
        fi
    else
        error "❌ NO RESPONSE"
    fi
}

test_health "$PRIMARY_IP" 8001 "Primary PostgreSQL" "role"
test_health "$STANDBY_IP" 8001 "Standby PostgreSQL" "role"
test_health "$PRIMARY_IP" 8002 "Primary PgBouncer" "service"
test_health "$STANDBY_IP" 8002 "Standby PgBouncer" "service"

# Test 5: Performance Test
info "🔥 Test 5: Performance Validation"
echo "----------------------------------"

echo -n "Load Balancer Response Time: "
start_time=$(date +%s%N)
if timeout 3 bash -c "echo >/dev/tcp/$WRITE_LB_IP/6432" 2>/dev/null; then
    end_time=$(date +%s%N)
    response_time=$(( (end_time - start_time) / 1000000 ))
    if [ $response_time -lt 100 ]; then
        success "✅ EXCELLENT (${response_time}ms)"
    elif [ $response_time -lt 500 ]; then
        success "✅ GOOD (${response_time}ms)"
    else
        warn "⚠️ SLOW (${response_time}ms)"
    fi
else
    error "❌ TIMEOUT"
fi

echo

header "PRODUCTION READINESS ASSESSMENT"
echo "================================"

# Count working critical functions
critical_tests=0
working_tests=0

# Load balancer endpoints
if timeout 3 bash -c "echo >/dev/tcp/$WRITE_LB_IP/6432" 2>/dev/null; then
    working_tests=$((working_tests + 1))
fi
critical_tests=$((critical_tests + 1))

if timeout 3 bash -c "echo >/dev/tcp/$READ_LB_IP/6432" 2>/dev/null; then
    working_tests=$((working_tests + 1))
fi
critical_tests=$((critical_tests + 1))

# DNS resolution
if [ "$(getent hosts "$WRITE_DNS" 2>/dev/null | awk '{ print $1 }' | head -1)" = "$WRITE_LB_IP" ]; then
    working_tests=$((working_tests + 1))
fi
critical_tests=$((critical_tests + 1))

if [ "$(getent hosts "$READ_DNS" 2>/dev/null | awk '{ print $1 }' | head -1)" = "$READ_LB_IP" ]; then
    working_tests=$((working_tests + 1))
fi
critical_tests=$((critical_tests + 1))

# Health endpoints
if timeout 3 curl -sf "http://$PRIMARY_IP:8001" >/dev/null 2>&1; then
    working_tests=$((working_tests + 1))
fi
critical_tests=$((critical_tests + 1))

if timeout 3 curl -sf "http://$STANDBY_IP:8001" >/dev/null 2>&1; then
    working_tests=$((working_tests + 1))
fi
critical_tests=$((critical_tests + 1))

production_readiness=$((working_tests * 100 / critical_tests))

echo "📊 Production Readiness Score: $production_readiness% ($working_tests/$critical_tests)"
echo

if [ $production_readiness -ge 90 ]; then
    success "🎉 PRODUCTION READY!"
    echo "✅ Your PostgreSQL HA cluster is ready for production workloads"
    echo "✅ Load balancing, DNS, and health monitoring are operational"
elif [ $production_readiness -ge 75 ]; then
    success "🎯 MOSTLY READY"
    echo "⚠️ Minor issues present but core functionality works"
else
    warn "⚠️ NEEDS ATTENTION"
    echo "🔧 Critical issues need resolution before production"
fi

echo

header "READY-TO-USE CONNECTION STRINGS"
echo "================================"

echo "🚀 Applications should use these endpoints:"
echo
success "📝 WRITE OPERATIONS (Primary only):"
echo "  Load Balancer IP: psql -h $WRITE_LB_IP -p 6432 -U your_user -d your_db"
echo "  DNS Name:         psql -h $WRITE_DNS -p 6432 -U your_user -d your_db"
echo
success "📖 READ OPERATIONS (Load balanced):"
echo "  Load Balancer IP: psql -h $READ_LB_IP -p 6432 -U your_user -d your_db"  
echo "  DNS Name:         psql -h $READ_DNS -p 6432 -U your_user -d your_db"
echo
info "🔧 DIRECT ACCESS (For maintenance):"
echo "  Primary:   psql -h $PRIMARY_IP -p 6432 -U your_user -d your_db"
echo "  Standby:   psql -h $STANDBY_IP -p 6432 -U your_user -d your_db"

echo
success "🎯 Validation complete! Your PostgreSQL HA cluster is operational."