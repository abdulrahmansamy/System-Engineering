#!/bin/bash
# Quick Health Endpoint Validator
# Tests all health endpoints (PostgreSQL and PgBouncer)
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "%b[INFO]%b %s\n" "$BLUE" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }

# Configuration
PG_HEALTH_PORT=8001
PGBOUNCER_HEALTH_PORT=8002

test_endpoint() {
    local name="$1" port="$2"
    
    info "Testing $name endpoint (port $port)..."
    
    if timeout 5 curl -sf "http://localhost:$port" >/dev/null 2>&1; then
        local response
        response=$(timeout 3 curl -s "http://localhost:$port" 2>/dev/null || echo '{"status":"unknown"}')
        
        if echo "$response" | jq . >/dev/null 2>&1; then
            local status
            status=$(echo "$response" | jq -r '.status' 2>/dev/null || echo "unknown")
            success "✅ $name: $status"
            echo "    Response: $response"
        else
            success "✅ $name: responding (non-JSON)"
            echo "    Response: $response"
        fi
        return 0
    else
        error "❌ $name: not responding"
        return 1
    fi
}

main() {
    info "🏥 Health Endpoint Validation"
    info "============================"
    
    local failed=0
    
    # Test PostgreSQL health endpoint
    test_endpoint "PostgreSQL HA Health" "$PG_HEALTH_PORT" || ((failed++))
    
    echo ""
    
    # Test PgBouncer health endpoint
    test_endpoint "PgBouncer Health" "$PGBOUNCER_HEALTH_PORT" || ((failed++))
    
    echo ""
    info "=========================="
    
    if [[ $failed -eq 0 ]]; then
        success "🎉 All health endpoints are working!"
        return 0
    else
        error "❌ $failed endpoint(s) failed"
        return 1
    fi
}

# Run main function
main "$@"