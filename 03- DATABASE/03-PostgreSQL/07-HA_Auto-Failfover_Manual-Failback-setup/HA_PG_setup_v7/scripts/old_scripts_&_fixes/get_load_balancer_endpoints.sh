#!/bin/bash
# Get Load Balancer Endpoints from Terraform
# Retrieves the actual IP addresses and FQDNs for validation

echo "🔍 Retrieving Load Balancer Endpoints from Terraform..."
echo "======================================================"

# Check if terraform is available
if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ ERROR: Terraform not found. Please install Terraform."
    exit 1
fi

# Check if terraform state exists
if [[ ! -f "terraform.tfstate" ]]; then
    echo "❌ ERROR: terraform.tfstate not found. Please run 'terraform apply' first."
    exit 1
fi

echo ""
echo "📋 Load Balancer Configuration:"
echo "------------------------------"

# Get outputs from terraform
echo "Retrieving Terraform outputs..."

# Write endpoint information (based on your load_balancer.tf outputs)
WRITE_IP=$(terraform output -json pgbouncer_write_endpoint 2>/dev/null | jq -r '.ip_address' || echo "Not found")
WRITE_FQDN=$(terraform output -json pgbouncer_write_endpoint 2>/dev/null | jq -r '.dns_name' || echo "Not found")

# Read endpoint information  
READ_IP=$(terraform output -json pgbouncer_read_endpoint 2>/dev/null | jq -r '.ip_address' || echo "Not found")
READ_FQDN=$(terraform output -json pgbouncer_read_endpoint 2>/dev/null | jq -r '.dns_name' || echo "Not found")

# Display results
echo ""
echo "✅ Write Endpoint (Primary):"
echo "   FQDN: $WRITE_FQDN"
echo "   IP:   $WRITE_IP"
echo ""
echo "✅ Read Endpoint (Standby):"
echo "   FQDN: $READ_FQDN"
echo "   IP:   $READ_IP"

# Check if we got valid results
if [[ "$WRITE_IP" == "Not found" ]] || [[ "$READ_IP" == "Not found" ]]; then
    echo ""
    echo "⚠️  WARNING: Some outputs not found. Available outputs:"
    terraform output 2>/dev/null | head -10
    
    echo ""
    echo "💡 Manual IP Discovery:"
    echo "   1. Check GCP Console > Network Services > Load Balancing"
    echo "   2. Look for load balancers with names containing 'pgbouncer'"
    echo "   3. Use 'gcloud compute addresses list' to find reserved IPs"
    echo ""
fi

# Generate environment-specific validation commands
echo ""
echo "🚀 Ready-to-Use Validation Commands:"
echo "===================================="

cat << EOF

# 1. Test DNS Resolution
nslookup $WRITE_FQDN
nslookup $READ_FQDN

# 2. Test Network Connectivity
nc -zv $WRITE_FQDN 6432
nc -zv $READ_FQDN 6432
nc -zv $WRITE_IP 6432
nc -zv $READ_IP 6432

# 3. Test Database Connections
# Write endpoint (should connect to primary)
psql -h $WRITE_FQDN -p 6432 -U postgres -d postgres -c "SELECT 'Write Endpoint', current_timestamp, CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role;"

# Read endpoint (should connect to standby)
psql -h $READ_FQDN -p 6432 -U postgres -d postgres -c "SELECT 'Read Endpoint', current_timestamp, CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role;"

# 4. Replication Test
# Insert on write endpoint
psql -h $WRITE_FQDN -p 6432 -U postgres -d postgres -c "
CREATE TABLE IF NOT EXISTS lb_test (id SERIAL, message TEXT, created_at TIMESTAMP DEFAULT NOW());
INSERT INTO lb_test (message) VALUES ('LB test at ' || NOW());
SELECT * FROM lb_test ORDER BY created_at DESC LIMIT 3;"

# Wait and check on read endpoint
sleep 5
psql -h $READ_FQDN -p 6432 -U postgres -d postgres -c "
SELECT * FROM lb_test ORDER BY created_at DESC LIMIT 3;"

# 5. Health Endpoints
curl -s http://192.168.14.21:8001 | jq
curl -s http://192.168.14.22:8001 | jq
curl -s http://192.168.14.21:8002 | jq
curl -s http://192.168.14.22:8002 | jq

# 6. Connection Strings for Applications
Write: postgresql://postgres:password@$WRITE_FQDN:6432/postgres
Read:  postgresql://postgres:password@$READ_FQDN:6432/postgres

EOF

# Save configuration to file for easy reference
cat << EOF > load_balancer_config.txt
# PostgreSQL HA Load Balancer Configuration
# Generated: $(date)

WRITE_FQDN=$WRITE_FQDN
WRITE_IP=$WRITE_IP
READ_FQDN=$READ_FQDN  
READ_IP=$READ_IP
PGBOUNCER_PORT=6432
POSTGRES_PORT=5432

# Application Connection Strings
WRITE_CONNECTION=postgresql://postgres:password@$WRITE_FQDN:6432/postgres
READ_CONNECTION=postgresql://postgres:password@$READ_FQDN:6432/postgres

# Health Check URLs
PRIMARY_PG_HEALTH=http://192.168.14.21:8001
STANDBY_PG_HEALTH=http://192.168.14.22:8001
PRIMARY_PGB_HEALTH=http://192.168.14.21:8002
STANDBY_PGB_HEALTH=http://192.168.14.22:8002
EOF

echo ""
echo "💾 Configuration saved to: load_balancer_config.txt"
echo ""
echo "🎯 Next Steps:"
echo "   1. Run the validation commands above"
echo "   2. Use './validate_load_balancer_replication.sh' for automated testing"
echo "   3. Configure your applications with the connection strings"
echo ""