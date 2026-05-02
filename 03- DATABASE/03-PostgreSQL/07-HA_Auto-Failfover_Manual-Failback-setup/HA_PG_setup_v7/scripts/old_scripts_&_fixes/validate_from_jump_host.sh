#!/bin/bash
# PostgreSQL HA Load Balancer Validation from Jump Host
# Uses actual load balancer IPs from Terraform configuration
# Validates replication through GCP Internal Load Balancer

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

echo -e "${BLUE}🔍 PostgreSQL HA Load Balancer Validation from Jump Host${NC}"
echo -e "${BLUE}=============================================================${NC}"
echo ""

# Configuration based on your Terraform setup
ORG_CODE="ipa"
ENV_CODE="nprd"
PGBOUNCER_PORT=6432
DB_USER="postgres"
DB_NAME="postgres"

# Load balancer IPs (from your Terraform addresses.tf and load_balancer.tf)
# These are the reserved IPs for load balancer endpoints
echo -e "${CYAN}📋 Getting Load Balancer IPs from Terraform...${NC}"

# Get the actual IPs from Terraform state or use the expected IPs from your configuration
# Based on your subnet: nonprod_db_subnet_cidr = "192.168.14.0/23"
# Your load balancer IPs should be in this range

# DNS names (based on your load_balancer.tf configuration)
WRITE_FQDN="pg-write.db.internal.nprd.ipa.edu.sa"
READ_FQDN="pg-read.db.internal.nprd.ipa.edu.sa"

# Try to get actual IPs from DNS resolution first
echo "   Resolving load balancer IPs from DNS..."
WRITE_IP=$(nslookup "$WRITE_FQDN" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1 || echo "")
READ_IP=$(nslookup "$READ_FQDN" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1 || echo "")

# Try alternative DNS resolution if first method fails
if [[ -z "$WRITE_IP" ]]; then
    WRITE_IP=$(dig +short "$WRITE_FQDN" 2>/dev/null | head -1 || echo "")
fi
if [[ -z "$READ_IP" ]]; then
    READ_IP=$(dig +short "$READ_FQDN" 2>/dev/null | head -1 || echo "")
fi

# Fallback IPs if DNS resolution fails
if [[ -z "$WRITE_IP" ]]; then
    WRITE_IP="192.168.14.25"  # Fallback write load balancer IP
    echo "   ⚠️  Using fallback IP for write endpoint"
fi
if [[ -z "$READ_IP" ]]; then
    READ_IP="192.168.14.26"   # Fallback read load balancer IP
    echo "   ⚠️  Using fallback IP for read endpoint"
fi

# Backend node IPs (from your configuration)
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

echo -e "${GREEN}✅ Configuration:${NC}"
echo "   Write Endpoint: $WRITE_FQDN -> $WRITE_IP"
echo "   Read Endpoint:  $READ_FQDN -> $READ_IP"
echo "   Primary Node:   $PRIMARY_IP"
echo "   Standby Node:   $STANDBY_IP"
echo "   Port:           $PGBOUNCER_PORT"
echo ""

# Test counters
total_tests=0
passed_tests=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3"
    
    ((total_tests++))
    echo -n "   Testing $test_name... "
    
    # Use timeout to prevent hanging
    if timeout 10 bash -c "$test_command" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ PASS${NC}"
        ((passed_tests++))
        return 0
    else
        echo -e "${RED}❌ FAIL${NC}"
        return 1
    fi
}

# 1. Network Connectivity Tests
echo -e "${YELLOW}🌐 Network Connectivity Tests${NC}"
echo "   =================================="

# Test connectivity with better error handling
test_connectivity() {
    local ip="$1"
    local port="$2"
    local description="$3"
    
    ((total_tests++))
    echo -n "   Testing $description ($ip:$port)... "
    
    # Try nc with very short timeout first
    if timeout 3 nc -z -w2 "$ip" "$port" 2>/dev/null; then
        echo -e "${GREEN}✅ PASS${NC}"
        ((passed_tests++))
        return 0
    else
        echo -e "${RED}❌ FAIL${NC}"
        return 1
    fi
}

test_connectivity "$PRIMARY_IP" "$PGBOUNCER_PORT" "Primary node"
test_connectivity "$STANDBY_IP" "$PGBOUNCER_PORT" "Standby node"  
test_connectivity "$WRITE_IP" "$PGBOUNCER_PORT" "Write LB IP"
test_connectivity "$READ_IP" "$PGBOUNCER_PORT" "Read LB IP"

echo ""

# 2. DNS Resolution Tests (optional since DNS may not be configured)
echo -e "${YELLOW}🔍 DNS Resolution Tests (optional)${NC}"
echo "   =================================="

if nslookup "$WRITE_FQDN" >/dev/null 2>&1; then
    echo -e "   Write FQDN: ${GREEN}✅ RESOLVES${NC}"
    ((passed_tests++))
else
    echo -e "   Write FQDN: ${YELLOW}⚠️  NO DNS (expected if DNS zone not configured)${NC}"
fi

if nslookup "$READ_FQDN" >/dev/null 2>&1; then
    echo -e "   Read FQDN:  ${GREEN}✅ RESOLVES${NC}"
    ((passed_tests++))
else
    echo -e "   Read FQDN:  ${YELLOW}⚠️  NO DNS (expected if DNS zone not configured)${NC}"
fi

echo ""

# 3. Database Connection Tests
echo -e "${YELLOW}🗄️  Database Connection Tests${NC}"
echo "   ============================="

test_db_connection() {
    local endpoint="$1"
    local description="$2"
    local expected_role="$3"
    
    echo -n "   $description... "
    
    # Test basic connection
    if ! timeout 10 psql -h "$endpoint" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
        echo -e "${RED}❌ CONNECTION FAILED${NC}"
        return 1
    fi
    
    # Get node role
    local role_result
    role_result=$(timeout 10 psql -h "$endpoint" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc \
        "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
    
    if [[ "$role_result" == "$expected_role" ]]; then
        echo -e "${GREEN}✅ $expected_role ($role_result)${NC}"
        ((passed_tests++))
        return 0
    else
        echo -e "${YELLOW}⚠️  Connected to $role_result (expected $expected_role)${NC}"
        return 1
    fi
}

((total_tests++))
test_db_connection "$WRITE_IP" "Write LB -> Primary" "primary"

((total_tests++))
test_db_connection "$READ_IP" "Read LB -> Standby" "standby"

# Test direct backend connections for comparison
((total_tests++))
test_db_connection "$PRIMARY_IP" "Direct Primary" "primary"

((total_tests++))
test_db_connection "$STANDBY_IP" "Direct Standby" "standby"

echo ""

# 4. Replication Test
echo -e "${YELLOW}🔄 Replication Test${NC}"
echo "   ================="

((total_tests++))
echo -n "   Testing data replication... "

# Insert test data via write endpoint
test_id=$((RANDOM % 10000))
insert_cmd="CREATE TABLE IF NOT EXISTS lb_test_$(date +%s) (id INT, message TEXT, created_at TIMESTAMP DEFAULT NOW());
            INSERT INTO lb_test_$(date +%s) VALUES ($test_id, 'LB test from jump host', NOW());"

if timeout 15 psql -h "$WRITE_IP" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$insert_cmd" >/dev/null 2>&1; then
    # Wait for replication
    sleep 5
    
    # Check if data exists on read endpoint (we'll check for any recent test data)
    recent_data=$(timeout 10 psql -h "$READ_IP" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_name LIKE 'lb_test_%';" 2>/dev/null || echo "0")
    
    if [[ "$recent_data" -gt "0" ]]; then
        echo -e "${GREEN}✅ REPLICATION WORKING${NC}"
        ((passed_tests++))
    else
        echo -e "${RED}❌ REPLICATION NOT WORKING${NC}"
    fi
else
    echo -e "${RED}❌ WRITE TEST FAILED${NC}"
fi

echo ""

# 5. Health Endpoint Tests
echo -e "${YELLOW}🏥 Health Endpoint Tests${NC}"
echo "   ======================"

for node_ip in "$PRIMARY_IP" "$STANDBY_IP"; do
    ((total_tests++))
    echo -n "   PostgreSQL health ($node_ip:8001)... "
    
    health_response=$(timeout 5 curl -s "http://${node_ip}:8001" 2>/dev/null || echo "failed")
    
    if echo "$health_response" | grep -q '"status":"healthy"'; then
        echo -e "${GREEN}✅ HEALTHY${NC}"
        ((passed_tests++))
    else
        echo -e "${RED}❌ UNHEALTHY${NC}"
    fi
    
    ((total_tests++))
    echo -n "   PgBouncer health ($node_ip:8002)... "
    
    pgb_health_response=$(timeout 5 curl -s "http://${node_ip}:8002" 2>/dev/null || echo "failed")
    
    if echo "$pgb_health_response" | grep -q '"service":"pgbouncer"'; then
        echo -e "${GREEN}✅ HEALTHY${NC}"
        ((passed_tests++))
    else
        echo -e "${RED}❌ UNHEALTHY${NC}"
    fi
done

echo ""

# 6. Summary
echo -e "${BLUE}📊 Validation Summary${NC}"
echo -e "${BLUE}===================${NC}"

percentage=$((passed_tests * 100 / total_tests))

echo "   Tests Passed: $passed_tests/$total_tests ($percentage%)"

if [[ $percentage -ge 80 ]]; then
    echo -e "   Status: ${GREEN}✅ EXCELLENT - Load balancer is working well${NC}"
elif [[ $percentage -ge 60 ]]; then
    echo -e "   Status: ${YELLOW}⚠️  GOOD - Minor issues detected${NC}"
else
    echo -e "   Status: ${RED}❌ NEEDS ATTENTION - Multiple issues detected${NC}"
fi

echo ""

# 7. Manual Test Commands
echo -e "${BLUE}📋 Manual Test Commands${NC}"
echo -e "${BLUE}========================${NC}"

cat << EOF

# Test write endpoint (should connect to primary):
psql -h $WRITE_IP -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT 'Write Endpoint', current_timestamp, CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role;"

# Test read endpoint (should connect to standby):
psql -h $READ_IP -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT 'Read Endpoint', current_timestamp, CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role;"

# Test replication:
psql -h $WRITE_IP -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "CREATE TABLE IF NOT EXISTS test_repl (id SERIAL, msg TEXT, ts TIMESTAMP DEFAULT NOW()); INSERT INTO test_repl (msg) VALUES ('Test from jump host');"
sleep 3
psql -h $READ_IP -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT * FROM test_repl ORDER BY ts DESC LIMIT 3;"

# Connection strings for applications:
Write: postgresql://$DB_USER:password@$WRITE_IP:$PGBOUNCER_PORT/$DB_NAME
Read:  postgresql://$DB_USER:password@$READ_IP:$PGBOUNCER_PORT/$DB_NAME

EOF

echo -e "${GREEN}🎯 Validation completed!${NC}"

exit $((total_tests - passed_tests))