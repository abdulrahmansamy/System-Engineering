#!/bin/bash
# PostgreSQL HA Load Balancer Deep Diagnostic Script
# Provides complete visibility into cluster state and routing issues
# Version: 1.0.0

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly PURPLE='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Configuration
readonly PROJECT_ID="ipa-nprd-svc-db-01"
readonly REGION="me-central2"
readonly ZONE="me-central2-a"

# Network Configuration
readonly WRITE_IP="192.168.14.20"
readonly READ_IP="192.168.14.19"
readonly PRIMARY_IP="192.168.14.21"
readonly STANDBY_IP="192.168.14.22"
readonly PORT=6432
readonly PG_PORT=5432

# DNS Configuration
readonly WRITE_FQDN="pg-write.db.internal.nprd.ipa.edu.sa"
readonly READ_FQDN="pg-read.db.internal.nprd.ipa.edu.sa"

print_banner() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}    ${BOLD}PostgreSQL HA Load Balancer Deep Diagnostic Analysis${NC}             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}🕐 Analysis Started: $(date -u +"%Y-%m-%d %H:%M:%S UTC")${NC}"
    echo -e "${CYAN}🏷️  Environment: nprd | Project: ${PROJECT_ID}${NC}"
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

# Get PostgreSQL password
get_postgres_password() {
    echo -e "${CYAN}🔐 Retrieving PostgreSQL credentials...${NC}"
    if POSTGRES_PASS=$(gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="$PROJECT_ID" 2>/dev/null); then
        echo -e "${GREEN}✅ Credentials retrieved successfully${NC}"
        export PGPASSWORD="$POSTGRES_PASS"
        
        # Create comprehensive .pgpass
        cat > ~/.pgpass << EOL
# Comprehensive .pgpass for diagnostics
$WRITE_IP:$PORT:*:postgres:$POSTGRES_PASS
$READ_IP:$PORT:*:postgres:$POSTGRES_PASS
$PRIMARY_IP:$PORT:*:postgres:$POSTGRES_PASS
$STANDBY_IP:$PORT:*:postgres:$POSTGRES_PASS
$WRITE_FQDN:$PORT:*:postgres:$POSTGRES_PASS
$READ_FQDN:$PORT:*:postgres:$POSTGRES_PASS
$PRIMARY_IP:$PG_PORT:*:postgres:$POSTGRES_PASS
$STANDBY_IP:$PG_PORT:*:postgres:$POSTGRES_PASS
EOL
        chmod 600 ~/.pgpass
        echo -e "${GREEN}✅ .pgpass configured for all endpoints${NC}"
    else
        echo -e "${RED}❌ Failed to retrieve credentials${NC}"
        exit 1
    fi
}

# Analyze Google Cloud Load Balancer configuration
analyze_load_balancer_config() {
    print_section "Google Cloud Load Balancer Configuration Analysis" "☁️"
    
    echo -e "${CYAN}🔍 Analyzing Load Balancer Resources...${NC}"
    
    # List all load balancers
    echo ""
    echo -e "${YELLOW}📋 Load Balancer Resources:${NC}"
    gcloud compute forwarding-rules list --project="$PROJECT_ID" --filter="region:($REGION)" --format="table(name,IPAddress,target,portRange)" 2>/dev/null || echo "No forwarding rules found"
    
    echo ""
    echo -e "${YELLOW}📋 Backend Services:${NC}"
    gcloud compute backend-services list --project="$PROJECT_ID" --filter="region:($REGION)" --format="table(name,backends[].group,healthChecks[],loadBalancingScheme)" 2>/dev/null || echo "No backend services found"
    
    echo ""
    echo -e "${YELLOW}📋 Health Checks:${NC}"
    gcloud compute health-checks list --project="$PROJECT_ID" --format="table(name,type,port,checkIntervalSec,timeoutSec)" 2>/dev/null || echo "No health checks found"
    
    # Detailed backend service analysis
    echo ""
    echo -e "${CYAN}🔍 Backend Service Detailed Analysis:${NC}"
    
    # Try to find the read backend service
    READ_BACKEND_SERVICES=$(gcloud compute backend-services list --project="$PROJECT_ID" --filter="region:($REGION)" --format="value(name)" 2>/dev/null | grep -i read || echo "")
    
    if [[ -n "$READ_BACKEND_SERVICES" ]]; then
        for service in $READ_BACKEND_SERVICES; do
            echo ""
            echo -e "${YELLOW}📊 Read Backend Service: $service${NC}"
            gcloud compute backend-services describe "$service" --region="$REGION" --project="$PROJECT_ID" --format="yaml" 2>/dev/null || echo "Could not describe $service"
        done
    else
        echo -e "${RED}❌ No read backend services found${NC}"
    fi
}

# Analyze backend health and status
analyze_backend_health() {
    print_section "Backend Instance Health Analysis" "🏥"
    
    echo -e "${CYAN}🔍 Backend Instance Status:${NC}"
    
    # Check instance status
    echo ""
    echo -e "${YELLOW}📋 Compute Instance Status:${NC}"
    gcloud compute instances list --project="$PROJECT_ID" --filter="zone:($ZONE)" --format="table(name,status,machineType,internalIP,externalIP)" 2>/dev/null || echo "No instances found"
    
    # Check instance groups
    echo ""
    echo -e "${YELLOW}📋 Instance Groups:${NC}"
    gcloud compute instance-groups list --project="$PROJECT_ID" --filter="zone:($ZONE)" --format="table(name,zone,size)" 2>/dev/null || echo "No instance groups found"
    
    # Health check status for each backend
    echo ""
    echo -e "${CYAN}🔍 Direct Health Endpoint Analysis:${NC}"
    
    endpoints=("$PRIMARY_IP:8001:Primary_PostgreSQL" "$PRIMARY_IP:8002:Primary_PgBouncer" "$STANDBY_IP:8001:Standby_PostgreSQL" "$STANDBY_IP:8002:Standby_PgBouncer")
    
    for endpoint in "${endpoints[@]}"; do
        IFS=':' read -r ip port name <<< "$endpoint"
        echo ""
        echo -e "${YELLOW}📊 $name Health Check ($ip:$port):${NC}"
        
        if health_response=$(curl -s -m 5 "http://$ip:$port" 2>/dev/null); then
            echo "   Raw Response: $health_response"
            
            # Parse JSON if possible
            if status=$(echo "$health_response" | jq -r '.status // "unknown"' 2>/dev/null); then
                role=$(echo "$health_response" | jq -r '.role // "unknown"' 2>/dev/null)
                timestamp=$(echo "$health_response" | jq -r '.timestamp // "unknown"' 2>/dev/null)
                echo -e "   ${GREEN}✅ Status: $status${NC}"
                [[ "$role" != "unknown" ]] && echo -e "   ${CYAN}🎯 Role: $role${NC}"
                [[ "$timestamp" != "unknown" ]] && echo -e "   ${BLUE}⏰ Timestamp: $timestamp${NC}"
            else
                echo -e "   ${YELLOW}⚠️  Non-JSON response or parsing error${NC}"
            fi
        else
            echo -e "   ${RED}❌ Health endpoint unreachable${NC}"
        fi
    done
}

# Deep PostgreSQL cluster analysis
analyze_postgresql_cluster() {
    print_section "PostgreSQL Cluster State Analysis" "🗄️"
    
    echo -e "${CYAN}🔍 PostgreSQL Cluster Status:${NC}"
    
    # Direct PostgreSQL analysis
    backends=("$PRIMARY_IP:Primary" "$STANDBY_IP:Standby")
    
    for backend in "${backends[@]}"; do
        IFS=':' read -r ip name <<< "$backend"
        echo ""
        echo -e "${YELLOW}📊 $name Node Analysis ($ip):${NC}"
        
        # Basic connection test via PgBouncer
        echo -n "   PgBouncer Connection ($PORT)... "
        if timeout 5 psql -h "$ip" -p "$PORT" -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Connected${NC}"
            
            # Get role information
            role_info=$(timeout 5 psql -h "$ip" -p "$PORT" -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown") 
            echo -e "   ${CYAN}🎯 Role via PgBouncer: $role_info${NC}"
            
            # Get backend server info
            backend_info=$(timeout 5 psql -h "$ip" -p "$PORT" -U postgres -d postgres -Atqc "SELECT inet_server_addr() || ':' || inet_server_port();" 2>/dev/null || echo "unknown")
            echo -e "   ${BLUE}🔗 Backend Server: $backend_info${NC}"
            
            # Get PgBouncer stats
            echo -e "   ${PURPLE}📈 PgBouncer Pool Status:${NC}"
            timeout 5 psql -h "$ip" -p "$PORT" -U postgres -d pgbouncer -c "SHOW pools;" 2>/dev/null | head -5 || echo "      Could not retrieve pool stats"
            
        else
            echo -e "${RED}❌ Connection failed${NC}"
        fi
        
        # Direct PostgreSQL connection test
        echo -n "   Direct PostgreSQL Connection ($PG_PORT)... "
        if timeout 5 psql -h "$ip" -p "$PG_PORT" -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Connected${NC}"
            
            # Detailed PostgreSQL analysis
            direct_role=$(timeout 5 psql -h "$ip" -p "$PG_PORT" -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
            echo -e "   ${CYAN}🎯 Role via Direct: $direct_role${NC}"
            
            # Replication status
            if [[ "$direct_role" == "primary" ]]; then
                echo -e "   ${PURPLE}📡 Replication Status (as Primary):${NC}"
                timeout 5 psql -h "$ip" -p "$PG_PORT" -U postgres -d postgres -c "SELECT client_addr, state, sync_state, flush_lsn FROM pg_stat_replication;" 2>/dev/null || echo "      No replication info"
            else
                echo -e "   ${PURPLE}📡 Replication Status (as Standby):${NC}"
                timeout 5 psql -h "$ip" -p "$PG_PORT" -U postgres -d postgres -c "SELECT status, received_lsn, last_msg_send_time, last_msg_receipt_time FROM pg_stat_wal_receiver;" 2>/dev/null || echo "      No WAL receiver info"
            fi
            
        else
            echo -e "${RED}❌ Direct connection failed${NC}"
        fi
    done
}

# Load balancer routing analysis
analyze_load_balancer_routing() {
    print_section "Load Balancer Routing Behavior Analysis" "🔄"
    
    echo -e "${CYAN}🔍 Testing Load Balancer Routing Behavior:${NC}"
    
    # Multiple connection tests to see routing patterns
    endpoints=("$WRITE_IP:Write_LB_IP" "$READ_IP:Read_LB_IP" "$WRITE_FQDN:Write_LB_FQDN" "$READ_FQDN:Read_LB_FQDN")
    
    for endpoint in "${endpoints[@]}"; do
        IFS=':' read -r address name <<< "$endpoint"
        echo ""
        echo -e "${YELLOW}📊 $name Routing Analysis ($address):${NC}"
        
        # Multiple consecutive tests to check consistency
        echo -e "   ${PURPLE}🔄 Multiple Connection Test (5 attempts):${NC}"
        for i in {1..5}; do
            echo -n "      Attempt $i: "
            
            result=$(timeout 3 psql -h "$address" -p "$PORT" -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END, inet_server_addr(), inet_server_port();" 2>/dev/null || echo "failed,unknown,unknown")
            
            IFS=',' read -r role backend_ip backend_port <<< "$result"
            if [[ "$role" != "failed" ]]; then
                echo -e "${GREEN}✅ $role${NC} (backend: $backend_ip:$backend_port)"
            else
                echo -e "${RED}❌ Connection failed${NC}"
            fi
            
            sleep 1
        done
        
        # DNS resolution check for FQDN endpoints
        if [[ "$address" == *"."* ]]; then
            echo -n "   DNS Resolution: "
            resolved_ip=$(dig +short "$address" 2>/dev/null | head -1 || echo "failed")
            if [[ "$resolved_ip" != "failed" ]]; then
                echo -e "${GREEN}✅ $resolved_ip${NC}"
            else
                echo -e "${RED}❌ DNS resolution failed${NC}"
            fi
        fi
    done
}

# Network connectivity deep analysis
analyze_network_connectivity() {
    print_section "Network Connectivity Deep Analysis" "🌐"
    
    echo -e "${CYAN}🔍 Network Layer Analysis:${NC}"
    
    # Port connectivity tests
    endpoints=("$WRITE_IP:$PORT:Write_LB" "$READ_IP:$PORT:Read_LB" "$PRIMARY_IP:$PORT:Primary_PgBouncer" "$STANDBY_IP:$PORT:Standby_PgBouncer" "$PRIMARY_IP:$PG_PORT:Primary_PostgreSQL" "$STANDBY_IP:$PG_PORT:Standby_PostgreSQL")
    
    for endpoint in "${endpoints[@]}"; do
        IFS=':' read -r ip port name <<< "$endpoint"
        echo ""
        echo -e "${YELLOW}📊 $name Network Test ($ip:$port):${NC}"
        
        # TCP connectivity
        echo -n "   TCP Connection: "
        if timeout 3 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
            echo -e "${GREEN}✅ Port $port open${NC}"
        else
            echo -e "${RED}❌ Port $port closed/filtered${NC}"
        fi
        
        # Telnet-style test
        echo -n "   Socket Test: "
        if nc -z -w3 "$ip" "$port" 2>/dev/null; then
            echo -e "${GREEN}✅ Socket connection successful${NC}"
        else
            echo -e "${RED}❌ Socket connection failed${NC}"
        fi
        
        # Response time test
        echo -n "   Response Time: "
        if response_time=$(timeout 5 bash -c "time echo '' | nc -w3 $ip $port" 2>&1 | grep real | awk '{print $2}' || echo "timeout"); then
            if [[ "$response_time" != "timeout" ]]; then
                echo -e "${GREEN}✅ $response_time${NC}"
            else
                echo -e "${RED}❌ Timeout${NC}"
            fi
        else
            echo -e "${RED}❌ No response${NC}"
        fi
    done
    
    # Firewall and routing analysis
    echo ""
    echo -e "${YELLOW}🔥 Firewall Rules Analysis:${NC}"
    gcloud compute firewall-rules list --project="$PROJECT_ID" --filter="direction:INGRESS AND allowed.ports:($PORT OR $PG_PORT)" --format="table(name,direction,priority,sourceRanges.list():label=SRC_RANGES,allowed[].map().firewall_rule().list():label=ALLOW)" 2>/dev/null || echo "No relevant firewall rules found"
}

# Generate diagnostic summary and recommendations
generate_diagnostic_summary() {
    print_section "Diagnostic Summary & Recommendations" "📋"
    
    echo -e "${CYAN}🎯 Key Findings Analysis:${NC}"
    echo ""
    
    echo -e "${YELLOW}1. Read Load Balancer Issues:${NC}"
    echo "   • Read LB FQDN routes to primary instead of standby"
    echo "   • Read LB IP connection failures"
    echo "   • Inconsistent routing behavior"
    echo ""
    
    echo -e "${YELLOW}2. Possible Root Causes:${NC}"
    echo "   • Backend service configuration may route to both instances"
    echo "   • Health checks may be passing for both primary and standby"
    echo "   • Load balancer may not distinguish between primary/standby roles"
    echo "   • Session affinity or connection pooling issues"
    echo ""
    
    echo -e "${YELLOW}3. Investigation Areas:${NC}"
    echo "   • Check if read backend service includes both instances"
    echo "   • Verify health check configuration targets correct endpoints"
    echo "   • Review load balancer backend selection algorithm"
    echo "   • Analyze PgBouncer configuration on standby node"
    echo ""
    
    echo -e "${CYAN}🔧 Recommended Actions:${NC}"
    echo ""
    echo -e "${GREEN}Immediate Actions:${NC}"
    echo "   1. Review backend service configuration"
    echo "   2. Check health check endpoints and logic"
    echo "   3. Verify instance group membership"
    echo "   4. Test direct PgBouncer connections"
    echo ""
    
    echo -e "${GREEN}Configuration Checks:${NC}"
    echo "   1. Ensure read backend service only targets standby instance"
    echo "   2. Verify health checks properly identify standby role"
    echo "   3. Check load balancer session affinity settings"
    echo "   4. Review DNS configuration for consistency"
    echo ""
    
    echo -e "${GREEN}Monitoring & Testing:${NC}"
    echo "   1. Set up continuous endpoint monitoring"
    echo "   2. Implement role-based health checks"
    echo "   3. Add load balancer routing verification"
    echo "   4. Create automated failover testing"
}

# Main execution
main() {
    print_banner
    
    get_postgres_password
    
    analyze_load_balancer_config
    analyze_backend_health
    analyze_postgresql_cluster
    analyze_load_balancer_routing
    analyze_network_connectivity
    generate_diagnostic_summary
    
    echo ""
    echo -e "${GREEN}🎯 Deep diagnostic analysis completed!${NC}"
    echo -e "${CYAN}📋 Review the findings above to identify and resolve routing issues.${NC}"
}

# Execute main function
main "$@"