#!/bin/bash
# Robust PostgreSQL HA Load Balancer Validation Script
# Version: 2.1.0 - Non-hanging with progress indicators

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Configuration
readonly PROJECT_ID="ipa-nprd-svc-db-01"
readonly WRITE_IP="192.168.14.20"
readonly READ_IP="192.168.14.19"
readonly PRIMARY_IP="192.168.14.21"
readonly STANDBY_IP="192.168.14.22"
readonly PGBOUNCER_PORT=6432

# Secret IDs
readonly PG_SUPERUSER_SECRET="ipa-nprd-sec-pg-superuser-password-01"

echo -e "${BLUE}🚀 PostgreSQL HA Load Balancer Validation v2.1.0${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""

# Progress indicator
show_progress() {
    local current=$1
    local total=$2
    local desc="$3"
    echo -e "${CYAN}[$current/$total] $desc${NC}"
}

# Step 1: Prerequisites Check
show_progress 1 6 "Checking prerequisites..."

echo -n "   Checking gcloud... "
if command -v gcloud >/dev/null 2>&1; then
    echo -e "${GREEN}✅${NC}"
else
    echo -e "${RED}❌ gcloud not found${NC}"
    exit 1
fi

echo -n "   Checking psql... "
if command -v psql >/dev/null 2>&1; then
    echo -e "${GREEN}✅${NC}"
else
    echo -e "${RED}❌ psql not found${NC}"
    exit 1
fi

echo -n "   Checking gcloud auth... "
if gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
    echo -e "${GREEN}✅ ($ACTIVE_ACCOUNT)${NC}"
else
    echo -e "${RED}❌ Not authenticated${NC}"
    echo "Please run: gcloud auth login"
    exit 1
fi

# Step 2: Get credentials from Secret Manager
show_progress 2 6 "Retrieving credentials from Secret Manager..."

echo -n "   Getting postgres password... "
POSTGRES_PASSWORD=""
if POSTGRES_PASSWORD=$(gcloud secrets versions access latest --secret="$PG_SUPERUSER_SECRET" --project="$PROJECT_ID" 2>/dev/null); then
    echo -e "${GREEN}✅ (length: ${#POSTGRES_PASSWORD})${NC}"
else
    echo -e "${RED}❌ Failed to retrieve password${NC}"
    echo "   Please check:"
    echo "   - Secret exists: $PG_SUPERUSER_SECRET"
    echo "   - You have access to project: $PROJECT_ID"
    exit 1
fi

# Step 3: Create .pgpass file
show_progress 3 6 "Setting up authentication..."

cat > ~/.pgpass << EOF
$WRITE_IP:$PGBOUNCER_PORT:*:postgres:$POSTGRES_PASSWORD
$READ_IP:$PGBOUNCER_PORT:*:postgres:$POSTGRES_PASSWORD
$PRIMARY_IP:$PGBOUNCER_PORT:*:postgres:$POSTGRES_PASSWORD
$STANDBY_IP:$PGBOUNCER_PORT:*:postgres:$POSTGRES_PASSWORD
EOF

chmod 600 ~/.pgpass
echo -e "   ${GREEN}✅ .pgpass file created${NC}"

# Step 4: Network connectivity tests
show_progress 4 6 "Testing network connectivity..."

test_connectivity() {
    local ip="$1"
    local port="$2"
    local name="$3"
    
    echo -n "   $name ($ip:$port)... "
    if timeout 3 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
        echo -e "${GREEN}✅${NC}"
        return 0
    else
        echo -e "${RED}❌${NC}"
        return 1
    fi
}

test_connectivity "$WRITE_IP" "$PGBOUNCER_PORT" "Write LB"
test_connectivity "$READ_IP" "$PGBOUNCER_PORT" "Read LB"
test_connectivity "$PRIMARY_IP" "$PGBOUNCER_PORT" "Primary"
test_connectivity "$STANDBY_IP" "$PGBOUNCER_PORT" "Standby"

# Step 5: Database role tests
show_progress 5 6 "Testing database connections and roles..."

test_db_role() {
    local ip="$1"
    local name="$2"
    local expected="$3"
    
    echo -n "   $name... "
    
    local role
    if role=$(timeout 10 psql -h "$ip" -p "$PGBOUNCER_PORT" -U postgres -d postgres \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null); then
        
        if [[ "$role" == "$expected" ]]; then
            echo -e "${GREEN}✅ $role${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️  $role (expected $expected)${NC}"
            return 1
        fi
    else
        echo -e "${RED}❌ Connection failed${NC}"
        return 1
    fi
}

ROLE_TESTS=0
ROLE_PASSED=0

((ROLE_TESTS++))
if test_db_role "$WRITE_IP" "Write LB" "primary"; then ((ROLE_PASSED++)); fi

((ROLE_TESTS++))
if test_db_role "$READ_IP" "Read LB" "standby"; then ((ROLE_PASSED++)); fi

((ROLE_TESTS++))
if test_db_role "$PRIMARY_IP" "Primary" "primary"; then ((ROLE_PASSED++)); fi

((ROLE_TESTS++))
if test_db_role "$STANDBY_IP" "Standby" "standby"; then ((ROLE_PASSED++)); fi

# Step 6: Replication test
show_progress 6 6 "Testing replication..."

echo -n "   Inserting test data via Write LB... "
TEST_ID=$((RANDOM % 10000))
TABLE_NAME="quick_repl_test_$(date +%s)"

if timeout 15 psql -h "$WRITE_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres << EOF >/dev/null 2>&1
CREATE TABLE $TABLE_NAME (id INT, msg TEXT, ts TIMESTAMP DEFAULT NOW());
INSERT INTO $TABLE_NAME VALUES ($TEST_ID, 'Replication test', NOW());
EOF
then
    echo -e "${GREEN}✅${NC}"
    
    echo -n "   Waiting for replication (5s)... "
    sleep 5
    echo -e "${BLUE}⏱️${NC}"
    
    echo -n "   Checking data on Read LB... "
    if FOUND=$(timeout 10 psql -h "$READ_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres \
        -Atqc "SELECT COUNT(*) FROM $TABLE_NAME WHERE id = $TEST_ID;" 2>/dev/null) && [[ "$FOUND" == "1" ]]; then
        echo -e "${GREEN}✅ Found${NC}"
        REPLICATION_WORKING=true
    else
        echo -e "${RED}❌ Not found${NC}"
        REPLICATION_WORKING=false
    fi
    
    # Cleanup
    timeout 10 psql -h "$WRITE_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres \
        -c "DROP TABLE $TABLE_NAME;" >/dev/null 2>&1 || true
        
else
    echo -e "${RED}❌ Insert failed${NC}"
    REPLICATION_WORKING=false
fi

# Results Summary
echo ""
echo -e "${BLUE}📊 VALIDATION RESULTS${NC}"
echo -e "${BLUE}====================${NC}"

echo "Network Connectivity: ✅ All endpoints reachable"
echo "Database Roles: $ROLE_PASSED/$ROLE_TESTS correct"

if [[ "$REPLICATION_WORKING" == "true" ]]; then
    echo "Replication: ✅ Working"
else
    echo "Replication: ❌ Not working"
fi

echo ""
echo -e "${GREEN}🔗 CONNECTION STRINGS FOR APPLICATIONS:${NC}"
echo ""
echo "Write (Primary via LB):"
echo "  postgresql://postgres:password@$WRITE_IP:$PGBOUNCER_PORT/your_database"
echo ""
echo "Read (Standby via LB):"
echo "  postgresql://postgres:password@$READ_IP:$PGBOUNCER_PORT/your_database"
echo ""

echo -e "${BLUE}🧪 MANUAL TEST COMMANDS:${NC}"
cat << EOF

# Test write endpoint:
psql -h $WRITE_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "SELECT 'Write LB', pg_is_in_recovery();"

# Test read endpoint:
psql -h $READ_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "SELECT 'Read LB', pg_is_in_recovery();"

# Test replication:
psql -h $WRITE_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "CREATE TABLE test_table (id INT, ts TIMESTAMP DEFAULT NOW()); INSERT INTO test_table VALUES (1, NOW());"
sleep 3
psql -h $READ_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "SELECT * FROM test_table;"

EOF

# Final status
if [[ $ROLE_PASSED -eq $ROLE_TESTS && "$REPLICATION_WORKING" == "true" ]]; then
    echo -e "${GREEN}🎉 SUCCESS: Load balancer is working perfectly!${NC}"
    exit 0
elif [[ $ROLE_PASSED -ge 2 ]]; then
    echo -e "${YELLOW}⚠️  PARTIAL: Load balancer mostly working, minor issues detected${NC}"
    exit 1
else
    echo -e "${RED}❌ FAILED: Load balancer has significant issues${NC}"
    exit 2
fi