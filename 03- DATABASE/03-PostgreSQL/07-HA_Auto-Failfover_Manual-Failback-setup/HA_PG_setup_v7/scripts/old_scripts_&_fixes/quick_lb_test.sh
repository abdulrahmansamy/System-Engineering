#!/bin/bash
# Quick PostgreSQL HA Load Balancer Test with Discovered IPs
# Based on your actual DNS resolution results

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🚀 Quick PostgreSQL HA Load Balancer Test${NC}"
echo -e "${BLUE}==========================================${NC}"

# Actual IPs discovered from your DNS
WRITE_IP="192.168.14.20"  # pg-write.db.internal.nprd.ipa.edu.sa
READ_IP="192.168.14.19"   # pg-read.db.internal.nprd.ipa.edu.sa
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PGBOUNCER_PORT=6432

echo -e "${GREEN}📋 Discovered Configuration:${NC}"
echo "   Write Load Balancer: $WRITE_IP"
echo "   Read Load Balancer:  $READ_IP"
echo "   Primary Backend:     $PRIMARY_IP"  
echo "   Standby Backend:     $STANDBY_IP"
echo ""

# Test function
test_connection() {
    local ip="$1"
    local description="$2"
    local expected_role="$3"
    
    echo -n "🔍 Testing $description ($ip)... "
    
    # Test connectivity first
    if ! timeout 5 nc -z "$ip" $PGBOUNCER_PORT 2>/dev/null; then
        echo -e "${RED}❌ No connectivity${NC}"
        return 1
    fi
    
    # Test database connection and get role
    local role_result
    role_result=$(timeout 10 psql -h "$ip" -p $PGBOUNCER_PORT -U postgres -d postgres -Atqc \
        "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "failed")
    
    if [[ "$role_result" == "$expected_role" ]]; then
        echo -e "${GREEN}✅ SUCCESS - Connected to $role_result${NC}"
        return 0
    elif [[ "$role_result" == "failed" ]]; then
        echo -e "${RED}❌ Database connection failed${NC}"
        return 1
    else
        echo -e "${YELLOW}⚠️  Connected to $role_result (expected $expected_role)${NC}"
        return 1
    fi
}

# Run tests
echo -e "${BLUE}🧪 Load Balancer Routing Tests:${NC}"
test_connection "$WRITE_IP" "Write Load Balancer" "primary"
test_connection "$READ_IP" "Read Load Balancer" "standby"

echo ""
echo -e "${BLUE}🔗 Direct Backend Tests:${NC}" 
test_connection "$PRIMARY_IP" "Direct Primary" "primary"
test_connection "$STANDBY_IP" "Direct Standby" "standby"

echo ""
echo -e "${BLUE}🔄 Quick Replication Test:${NC}"
echo -n "   Inserting data via write endpoint... "

# Insert test data
TEST_ID=$((RANDOM % 10000))
if psql -h "$WRITE_IP" -p $PGBOUNCER_PORT -U postgres -d postgres -c \
   "CREATE TABLE IF NOT EXISTS lb_quick_test (id INT, msg TEXT, ts TIMESTAMP DEFAULT NOW());
    INSERT INTO lb_quick_test VALUES ($TEST_ID, 'Quick test', NOW());" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Data inserted${NC}"
    
    echo -n "   Checking replication on read endpoint... "
    sleep 3
    
    # Check if data replicated
    FOUND=$(psql -h "$READ_IP" -p $PGBOUNCER_PORT -U postgres -d postgres -Atqc \
            "SELECT COUNT(*) FROM lb_quick_test WHERE id = $TEST_ID;" 2>/dev/null || echo "0")
    
    if [[ "$FOUND" == "1" ]]; then
        echo -e "${GREEN}✅ Replication working${NC}"
    else
        echo -e "${RED}❌ Replication not working${NC}"
    fi
else
    echo -e "${RED}❌ Failed to insert data${NC}"
fi

echo ""
echo -e "${BLUE}🏥 Health Check Tests:${NC}"
for ip in "$PRIMARY_IP" "$STANDBY_IP"; do
    echo -n "   Health endpoint $ip:8001... "
    if curl -s -m 5 "http://${ip}:8001" | grep -q '"status":"healthy"'; then
        echo -e "${GREEN}✅ Healthy${NC}"
    else
        echo -e "${RED}❌ Unhealthy${NC}"
    fi
done

echo ""
echo -e "${GREEN}🎯 Manual Test Commands:${NC}"
echo "# Test write endpoint (should connect to primary):"
echo "psql -h $WRITE_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c \"SELECT 'Write LB', pg_is_in_recovery();\""
echo ""
echo "# Test read endpoint (should connect to standby):"  
echo "psql -h $READ_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c \"SELECT 'Read LB', pg_is_in_recovery();\""
echo ""
echo "# Application connection strings:"
echo "Write: postgresql://postgres:password@$WRITE_IP:$PGBOUNCER_PORT/postgres"
echo "Read:  postgresql://postgres:password@$READ_IP:$PGBOUNCER_PORT/postgres"
echo ""

echo -e "${GREEN}✅ Test completed!${NC}"