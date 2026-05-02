#!/bin/bash
# Simple PostgreSQL HA Load Balancer Test (No Hanging)
# Quick test with proper timeouts and error handling

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🚀 Simple PostgreSQL HA Load Balancer Test${NC}"
echo -e "${BLUE}===========================================${NC}"

# Configuration with actual discovered IPs
WRITE_IP="192.168.14.20"  # pg-write.db.internal.nprd.ipa.edu.sa
READ_IP="192.168.14.19"   # pg-read.db.internal.nprd.ipa.edu.sa
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PORT=6432

echo -e "${GREEN}📋 Testing Configuration:${NC}"
echo "   Write Load Balancer: $WRITE_IP:$PORT"
echo "   Read Load Balancer:  $READ_IP:$PORT"
echo "   Primary Backend:     $PRIMARY_IP:$PORT"  
echo "   Standby Backend:     $STANDBY_IP:$PORT"
echo ""

# Simple connectivity test function
test_port() {
    local ip="$1"
    local port="$2"
    local name="$3"
    
    echo -n "🔍 $name ($ip:$port)... "
    
    # Use bash built-in TCP test (faster than nc)
    if timeout 3 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
        echo -e "${GREEN}✅ Connected${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed${NC}"
        return 1
    fi
}

echo -e "${YELLOW}🌐 Network Connectivity Tests:${NC}"
test_port "$WRITE_IP" "$PORT" "Write Load Balancer"
test_port "$READ_IP" "$PORT" "Read Load Balancer"
test_port "$PRIMARY_IP" "$PORT" "Primary Backend"
test_port "$STANDBY_IP" "$PORT" "Standby Backend"

echo ""
echo -e "${YELLOW}🗄️  Database Role Tests:${NC}"

# Database role test function
test_db_role() {
    local ip="$1"
    local name="$2"
    local expected="$3"
    
    echo -n "🔍 $name ($ip)... "
    
    # Quick database connection test
    local role
    role=$(timeout 8 psql -h "$ip" -p "$PORT" -U postgres -d postgres -Atqc \
        "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "failed")
    
    if [[ "$role" == "$expected" ]]; then
        echo -e "${GREEN}✅ $role (correct)${NC}"
        return 0
    elif [[ "$role" == "failed" ]]; then
        echo -e "${RED}❌ Connection failed${NC}"
        return 1
    else
        echo -e "${YELLOW}⚠️  $role (expected $expected)${NC}"
        return 1
    fi
}

test_db_role "$WRITE_IP" "Write Load Balancer" "primary"
test_db_role "$READ_IP" "Read Load Balancer" "standby"
test_db_role "$PRIMARY_IP" "Primary Backend" "primary"
test_db_role "$STANDBY_IP" "Standby Backend" "standby"

echo ""
echo -e "${YELLOW}🔄 Quick Replication Test:${NC}"

echo -n "🔍 Testing replication through load balancer... "

# Simple replication test
TEST_ID=$((RANDOM % 10000))
INSERT_SUCCESS=false

# Insert data via write endpoint
if timeout 10 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres -c \
   "CREATE TABLE IF NOT EXISTS simple_lb_test (id INT, msg TEXT, ts TIMESTAMP DEFAULT NOW());
    INSERT INTO simple_lb_test VALUES ($TEST_ID, 'Simple test', NOW());" >/dev/null 2>&1; then
    INSERT_SUCCESS=true
fi

if [[ "$INSERT_SUCCESS" == "true" ]]; then
    # Wait for replication
    sleep 3
    
    # Check if data replicated to read endpoint
    local found
    found=$(timeout 8 psql -h "$READ_IP" -p "$PORT" -U postgres -d postgres -Atqc \
            "SELECT COUNT(*) FROM simple_lb_test WHERE id = $TEST_ID;" 2>/dev/null || echo "0")
    
    if [[ "$found" == "1" ]]; then
        echo -e "${GREEN}✅ Replication working${NC}"
    else
        echo -e "${RED}❌ Replication failed${NC}"
    fi
else
    echo -e "${RED}❌ Insert failed${NC}"
fi

echo ""
echo -e "${GREEN}📋 Manual Test Commands:${NC}"
cat << EOF

# Test write endpoint (should show PRIMARY):
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "SELECT 'Write LB', pg_is_in_recovery();"

# Test read endpoint (should show STANDBY):
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT 'Read LB', pg_is_in_recovery();"

# Test replication:
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "INSERT INTO simple_lb_test VALUES (999, 'Manual test', NOW());"
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT * FROM simple_lb_test WHERE id = 999;"

# Application connection strings:
Write: postgresql://postgres:password@$WRITE_IP:$PORT/your_database
Read:  postgresql://postgres:password@$READ_IP:$PORT/your_database

EOF

echo -e "${GREEN}✅ Simple test completed!${NC}"