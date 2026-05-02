#!/bin/bash
# Final PostgreSQL HA Cluster Validation - Post Reprovisioning
# Comprehensive validation to ensure cluster is 100% operational

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     PostgreSQL 17 HA Final Validation (v3.6.0)     ║${NC}"
echo -e "${CYAN}║              Post-Reprovisioning Check              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo

START_TIME=$(date +%s)
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

test_result() {
    local test_name="$1"
    local result="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if [[ "$result" == "PASS" ]]; then
        success "✅ $test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        error "❌ $test_name"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

echo "🔍 Starting comprehensive cluster validation..."
echo "=============================================="
echo

# Get passwords from Secret Manager
info "🔐 Retrieving credentials from Secret Manager..."
PROJECT_ID=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id)
TOKEN=$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token')

get_secret() {
    local secret_id="$1"
    local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${secret_id}/versions/latest:access"
    curl -sf -H "Authorization: Bearer $TOKEN" "$url" | jq -r '.payload.data' | base64 -d 2>/dev/null || echo "FAILED"
}

PG_PASS=$(get_secret "ipa-nprd-sec-pg-superuser-password-01")
PGBOUNCER_PASS=$(get_secret "ipa-nprd-sec-pgbouncer-password-01")

if [[ "$PG_PASS" == "FAILED" ]]; then
    warn "Could not retrieve password from Secret Manager"
    exit 1
fi

success "🔐 Credentials retrieved successfully"
export PGPASSWORD="$PG_PASS"
echo

# === SECTION 1: SERVICE STATUS ===
echo "📊 Section 1: Service Status Validation"
echo "======================================="

# PostgreSQL Service
if systemctl is-active --quiet postgresql; then
    test_result "PostgreSQL Service Running" "PASS"
else
    test_result "PostgreSQL Service Running" "FAIL"
fi

# PgBouncer Service
if systemctl is-active --quiet pgbouncer; then
    test_result "PgBouncer Service Running" "PASS"
else
    test_result "PgBouncer Service Running" "FAIL"
fi

# repmgrd Service
if systemctl is-active --quiet repmgrd; then
    test_result "repmgrd Service Running" "PASS"
else
    test_result "repmgrd Service Running" "FAIL"
fi

# Health Endpoints Services
if systemctl is-active --quiet pg-ha-health; then
    test_result "PostgreSQL Health Service Running" "PASS"
else
    test_result "PostgreSQL Health Service Running" "FAIL"
fi

if systemctl is-active --quiet pgbouncer-health; then
    test_result "PgBouncer Health Service Running" "PASS"
else
    test_result "PgBouncer Health Service Running" "FAIL"
fi

echo

# === SECTION 2: CONNECTIVITY TESTS ===
echo "🔗 Section 2: Database Connectivity"
echo "==================================="

# Local PostgreSQL Direct
if sudo -u postgres psql -c "SELECT 'Local PostgreSQL OK' as status;" >/dev/null 2>&1; then
    test_result "Local PostgreSQL Direct Connection" "PASS"
else
    test_result "Local PostgreSQL Direct Connection" "FAIL"
fi

# Local PgBouncer
if timeout 10 psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'Local PgBouncer OK' as status;" >/dev/null 2>&1; then
    test_result "Local PgBouncer Connection" "PASS"
else
    test_result "Local PgBouncer Connection" "FAIL"
fi

# Remote Connections
if timeout 10 psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c "SELECT 'Primary Direct OK' as status;" >/dev/null 2>&1; then
    test_result "Primary Direct Connection (192.168.14.21:5432)" "PASS"
else
    test_result "Primary Direct Connection (192.168.14.21:5432)" "FAIL"
fi

if timeout 10 psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c "SELECT 'Standby Direct OK' as status;" >/dev/null 2>&1; then
    test_result "Standby Direct Connection (192.168.14.22:5432)" "PASS"
else
    test_result "Standby Direct Connection (192.168.14.22:5432)" "FAIL"
fi

if timeout 10 psql -h 192.168.14.21 -p 6432 -U postgres -d postgres -c "SELECT 'Primary PgBouncer OK' as status;" >/dev/null 2>&1; then
    test_result "Primary PgBouncer Connection (192.168.14.21:6432)" "PASS"
else
    test_result "Primary PgBouncer Connection (192.168.14.21:6432)" "FAIL"
fi

if timeout 10 psql -h 192.168.14.22 -p 6432 -U postgres -d postgres -c "SELECT 'Standby PgBouncer OK' as status;" >/dev/null 2>&1; then
    test_result "Standby PgBouncer Connection (192.168.14.22:6432)" "PASS"
else
    test_result "Standby PgBouncer Connection (192.168.14.22:6432)" "FAIL"
fi

echo

# === SECTION 3: HEALTH ENDPOINTS ===
echo "🏥 Section 3: Health Endpoints"
echo "=============================="

# Test Primary Health Endpoint
if timeout 10 curl -sf http://192.168.14.21:8001 | jq -e '.status == "healthy" and .role == "primary"' >/dev/null 2>&1; then
    test_result "Primary PostgreSQL Health Endpoint (192.168.14.21:8001)" "PASS"
else
    test_result "Primary PostgreSQL Health Endpoint (192.168.14.21:8001)" "FAIL"
fi

# Test Standby Health Endpoint
if timeout 10 curl -sf http://192.168.14.22:8001 | jq -e '.status == "healthy" and .role == "standby"' >/dev/null 2>&1; then
    test_result "Standby PostgreSQL Health Endpoint (192.168.14.22:8001)" "PASS"
else
    test_result "Standby PostgreSQL Health Endpoint (192.168.14.22:8001)" "FAIL"
fi

# Test Primary PgBouncer Health Endpoint
if timeout 10 curl -sf http://192.168.14.21:8002 | jq -e '.status == "healthy" and .service == "pgbouncer"' >/dev/null 2>&1; then
    test_result "Primary PgBouncer Health Endpoint (192.168.14.21:8002)" "PASS"
else
    test_result "Primary PgBouncer Health Endpoint (192.168.14.21:8002)" "FAIL"
fi

# Test Standby PgBouncer Health Endpoint
if timeout 10 curl -sf http://192.168.14.22:8002 | jq -e '.status == "healthy" and .service == "pgbouncer"' >/dev/null 2>&1; then
    test_result "Standby PgBouncer Health Endpoint (192.168.14.22:8002)" "PASS"
else
    test_result "Standby PgBouncer Health Endpoint (192.168.14.22:8002)" "FAIL"
fi

echo

# === SECTION 4: REPLICATION STATUS ===
echo "🔄 Section 4: Replication Status"
echo "================================"

# Check Primary Replication Status
PRIMARY_REPL_COUNT=$(psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -Atqc "SELECT COUNT(*) FROM pg_stat_replication WHERE state = 'streaming';" 2>/dev/null || echo "0")
if [[ "$PRIMARY_REPL_COUNT" -ge "1" ]]; then
    test_result "Primary Has Active Replication Connections" "PASS"
else
    test_result "Primary Has Active Replication Connections" "FAIL"
fi

# Check Standby Recovery Status
STANDBY_RECOVERY=$(psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "f")
if [[ "$STANDBY_RECOVERY" == "t" ]]; then
    test_result "Standby Node in Recovery Mode" "PASS"
else
    test_result "Standby Node in Recovery Mode" "FAIL"
fi

# Check WAL Receiver Status
WAL_RECEIVER_COUNT=$(psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -Atqc "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';" 2>/dev/null || echo "0")
if [[ "$WAL_RECEIVER_COUNT" -ge "1" ]]; then
    test_result "Standby WAL Receiver Active" "PASS"
else
    test_result "Standby WAL Receiver Active" "FAIL"
fi

echo

# === SECTION 5: REPMGR CLUSTER STATUS ===
echo "🏗️  Section 5: repmgr Cluster Status"
echo "==================================="

# Check repmgr cluster visibility from primary
if psql -h 192.168.14.21 -p 5432 -U postgres -d repmgr -c "SELECT node_name, type, active FROM repmgr.nodes;" >/dev/null 2>&1; then
    CLUSTER_NODES=$(psql -h 192.168.14.21 -p 5432 -U postgres -d repmgr -Atqc "SELECT COUNT(*) FROM repmgr.nodes WHERE active = true;" 2>/dev/null || echo "0")
    if [[ "$CLUSTER_NODES" == "2" ]]; then
        test_result "repmgr Cluster Has Both Nodes Active" "PASS"
    else
        test_result "repmgr Cluster Has Both Nodes Active" "FAIL"
    fi
else
    test_result "repmgr Database Accessible" "FAIL"
fi

echo

# === SECTION 6: DATA CONSISTENCY TEST ===
echo "📊 Section 6: Data Consistency Test"
echo "==================================="

# Create test data on primary
TEST_TABLE="validation_test_$(date +%s)"
if psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c "
    CREATE TABLE $TEST_TABLE (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT NOW());
    INSERT INTO $TEST_TABLE (data) VALUES ('Primary Test Data $(date)');
" >/dev/null 2>&1; then
    test_result "Test Data Creation on Primary" "PASS"
    
    # Wait for replication
    sleep 3
    
    # Check if data replicated to standby
    if psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -c "SELECT COUNT(*) FROM $TEST_TABLE;" >/dev/null 2>&1; then
        REPLICATED_COUNT=$(psql -h 192.168.14.22 -p 5432 -U postgres -d postgres -Atqc "SELECT COUNT(*) FROM $TEST_TABLE;" 2>/dev/null || echo "0")
        if [[ "$REPLICATED_COUNT" == "1" ]]; then
            test_result "Data Replication to Standby" "PASS"
        else
            test_result "Data Replication to Standby" "FAIL"
        fi
    else
        test_result "Data Replication to Standby" "FAIL"
    fi
    
    # Cleanup test data
    psql -h 192.168.14.21 -p 5432 -U postgres -d postgres -c "DROP TABLE IF EXISTS $TEST_TABLE;" >/dev/null 2>&1 || true
else
    test_result "Test Data Creation on Primary" "FAIL"
fi

echo

# === FINAL RESULTS ===
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "📋 FINAL VALIDATION RESULTS"
echo "============================"
echo -e "⏱️  Total Duration: ${DURATION} seconds"
echo -e "📊 Total Tests: ${TOTAL_TESTS}"
echo -e "✅ Passed: ${GREEN}${PASSED_TESTS}${NC}"
echo -e "❌ Failed: ${RED}${FAILED_TESTS}${NC}"

PASS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
echo -e "📈 Pass Rate: ${PASS_RATE}%"

echo
if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "${GREEN}🎉 CONGRATULATIONS! 🎉${NC}"
    echo -e "${GREEN}═══════════════════════════${NC}"
    echo -e "${GREEN}✅ PostgreSQL 17 HA Cluster is 100% PRODUCTION READY!${NC}"
    echo -e "${GREEN}✅ All services are running perfectly${NC}"
    echo -e "${GREEN}✅ All connections are working${NC}"
    echo -e "${GREEN}✅ Health endpoints are responding${NC}"
    echo -e "${GREEN}✅ Replication is active and healthy${NC}"
    echo -e "${GREEN}✅ Data consistency verified${NC}"
    echo
    echo "🚀 Ready for GCP Internal Load Balancer integration!"
    echo "🔗 Health Check URLs:"
    echo "   Primary PostgreSQL: http://192.168.14.21:8001"
    echo "   Standby PostgreSQL: http://192.168.14.22:8001"
    echo "   Primary PgBouncer:  http://192.168.14.21:8002"
    echo "   Standby PgBouncer:  http://192.168.14.22:8002"
    
    exit 0
else
    echo -e "${RED}⚠️  ATTENTION REQUIRED ⚠️${NC}"
    echo -e "${RED}========================${NC}"
    echo -e "${RED}❌ ${FAILED_TESTS} test(s) failed${NC}"
    echo -e "${YELLOW}🔧 Manual intervention may be needed${NC}"
    echo
    echo "📋 Next Steps:"
    echo "1. Review failed tests above"
    echo "2. Check service logs: journalctl -u <service-name>"
    echo "3. Verify network connectivity between nodes"
    echo "4. Re-run this validation script after fixes"
    
    exit 1
fi