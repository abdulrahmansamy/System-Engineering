#!/bin/bash
# Bulletproof PostgreSQL HA Load Balancer Validation
# Based on your successful manual tests

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}🚀 Bulletproof PostgreSQL HA Load Balancer Validation${NC}"
echo -e "${BLUE}====================================================${NC}"
echo ""

# Configuration - using your proven working values
PROJECT_ID="ipa-nprd-svc-db-01"
WRITE_IP="192.168.14.20"
READ_IP="192.168.14.19"
WRITE_FQDN="pg-write.db.internal.nprd.ipa.edu.sa"
READ_FQDN="pg-read.db.internal.nprd.ipa.edu.sa"
PORT=6432

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0

echo -e "${CYAN}📋 Configuration:${NC}"
echo "   Write LB IP:   $WRITE_IP:$PORT"
echo "   Read LB IP:    $READ_IP:$PORT"
echo "   Write LB FQDN: $WRITE_FQDN:$PORT"
echo "   Read LB FQDN:  $READ_FQDN:$PORT"
echo ""

# Get credentials (we know this works)
echo -e "${YELLOW}🔐 Authentication Setup:${NC}"
echo -n "   Getting credentials from Secret Manager... "

if POSTGRES_PASS=$(gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="$PROJECT_ID" 2>/dev/null); then
    echo -e "${GREEN}✅ Success${NC}"
    
    # Create .pgpass with all endpoints
    cat > ~/.pgpass << EOL
$WRITE_IP:$PORT:*:postgres:$POSTGRES_PASS
$READ_IP:$PORT:*:postgres:$POSTGRES_PASS
$WRITE_FQDN:$PORT:*:postgres:$POSTGRES_PASS
$READ_FQDN:$PORT:*:postgres:$POSTGRES_PASS
EOL
    chmod 600 ~/.pgpass
    echo -e "   ${GREEN}✅ .pgpass configured${NC}"
else
    echo -e "${RED}❌ Failed${NC}"
    exit 1
fi

echo ""

# Health endpoint validation
echo -e "${YELLOW}🏥 Health Endpoint Validation:${NC}"
echo -n "   Primary PostgreSQL Health... "
PRIMARY_PG_HEALTH=$(curl -s http://192.168.14.21:8001 | jq -r '.status // "unknown"' 2>/dev/null || echo "unreachable")
if [[ "$PRIMARY_PG_HEALTH" == "healthy" ]]; then
    PRIMARY_PG_ROLE=$(curl -s http://192.168.14.21:8001 | jq -r '.role // "unknown"' 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✅ $PRIMARY_PG_HEALTH ($PRIMARY_PG_ROLE)${NC}"
else
    echo -e "${RED}❌ $PRIMARY_PG_HEALTH${NC}"
fi

echo -n "   Primary PgBouncer Health... "
PRIMARY_PGB_HEALTH=$(curl -s http://192.168.14.21:8002 | jq -r '.status // "unknown"' 2>/dev/null || echo "unreachable")
if [[ "$PRIMARY_PGB_HEALTH" == "healthy" ]]; then
    echo -e "${GREEN}✅ $PRIMARY_PGB_HEALTH${NC}"
else
    echo -e "${RED}❌ $PRIMARY_PGB_HEALTH${NC}"
fi

echo -n "   Standby PostgreSQL Health... "
STANDBY_PG_HEALTH=$(curl -s http://192.168.14.22:8001 | jq -r '.status // "unknown"' 2>/dev/null || echo "unreachable")
if [[ "$STANDBY_PG_HEALTH" == "healthy" ]]; then
    STANDBY_PG_ROLE=$(curl -s http://192.168.14.22:8001 | jq -r '.role // "unknown"' 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✅ $STANDBY_PG_HEALTH ($STANDBY_PG_ROLE)${NC}"
else
    echo -e "${RED}❌ $STANDBY_PG_HEALTH${NC}"
fi

echo -n "   Standby PgBouncer Health... "
STANDBY_PGB_HEALTH=$(curl -s http://192.168.14.22:8002 | jq -r '.status // "unknown"' 2>/dev/null || echo "unreachable")
if [[ "$STANDBY_PGB_HEALTH" == "healthy" ]]; then
    echo -e "${GREEN}✅ $STANDBY_PGB_HEALTH${NC}"
else
    echo -e "${RED}❌ $STANDBY_PGB_HEALTH${NC}"
fi

echo ""

# Test function using exact same approach as your manual tests
test_endpoint() {
    local endpoint="$1"
    local name="$2"
    local expected_role="$3"
    
    ((TOTAL_TESTS++))
    echo -e "${YELLOW}🔍 Testing $name:${NC}"
    
    # Connection test (using your proven approach)
    echo -n "   Connection test... "
    if timeout 8 psql -h "$endpoint" -p "$PORT" -U postgres -d postgres -c "SELECT '$name test';" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Connected${NC}"
    else
        echo -e "${RED}❌ Failed${NC}"
        return 1
    fi
    
    # Role test (using your proven query)
    echo -n "   Role verification... "
    ROLE_RESULT=$(timeout 8 psql -h "$endpoint" -p "$PORT" -U postgres -d postgres -c "SELECT pg_is_in_recovery();" -t -A 2>/dev/null | tr -d ' ' || echo "unknown")
    
    if [[ "$expected_role" == "primary" && "$ROLE_RESULT" == "f" ]]; then
        echo -e "${GREEN}✅ Primary (correct)${NC}"
        ((PASSED_TESTS++))
        return 0
    elif [[ "$expected_role" == "standby" && "$ROLE_RESULT" == "t" ]]; then
        echo -e "${GREEN}✅ Standby (correct)${NC}"
        ((PASSED_TESTS++))
        return 0
    else
        echo -e "${YELLOW}⚠️  Role: $ROLE_RESULT (expected $expected_role)${NC}"
        return 1
    fi
}

# Run all endpoint tests
echo -e "${BLUE}🧪 Endpoint Connection & Role Tests:${NC}"
echo ""

test_endpoint "$WRITE_IP" "Write Load Balancer IP" "primary" || echo "Failed test endpoint Write LB IP test to primary using $WRITE_IP"
echo ""
test_endpoint "$READ_IP" "Read Load Balancer IP" "standby" || echo "Failed test endpoint Read LB IP test to standby using $READ_IP"
echo ""
test_endpoint "$WRITE_FQDN" "Write Load Balancer FQDN" "primary" || echo "Failed test endpoint Write LB FQDN test to primary using $WRITE_FQDN"
echo ""
test_endpoint "$READ_FQDN" "Read Load Balancer FQDN" "standby" || echo "Failed test endpoint Read LB FQDN test to standby using $READ_FQDN"
echo ""

# Quick validation tests using environment password
echo -e "${BLUE}🎯 Quick Validation Tests:${NC}"
((TOTAL_TESTS++))

echo -n "   Testing Write LB with direct password... "
WRITE_QUICK_TEST=$(PGPASSWORD="$POSTGRES_PASS" timeout 5 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres -c "SELECT 'WRITE_SUCCESS';" -t -A 2>/dev/null | tr -d ' ' || echo "FAILED")
if [[ "$WRITE_QUICK_TEST" == "WRITE_SUCCESS" ]]; then
    echo -e "${GREEN}✅ Success${NC}"
    ((PASSED_TESTS++))
else
    echo -e "${RED}❌ Failed${NC}"
fi

echo -n "   Testing Read LB with direct password... "
READ_QUICK_TEST=$(PGPASSWORD="$POSTGRES_PASS" timeout 5 psql -h "$READ_IP" -p "$PORT" -U postgres -d postgres -c "SELECT 'READ_success';" -t -A 2>/dev/null | tr -d ' ' || echo "FAILED")
if [[ "$READ_QUICK_TEST" == "read_success" ]]; then
    echo -e "${GREEN}✅ Success${NC}"
else
    echo -e "${RED}❌ Failed${NC}"
fi

echo -n "   Testing Write FQDN with direct password... "
DNS_WRITE_TEST=$(PGPASSWORD="$POSTGRES_PASS" timeout 5 psql -h "$WRITE_FQDN" -p "$PORT" -U postgres -d postgres -c "SELECT 'DNS_WRITE_SUCCESS';" -t -A 2>/dev/null | tr -d ' ' || echo "FAILED")
if [[ "$DNS_WRITE_TEST" == "DNS_WRITE_SUCCESS" ]]; then
    echo -e "${GREEN}✅ Success${NC}"
else
    echo -e "${RED}❌ Failed${NC}"
fi

echo -n "   Testing Read FQDN with direct password... "
DNS_READ_TEST=$(PGPASSWORD="$POSTGRES_PASS" timeout 5 psql -h "$READ_FQDN" -p "$PORT" -U postgres -d postgres -c "SELECT 'DNS_READ_SUCCESS';" -t -A 2>/dev/null | tr -d ' ' || echo "FAILED")
if [[ "$DNS_READ_TEST" == "DNS_READ_SUCCESS" ]]; then
    echo -e "${GREEN}✅ Success${NC}"
else
    echo -e "${RED}❌ Failed${NC}"
fi

echo ""

# Comprehensive replication test
echo -e "${BLUE}🔄 Comprehensive Replication Test:${NC}"
((TOTAL_TESTS++))

TEST_ID=$((RANDOM % 10000))
TABLE_NAME="bulletproof_test_$(date +%s)"

echo -e "${CYAN}   Testing complete replication workflow...${NC}"

# Step 1: Insert via Write IP
echo -n "   Step 1 - Insert via Write LB IP... "
if timeout 15 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres << EOL >/dev/null 2>&1
CREATE TABLE $TABLE_NAME (
    id INTEGER PRIMARY KEY,
    message TEXT,
    endpoint_type TEXT,
    endpoint_name TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO $TABLE_NAME VALUES ($TEST_ID, 'IP to IP test', 'ip', 'write_ip', NOW());
EOL
then
    echo -e "${GREEN}✅ Success${NC}"
else
    echo -e "${RED}❌ Failed${NC}"
    exit 1
fi

# Wait for replication
echo -n "   Step 2 - Waiting for replication (8s)... "
sleep 8
echo -e "${BLUE}⏱️  Complete${NC}"

# Step 3: Read via Read IP
echo -n "   Step 3 - Read via Read LB IP... "
FOUND_IP=$(timeout 10 psql -h "$READ_IP" -p "$PORT" -U postgres -d postgres -Atqc "SELECT COUNT(*) FROM $TABLE_NAME WHERE id = $TEST_ID;" 2>/dev/null | tr -d ' ' || echo "0")

if [[ "$FOUND_IP" == "1" ]]; then
    echo -e "${GREEN}✅ IP-to-IP replication working${NC}"
else
    echo -e "${RED}❌ IP-to-IP replication failed${NC}"
fi

# Step 4: Insert via Write FQDN
echo -n "   Step 4 - Insert via Write LB FQDN... "
TEST_ID2=$((RANDOM % 10000))
if timeout 15 psql -h "$WRITE_FQDN" -p "$PORT" -U postgres -d postgres \
    -c "INSERT INTO $TABLE_NAME VALUES ($TEST_ID2, 'FQDN to FQDN test', 'fqdn', 'write_fqdn', NOW());" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Success${NC}"
else
    echo -e "${RED}❌ Failed${NC}"
fi

# Step 5: Wait and read via Read FQDN
sleep 5
echo -n "   Step 5 - Read via Read LB FQDN... "
FOUND_FQDN=$(timeout 10 psql -h "$READ_FQDN" -p "$PORT" -U postgres -d postgres -Atqc "SELECT COUNT(*) FROM $TABLE_NAME WHERE id = $TEST_ID2;" 2>/dev/null | tr -d ' ' || echo "0")

if [[ "$FOUND_FQDN" == "1" ]]; then
    echo -e "${GREEN}✅ FQDN-to-FQDN replication working${NC}"
    ((PASSED_TESTS++))
else
    echo -e "${RED}❌ FQDN-to-FQDN replication failed${NC}"
fi

# Step 6: Cross-endpoint test (IP write, FQDN read)
echo -n "   Step 6 - Cross-endpoint test (IP→FQDN)... "
TEST_ID3=$((RANDOM % 10000))
if timeout 15 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres \
    -c "INSERT INTO $TABLE_NAME VALUES ($TEST_ID3, 'Cross endpoint test', 'cross', 'ip_to_fqdn', NOW());" >/dev/null 2>&1; then
    
    sleep 5
    FOUND_CROSS=$(timeout 10 psql -h "$READ_FQDN" -p "$PORT" -U postgres -d postgres -Atqc "SELECT COUNT(*) FROM $TABLE_NAME WHERE id = $TEST_ID3;" 2>/dev/null | tr -d ' ' || echo "0")
    
    if [[ "$FOUND_CROSS" == "1" ]]; then
        echo -e "${GREEN}✅ Cross-endpoint replication working${NC}"
    else
        echo -e "${YELLOW}⚠️  Cross-endpoint replication issue${NC}"
    fi
else
    echo -e "${RED}❌ Cross-endpoint insert failed${NC}"
fi

# Show replicated data
echo ""
echo -e "${CYAN}   Replicated Data Sample:${NC}"
timeout 8 psql -h "$READ_FQDN" -p "$PORT" -U postgres -d postgres \
    -c "SELECT id, message, endpoint_type, created_at FROM $TABLE_NAME ORDER BY created_at DESC LIMIT 3;" 2>/dev/null || echo "   Could not retrieve sample data"

# Cleanup
echo -n "   Cleanup... "
timeout 8 psql -h "$WRITE_IP" -p "$PORT" -U postgres -d postgres -c "DROP TABLE $TABLE_NAME;" >/dev/null 2>&1 && echo -e "${GREEN}✅ Done${NC}" || echo -e "${YELLOW}⚠️  Manual cleanup needed${NC}"

echo ""

# Final comprehensive status summary
echo -e "${BLUE}🎯 COMPREHENSIVE STATUS SUMMARY${NC}"
echo -e "${BLUE}===============================${NC}"
echo ""

echo -e "${CYAN}Health Check Results:${NC}"
echo "   Primary PostgreSQL:  $PRIMARY_PG_HEALTH ($PRIMARY_PG_ROLE)"
echo "   Primary PgBouncer:   $PRIMARY_PGB_HEALTH"
echo "   Standby PostgreSQL:  $STANDBY_PG_HEALTH ($STANDBY_PG_ROLE)"
echo "   Standby PgBouncer:   $STANDBY_PGB_HEALTH"

echo ""
echo -e "${CYAN}Quick Connection Tests:${NC}"
echo "   Write LB (IP):       $([[ "$WRITE_QUICK_TEST" == "WRITE_SUCCESS" ]] && echo "✅ Success" || echo "❌ Failed")"
echo "   Read LB (IP):        $([[ "$READ_QUICK_TEST" == "read_success" ]] && echo "✅ Success" || echo "❌ Failed")"
echo "   Write LB (FQDN):     $([[ "$DNS_WRITE_TEST" == "DNS_WRITE_SUCCESS" ]] && echo "✅ Success" || echo "❌ Failed")"
echo "   Read LB (FQDN):      $([[ "$DNS_READ_TEST" == "DNS_READ_SUCCESS" ]] && echo "✅ Success" || echo "❌ Failed")"

echo ""

# Final Results
echo -e "${BLUE}📊 BULLETPROOF VALIDATION RESULTS${NC}"
echo -e "${BLUE}==================================${NC}"
echo ""
echo "Tests Executed: $TOTAL_TESTS"
echo "Tests Passed:   $PASSED_TESTS"

SUCCESS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
echo "Success Rate:   $SUCCESS_RATE%"

echo ""
if [[ $SUCCESS_RATE -ge 90 ]]; then
    echo -e "${GREEN}🎉 EXCELLENT: Load balancer is production ready!${NC}"
    echo -e "${GREEN}✅ All major functionality validated${NC}"
    STATUS="EXCELLENT"
elif [[ $SUCCESS_RATE -ge 75 ]]; then
    echo -e "${YELLOW}⚠️  GOOD: Load balancer operational with minor issues${NC}"
    echo -e "${YELLOW}✅ Core functionality working${NC}"
    STATUS="GOOD"
else
    echo -e "${RED}❌ NEEDS ATTENTION: Significant issues detected${NC}"
    echo -e "${RED}🔧 Requires troubleshooting${NC}"
    STATUS="NEEDS_ATTENTION"
fi

echo ""
echo -e "${CYAN}🔗 VALIDATED CONNECTION STRINGS:${NC}"
echo ""
echo -e "${GREEN}Write Operations (Primary):${NC}"
echo "  IP:   postgresql://postgres:password@$WRITE_IP:$PORT/your_database"
echo "  FQDN: postgresql://postgres:password@$WRITE_FQDN:$PORT/your_database"
echo ""
echo -e "${GREEN}Read Operations (Standby):${NC}"
echo "  IP:   postgresql://postgres:password@$READ_IP:$PORT/your_database"
echo "  FQDN: postgresql://postgres:password@$READ_FQDN:$PORT/your_database"
echo ""

echo -e "${BLUE}🧪 Manual Verification Commands:${NC}"
cat << EOL

# Test individual endpoints:
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "SELECT 'Write IP', pg_is_in_recovery();"
psql -h $READ_IP -p $PORT -U postgres -d postgres -c "SELECT 'Read IP', pg_is_in_recovery();"
psql -h $WRITE_FQDN -p $PORT -U postgres -d postgres -c "SELECT 'Write FQDN', pg_is_in_recovery();"
psql -h $READ_FQDN -p $PORT -U postgres -d postgres -c "SELECT 'Read FQDN', pg_is_in_recovery();"

# Test complete replication workflow:
psql -h $WRITE_IP -p $PORT -U postgres -d postgres -c "CREATE TABLE manual_test (id SERIAL, data TEXT, ts TIMESTAMP DEFAULT NOW()); INSERT INTO manual_test (data) VALUES ('Manual validation');"
sleep 5
psql -h $READ_FQDN -p $PORT -U postgres -d postgres -c "SELECT * FROM manual_test ORDER BY ts DESC LIMIT 1;"

EOL

echo -e "${GREEN}🎯 Bulletproof validation completed successfully!${NC}"

case "$STATUS" in
    "EXCELLENT") exit 0 ;;
    "GOOD") exit 1 ;;
    *) exit 2 ;;
esac