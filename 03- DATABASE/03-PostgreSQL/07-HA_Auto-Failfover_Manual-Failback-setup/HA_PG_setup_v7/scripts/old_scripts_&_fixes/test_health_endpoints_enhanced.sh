#!/bin/bash
# Enhanced Health Endpoint Test Script for PostgreSQL HA Cluster
# Tests all health endpoints with comprehensive validation
# Version: 2.0.0
# Usage: ./test_health_endpoints_enhanced.sh

set -euo pipefail

# Configuration from Terraform outputs (update these IPs based on your deployment)
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22" 
WITNESS_IP="192.168.14.23"  # Optional if witness enabled
PG_HEALTH_PORT="8001"
PGBOUNCER_HEALTH_PORT="8002"
TIMEOUT=10

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Counters
TOTAL_ENDPOINTS=0
WORKING_ENDPOINTS=0
FAILED_ENDPOINTS=0

# Logging functions
info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[PASS]${NC} %s\n" "$*"; ((WORKING_ENDPOINTS++)); }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; ((FAILED_ENDPOINTS++)); }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
section() { printf "\n${PURPLE}=== %s ===${NC}\n" "$*"; }

# Test individual endpoint
test_endpoint() {
    local ip="$1"
    local port="$2" 
    local name="$3"
    local service="$4"
    local url="http://${ip}:${port}"
    
    ((TOTAL_ENDPOINTS++))
    
    info "Testing $name ($service) at $url"
    
    local start_time=$(date +%s%3N)
    local response=$(curl --max-time $TIMEOUT -s -w "%{http_code}" -o /tmp/health_response.json "$url" 2>/dev/null || echo "000")
    local end_time=$(date +%s%3N)
    local duration=$((end_time - start_time))
    
    printf "  ⏱️  Response time: %d ms\n" $duration
    
    if [[ "$response" =~ ^[0-9]+$ ]] && [[ "$response" -ge 200 ]] && [[ "$response" -lt 400 ]]; then
        if [[ -f /tmp/health_response.json ]] && jq . /tmp/health_response.json >/dev/null 2>&1; then
            success "$name endpoint is healthy (HTTP $response)"
            printf "  📋 Response: "
            jq -c . /tmp/health_response.json
            
            # Additional validation based on service type
            if [[ "$service" == "PostgreSQL-HA" ]]; then
                local role=$(jq -r '.role // "unknown"' /tmp/health_response.json 2>/dev/null)
                printf "  🎭 Role: %s\n" "$role"
                
                # Primary should return 200, standby should return 503 for proper LB behavior
                if [[ "$ip" == "$PRIMARY_IP" && "$response" == "200" && "$role" == "primary" ]]; then
                    success "Primary node correctly returns 200 status"
                elif [[ "$ip" == "$STANDBY_IP" && "$response" == "503" && "$role" == "standby" ]]; then
                    success "Standby node correctly returns 503 status"
                else
                    warn "Unexpected role/status combination: $role/$response for $ip"
                fi
            fi
        else
            fail "$name endpoint returned invalid JSON (HTTP $response)"
            if [[ -f /tmp/health_response.json ]]; then
                printf "  📄 Raw response: "
                cat /tmp/health_response.json
                echo
            fi
        fi
    else
        fail "$name endpoint is not responding properly (HTTP $response)"
        if [[ -f /tmp/health_response.json ]]; then
            printf "  📄 Raw response: "
            cat /tmp/health_response.json
            echo
        fi
    fi
    
    rm -f /tmp/health_response.json
    echo
}

# Test connectivity to IP addresses
test_connectivity() {
    section "Network Connectivity Tests"
    
    for ip in "$PRIMARY_IP" "$STANDBY_IP"; do
        info "Testing basic connectivity to $ip"
        if ping -c 1 -W 3 "$ip" >/dev/null 2>&1; then
            success "Can ping $ip"
        else
            fail "Cannot ping $ip"
        fi
    done
}

# Test PostgreSQL direct connections
test_postgresql_direct() {
    section "PostgreSQL Direct Connection Tests"
    
    for ip in "$PRIMARY_IP" "$STANDBY_IP"; do
        info "Testing PostgreSQL connection to $ip:5432"
        if timeout 5 bash -c "</dev/tcp/$ip/5432" 2>/dev/null; then
            success "PostgreSQL port 5432 is open on $ip"
        else
            fail "PostgreSQL port 5432 is not accessible on $ip"
        fi
    done
}

# Test PgBouncer connections  
test_pgbouncer_direct() {
    section "PgBouncer Direct Connection Tests"
    
    for ip in "$PRIMARY_IP" "$STANDBY_IP"; do
        info "Testing PgBouncer connection to $ip:6432"
        if timeout 5 bash -c "</dev/tcp/$ip/6432" 2>/dev/null; then
            success "PgBouncer port 6432 is open on $ip"
        else
            fail "PgBouncer port 6432 is not accessible on $ip"
        fi
    done
}

# Main health endpoint tests
test_all_health_endpoints() {
    section "PostgreSQL HA Health Endpoints (Port $PG_HEALTH_PORT)"
    test_endpoint "$PRIMARY_IP" "$PG_HEALTH_PORT" "Primary PostgreSQL HA" "PostgreSQL-HA"
    test_endpoint "$STANDBY_IP" "$PG_HEALTH_PORT" "Standby PostgreSQL HA" "PostgreSQL-HA"
    
    section "PgBouncer Health Endpoints (Port $PGBOUNCER_HEALTH_PORT)"  
    test_endpoint "$PRIMARY_IP" "$PGBOUNCER_HEALTH_PORT" "Primary PgBouncer" "PgBouncer"
    test_endpoint "$STANDBY_IP" "$PGBOUNCER_HEALTH_PORT" "Standby PgBouncer" "PgBouncer"
}

# Generate summary report
generate_summary() {
    section "Health Check Summary Report"
    
    printf "📊 Endpoint Statistics:\n"
    printf "  Total Endpoints Tested: %d\n" $TOTAL_ENDPOINTS
    printf "  ${GREEN}Working Endpoints: %d${NC}\n" $WORKING_ENDPOINTS  
    printf "  ${RED}Failed Endpoints: %d${NC}\n" $FAILED_ENDPOINTS
    printf "  Success Rate: %.1f%%\n" $(echo "scale=1; $WORKING_ENDPOINTS * 100 / $TOTAL_ENDPOINTS" | bc -l 2>/dev/null || echo "N/A")
    
    echo
    printf "🎯 Load Balancer Configuration:\n"
    printf "  Primary PostgreSQL Health: http://%s:%s\n" "$PRIMARY_IP" "$PG_HEALTH_PORT"
    printf "  Primary PgBouncer Health: http://%s:%s\n" "$PRIMARY_IP" "$PGBOUNCER_HEALTH_PORT" 
    printf "  Standby PostgreSQL Health: http://%s:%s\n" "$STANDBY_IP" "$PG_HEALTH_PORT"
    printf "  Standby PgBouncer Health: http://%s:%s\n" "$STANDBY_IP" "$PGBOUNCER_HEALTH_PORT"
    
    echo
    if [[ $WORKING_ENDPOINTS -eq $TOTAL_ENDPOINTS ]]; then
        success "🎉 ALL HEALTH ENDPOINTS WORKING - READY FOR LOAD BALANCER!"
        return 0
    elif [[ $WORKING_ENDPOINTS -ge $((TOTAL_ENDPOINTS * 3 / 4)) ]]; then
        warn "🔧 MOSTLY WORKING - Minor issues to address ($FAILED_ENDPOINTS failures)"
        return 1
    elif [[ $WORKING_ENDPOINTS -gt 0 ]]; then
        warn "⚠️ PARTIAL SUCCESS - Some endpoints working ($FAILED_ENDPOINTS failures)"  
        return 1
    else
        fail "❌ ALL ENDPOINTS FAILED - Need troubleshooting"
        return 1
    fi
}

# Main execution
main() {
    printf "${PURPLE}"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║     PostgreSQL HA Health Endpoint Test Suite        ║
║               Production Validation                  ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "${NC}\n"
    
    info "Testing PostgreSQL HA Cluster Health Endpoints"
    info "Primary: $PRIMARY_IP | Standby: $STANDBY_IP"
    info "PostgreSQL Health Port: $PG_HEALTH_PORT | PgBouncer Health Port: $PGBOUNCER_HEALTH_PORT"
    
    test_connectivity
    test_postgresql_direct
    test_pgbouncer_direct  
    test_all_health_endpoints
    generate_summary
}

# Check for required tools
for tool in curl jq bc; do
    if ! command -v $tool >&/dev/null; then
        fail "Required tool '$tool' is not installed"
        exit 1
    fi
done

main "$@"