#!/bin/bash
# PostgreSQL HA Load Balancer Diagnostics
# Checks load balancer configuration and backend health

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔍 PostgreSQL HA Load Balancer Diagnostics${NC}"
echo -e "${BLUE}===========================================${NC}"

# Configuration
WRITE_IP="192.168.14.20"
READ_IP="192.168.14.19"
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PGBOUNCER_PORT=6432
POSTGRES_PORT=5432

echo -e "${GREEN}📋 Configuration:${NC}"
echo "   Write LB:    $WRITE_IP:$PGBOUNCER_PORT"
echo "   Read LB:     $READ_IP:$PGBOUNCER_PORT"
echo "   Primary:     $PRIMARY_IP:$PGBOUNCER_PORT"
echo "   Standby:     $STANDBY_IP:$PGBOUNCER_PORT"
echo ""

echo -e "${YELLOW}🔍 Step 1: Direct Backend Health Check${NC}"
echo "   ====================================="

# Test direct connections to backends
test_direct_connection() {
    local ip="$1"
    local name="$2"
    
    echo -n "   Testing $name ($ip) - PgBouncer... "
    if timeout 5 psql -h "$ip" -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ OK${NC}"
        
        # Get role info
        local role
        role=$(timeout 5 psql -h "$ip" -p "$PGBOUNCER_PORT" -U postgres -d postgres -Atqc \
            "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null)
        echo "     Role: $role"
        
        return 0
    else
        echo -e "${RED}❌ FAILED${NC}"
        return 1
    fi
}

test_direct_connection "$PRIMARY_IP" "Primary"
test_direct_connection "$STANDBY_IP" "Standby"

echo ""
echo -e "${YELLOW}🏥 Step 2: Backend Health Endpoints${NC}"
echo "   =================================="

# Test health endpoints (used by load balancer)
test_health_endpoint() {
    local ip="$1"
    local port="$2"
    local name="$3"
    
    echo -n "   Testing $name health ($ip:$port)... "
    local response
    response=$(timeout 5 curl -s "http://$ip:$port" 2>/dev/null || echo "failed")
    
    if echo "$response" | grep -q '"status":"healthy"' || echo "$response" | grep -q '"service":"pgbouncer"'; then
        echo -e "${GREEN}✅ HEALTHY${NC}"
        echo "     Response: $(echo "$response" | head -c 50)..."
        return 0
    else
        echo -e "${RED}❌ UNHEALTHY${NC}"
        echo "     Response: $response"
        return 1
    fi
}

# Test PostgreSQL health endpoints (port 8001)
test_health_endpoint "$PRIMARY_IP" "8001" "Primary PostgreSQL"
test_health_endpoint "$STANDBY_IP" "8001" "Standby PostgreSQL"

# Test PgBouncer health endpoints (port 8002) - used by load balancer
test_health_endpoint "$PRIMARY_IP" "8002" "Primary PgBouncer"
test_health_endpoint "$STANDBY_IP" "8002" "Standby PgBouncer"

echo ""
echo -e "${YELLOW}⚖️  Step 3: Load Balancer Connection Test${NC}"
echo "   ========================================"

# Test load balancer connections with detailed error reporting
test_lb_connection() {
    local ip="$1"
    local name="$2"
    
    echo "   Testing $name ($ip):"
    
    # Test raw connectivity first
    echo -n "     Raw connectivity (telnet-style)... "
    if timeout 3 bash -c "echo >/dev/tcp/$ip/$PGBOUNCER_PORT" 2>/dev/null; then
        echo -e "${GREEN}✅ Connected${NC}"
    else
        echo -e "${RED}❌ Failed${NC}"
        return 1
    fi
    
    # Test psql connection with verbose error reporting
    echo -n "     Database connection... "
    local connection_result
    connection_result=$(timeout 10 psql -h "$ip" -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 'Connected', current_timestamp;" 2>&1 || echo "FAILED")
    
    if echo "$connection_result" | grep -q "Connected"; then
        echo -e "${GREEN}✅ OK${NC}"
        
        # Get backend info
        echo -n "     Getting backend info... "
        local backend_info
        backend_info=$(timeout 5 psql -h "$ip" -p "$PGBOUNCER_PORT" -U postgres -d postgres -Atqc \
            "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END || ' @ ' || inet_server_addr();" 2>/dev/null || echo "unknown")
        echo "$backend_info"
        
        return 0
    else
        echo -e "${RED}❌ FAILED${NC}"
        echo "     Error: $(echo "$connection_result" | head -n 1)"
        return 1
    fi
}

test_lb_connection "$WRITE_IP" "Write Load Balancer"
test_lb_connection "$READ_IP" "Read Load Balancer"

echo ""
echo -e "${YELLOW}🔧 Step 4: Troubleshooting Commands${NC}"
echo "   =================================="

cat << EOF

# If load balancer connections fail, try these:

# 1. Check PgBouncer status on backends:
psql -h $PRIMARY_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "SHOW pools;"
psql -h $STANDBY_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "SHOW pools;"

# 2. Check PgBouncer configuration:
psql -h $PRIMARY_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "SHOW config;"

# 3. Test direct PostgreSQL (bypass PgBouncer):
psql -h $PRIMARY_IP -p $POSTGRES_PORT -U postgres -d postgres -c "SELECT 'Direct PostgreSQL Primary';"
psql -h $STANDBY_IP -p $POSTGRES_PORT -U postgres -d postgres -c "SELECT 'Direct PostgreSQL Standby';"

# 4. Check backend services health (from outside jump host):
gcloud compute backend-services get-health ipa-nprd-bs-pgbouncer-write-01 --region=me-central2 --project=ipa-nprd-svc-db-01
gcloud compute backend-services get-health ipa-nprd-bs-pgbouncer-read-01 --region=me-central2 --project=ipa-nprd-svc-db-01

# 5. Check load balancer forwarding rules:
gcloud compute forwarding-rules describe ipa-nprd-fr-pgbouncer-write-01 --region=me-central2 --project=ipa-nprd-svc-db-01
gcloud compute forwarding-rules describe ipa-nprd-fr-pgbouncer-read-01 --region=me-central2 --project=ipa-nprd-svc-db-01

EOF

echo ""
echo -e "${GREEN}🎯 Diagnostics completed!${NC}"