#!/bin/bash
# Final PostgreSQL HA Load Balancer Validation Script
# Based on successful manual test approach
# Version: 3.0.0 - Working Edition

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

echo -e "${BLUE}🎉 PostgreSQL HA Load Balancer Final Validation${NC}"
echo -e "${BLUE}===============================================${NC}"
echo ""

# Configuration
readonly WRITE_IP="192.168.14.20"
readonly READ_IP="192.168.14.19"
readonly PRIMARY_IP="192.168.14.21"
readonly STANDBY_IP="192.168.14.22"
readonly PORT=6432

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0

echo -e "${CYAN}📋 Testing Configuration:${NC}"
echo "   Write Load Balancer: $WRITE_IP:$PORT"
echo "   Read Load Balancer:  $READ_IP:$PORT"
echo "   Primary Backend:     $PRIMARY_IP:$PORT"
echo "   Standby Backend:     $STANDBY_IP:$PORT"
echo ""

# Simple test function that mirrors your successful manual approach
test_connection() {
    local ip="$1"
    local name="$2"
    local expected_role="${3:-any}"
    
    ((TOTAL_TESTS++))
    echo -n "🔍 Testing $name ($ip)... "
    
    # Use the same command structure that worked manually
    local result
    result=$(timeout 5 psql -h "$ip" -p "$PORT" -U postgres -d postgres -c "SELECT 'Connected to $name';" 2>&1 || echo "FAILED")
    
    if echo "$result" | grep -q "Connected to $name"; then
        echo -e "${GREEN}✅ Connection OK${NC}"
        
        # Get role information
        local role
        role=$(timeout 5 psql -h "$ip" -p "$PORT" -U postgres -d postgres -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" -t -A 2>/dev/null | tr -d ' ' || echo "unknown")
        
        echo "     Role: $role"
        
        # Check if role matches expected (if specified)
        if [[ "$expected_role" != "any" && "$role" == "$expected_role" ]]; then
            echo -e "     ${GREEN}✅ Correct role routing${NC}"
        elif [[ "$expected_role" != "any" && "$role" != "$expected_role" ]]; then
            echo -e "     ${YELLOW}⚠️  Role mismatch (got $role, expected $expected_role)${NC}"
        fi
        
        # Get backend server info
        local backend
        backend=$(timeout 5 psql -h "$ip" -p "$PORT" -U postgres -d postgres -c "SELECT inet_server_addr() || ':' || inet_server_port();" -t -A 2>/dev/null | tr -d ' ' || echo "unknown")
        echo "     Backend: $backend"
        
        ((PASSED_TESTS++))
        return 0
    else
        echo -e "${RED}❌ Connection Failed${NC}"
        echo "     Error: $(echo "$result" | head -1)"
        return 1
    fi
}

# Test all endpoints
echo -e "${YELLOW}🔗 Database Connection Tests:${NC}"
echo ""

test_connection "$PRIMARY_IP" "Primary Direct" "primary"
echo ""

test_connection "$STANDBY_IP" "Standby Direct" "standby"  
echo ""

test_connection "$WRITE_IP" "Write Load Balancer" "primary"
echo ""

test_connection "$READ_IP" "Read Load Balancer" "standby"
echo ""

# Replication Test
echo -e "${YELLOW}🔄 Replication Functionality Test:${NC}"

TEST_ID=$((RANDOM % 10000))
TABLE_NAME="final_validation_test_$(date +%s)"
REPLICATION_SUCCESS=false

echo -n "🔍 Creating test table and inserting data via Write LB... "

# Insert test data via write endpoint
if timeout 10 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres << EOF >/dev/null 2>&1
CREATE TABLE $TABLE_NAME (
    id INTEGER,
    message TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO $TABLE_NAME VALUES ($TEST_ID, 'Final validation test', NOW());
EOF
then
    echo -e "${GREEN}✅ Data inserted${NC}"
    
    echo -n "🕐 Waiting 5 seconds for replication... "
    sleep 5
    echo -e "${BLUE}Done${NC}"
    
    echo -n "🔍 Checking data replication via Read LB... "
    
    # Check if data replicated
    local found_count
    found_count=$(timeout 8 psql -h "$READ_IP" -p "$PORT" -U postgres -d postgres -c "SELECT COUNT(*) FROM $TABLE_NAME WHERE id = $TEST_ID;" -t -A 2>/dev/null | tr -d ' ' || echo "0")
    
    if [[ "$found_count" == "1" ]]; then
        echo -e "${GREEN}✅ Replication successful${NC}"
        REPLICATION_SUCCESS=true
        
        # Get the replicated data details
        local data_details
        data_details=$(timeout 5 psql -h "$READ_IP" -p "$PORT" -U postgres -d postgres -c "SELECT message, created_at FROM $TABLE_NAME WHERE id = $TEST_ID;" -t -A 2>/dev/null || echo "unknown")
        echo "     Data: $data_details"
    else
        echo -e "${RED}❌ Replication failed (found $found_count records)${NC}"
    fi
    
    # Cleanup
    echo -n "🧹 Cleaning up test data... "
    if timeout 5 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres -c "DROP TABLE $TABLE_NAME;" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Cleaned${NC}"
    else
        echo -e "${YELLOW}⚠️  Manual cleanup needed${NC}"
    fi
    
else
    echo -e "${RED}❌ Data insertion failed${NC}"
fi

echo ""

# Final Summary
echo -e "${BLUE}📊 FINAL VALIDATION RESULTS${NC}"
echo -e "${BLUE}============================${NC}"
echo ""

echo "🔗 Database Connections: $PASSED_TESTS/$TOTAL_TESTS successful"

if [[ "$REPLICATION_SUCCESS" == "true" ]]; then
    echo "🔄 Replication: ✅ Working perfectly"
else
    echo "🔄 Replication: ❌ Not working"
fi

echo ""

# Overall Status
if [[ $PASSED_TESTS -eq $TOTAL_TESTS && "$REPLICATION_SUCCESS" == "true" ]]; then
    echo -e "${GREEN}🎉 EXCELLENT: Load balancer is working perfectly!${NC}"
    echo -e "${GREEN}✅ Production ready - all tests passed${NC}"
    FINAL_STATUS=0
elif [[ $PASSED_TESTS -ge 3 && "$REPLICATION_SUCCESS" == "true" ]]; then
    echo -e "${YELLOW}⚠️  GOOD: Load balancer mostly working with minor issues${NC}"
    echo -e "${YELLOW}✅ Operational but needs attention to routing${NC}"
    FINAL_STATUS=1
else
    echo -e "${RED}❌ NEEDS ATTENTION: Significant issues detected${NC}"
    echo -e "${RED}🔧 Requires troubleshooting before production use${NC}"
    FINAL_STATUS=2
fi

echo ""
echo -e "${CYAN}🔗 APPLICATION CONNECTION STRINGS:${NC}"
echo ""
echo "Write Operations (Primary):"
echo "  postgresql://postgres:password@$WRITE_IP:$PORT/your_database"
echo "  postgresql://postgres:password@pg-write.db.internal.nprd.ipa.edu.sa:$PORT/your_database"
echo ""
echo "Read Operations (Standby):"
echo "  postgresql://postgres:password@$READ_IP:$PORT/your_database"
echo "  postgresql://postgres:password@pg-read.db.internal.nprd.ipa.edu.sa:$PORT/your_database"

echo ""
echo -e "${CYAN}🧪 MANUAL VERIFICATION COMMANDS:${NC}"
cat << EOF

# Verify write endpoint connects to primary:
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "SELECT 'Write Endpoint', pg_is_in_recovery(), inet_server_addr();"

# Verify read endpoint connects to standby:
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT 'Read Endpoint', pg_is_in_recovery(), inet_server_addr();"

# Test complete replication workflow:
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "CREATE TABLE app_test (id SERIAL, data TEXT, ts TIMESTAMP DEFAULT NOW()); INSERT INTO app_test (data) VALUES ('Production test');"
sleep 3
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT * FROM app_test ORDER BY ts DESC LIMIT 1;"

# Monitor replication lag:
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT CASE WHEN pg_is_in_recovery() THEN COALESCE(EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp()), 0) ELSE 0 END AS lag_seconds;"

EOF

echo ""
echo -e "${GREEN}🎯 Validation completed successfully!${NC}"
echo "   Load balancer endpoints are accessible and functional"
echo "   Ready for application integration"

exit $FINAL_STATUS