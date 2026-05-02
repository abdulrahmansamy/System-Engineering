#!/bin/bash
# Comprehensive PostgreSQL HA Load Balancer Validation Script
# Tests replication via both FQDN and IP addresses
# Version: 4.0.0 - Complete Working Edition
# Based on successful manual validation approach

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Script metadata
readonly SCRIPT_VERSION="4.0.0"
readonly VALIDATION_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
readonly TEST_SESSION_ID=$(date +%s)

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly PURPLE='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Environment Configuration
readonly PROJECT_ID="ipa-nprd-svc-db-01"
readonly ENV_CODE="nprd"
readonly REGION="me-central2"

# Load Balancer Configuration
readonly WRITE_IP="192.168.14.20"
readonly READ_IP="192.168.14.19"
readonly PRIMARY_IP="192.168.14.21"
readonly STANDBY_IP="192.168.14.22"
readonly PGBOUNCER_PORT=6432

# DNS Configuration
readonly WRITE_FQDN="pg-write.db.internal.nprd.ipa.edu.sa"
readonly READ_FQDN="pg-read.db.internal.nprd.ipa.edu.sa"

# Secret Manager Configuration
readonly PG_SUPERUSER_SECRET="ipa-nprd-sec-pg-superuser-password-01"

# Test Configuration
readonly DB_USER="postgres"
readonly DB_NAME="postgres"
readonly TEST_TABLE="comprehensive_validation_$(date +%s)"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

print_banner() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}    ${BOLD}PostgreSQL HA Load Balancer Comprehensive Validation v${SCRIPT_VERSION}${NC}    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}🕐 Validation Started: ${VALIDATION_DATE}${NC}"
    echo -e "${CYAN}📋 Session ID: ${TEST_SESSION_ID}${NC}"
    echo -e "${CYAN}🏷️  Environment: ${ENV_CODE} | Project: ${PROJECT_ID}${NC}"
    echo ""
}

print_section() {
    local title="$1"
    local icon="${2:-🔍}"
    echo ""
    echo -e "${YELLOW}${icon} ═══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}${BOLD}   $title${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════${NC}"
}

log_info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
log_success() { echo -e "${GREEN}✅ $*${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error() { echo -e "${RED}❌ $*${NC}"; }
log_debug() { [[ "${DEBUG:-}" == "1" ]] && echo -e "${PURPLE}🐛 $*${NC}" || true; }

# Progress tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

increment_test() { ((TOTAL_TESTS++)); }
increment_pass() { ((PASSED_TESTS++)); }
increment_fail() { ((FAILED_TESTS++)); }

# ============================================================================
# PREREQUISITE FUNCTIONS
# ============================================================================

check_prerequisites() {
    print_section "Checking Prerequisites" "🔧"
    
    local prereq_checks=0
    local prereq_passed=0
    
    # Check required commands
    local required_commands=("gcloud" "psql" "curl" "dig")
    
    for cmd in "${required_commands[@]}"; do
        ((prereq_checks++))
        echo -n "   Checking $cmd... "
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Available${NC}"
            ((prereq_passed++))
        else
            echo -e "${RED}❌ Missing${NC}"
        fi
    done
    
    # Check gcloud authentication
    ((prereq_checks++))
    echo -n "   Checking gcloud authentication... "
    if gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
        local active_account
        active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
        echo -e "${GREEN}✅ Authenticated as: $active_account${NC}"
        ((prereq_passed++))
    else
        echo -e "${RED}❌ Not authenticated${NC}"
        log_error "Please run: gcloud auth login"
        return 1
    fi
    
    # Check project access
    ((prereq_checks++))
    echo -n "   Checking project access... "
    if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Access confirmed${NC}"
        ((prereq_passed++))
    else
        echo -e "${RED}❌ Cannot access project${NC}"
        return 1
    fi
    
    log_info "Prerequisites: $prereq_passed/$prereq_checks passed"
    
    if [[ $prereq_passed -ne $prereq_checks ]]; then
        log_error "Prerequisites not met. Please install missing components."
        return 1
    fi
    
    return 0
}

setup_authentication() {
    print_section "Setting Up Authentication" "🔐"
    
    log_info "Retrieving credentials from Secret Manager..."
    
    local postgres_password
    echo -n "   Getting PostgreSQL superuser password... "
    
    if postgres_password=$(gcloud secrets versions access latest --secret="$PG_SUPERUSER_SECRET" --project="$PROJECT_ID" 2>/dev/null); then
        echo -e "${GREEN}✅ Retrieved (length: ${#postgres_password})${NC}"
    else
        echo -e "${RED}❌ Failed${NC}"
        log_error "Could not retrieve password from Secret Manager"
        log_error "Secret: $PG_SUPERUSER_SECRET"
        log_error "Project: $PROJECT_ID"
        return 1
    fi
    
    log_info "Creating .pgpass file..."
    cat > ~/.pgpass << EOF
# Comprehensive PostgreSQL HA .pgpass file
# Generated: $VALIDATION_DATE
# Session: $TEST_SESSION_ID

# Load Balancer IPs
$WRITE_IP:$PGBOUNCER_PORT:*:$DB_USER:$postgres_password
$READ_IP:$PGBOUNCER_PORT:*:$DB_USER:$postgres_password

# Load Balancer FQDNs
$WRITE_FQDN:$PGBOUNCER_PORT:*:$DB_USER:$postgres_password
$READ_FQDN:$PGBOUNCER_PORT:*:$DB_USER:$postgres_password

# Direct Backend IPs
$PRIMARY_IP:$PGBOUNCER_PORT:*:$DB_USER:$postgres_password
$STANDBY_IP:$PGBOUNCER_PORT:*:$DB_USER:$postgres_password

# Localhost
localhost:$PGBOUNCER_PORT:*:$DB_USER:$postgres_password
EOF
    
    chmod 600 ~/.pgpass
    
    log_success ".pgpass file created with $(wc -l ~/.pgpass | awk '{print $1}') entries"
    log_info "File permissions: $(ls -l ~/.pgpass | awk '{print $1}')"
    
    return 0
}

# ============================================================================
# CONNECTIVITY TEST FUNCTIONS
# ============================================================================

test_network_connectivity() {
    print_section "Network Connectivity Tests" "🌐"
    
    local endpoints=(
        "$WRITE_IP:$PGBOUNCER_PORT:Write_LB_IP"
        "$READ_IP:$PGBOUNCER_PORT:Read_LB_IP"
        "$PRIMARY_IP:$PGBOUNCER_PORT:Primary_Backend"
        "$STANDBY_IP:$PGBOUNCER_PORT:Standby_Backend"
    )
    
    for endpoint in "${endpoints[@]}"; do
        IFS=':' read -r ip port name <<< "$endpoint"
        increment_test
        
        echo -n "   Testing $name ($ip:$port)... "
        
        if timeout 5 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
            echo -e "${GREEN}✅ Connected${NC}"
            increment_pass
        else
            echo -e "${RED}❌ Failed${NC}"
            increment_fail
        fi
    done
}

test_dns_resolution() {
    print_section "DNS Resolution Tests" "🔍"
    
    local dns_tests=(
        "$WRITE_FQDN:$WRITE_IP:Write_Load_Balancer"
        "$READ_FQDN:$READ_IP:Read_Load_Balancer"
    )
    
    for dns_test in "${dns_tests[@]}"; do
        IFS=':' read -r fqdn expected_ip name <<< "$dns_test"
        increment_test
        
        echo -n "   Testing $name DNS ($fqdn)... "
        
        local resolved_ip
        resolved_ip=$(dig +short "$fqdn" 2>/dev/null | head -1 || echo "")
        
        if [[ "$resolved_ip" == "$expected_ip" ]]; then
            echo -e "${GREEN}✅ Resolves to $resolved_ip${NC}"
            increment_pass
        elif [[ -n "$resolved_ip" ]]; then
            echo -e "${YELLOW}⚠️  Resolves to $resolved_ip (expected $expected_ip)${NC}"
            increment_fail
        else
            echo -e "${RED}❌ No resolution${NC}"
            increment_fail
        fi
    done
}

# ============================================================================
# DATABASE CONNECTION TEST FUNCTIONS
# ============================================================================

test_database_connection() {
    local endpoint="$1"
    local name="$2"
    local expected_role="${3:-any}"
    local test_type="${4:-connection}"
    
    increment_test
    
    echo ""
    log_info "Testing $name ($endpoint)"
    
    # Basic connection test
    echo -n "     Basic connectivity... "
    local connection_result
    connection_result=$(timeout 10 psql -h "$endpoint" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -c "SELECT 'Connected to $name';" -t -A 2>/dev/null | tr -d ' ' || echo "FAILED")
    
    if [[ "$connection_result" == "Connectedto$name" ]]; then
        echo -e "${GREEN}✅ Success${NC}"
    else
        echo -e "${RED}❌ Failed${NC}"
        increment_fail
        return 1
    fi
    
    # Role detection
    echo -n "     Role detection... "
    local actual_role
    actual_role=$(timeout 8 psql -h "$endpoint" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null | tr -d ' ' || echo "unknown")
    
    if [[ "$actual_role" == "primary" ]] || [[ "$actual_role" == "standby" ]]; then
        echo -e "${GREEN}✅ $actual_role${NC}"
        
        # Check role expectation
        if [[ "$expected_role" != "any" && "$actual_role" == "$expected_role" ]]; then
            echo -e "     ${GREEN}✅ Correct routing (expected $expected_role)${NC}"
        elif [[ "$expected_role" != "any" && "$actual_role" != "$expected_role" ]]; then
            echo -e "     ${YELLOW}⚠️  Role mismatch (got $actual_role, expected $expected_role)${NC}"
        fi
    else
        echo -e "${RED}❌ Unknown role: $actual_role${NC}"
        increment_fail
        return 1
    fi
    
    # Backend server information
    echo -n "     Backend server... "
    local backend_info
    backend_info=$(timeout 8 psql -h "$endpoint" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -Atqc "SELECT inet_server_addr() || ':' || inet_server_port();" 2>/dev/null | tr -d ' ' || echo "unknown")
    
    if [[ "$backend_info" != "unknown" ]] && [[ "$backend_info" != *"ERROR"* ]]; then
        echo -e "${GREEN}✅ $backend_info${NC}"
    else
        echo -e "${YELLOW}⚠️  $backend_info${NC}"
    fi
    
    increment_pass
    return 0
}

test_all_database_connections() {
    print_section "Database Connection Tests" "🗄️"
    
    # Test direct backend connections first
    log_info "Testing Direct Backend Connections:"
    test_database_connection "$PRIMARY_IP" "Primary_Backend_Direct" "primary"
    test_database_connection "$STANDBY_IP" "Standby_Backend_Direct" "standby"
    
    # Test load balancer IP connections
    log_info "Testing Load Balancer IP Connections:"
    test_database_connection "$WRITE_IP" "Write_Load_Balancer_IP" "primary"
    test_database_connection "$READ_IP" "Read_Load_Balancer_IP" "standby"
    
    # Test load balancer FQDN connections
    log_info "Testing Load Balancer FQDN Connections:"
    test_database_connection "$WRITE_FQDN" "Write_Load_Balancer_FQDN" "primary"
    test_database_connection "$READ_FQDN" "Read_Load_Balancer_FQDN" "standby"
}

# ============================================================================
# REPLICATION TEST FUNCTIONS
# ============================================================================

test_replication_via_ips() {
    print_section "Replication Test via IP Addresses" "🔄"
    
    local test_id=$((RANDOM % 100000))
    local test_message="IP_replication_test_${test_id}"
    
    increment_test
    
    log_info "Testing replication using IP addresses"
    log_info "Test ID: $test_id | Message: $test_message"
    
    # Step 1: Insert data via Write Load Balancer IP
    echo -n "   Step 1: Inserting data via Write LB IP ($WRITE_IP)... "
    
    if timeout 15 psql -h "$WRITE_IP" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" << EOF >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS $TEST_TABLE (
    id INTEGER,
    message TEXT,
    test_type TEXT,
    endpoint_used TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO $TEST_TABLE (id, message, test_type, endpoint_used) 
VALUES ($test_id, '$test_message', 'ip_test', 'write_lb_ip');
EOF
    then
        echo -e "${GREEN}✅ Success${NC}"
    else
        echo -e "${RED}❌ Failed${NC}"
        increment_fail
        return 1
    fi
    
    # Step 2: Wait for replication
    echo -n "   Step 2: Waiting for replication (8 seconds)... "
    sleep 8
    echo -e "${BLUE}⏱️  Complete${NC}"
    
    # Step 3: Verify data via Read Load Balancer IP
    echo -n "   Step 3: Verifying data via Read LB IP ($READ_IP)... "
    
    local found_count
    found_count=$(timeout 12 psql -h "$READ_IP" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -Atqc "SELECT COUNT(*) FROM $TEST_TABLE WHERE id = $test_id AND test_type = 'ip_test';" 2>/dev/null | tr -d ' ' || echo "0")
    
    if [[ "$found_count" == "1" ]]; then
        echo -e "${GREEN}✅ Data replicated successfully${NC}"
        
        # Get detailed data
        local replicated_data
        replicated_data=$(timeout 10 psql -h "$READ_IP" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -Atqc "SELECT message, created_at FROM $TEST_TABLE WHERE id = $test_id;" 2>/dev/null || echo "unknown")
        
        log_success "Replicated data: $replicated_data"
        increment_pass
        return 0
    else
        echo -e "${RED}❌ Data not found (count: $found_count)${NC}"
        increment_fail
        return 1
    fi
}

test_replication_via_fqdns() {
    print_section "Replication Test via FQDN Addresses" "🔄"
    
    local test_id=$((RANDOM % 100000))
    local test_message="FQDN_replication_test_${test_id}"
    
    increment_test
    
    log_info "Testing replication using FQDN addresses"
    log_info "Test ID: $test_id | Message: $test_message"
    
    # Step 1: Insert data via Write Load Balancer FQDN
    echo -n "   Step 1: Inserting data via Write LB FQDN ($WRITE_FQDN)... "
    
    if timeout 15 psql -h "$WRITE_FQDN" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" << EOF >/dev/null 2>&1
INSERT INTO $TEST_TABLE (id, message, test_type, endpoint_used) 
VALUES ($test_id, '$test_message', 'fqdn_test', 'write_lb_fqdn');
EOF
    then
        echo -e "${GREEN}✅ Success${NC}"
    else
        echo -e "${RED}❌ Failed${NC}"
        increment_fail
        return 1
    fi
    
    # Step 2: Wait for replication
    echo -n "   Step 2: Waiting for replication (8 seconds)... "
    sleep 8
    echo -e "${BLUE}⏱️  Complete${NC}"
    
    # Step 3: Verify data via Read Load Balancer FQDN
    echo -n "   Step 3: Verifying data via Read LB FQDN ($READ_FQDN)... "
    
    local found_count
    found_count=$(timeout 12 psql -h "$READ_FQDN" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -Atqc "SELECT COUNT(*) FROM $TEST_TABLE WHERE id = $test_id AND test_type = 'fqdn_test';" 2>/dev/null | tr -d ' ' || echo "0")
    
    if [[ "$found_count" == "1" ]]; then
        echo -e "${GREEN}✅ Data replicated successfully${NC}"
        
        # Get detailed data
        local replicated_data
        replicated_data=$(timeout 10 psql -h "$READ_FQDN" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -Atqc "SELECT message, created_at FROM $TEST_TABLE WHERE id = $test_id;" 2>/dev/null || echo "unknown")
        
        log_success "Replicated data: $replicated_data"
        increment_pass
        return 0
    else
        echo -e "${RED}❌ Data not found (count: $found_count)${NC}"
        increment_fail
        return 1
    fi
}

test_cross_endpoint_replication() {
    print_section "Cross-Endpoint Replication Test" "🔄"
    
    local test_id=$((RANDOM % 100000))
    local test_message="Cross_endpoint_test_${test_id}"
    
    increment_test
    
    log_info "Testing write via IP, read via FQDN"
    log_info "Test ID: $test_id | Message: $test_message"
    
    # Step 1: Insert via Write IP
    echo -n "   Step 1: Writing via IP ($WRITE_IP)... "
    if timeout 15 psql -h "$WRITE_IP" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -c "INSERT INTO $TEST_TABLE (id, message, test_type, endpoint_used) VALUES ($test_id, '$test_message', 'cross_test', 'write_ip_read_fqdn');" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Success${NC}"
    else
        echo -e "${RED}❌ Failed${NC}"
        increment_fail
        return 1
    fi
    
    # Step 2: Wait and read via FQDN
    sleep 8
    echo -n "   Step 2: Reading via FQDN ($READ_FQDN)... "
    
    local cross_test_count
    cross_test_count=$(timeout 12 psql -h "$READ_FQDN" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -Atqc "SELECT COUNT(*) FROM $TEST_TABLE WHERE id = $test_id;" 2>/dev/null | tr -d ' ' || echo "0")
    
    if [[ "$cross_test_count" == "1" ]]; then
        echo -e "${GREEN}✅ Cross-endpoint replication working${NC}"
        increment_pass
    else
        echo -e "${RED}❌ Cross-endpoint replication failed${NC}"
        increment_fail
    fi
}

# ============================================================================
# PERFORMANCE TESTS
# ============================================================================

test_replication_lag() {
    print_section "Replication Lag Assessment" "⏱️"
    
    increment_test
    
    log_info "Measuring replication lag"
    
    echo -n "   Checking current replication lag... "
    
    local lag_seconds
    lag_seconds=$(timeout 10 psql -h "$READ_IP" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 
                 COALESCE(EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp()), 0)
               ELSE 0 END;" 2>/dev/null | tr -d ' ' || echo "999")
    
    # Convert to integer for comparison (remove decimal part)
    local lag_int
    lag_int=$(echo "$lag_seconds" | cut -d'.' -f1 2>/dev/null || echo "999")
    
    if [[ "$lag_int" =~ ^[0-9]+$ ]] && [[ $lag_int -lt 60 ]]; then
        echo -e "${GREEN}✅ ${lag_seconds} seconds (excellent)${NC}"
        increment_pass
    elif [[ "$lag_int" =~ ^[0-9]+$ ]] && [[ $lag_int -lt 300 ]]; then
        echo -e "${YELLOW}⚠️  ${lag_seconds} seconds (acceptable)${NC}"
        increment_pass
    else
        echo -e "${RED}❌ ${lag_seconds} seconds (high lag)${NC}"
        increment_fail
    fi
}

# ============================================================================
# CLEANUP FUNCTIONS
# ============================================================================

cleanup_test_data() {
    print_section "Cleaning Up Test Data" "🧹"
    
    log_info "Removing test table: $TEST_TABLE"
    
    echo -n "   Dropping test table... "
    if timeout 10 psql -h "$WRITE_IP" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -c "DROP TABLE IF EXISTS $TEST_TABLE;" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Cleaned up${NC}"
    else
        echo -e "${YELLOW}⚠️  Manual cleanup may be needed${NC}"
        log_warning "Please manually run: DROP TABLE IF EXISTS $TEST_TABLE;"
    fi
}

# ============================================================================
# REPORTING FUNCTIONS
# ============================================================================

generate_summary_report() {
    print_section "Comprehensive Validation Summary" "📊"
    
    local success_rate
    if [[ $TOTAL_TESTS -gt 0 ]]; then
        success_rate=$(( PASSED_TESTS * 100 / TOTAL_TESTS ))
    else
        success_rate=0
    fi
    
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                        ${BOLD}VALIDATION RESULTS SUMMARY${NC}                        ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} Validation Date:     ${VALIDATION_DATE}                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} Session ID:          ${TEST_SESSION_ID}                                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} Environment:         ${ENV_CODE} (${PROJECT_ID})                 ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} Total Tests:         ${TOTAL_TESTS}                                                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} Passed Tests:        ${PASSED_TESTS}                                                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} Failed Tests:        ${FAILED_TESTS}                                                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} Success Rate:        ${success_rate}%                                                  ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Determine overall status
    if [[ $success_rate -ge 90 ]]; then
        echo -e "${BLUE}║${NC} ${GREEN}Status:              ✅ EXCELLENT - Production Ready${NC}                      ${BLUE}║${NC}"
        OVERALL_STATUS="EXCELLENT"
    elif [[ $success_rate -ge 75 ]]; then
        echo -e "${BLUE}║${NC} ${YELLOW}Status:              ⚠️  GOOD - Minor Issues${NC}                           ${BLUE}║${NC}"
        OVERALL_STATUS="GOOD"
    else
        echo -e "${BLUE}║${NC} ${RED}Status:              ❌ NEEDS ATTENTION - Multiple Issues${NC}               ${BLUE}║${NC}"
        OVERALL_STATUS="NEEDS_ATTENTION"
    fi
    
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
}

generate_connection_examples() {
    print_section "Production Connection Examples" "🔗"
    
    echo ""
    echo -e "${CYAN}${BOLD}LOAD BALANCER ENDPOINTS:${NC}"
    echo ""
    echo -e "${GREEN}Write Operations (Primary):${NC}"
    echo "  IP Address:  postgresql://${DB_USER}:password@${WRITE_IP}:${PGBOUNCER_PORT}/your_database"
    echo "  FQDN:        postgresql://${DB_USER}:password@${WRITE_FQDN}:${PGBOUNCER_PORT}/your_database"
    echo ""
    echo -e "${GREEN}Read Operations (Standby):${NC}"
    echo "  IP Address:  postgresql://${DB_USER}:password@${READ_IP}:${PGBOUNCER_PORT}/your_database"
    echo "  FQDN:        postgresql://${DB_USER}:password@${READ_FQDN}:${PGBOUNCER_PORT}/your_database"
    echo ""
    
    echo -e "${CYAN}${BOLD}DIRECT BACKEND CONNECTIONS (for maintenance):${NC}"
    echo ""
    echo -e "${GREEN}Primary Backend:${NC}"
    echo "  postgresql://${DB_USER}:password@${PRIMARY_IP}:${PGBOUNCER_PORT}/your_database"
    echo ""
    echo -e "${GREEN}Standby Backend:${NC}"
    echo "  postgresql://${DB_USER}:password@${STANDBY_IP}:${PGBOUNCER_PORT}/your_database"
    echo ""
    
    echo -e "${CYAN}${BOLD}APPLICATION CONFIGURATION EXAMPLES:${NC}"
    cat << 'EOF'

# Python Example:
DATABASE_CONFIG = {
    'write': 'postgresql://postgres:password@pg-write.db.internal.nprd.ipa.edu.sa:6432/app_db',
    'read': 'postgresql://postgres:password@pg-read.db.internal.nprd.ipa.edu.sa:6432/app_db'
}

# Java Example:
spring.datasource.write.url=jdbc:postgresql://pg-write.db.internal.nprd.ipa.edu.sa:6432/app_db
spring.datasource.read.url=jdbc:postgresql://pg-read.db.internal.nprd.ipa.edu.sa:6432/app_db

# Node.js Example:
const writePool = new Pool({
  connectionString: 'postgresql://postgres:password@pg-write.db.internal.nprd.ipa.edu.sa:6432/app_db'
});
const readPool = new Pool({
  connectionString: 'postgresql://postgres:password@pg-read.db.internal.nprd.ipa.edu.sa:6432/app_db'
});

EOF
}

generate_monitoring_commands() {
    print_section "Monitoring & Troubleshooting Commands" "📊"
    
    cat << EOF

# Check current replication lag:
psql -h ${READ_IP} -p ${PGBOUNCER_PORT} -U ${DB_USER} -d ${DB_NAME} -c "
SELECT CASE WHEN pg_is_in_recovery() THEN 
  COALESCE(EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp()), 0)
ELSE 0 END as lag_seconds;"

# Check streaming replication status (on primary):
psql -h ${PRIMARY_IP} -p 5432 -U ${DB_USER} -d ${DB_NAME} -c "
SELECT client_addr, state, sync_state, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)) as lag
FROM pg_stat_replication;"

# Check PgBouncer pool status:
psql -h ${PRIMARY_IP} -p ${PGBOUNCER_PORT} -U ${DB_USER} -d ${DB_NAME} -c "SHOW pools;"
psql -h ${STANDBY_IP} -p ${PGBOUNCER_PORT} -U ${DB_USER} -d ${DB_NAME} -c "SHOW pools;"

# Health endpoint checks:
curl -s http://${PRIMARY_IP}:8001 | jq '.status'   # PostgreSQL health
curl -s http://${PRIMARY_IP}:8002 | jq '.status'   # PgBouncer health
curl -s http://${STANDBY_IP}:8001 | jq '.status'   # PostgreSQL health  
curl -s http://${STANDBY_IP}:8002 | jq '.status'   # PgBouncer health

# Test load balancer routing:
psql -h ${WRITE_IP} -p ${PGBOUNCER_PORT} -U ${DB_USER} -d ${DB_NAME} -c "SELECT 'Write LB', pg_is_in_recovery(), inet_server_addr();"
psql -h ${READ_IP} -p ${PGBOUNCER_PORT} -U ${DB_USER} -d ${DB_NAME} -c "SELECT 'Read LB', pg_is_in_recovery(), inet_server_addr();"

EOF
}

# ============================================================================
# MAIN EXECUTION FUNCTION
# ============================================================================

main() {
    local start_time
    start_time=$(date +%s)
    
    # Enable debug mode if requested
    if [[ "${1:-}" == "--debug" ]]; then
        export DEBUG=1
        log_info "Debug mode enabled"
    fi
    
    print_banner
    
    # Execute validation phases
    if ! check_prerequisites; then
        log_error "Prerequisites check failed. Exiting."
        exit 1
    fi
    
    if ! setup_authentication; then
        log_error "Authentication setup failed. Exiting."
        exit 1
    fi
    
    # Network and DNS tests
    test_network_connectivity
    test_dns_resolution
    
    # Database connection tests
    test_all_database_connections
    
    # Replication tests
    test_replication_via_ips
    test_replication_via_fqdns  
    test_cross_endpoint_replication
    
    # Performance tests
    test_replication_lag
    
    # Cleanup
    cleanup_test_data
    
    # Generate reports
    generate_summary_report
    generate_connection_examples
    generate_monitoring_commands
    
    # Final status
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo ""
    log_info "Comprehensive validation completed in ${duration} seconds"
    
    # Return appropriate exit code
    case "${OVERALL_STATUS:-UNKNOWN}" in
        "EXCELLENT") 
            log_success "Load balancer is production ready!"
            exit 0 
            ;;
        "GOOD") 
            log_warning "Load balancer is operational with minor issues"
            exit 1 
            ;;
        *) 
            log_error "Load balancer requires attention before production use"
            exit 2 
            ;;
    esac
}

# ============================================================================
# SCRIPT EXECUTION
# ============================================================================

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi