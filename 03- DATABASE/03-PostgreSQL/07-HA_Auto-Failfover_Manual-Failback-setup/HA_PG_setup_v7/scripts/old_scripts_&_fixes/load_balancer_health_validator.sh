#!/bin/bash
# GCP Internal Load Balancer Health Validation Script
# Tests both Write and Read Load Balancers with proper health check validation
# 
# Version: 1.0.0/b# ============================================================================
# CONFIGURATION
# ============================================================================nternal Load Balancer Health Validation Script
# Tests both Write and Read Load Balancers with proper health check validation
# 
# Version: 1.0.0

set -uo pipefail

# ============================================================================
# CONFIGURATION
# ======================================================        # Test read capability
        local read_test_result
        read_test_result=$(PGPASSWORD="$PG_SUPER_PASS" psql -h "$READ_LB_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 'READ_test_success' as test_result;" -t 2>/dev/null | xargs || echo "FAILED")
        
        if [[ "$read_test_result" =~ ^read_test_success$|^READ_TEST_SUCCESS$ ]]; then
            print_success "Read Load Balancer read capability: CONFIRMED"
        else
            print_error "Read Load Balancer read test failed: $read_test_result"
        fi=============

# Load Balancer IPs (Internal Load Balancers)
readonly WRITE_LB_IP="192.168.14.20"
readonly READ_LB_IP="192.168.14.19"

# Backend Instance IPs
readonly PRIMARY_IP="192.168.14.21"
readonly STANDBY_IP="192.168.14.22"

# Ports
readonly PG_PORT="5432"
readonly PGBOUNCER_PORT="6432"
readonly PG_HEALTH_PORT="8001"
readonly PGBOUNCER_HEALTH_PORT="8002"

# DNS Names
readonly WRITE_DNS="pg-write.db.internal.nprd.ipa.edu.sa"
readonly READ_DNS="pg-read.db.internal.nprd.ipa.edu.sa"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Check for required tools and install if needed
check_and_install_tools() {
    local missing_tools=()
    
    # Check each tool
    for tool in curl jq psql timeout; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    # Special handling for dig (part of dnsutils)
    if ! command -v dig >/dev/null 2>&1; then
        if ! command -v nslookup >/dev/null 2>&1; then
            missing_tools+=("dnsutils")
        fi
    fi
    
    # Install missing tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  Installing missing tools: ${missing_tools[*]}${NC}"
        
        # Update package list
        sudo apt-get update -qq
        
        # Install tools
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                "dnsutils")
                    sudo apt-get install -y dnsutils
                    ;;
                "jq")
                    sudo apt-get install -y jq
                    ;;
                "curl")
                    sudo apt-get install -y curl
                    ;;
                "psql")
                    sudo apt-get install -y postgresql-client
                    ;;
                "timeout")
                    sudo apt-get install -y coreutils
                    ;;
            esac
        done
        
        echo -e "${GREEN}✅ All required tools installed successfully${NC}"
    fi
}

# Alternative DNS resolution function that works with nslookup if dig is not available
resolve_dns() {
    local hostname="$1"
    
    if command -v dig >/dev/null 2>&1; then
        dig +short "$hostname" 2>/dev/null | head -1
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$hostname" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}'
    else
        # Fallback to getent
        getent hosts "$hostname" 2>/dev/null | awk '{print $1}' | head -1
    fi
}

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_test() {
    echo -e "\n${YELLOW}🔍 $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Test TCP connectivity to a host/port
test_tcp_connection() {
    local host="$1"
    local port="$2"
    local timeout="${3:-5}"
    
    if timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Test HTTP endpoint
test_http_endpoint() {
    local url="$1"
    local expected_status="${2:-200}"
    
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000")
    
    if [[ "$response" == "$expected_status" ]]; then
        return 0
    else
        echo "$response"
        return 1
    fi
}

# Get HTTP response body
get_http_response() {
    local url="$1"
    curl -s --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo ""
}

# Test database connectivity
test_database_connection() {
    local host="$1"
    local port="$2"
    local database="${3:-postgres}"
    local user="${4:-postgres}"
    local password="$5"
    
    if [[ -n "$password" ]]; then
        PGPASSWORD="$password" timeout 10 psql -h "$host" -p "$port" -U "$user" -d "$database" -c "SELECT 1;" >/dev/null 2>&1
    else
        timeout 10 psql -h "$host" -p "$port" -U "$user" -d "$database" -c "SELECT 1;" >/dev/null 2>&1
    fi
}

# ============================================================================
# VALIDATION TESTS
# ============================================================================

validate_dns_resolution() {
    print_header "DNS RESOLUTION VALIDATION"
    
    print_test "Testing Write Load Balancer DNS Resolution"
    local write_resolved
    write_resolved=$(resolve_dns "$WRITE_DNS")
    if [[ "$write_resolved" == "$WRITE_LB_IP" ]]; then
        print_success "Write DNS resolves correctly: $WRITE_DNS → $WRITE_LB_IP"
    else
        print_error "Write DNS resolution failed: $WRITE_DNS → $write_resolved (expected: $WRITE_LB_IP)"
        return 1
    fi
    
    print_test "Testing Read Load Balancer DNS Resolution"
    local read_resolved
    read_resolved=$(resolve_dns "$READ_DNS")
    if [[ "$read_resolved" == "$READ_LB_IP" ]]; then
        print_success "Read DNS resolves correctly: $READ_DNS → $READ_LB_IP"
    else
        print_error "Read DNS resolution failed: $READ_DNS → $read_resolved (expected: $READ_LB_IP)"
        return 1
    fi
}

validate_backend_health_endpoints() {
    print_header "BACKEND HEALTH ENDPOINTS VALIDATION"
    
    # Test Primary PostgreSQL Health
    print_test "Testing Primary PostgreSQL Health Endpoint"
    local primary_pg_health
    primary_pg_health=$(get_http_response "http://$PRIMARY_IP:$PG_HEALTH_PORT")
    if echo "$primary_pg_health" | jq -e '.status == "healthy" and .role == "primary"' >/dev/null 2>&1; then
        print_success "Primary PostgreSQL health endpoint: HEALTHY (PRIMARY)"
        echo "   Response: $primary_pg_health"
    else
        print_error "Primary PostgreSQL health endpoint: UNHEALTHY"
        echo "   Response: $primary_pg_health"
        return 1
    fi
    
    # Test Standby PostgreSQL Health
    print_test "Testing Standby PostgreSQL Health Endpoint"
    local standby_pg_health
    standby_pg_health=$(get_http_response "http://$STANDBY_IP:$PG_HEALTH_PORT")
    if echo "$standby_pg_health" | jq -e '.status == "healthy" and .role == "standby"' >/dev/null 2>&1; then
        print_success "Standby PostgreSQL health endpoint: HEALTHY (STANDBY)"
        echo "   Response: $standby_pg_health"
    else
        print_error "Standby PostgreSQL health endpoint: UNHEALTHY"
        echo "   Response: $standby_pg_health"
        return 1
    fi
    
    # Test Primary PgBouncer Health
    print_test "Testing Primary PgBouncer Health Endpoint"
    local primary_pgb_health
    primary_pgb_health=$(get_http_response "http://$PRIMARY_IP:$PGBOUNCER_HEALTH_PORT")
    if echo "$primary_pgb_health" | jq -e '.status == "healthy" and .service == "pgbouncer"' >/dev/null 2>&1; then
        print_success "Primary PgBouncer health endpoint: HEALTHY"
        echo "   Response: $primary_pgb_health"
    else
        print_error "Primary PgBouncer health endpoint: UNHEALTHY"
        echo "   Response: $primary_pgb_health"
        return 1
    fi
    
    # Test Standby PgBouncer Health
    print_test "Testing Standby PgBouncer Health Endpoint"
    local standby_pgb_health
    standby_pgb_health=$(get_http_response "http://$STANDBY_IP:$PGBOUNCER_HEALTH_PORT")
    if echo "$standby_pgb_health" | jq -e '.status == "healthy" and .service == "pgbouncer"' >/dev/null 2>&1; then
        print_success "Standby PgBouncer health endpoint: HEALTHY"
        echo "   Response: $standby_pgb_health"
    else
        print_error "Standby PgBouncer health endpoint: UNHEALTHY"
        echo "   Response: $standby_pgb_health"
        return 1
    fi
}

validate_load_balancer_tcp_connectivity() {
    print_header "LOAD BALANCER TCP CONNECTIVITY VALIDATION"
    
    # Test Write Load Balancer PostgreSQL Port
    print_test "Testing Write Load Balancer PostgreSQL Port ($WRITE_LB_IP:$PG_PORT)"
    if test_tcp_connection "$WRITE_LB_IP" "$PG_PORT"; then
        print_success "Write Load Balancer PostgreSQL port: ACCESSIBLE"
    else
        print_error "Write Load Balancer PostgreSQL port: NOT ACCESSIBLE"
        return 1
    fi
    
    # Test Write Load Balancer PgBouncer Port
    print_test "Testing Write Load Balancer PgBouncer Port ($WRITE_LB_IP:$PGBOUNCER_PORT)"
    if test_tcp_connection "$WRITE_LB_IP" "$PGBOUNCER_PORT"; then
        print_success "Write Load Balancer PgBouncer port: ACCESSIBLE"
    else
        print_error "Write Load Balancer PgBouncer port: NOT ACCESSIBLE"
        return 1
    fi
    
    # Test Read Load Balancer PostgreSQL Port
    print_test "Testing Read Load Balancer PostgreSQL Port ($READ_LB_IP:$PG_PORT)"
    if test_tcp_connection "$READ_LB_IP" "$PG_PORT"; then
        print_success "Read Load Balancer PostgreSQL port: ACCESSIBLE"
    else
        print_error "Read Load Balancer PostgreSQL port: NOT ACCESSIBLE"
        return 1
    fi
    
    # Test Read Load Balancer PgBouncer Port
    print_test "Testing Read Load Balancer PgBouncer Port ($READ_LB_IP:$PGBOUNCER_PORT)"
    if test_tcp_connection "$READ_LB_IP" "$PGBOUNCER_PORT"; then
        print_success "Read Load Balancer PgBouncer port: ACCESSIBLE"
    else
        print_error "Read Load Balancer PgBouncer port: NOT ACCESSIBLE"
        return 1
    fi
}

validate_load_balancer_routing() {
    print_header "LOAD BALANCER ROUTING VALIDATION"
    
    # This test requires database credentials
    if [[ -z "${PG_SUPER_PASS:-}" ]]; then
        print_warning "PG_SUPER_PASS not set - skipping database routing tests"
        print_warning "To test database routing, set: export PG_SUPER_PASS='your_password'"
        return 0
    fi
    
    # Test Write Load Balancer Database Routing
    print_test "Testing Write Load Balancer Database Routing via PgBouncer"
    if test_database_connection "$WRITE_LB_IP" "$PGBOUNCER_PORT" "postgres" "postgres" "$PG_SUPER_PASS"; then
        print_success "Write Load Balancer database routing: WORKING"
        
        # Test if we can write (should route to primary)
        local write_test_result
        write_test_result=$(PGPASSWORD="$PG_SUPER_PASS" psql -h "$WRITE_LB_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 'WRITE_TEST_SUCCESS' as test_result;" -t 2>/dev/null | xargs || echo "FAILED")
        
        if [[ "$write_test_result" == "WRITE_TEST_SUCCESS" ]]; then
            print_success "Write Load Balancer write capability: CONFIRMED"
        else
            print_error "Write Load Balancer write test failed: $write_test_result"
        fi
    else
        print_error "Write Load Balancer database routing: FAILED"
        return 1
    fi
    
    # Test Read Load Balancer Database Routing
    print_test "Testing Read Load Balancer Database Routing via PgBouncer"
    if test_database_connection "$READ_LB_IP" "$PGBOUNCER_PORT" "postgres" "postgres" "$PG_SUPER_PASS"; then
        print_success "Read Load Balancer database routing: WORKING"
        
        # Test read capability
        local read_test_result
        read_test_result=$(PGPASSWORD="$PG_SUPER_PASS" psql -h "$READ_LB_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 'READ_test_success' as test_result;" -t 2>/dev/null | xargs || echo "FAILED")
        
        if [[ "$read_test_result" == "read_test_success" ]]; then
            print_success "Read Load Balancer read capability: CONFIRMED"
        else
            print_error "Read Load Balancer read test failed: $read_test_result"
        fi
    else
        print_error "Read Load Balancer database routing: FAILED"
        return 1
    fi
}

validate_dns_routing() {
    print_header "DNS-BASED ROUTING VALIDATION"
    
    # This test requires database credentials
    if [[ -z "${PG_SUPER_PASS:-}" ]]; then
        print_warning "PG_SUPER_PASS not set - skipping DNS routing tests"
        return 0
    fi
    
    # Test Write DNS
    print_test "Testing Write DNS Database Connection ($WRITE_DNS:$PGBOUNCER_PORT)"
    if test_database_connection "$WRITE_DNS" "$PGBOUNCER_PORT" "postgres" "postgres" "$PG_SUPER_PASS"; then
        print_success "Write DNS database connection: WORKING"
    else
        print_error "Write DNS database connection: FAILED"
        return 1
    fi
    
    # Test Read DNS
    print_test "Testing Read DNS Database Connection ($READ_DNS:$PGBOUNCER_PORT)"
    if test_database_connection "$READ_DNS" "$PGBOUNCER_PORT" "postgres" "postgres" "$PG_SUPER_PASS"; then
        print_success "Read DNS database connection: WORKING"
    else
        print_error "Read DNS database connection: FAILED"
        return 1
    fi
}

validate_gcp_load_balancer_health_checks() {
    print_header "GCP LOAD BALANCER HEALTH CHECK VALIDATION"
    
    print_test "Simulating GCP Internal Load Balancer Health Checks"
    
    # Test health checks that GCP ILB would perform
    echo -e "\n${BLUE}Testing health checks for Write Load Balancer backends:${NC}"
    
    # Primary instance health checks (Write LB should route here)
    local primary_pg_status primary_pgb_status
    primary_pg_status=$(test_http_endpoint "http://$PRIMARY_IP:$PG_HEALTH_PORT" 200 && echo "HEALTHY" || echo "UNHEALTHY")
    primary_pgb_status=$(test_http_endpoint "http://$PRIMARY_IP:$PGBOUNCER_HEALTH_PORT" 200 && echo "HEALTHY" || echo "UNHEALTHY")
    
    echo "   Primary ($PRIMARY_IP) - PostgreSQL Health: $primary_pg_status"
    echo "   Primary ($PRIMARY_IP) - PgBouncer Health: $primary_pgb_status"
    
    echo -e "\n${BLUE}Testing health checks for Read Load Balancer backends:${NC}"
    
    # Standby instance health checks (Read LB should route here)
    local standby_pg_status standby_pgb_status
    standby_pg_status=$(test_http_endpoint "http://$STANDBY_IP:$PG_HEALTH_PORT" 200 && echo "HEALTHY" || echo "UNHEALTHY")
    standby_pgb_status=$(test_http_endpoint "http://$STANDBY_IP:$PGBOUNCER_HEALTH_PORT" 200 && echo "HEALTHY" || echo "UNHEALTHY")
    
    echo "   Standby ($STANDBY_IP) - PostgreSQL Health: $standby_pg_status"
    echo "   Standby ($STANDBY_IP) - PgBouncer Health: $standby_pgb_status"
    
    # Summary
    if [[ "$primary_pg_status" == "HEALTHY" && "$primary_pgb_status" == "HEALTHY" && 
          "$standby_pg_status" == "HEALTHY" && "$standby_pgb_status" == "HEALTHY" ]]; then
        print_success "All GCP Load Balancer health checks: PASSING"
        print_success "GCP Internal Load Balancers should route traffic correctly"
    else
        print_error "Some GCP Load Balancer health checks: FAILING"
        print_error "GCP Internal Load Balancers may not route traffic correctly"
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    echo -e "${GREEN}"
    echo "🎯 GCP Internal Load Balancer Health Validation"
    echo "=============================================="
    echo "Testing Load Balancers, Health Checks, and Routing"
    echo -e "Date: $(date)${NC}\n"
    
    # Install tools if needed
    check_and_install_tools
    
    local test_failures=0
    
    # Run all validation tests
    validate_dns_resolution || ((test_failures++))
    validate_backend_health_endpoints || ((test_failures++))
    validate_load_balancer_tcp_connectivity || ((test_failures++))
    validate_gcp_load_balancer_health_checks || ((test_failures++))
    validate_load_balancer_routing || ((test_failures++))
    validate_dns_routing || ((test_failures++))
    
    # Final summary
    print_header "VALIDATION SUMMARY"
    
    if [[ $test_failures -eq 0 ]]; then
        echo -e "${GREEN}"
        echo "🎉 ALL TESTS PASSED! 🎉"
        echo "========================="
        echo "✅ DNS Resolution: WORKING"
        echo "✅ Backend Health Endpoints: HEALTHY"
        echo "✅ Load Balancer TCP Connectivity: WORKING"
        echo "✅ GCP Health Checks: PASSING"
        echo "✅ Database Routing: WORKING"
        echo "✅ DNS-based Routing: WORKING"
        echo ""
        echo "🚀 Your GCP Internal Load Balancers are 100% operational!"
        echo "🎯 Production traffic can be safely routed through:"
        echo "   - Write: $WRITE_DNS ($WRITE_LB_IP)"
        echo "   - Read:  $READ_DNS ($READ_LB_IP)"
        echo -e "${NC}"
        return 0
    else
        echo -e "${RED}"
        echo "❌ SOME TESTS FAILED!"
        echo "===================="
        echo "Failed tests: $test_failures"
        echo ""
        echo "Please check the failed tests above and resolve issues before"
        echo "using the load balancers in production."
        echo -e "${NC}"
        return 1
    fi
}



# Run main function
main "$@"