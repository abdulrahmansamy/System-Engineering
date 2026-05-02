#!/bin/bash
# PostgreSQL HA + PgBouncer + GCP Load Balancer Deployment Script
# Complete implementation for your existing infrastructure

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
guide() { echo -e "${BLUE}[GUIDE]${NC} $*"; }

echo "=========================================="
echo "PostgreSQL HA Complete Deployment"
echo "Phase 2: PgBouncer + Load Balancer"
echo "=========================================="
echo ""

# Check if we're in the right directory
if [[ ! -f "terraform.tfvars" ]]; then
    error "Please run this script from your Terraform directory containing terraform.tfvars"
    exit 1
fi

# Get current workspace/environment
current_workspace=$(terraform workspace show 2>/dev/null || echo "default")
info "Current Terraform workspace: $current_workspace"

# Function to deploy PgBouncer on both nodes
deploy_pgbouncer() {
    guide "Step 1: Deploying PgBouncer on both PostgreSQL nodes"
    echo ""
    
    # Get instance IPs from Terraform output
    info "Getting instance information from Terraform..."
    
    if ! terraform output > /dev/null 2>&1; then
        error "Cannot get Terraform outputs. Make sure your infrastructure is deployed."
        exit 1
    fi
    
    PRIMARY_IP=$(terraform output -raw primary_internal_ip 2>/dev/null || echo "")
    STANDBY_IP=$(terraform output -raw standby_internal_ip 2>/dev/null || echo "")
    
    if [[ -z "$PRIMARY_IP" || -z "$STANDBY_IP" ]]; then
        error "Cannot determine instance IPs. Please check your Terraform outputs."
        echo "Available outputs:"
        terraform output
        exit 1
    fi
    
    info "Primary IP: $PRIMARY_IP"
    info "Standby IP: $STANDBY_IP"
    echo ""
    
    # Deploy PgBouncer scripts to instances
    info "Deploying PgBouncer setup script to instances..."
    
    # Copy setup script to both instances
    gcloud compute scp scripts/setup_pgbouncer.sh root@ipa-nprd-ha-pg-primary-01:/tmp/ --zone=me-central2-a || {
        error "Failed to copy setup script to primary. Make sure you have SSH access."
        exit 1
    }
    
    gcloud compute scp scripts/setup_pgbouncer.sh root@ipa-nprd-ha-pg-standby-01:/tmp/ --zone=me-central2-b || {
        error "Failed to copy setup script to standby. Make sure you have SSH access."
        exit 1
    }
    
    # Execute on primary
    info "Installing PgBouncer on primary node..."
    gcloud compute ssh root@ipa-nprd-ha-pg-primary-01 --zone=me-central2-a --command="cd /tmp && chmod +x setup_pgbouncer.sh && ./setup_pgbouncer.sh" || {
        error "Failed to install PgBouncer on primary"
        exit 1
    }
    
    # Execute on standby  
    info "Installing PgBouncer on standby node..."
    gcloud compute ssh root@ipa-nprd-ha-pg-standby-01 --zone=me-central2-b --command="cd /tmp && chmod +x setup_pgbouncer.sh && ./setup_pgbouncer.sh" || {
        error "Failed to install PgBouncer on standby"
        exit 1
    }
    
    info "✅ PgBouncer deployed successfully on both nodes"
}

# Function to deploy load balancer infrastructure
deploy_load_balancer() {
    guide "Step 2: Deploying GCP Internal Load Balancer"
    echo ""
    
    info "Planning Terraform changes for load balancer..."
    if ! terraform plan -target=google_compute_health_check.pgbouncer_health_check \
                      -target=google_compute_region_backend_service.pgbouncer_write \
                      -target=google_compute_region_backend_service.pgbouncer_read \
                      -target=google_compute_instance_group.pg_primary_group \
                      -target=google_compute_instance_group.pg_standby_group \
                      -target=google_compute_forwarding_rule.pgbouncer_write \
                      -target=google_compute_forwarding_rule.pgbouncer_read \
                      -target=google_compute_address.pgbouncer_write_ip \
                      -target=google_compute_address.pgbouncer_read_ip \
                      -target=google_compute_firewall.pgbouncer_access \
                      -target=google_compute_firewall.pgbouncer_health_check; then
        error "Terraform plan failed. Please check your configuration."
        exit 1
    fi
    
    echo ""
    read -p "Do you want to apply these changes? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "Applying Terraform changes..."
        if terraform apply -target=google_compute_health_check.pgbouncer_health_check \
                          -target=google_compute_region_backend_service.pgbouncer_write \
                          -target=google_compute_region_backend_service.pgbouncer_read \
                          -target=google_compute_instance_group.pg_primary_group \
                          -target=google_compute_instance_group.pg_standby_group \
                          -target=google_compute_forwarding_rule.pgbouncer_write \
                          -target=google_compute_forwarding_rule.pgbouncer_read \
                          -target=google_compute_address.pgbouncer_write_ip \
                          -target=google_compute_address.pgbouncer_read_ip \
                          -target=google_compute_firewall.pgbouncer_access \
                          -target=google_compute_firewall.pgbouncer_health_check \
                          -auto-approve; then
            info "✅ Load balancer infrastructure deployed successfully"
        else
            error "Terraform apply failed"
            exit 1
        fi
    else
        warn "Deployment cancelled by user"
        exit 0
    fi
}

# Function to validate the complete setup
validate_setup() {
    guide "Step 3: Validating complete setup"
    echo ""
    
    info "Getting load balancer endpoints..."
    
    WRITE_ENDPOINT=$(terraform output -json pgbouncer_write_endpoint | jq -r '.ip_address' 2>/dev/null || echo "")
    READ_ENDPOINT=$(terraform output -json pgbouncer_read_endpoint | jq -r '.ip_address' 2>/dev/null || echo "")
    
    if [[ -n "$WRITE_ENDPOINT" && -n "$READ_ENDPOINT" ]]; then
        info "Write endpoint: $WRITE_ENDPOINT:6432"
        info "Read endpoint: $READ_ENDPOINT:6432"
        echo ""
        
        # Test direct PgBouncer connections
        info "Testing direct PgBouncer connections..."
        
        # Test primary PgBouncer
        if gcloud compute ssh root@ipa-nprd-ha-pg-primary-01 --zone=me-central2-a --command="timeout 5 bash -c '</dev/tcp/localhost/6432'" 2>/dev/null; then
            info "✅ Primary PgBouncer is accepting connections"
        else
            warn "⚠ Primary PgBouncer connection test failed"
        fi
        
        # Test standby PgBouncer
        if gcloud compute ssh root@ipa-nprd-ha-pg-standby-01 --zone=me-central2-b --command="timeout 5 bash -c '</dev/tcp/localhost/6432'" 2>/dev/null; then
            info "✅ Standby PgBouncer is accepting connections"
        else
            warn "⚠ Standby PgBouncer connection test failed"
        fi
        
        # Test health endpoints
        info "Testing health endpoints..."
        
        if gcloud compute ssh root@ipa-nprd-ha-pg-primary-01 --zone=me-central2-a --command="curl -s http://localhost:8002" 2>/dev/null | grep -q "healthy" 2>/dev/null; then
            info "✅ Primary health endpoint is responding"
        else
            warn "⚠ Primary health endpoint test failed"
        fi
        
        if gcloud compute ssh root@ipa-nprd-ha-pg-standby-01 --zone=me-central2-b --command="curl -s http://localhost:8002" 2>/dev/null | grep -q "healthy" 2>/dev/null; then
            info "✅ Standby health endpoint is responding"
        else
            warn "⚠ Standby health endpoint test failed"
        fi
        
    else
        error "Could not get load balancer endpoints from Terraform output"
        exit 1
    fi
}

# Function to show connection examples
show_connection_examples() {
    guide "Step 4: Connection Examples for Applications"
    echo ""
    
    WRITE_ENDPOINT=$(terraform output -json pgbouncer_write_endpoint | jq -r '.ip_address' 2>/dev/null || echo "unknown")
    READ_ENDPOINT=$(terraform output -json pgbouncer_read_endpoint | jq -r '.ip_address' 2>/dev/null || echo "unknown")
    
    info "Connection strings for your applications:"
    echo ""
    
    echo "📝 Write Operations (Primary only):"
    echo "postgresql://username:password@${WRITE_ENDPOINT}:6432/database_name"
    echo ""
    
    echo "📖 Read Operations (Load balanced):"
    echo "postgresql://username:password@${READ_ENDPOINT}:6432/database_name"
    echo ""
    
    info "Application code examples:"
    echo ""
    
    echo "Python (psycopg2):"
    cat << EOF
import psycopg2

# Connection pools
write_dsn = "postgresql://username:password@${WRITE_ENDPOINT}:6432/myapp"
read_dsn = "postgresql://username:password@${READ_ENDPOINT}:6432/myapp"

# Write operation
write_conn = psycopg2.connect(write_dsn)
cursor = write_conn.cursor()
cursor.execute("INSERT INTO users (name) VALUES (%s)", ('John Doe',))
write_conn.commit()
write_conn.close()

# Read operation  
read_conn = psycopg2.connect(read_dsn)
cursor = read_conn.cursor()
cursor.execute("SELECT * FROM users")
results = cursor.fetchall()
read_conn.close()
EOF
    
    echo ""
    echo "Java (Spring Boot application.properties):"
    cat << EOF
# Write datasource
spring.datasource.write.url=jdbc:postgresql://${WRITE_ENDPOINT}:6432/myapp
spring.datasource.write.username=username
spring.datasource.write.password=password

# Read datasource
spring.datasource.read.url=jdbc:postgresql://${READ_ENDPOINT}:6432/myapp
spring.datasource.read.username=username
spring.datasource.read.password=password
EOF
    
    echo ""
    echo "Node.js:"
    cat << EOF
const { Pool } = require('pg');

const writePool = new Pool({
  connectionString: 'postgresql://username:password@${WRITE_ENDPOINT}:6432/myapp',
  max: 20
});

const readPool = new Pool({
  connectionString: 'postgresql://username:password@${READ_ENDPOINT}:6432/myapp', 
  max: 50
});
EOF
}

# Function to show monitoring and next steps
show_next_steps() {
    guide "Step 5: Monitoring and Next Steps"
    echo ""
    
    info "Monitoring your setup:"
    echo ""
    echo "1. Check GCP Load Balancer health:"
    echo "   - Go to: Cloud Console > Network services > Load balancing"
    echo "   - View health status of backend services"
    echo ""
    
    echo "2. Monitor PgBouncer statistics:"
    echo "   - Connect to PgBouncer admin: psql -h <host> -p 6432 -U pgbouncer_admin -d pgbouncer"
    echo "   - Run: SHOW STATS; SHOW POOLS; SHOW CLIENTS;"
    echo ""
    
    echo "3. PostgreSQL replication monitoring:"
    echo "   - Use existing health endpoints: http://<host>:8001"
    echo "   - Check replication lag with: validate_local_node.sh"
    echo ""
    
    info "Performance tuning:"
    echo ""
    echo "1. Adjust PgBouncer pool sizes based on application needs"
    echo "2. Monitor connection usage and tune pool_size parameters"
    echo "3. Consider read/write ratio for capacity_scaler values"
    echo ""
    
    info "Backup and disaster recovery:"
    echo ""
    echo "1. Test manual failover scenarios"
    echo "2. Verify application reconnection behavior"  
    echo "3. Document failover procedures"
    echo ""
    
    info "Security hardening:"
    echo ""
    echo "1. Review firewall rules and restrict access"
    echo "2. Enable SSL/TLS for client connections"
    echo "3. Rotate passwords regularly"
}

# Main execution
main() {
    info "Starting PostgreSQL HA Phase 2 deployment..."
    echo ""
    
    # Check prerequisites
    if ! command -v terraform >/dev/null 2>&1; then
        error "Terraform is not installed"
        exit 1
    fi
    
    if ! command -v gcloud >/dev/null 2>&1; then
        error "Google Cloud CLI is not installed"
        exit 1
    fi
    
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1 >/dev/null 2>&1; then
        error "Please authenticate with Google Cloud: gcloud auth login"
        exit 1
    fi
    
    # Check if PgBouncer script exists
    if [[ ! -f "scripts/setup_pgbouncer.sh" ]]; then
        error "PgBouncer setup script not found. Please ensure scripts/setup_pgbouncer.sh exists."
        exit 1
    fi
    
    # Execute deployment steps
    deploy_pgbouncer
    echo ""
    
    deploy_load_balancer
    echo ""
    
    validate_setup
    echo ""
    
    show_connection_examples
    echo ""
    
    show_next_steps
    
    echo ""
    echo "=========================================="
    info "🎉 PostgreSQL HA deployment completed successfully!"
    echo "=========================================="
    echo ""
    echo "Your cluster now includes:"
    echo "✅ PostgreSQL streaming replication"
    echo "✅ Automatic failover (repmgr)"
    echo "✅ Connection pooling (PgBouncer)"
    echo "✅ Load balancing (GCP Internal LB)"
    echo "✅ Health monitoring"
    echo "✅ Read/write splitting capability"
    echo ""
    echo "Ready for production workloads! 🚀"
}

# Help function
show_help() {
    echo "PostgreSQL HA Complete Deployment Script"
    echo ""
    echo "This script deploys PgBouncer and GCP Internal Load Balancer"
    echo "for your existing PostgreSQL HA cluster."
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Prerequisites:"
    echo "• Existing PostgreSQL HA cluster (deployed via Terraform)"
    echo "• Terraform and gcloud CLI installed and configured"
    echo "• SSH access to PostgreSQL instances"
    echo "• scripts/setup_pgbouncer.sh script available"
    echo ""
    echo "The script will:"
    echo "1. Deploy PgBouncer on both PostgreSQL nodes"
    echo "2. Create GCP Internal Load Balancer infrastructure"
    echo "3. Configure health checks and firewall rules"
    echo "4. Validate the complete setup"
    echo "5. Show connection examples for applications"
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac