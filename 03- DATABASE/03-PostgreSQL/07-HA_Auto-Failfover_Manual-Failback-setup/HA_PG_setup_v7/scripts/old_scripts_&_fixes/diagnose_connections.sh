#!/bin/bash
# PostgreSQL Connection Diagnostic Script
# Identifies specific connection issues with detailed error reporting

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔍 PostgreSQL Connection Diagnostics${NC}"
echo -e "${BLUE}====================================${NC}"

# Configuration
WRITE_IP="192.168.14.20"
READ_IP="192.168.14.19"
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PORT=6432

echo ""
echo -e "${YELLOW}📋 Configuration Check:${NC}"
echo "   Write LB: $WRITE_IP:$PORT"
echo "   Read LB: $READ_IP:$PORT"
echo "   Primary: $PRIMARY_IP:$PORT"
echo "   Standby: $STANDBY_IP:$PORT"

echo ""
echo -e "${YELLOW}🔑 Authentication Check:${NC}"
if [[ -f ~/.pgpass ]]; then
    echo "   .pgpass file exists: ✅"
    echo "   Permissions: $(ls -la ~/.pgpass | awk '{print $1}')"
    echo "   Lines: $(wc -l ~/.pgpass | awk '{print $1}')"
    echo "   Sample entry: $(head -1 ~/.pgpass | sed 's/:[^:]*$/:*****/')"
else
    echo "   .pgpass file: ❌ Missing"
    exit 1
fi

echo ""
echo -e "${YELLOW}🌐 Network Tests:${NC}"

test_network() {
    local ip="$1"
    local port="$2"
    local name="$3"
    
    echo -n "   $name ($ip:$port)... "
    if timeout 3 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
        echo -e "${GREEN}✅ Connected${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed${NC}"
        return 1
    fi
}

test_network "$WRITE_IP" "$PORT" "Write LB"
test_network "$READ_IP" "$PORT" "Read LB"
test_network "$PRIMARY_IP" "$PORT" "Primary"
test_network "$STANDBY_IP" "$PORT" "Standby"

echo ""
echo -e "${YELLOW}🗄️  Database Connection Tests (with detailed errors):${NC}"

test_db_detailed() {
    local ip="$1"
    local name="$2"
    
    echo ""
    echo -e "   ${BLUE}Testing $name ($ip):${NC}"
    
    # Test 1: Basic connection
    echo -n "     Basic connection... "
    local basic_result
    basic_result=$(timeout 10 psql -h "$ip" -p "$PORT" -U postgres -d postgres \
        -c "SELECT 'success';" -t -A 2>&1 || echo "FAILED")
    
    if echo "$basic_result" | grep -q "success"; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
        echo "     Error: $(echo "$basic_result" | head -1)"
        return 1
    fi
    
    # Test 2: Role detection
    echo -n "     Role detection... "
    local role_result
    role_result=$(timeout 8 psql -h "$ip" -p "$PORT" -U postgres -d postgres \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>&1 || echo "FAILED")
    
    if [[ "$role_result" == "primary" ]] || [[ "$role_result" == "standby" ]]; then
        echo -e "${GREEN}✅ $role_result${NC}"
    else
        echo -e "${RED}❌${NC}"
        echo "     Error: $role_result"
        return 1
    fi
    
    # Test 3: Get backend info
    echo -n "     Backend info... "
    local backend_info
    backend_info=$(timeout 8 psql -h "$ip" -p "$PORT" -U postgres -d postgres \
        -Atqc "SELECT inet_server_addr() || ':' || inet_server_port();" 2>&1 || echo "unknown")
    
    if [[ "$backend_info" != "unknown" ]] && [[ "$backend_info" != *"ERROR"* ]]; then
        echo -e "${GREEN}✅ $backend_info${NC}"
    else
        echo -e "${YELLOW}⚠️  $backend_info${NC}"
    fi
    
    return 0
}

# Test all endpoints with detailed output
TOTAL_TESTS=0
PASSED_TESTS=0

((TOTAL_TESTS++))
if test_db_detailed "$PRIMARY_IP" "Primary Direct"; then ((PASSED_TESTS++)); fi

((TOTAL_TESTS++))
if test_db_detailed "$STANDBY_IP" "Standby Direct"; then ((PASSED_TESTS++)); fi

((TOTAL_TESTS++))
if test_db_detailed "$WRITE_IP" "Write Load Balancer"; then ((PASSED_TESTS++)); fi

((TOTAL_TESTS++))
if test_db_detailed "$READ_IP" "Read Load Balancer"; then ((PASSED_TESTS++)); fi

echo ""
echo -e "${YELLOW}🔧 Additional Diagnostics:${NC}"

# Check PgBouncer status
echo ""
echo -e "   ${BLUE}PgBouncer Status Check:${NC}"
for ip in "$PRIMARY_IP" "$STANDBY_IP"; do
    echo -n "     $ip SHOW POOLS... "
    if timeout 8 psql -h "$ip" -p "$PORT" -U postgres -d postgres \
        -c "SHOW pools;" >/dev/null 2>&1; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
done

# Check health endpoints
echo ""
echo -e "   ${BLUE}Health Endpoints:${NC}"
for ip in "$PRIMARY_IP" "$STANDBY_IP"; do
    echo -n "     $ip:8002 PgBouncer health... "
    if timeout 5 curl -s "http://$ip:8002" | grep -q '"status":"healthy"'; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
done

echo ""
echo -e "${BLUE}📊 Summary:${NC}"
echo "   Database Connections: $PASSED_TESTS/$TOTAL_TESTS working"

if [[ $PASSED_TESTS -eq $TOTAL_TESTS ]]; then
    echo -e "   Status: ${GREEN}✅ All connections working${NC}"
elif [[ $PASSED_TESTS -gt 0 ]]; then
    echo -e "   Status: ${YELLOW}⚠️  Partial connectivity${NC}"
else
    echo -e "   Status: ${RED}❌ No database connections working${NC}"
fi

echo ""
echo -e "${BLUE}🧪 Manual Test Commands:${NC}"
cat << EOF

# Test individual connections:
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "SELECT 'Write LB', pg_is_in_recovery();"
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT 'Read LB', pg_is_in_recovery();"
psql -h $PRIMARY_IP -p $PORT -U postgres -d postgres -c "SELECT 'Primary', pg_is_in_recovery();"
psql -h $STANDBY_IP -p $PORT -U postgres -d postgres -c "SELECT 'Standby', pg_is_in_recovery();"

# Check PgBouncer status:
psql -h $PRIMARY_IP -p $PORT -U postgres -d postgres -c "SHOW pools;"
psql -h $STANDBY_IP -p $PORT -U postgres -d postgres -c "SHOW config;"

EOF

exit $((TOTAL_TESTS - PASSED_TESTS))