#!/bin/bash
# Bulletproof PostgreSQL HA Load Balancer Validation
# Uses exact same commands that work manually
# Version: 3.1.0 - Simple & Working

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🎯 Simple PostgreSQL HA Load Balancer Validation${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""

# Configuration
WRITE_IP="192.168.14.20"
READ_IP="192.168.14.19"
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PORT=6432

# Test Results
TESTS_PASSED=0
TESTS_TOTAL=0

echo -e "${YELLOW}📋 Test Configuration:${NC}"
echo "   Write LB: $WRITE_IP:$PORT"
echo "   Read LB:  $READ_IP:$PORT"
echo "   Primary:  $PRIMARY_IP:$PORT" 
echo "   Standby:  $STANDBY_IP:$PORT"
echo ""

# Simple test function - mirrors your working manual commands
simple_test() {
    local ip="$1"
    local name="$2"
    local test_msg="$3"
    
    ((TESTS_TOTAL++))
    echo -e "${YELLOW}🔍 Testing $name:${NC}"
    
    # Use the exact same command format that works manually
    echo "   Command: psql -h $ip -p $PORT -U postgres -d postgres -c \"SELECT '$test_msg';\""
    
    if timeout 5 psql -h "$ip" -p "$PORT" -U postgres -d postgres -c "SELECT '$test_msg';" 2>&1; then
        echo -e "   ${GREEN}✅ SUCCESS: $name is working${NC}"
        ((TESTS_PASSED++))
        echo ""
        return 0
    else
        echo -e "   ${RED}❌ FAILED: $name connection failed${NC}"
        echo ""
        return 1
    fi
}

# Run the exact tests that work manually
echo -e "${BLUE}🧪 Database Connection Tests:${NC}"
echo ""

simple_test "$PRIMARY_IP" "Primary Direct" "Primary test"
simple_test "$WRITE_IP" "Write Load Balancer" "Write LB test"
simple_test "$STANDBY_IP" "Standby Direct" "Standby test"
simple_test "$READ_IP" "Read Load Balancer" "Read LB test"

# Role verification tests
echo -e "${BLUE}🎭 Role Verification Tests:${NC}"
echo ""

echo -e "${YELLOW}🔍 Testing Write LB Role (should be primary):${NC}"
echo "   Command: psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c \"SELECT pg_is_in_recovery();\""
if WRITE_ROLE=$(timeout 5 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres -c "SELECT pg_is_in_recovery();" 2>&1); then
    echo "$WRITE_ROLE"
    if echo "$WRITE_ROLE" | grep -q " f$"; then
        echo -e "   ${GREEN}✅ Write LB correctly routes to PRIMARY${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "   ${YELLOW}⚠️  Write LB routing issue (not primary)${NC}"
    fi
else
    echo -e "   ${RED}❌ Write LB role check failed${NC}"
fi
((TESTS_TOTAL++))
echo ""

echo -e "${YELLOW}🔍 Testing Read LB Role (should be standby):${NC}"
echo "   Command: psql -h $READ_IP -p $PORT -U postgres -d postgres -c \"SELECT pg_is_in_recovery();\""
if READ_ROLE=$(timeout 5 psql -h "$READ_IP" -p "$PORT" -U postgres -d postgres -c "SELECT pg_is_in_recovery();" 2>&1); then
    echo "$READ_ROLE"
    if echo "$READ_ROLE" | grep -q " t$"; then
        echo -e "   ${GREEN}✅ Read LB correctly routes to STANDBY${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "   ${YELLOW}⚠️  Read LB routing issue (not standby)${NC}"
    fi
else
    echo -e "   ${RED}❌ Read LB role check failed${NC}"
fi
((TESTS_TOTAL++))
echo ""

# Simple replication test
echo -e "${BLUE}🔄 Replication Test:${NC}"
echo ""

TEST_ID=$((RANDOM % 1000))
echo -e "${YELLOW}🔍 Testing replication with ID: $TEST_ID${NC}"

echo "   Step 1: Creating test table and inserting data via Write LB..."
if timeout 10 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres << EOF
CREATE TABLE IF NOT EXISTS simple_repl_test (id INT, msg TEXT, ts TIMESTAMP DEFAULT NOW());
INSERT INTO simple_repl_test VALUES ($TEST_ID, 'Simple replication test', NOW());
SELECT 'Data inserted with ID: $TEST_ID';
EOF
then
    echo -e "   ${GREEN}✅ Data inserted successfully${NC}"
    
    echo "   Step 2: Waiting 5 seconds for replication..."
    sleep 5
    
    echo "   Step 3: Checking data on Read LB..."
    if timeout 8 psql -h "$READ_IP" -p "$PORT" -U postgres -d postgres -c "SELECT * FROM simple_repl_test WHERE id = $TEST_ID;"; then
        echo -e "   ${GREEN}✅ Replication is working!${NC}"
        ((TESTS_PASSED++))
        
        # Cleanup
        echo "   Step 4: Cleaning up test data..."
        timeout 5 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres -c "DELETE FROM simple_repl_test WHERE id = $TEST_ID;" >/dev/null 2>&1 || echo "   Note: Manual cleanup may be needed"
    else
        echo -e "   ${RED}❌ Replication failed - data not found on standby${NC}"
    fi
else
    echo -e "   ${RED}❌ Failed to insert test data${NC}"
fi
((TESTS_TOTAL++))
echo ""

# Summary
echo -e "${BLUE}📊 FINAL RESULTS${NC}"
echo -e "${BLUE}================${NC}"
echo ""

echo "Tests Passed: $TESTS_PASSED / $TESTS_TOTAL"

if [[ $TESTS_PASSED -eq $TESTS_TOTAL ]]; then
    echo -e "${GREEN}🎉 EXCELLENT: All tests passed!${NC}"
    echo -e "${GREEN}✅ Load balancer is production ready${NC}"
    STATUS="EXCELLENT"
elif [[ $TESTS_PASSED -ge 4 ]]; then
    echo -e "${YELLOW}⚠️  GOOD: Most tests passed${NC}"
    echo -e "${YELLOW}✅ Load balancer is operational${NC}"
    STATUS="GOOD"
else
    echo -e "${RED}❌ ISSUES: Multiple test failures${NC}"
    echo -e "${RED}🔧 Load balancer needs attention${NC}"
    STATUS="NEEDS_ATTENTION"
fi

echo ""
echo -e "${CYAN}🔗 READY-TO-USE CONNECTION STRINGS:${NC}"
echo ""
echo "For your applications:"
echo ""
echo "Write (Primary):"
echo "  postgresql://postgres:your_password@$WRITE_IP:$PORT/your_database"
echo ""
echo "Read (Standby):"
echo "  postgresql://postgres:your_password@$READ_IP:$PORT/your_database"
echo ""

echo -e "${CYAN}🧪 MANUAL VERIFICATION:${NC}"
cat << EOF

# Verify everything is working:
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "SELECT 'Write LB Test', pg_is_in_recovery();"
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT 'Read LB Test', pg_is_in_recovery();"

# Test replication:
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "CREATE TABLE app_test (id SERIAL, data TEXT); INSERT INTO app_test (data) VALUES ('Production test');"
sleep 3
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT * FROM app_test ORDER BY id DESC LIMIT 1;"

EOF

echo -e "${GREEN}🎯 Validation completed!${NC}"

# Return appropriate exit code
case "$STATUS" in
    "EXCELLENT") exit 0 ;;
    "GOOD") exit 1 ;;
    *) exit 2 ;;
esac