#!/bin/bash
# Get Actual Load Balancer Configuration from Terraform/GCP
# This script discovers the real load balancer IPs and configuration

echo "🔍 Discovering Load Balancer Configuration..."
echo "============================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PROJECT_ID="ipa-nprd-svc-db-01"
REGION="me-central2"
ORG_CODE="ipa"
ENV_CODE="nprd"

echo ""
echo -e "${BLUE}📋 Project Configuration:${NC}"
echo "   Project ID: $PROJECT_ID"
echo "   Region: $REGION"
echo "   Environment: $ENV_CODE"
echo ""

# Function to run gcloud commands with error handling
run_gcloud() {
    local cmd="$1"
    local description="$2"
    
    echo -n "   $description... "
    if result=$(eval "$cmd" 2>/dev/null); then
        echo -e "${GREEN}✅${NC}"
        echo "$result"
    else
        echo -e "${RED}❌ Failed${NC}"
        return 1
    fi
}

# 1. Get Load Balancer IPs from reserved addresses
echo -e "${YELLOW}🔗 Load Balancer Reserved IP Addresses:${NC}"
echo "   ======================================"

# Based on your load_balancer.tf naming convention
WRITE_IP_NAME="${ORG_CODE}-${ENV_CODE}-ip-pgbouncer-write-01"
READ_IP_NAME="${ORG_CODE}-${ENV_CODE}-ip-pgbouncer-read-02"

echo "   Searching for:"
echo "     Write IP name: $WRITE_IP_NAME"
echo "     Read IP name:  $READ_IP_NAME"
echo ""

WRITE_IP=$(gcloud compute addresses describe "$WRITE_IP_NAME" --region="$REGION" --project="$PROJECT_ID" --format="value(address)" 2>/dev/null || echo "")
READ_IP=$(gcloud compute addresses describe "$READ_IP_NAME" --region="$REGION" --project="$PROJECT_ID" --format="value(address)" 2>/dev/null || echo "")

if [[ -n "$WRITE_IP" ]]; then
    echo -e "   Write LB IP:  ${GREEN}$WRITE_IP${NC}"
else
    echo -e "   Write LB IP:  ${RED}Not found${NC}"
fi

if [[ -n "$READ_IP" ]]; then
    echo -e "   Read LB IP:   ${GREEN}$READ_IP${NC}"
else
    echo -e "   Read LB IP:   ${RED}Not found${NC}"
fi

echo ""

# 2. Get Backend Instance IPs
echo -e "${YELLOW}🖥️  Backend Instance Information:${NC}"
echo "   ==============================="

PRIMARY_NAME="${ORG_CODE}-${ENV_CODE}-ha-pg-primary-01"
STANDBY_NAME="${ORG_CODE}-${ENV_CODE}-ha-pg-standby-01"

PRIMARY_IP=$(gcloud compute instances describe "$PRIMARY_NAME" --zone="me-central2-a" --project="$PROJECT_ID" --format="value(networkInterfaces[0].networkIP)" 2>/dev/null || echo "")
STANDBY_IP=$(gcloud compute instances describe "$STANDBY_NAME" --zone="me-central2-b" --project="$PROJECT_ID" --format="value(networkInterfaces[0].networkIP)" 2>/dev/null || echo "")

if [[ -n "$PRIMARY_IP" ]]; then
    echo -e "   Primary Node: ${GREEN}$PRIMARY_IP${NC} ($PRIMARY_NAME)"
else
    echo -e "   Primary Node: ${RED}Not found${NC} ($PRIMARY_NAME)"
fi

if [[ -n "$STANDBY_IP" ]]; then
    echo -e "   Standby Node: ${GREEN}$STANDBY_IP${NC} ($STANDBY_NAME)"
else
    echo -e "   Standby Node: ${RED}Not found${NC} ($STANDBY_NAME)"
fi

echo ""

# 3. Check Load Balancer Services
echo -e "${YELLOW}⚖️  Load Balancer Services:${NC}"
echo "   ========================="

# Backend services
BS_WRITE_NAME="${ORG_CODE}-${ENV_CODE}-bs-pgbouncer-write-01"
BS_READ_NAME="${ORG_CODE}-${ENV_CODE}-bs-pgbouncer-read-01"

echo "   Checking backend services:"
echo "     Write service: $BS_WRITE_NAME"
echo "     Read service:  $BS_READ_NAME"

# Check if backend services exist
if gcloud compute backend-services describe "$BS_WRITE_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo -e "   Write Backend Service: ${GREEN}✅ Exists${NC}"
    
    # Get backend health
    echo "     Backend health:"
    gcloud compute backend-services get-health "$BS_WRITE_NAME" --region="$REGION" --project="$PROJECT_ID" 2>/dev/null | grep -E "(instance|healthState)" | sed 's/^/       /' || echo "       Unable to get health status"
else
    echo -e "   Write Backend Service: ${RED}❌ Not found${NC}"
fi

if gcloud compute backend-services describe "$BS_READ_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo -e "   Read Backend Service:  ${GREEN}✅ Exists${NC}"
    
    # Get backend health
    echo "     Backend health:"
    gcloud compute backend-services get-health "$BS_READ_NAME" --region="$REGION" --project="$PROJECT_ID" 2>/dev/null | grep -E "(instance|healthState)" | sed 's/^/       /' || echo "       Unable to get health status"
else
    echo -e "   Read Backend Service:  ${RED}❌ Not found${NC}"
fi

echo ""

# 4. Check Forwarding Rules
echo -e "${YELLOW}🚀 Forwarding Rules:${NC}"
echo "   =================="

FR_WRITE_NAME="${ORG_CODE}-${ENV_CODE}-fr-pgbouncer-write-01"
FR_READ_NAME="${ORG_CODE}-${ENV_CODE}-fr-pgbouncer-read-01"

if gcloud compute forwarding-rules describe "$FR_WRITE_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo -e "   Write Forwarding Rule: ${GREEN}✅ Active${NC}"
else
    echo -e "   Write Forwarding Rule: ${RED}❌ Not found${NC}"
fi

if gcloud compute forwarding-rules describe "$FR_READ_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo -e "   Read Forwarding Rule:  ${GREEN}✅ Active${NC}"
else
    echo -e "   Read Forwarding Rule:  ${RED}❌ Not found${NC}"
fi

echo ""

# 5. DNS Zone Check
echo -e "${YELLOW}🌐 DNS Configuration:${NC}"
echo "   ==================="

DNS_ZONE_NAME="${ORG_CODE}-${ENV_CODE}-dns-zone-ha-pg"
INTERNAL_DOMAIN="db.internal.${ENV_CODE}.ipa.edu.sa"

if gcloud dns managed-zones describe "$DNS_ZONE_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo -e "   DNS Zone: ${GREEN}✅ Exists${NC} ($DNS_ZONE_NAME)"
    echo "   Domain: $INTERNAL_DOMAIN"
    
    # Check DNS records
    echo "   DNS Records:"
    gcloud dns record-sets list --zone="$DNS_ZONE_NAME" --project="$PROJECT_ID" --format="table(name,type,rrdatas)" 2>/dev/null | grep -E "(pg-write|pg-read)" | sed 's/^/     /' || echo "     No LB DNS records found"
else
    echo -e "   DNS Zone: ${RED}❌ Not configured${NC}"
fi

echo ""

# 6. Generate Test Commands
echo -e "${BLUE}🧪 Test Commands:${NC}"
echo -e "${BLUE}=================${NC}"

if [[ -n "$WRITE_IP" && -n "$READ_IP" && -n "$PRIMARY_IP" && -n "$STANDBY_IP" ]]; then
    cat << EOF

# Test load balancer endpoints:
psql -h $WRITE_IP -p 6432 -U postgres -d postgres -c "SELECT 'Write LB', pg_is_in_recovery();"
psql -h $READ_IP -p 6432 -U postgres -d postgres -c "SELECT 'Read LB', pg_is_in_recovery();"

# Test direct backend connections:
psql -h $PRIMARY_IP -p 6432 -U postgres -d postgres -c "SELECT 'Primary Direct', pg_is_in_recovery();"
psql -h $STANDBY_IP -p 6432 -U postgres -d postgres -c "SELECT 'Standby Direct', pg_is_in_recovery();"

# Test replication through load balancer:
psql -h $WRITE_IP -p 6432 -U postgres -d postgres -c "CREATE TABLE IF NOT EXISTS lb_test (id SERIAL, msg TEXT, ts TIMESTAMP DEFAULT NOW()); INSERT INTO lb_test (msg) VALUES ('Test via Write LB');"
sleep 3
psql -h $READ_IP -p 6432 -U postgres -d postgres -c "SELECT * FROM lb_test ORDER BY ts DESC LIMIT 3;"

# Health endpoints:
curl -s http://$PRIMARY_IP:8001 | jq
curl -s http://$STANDBY_IP:8001 | jq
curl -s http://$PRIMARY_IP:8002 | jq
curl -s http://$STANDBY_IP:8002 | jq

# Connection strings for applications:
Write: postgresql://postgres:password@$WRITE_IP:6432/postgres
Read:  postgresql://postgres:password@$READ_IP:6432/postgres

EOF

    # Save configuration to file
    cat > lb_config.env << EOF
# Load Balancer Configuration
WRITE_IP=$WRITE_IP
READ_IP=$READ_IP
PRIMARY_IP=$PRIMARY_IP
STANDBY_IP=$STANDBY_IP
PGBOUNCER_PORT=6432
WRITE_FQDN=pg-write.$INTERNAL_DOMAIN
READ_FQDN=pg-read.$INTERNAL_DOMAIN
EOF

    echo -e "${GREEN}💾 Configuration saved to: lb_config.env${NC}"
else
    echo -e "${RED}❌ Unable to generate test commands - missing configuration${NC}"
    echo "   This might mean the load balancer isn't fully deployed yet."
fi

echo ""
echo -e "${GREEN}🎯 Discovery completed!${NC}"