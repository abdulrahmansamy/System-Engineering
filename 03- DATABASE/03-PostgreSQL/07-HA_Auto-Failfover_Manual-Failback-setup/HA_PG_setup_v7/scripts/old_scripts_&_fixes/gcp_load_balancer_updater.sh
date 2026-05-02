#!/bin/bash
# GCP Load Balancer Automatic Update Script for PostgreSQL HA
# This script automatically updates load balancer backends during failover/failback
# Version: 1.0.0

set -euo pipefail

# Configuration
PROJECT_ID="ipa-nprd-svc-db-01"
REGION="me-central2"
ZONE_A="${REGION}-a"

# PostgreSQL nodes
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PRIMARY_INSTANCE="ipa-nprd-ha-pg-primary-01"
STANDBY_INSTANCE="ipa-nprd-ha-pg-standby-01"

# Load Balancer Configuration
WRITE_LB_NAME="pg-write-lb"
READ_LB_NAME="pg-read-lb"
WRITE_BACKEND_SERVICE="pg-write-backend"
READ_BACKEND_SERVICE="pg-read-backend"
WRITE_HEALTH_CHECK="pg-write-health-check"
READ_HEALTH_CHECK="pg-read-health-check"

# Instance Groups
PRIMARY_INSTANCE_GROUP="pg-primary-ig"
STANDBY_INSTANCE_GROUP="pg-standby-ig"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }

# Get credentials from Secret Manager or use provided ones
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    # Check if we can use gcloud
    if command -v gcloud >/dev/null 2>&1 && gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q "@"; then
        # Try to get from Secret Manager (requires gcloud auth)
        info "Fetching PostgreSQL superuser password from Secret Manager..."
        
        # Add timeout to prevent hanging
        if PG_SUPER_PASS=$(timeout 10 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
            if [[ -n "$PG_SUPER_PASS" ]]; then
                export PG_SUPER_PASS
                success "Successfully fetched PostgreSQL password from Secret Manager"
            else
                warn "Secret Manager returned empty password, using default"
                export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
            fi
        else
            warn "Failed to fetch from Secret Manager (timeout or auth issue), using default password"
            export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
        fi
    else
        warn "gcloud not available or not authenticated, using default password"
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

# Check if node is PostgreSQL primary
is_primary() {
    local ip="$1"
    
    # Get password from environment or use default
    local pg_pass="${PG_SUPER_PASS:-'?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'}"
    
    local result
    result=$(timeout 5 env PGPASSWORD="$pg_pass" psql -h "$ip" -p 6432 -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    [[ "$result" == "PRIMARY" ]]
}

# Detect current primary
detect_current_primary() {
    info "Detecting current PostgreSQL primary..."
    
    if is_primary "$PRIMARY_IP"; then
        echo "$PRIMARY_IP"
        info "Current primary: $PRIMARY_IP ($PRIMARY_INSTANCE)"
    elif is_primary "$STANDBY_IP"; then
        echo "$STANDBY_IP"
        info "Current primary: $STANDBY_IP ($STANDBY_INSTANCE)"
    else
        error "Cannot determine current primary!"
        return 1
    fi
}

# Update load balancer backend service
update_backend_service() {
    local service_name="$1"
    local primary_ip="$2"
    local operation="$3"  # "failover" or "failback"
    
    info "Updating backend service: $service_name for $operation"
    
    # Determine which instance group should be primary
    local primary_ig standby_ig
    if [[ "$primary_ip" == "$PRIMARY_IP" ]]; then
        primary_ig="$PRIMARY_INSTANCE_GROUP"
        standby_ig="$STANDBY_INSTANCE_GROUP"
    else
        primary_ig="$STANDBY_INSTANCE_GROUP"
        standby_ig="$PRIMARY_INSTANCE_GROUP"
    fi
    
    # For write backend service, route to current primary
    if [[ "$service_name" == "$WRITE_BACKEND_SERVICE" ]]; then
        info "Setting write traffic to route to current primary ($primary_ip)"
        
        # Update backend service to route writes to current primary
        gcloud compute backend-services update "$service_name" \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --health-checks="$WRITE_HEALTH_CHECK" \
            --quiet || warn "Failed to update write backend service"
            
        # Remove old primary from write backend
        gcloud compute backend-services remove-backend "$service_name" \
            --instance-group="$standby_ig" \
            --instance-group-zone="$ZONE_A" \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --quiet 2>/dev/null || true
            
        # Add new primary to write backend
        gcloud compute backend-services add-backend "$service_name" \
            --instance-group="$primary_ig" \
            --instance-group-zone="$ZONE_A" \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --balancing-mode=CONNECTION \
            --max-connections=100 \
            --quiet || error "Failed to add new primary to write backend"
            
    # For read backend service, both nodes can serve reads
    elif [[ "$service_name" == "$READ_BACKEND_SERVICE" ]]; then
        info "Ensuring both nodes are available for read traffic"
        
        # Make sure both instance groups are in read backend (for load distribution)
        gcloud compute backend-services add-backend "$service_name" \
            --instance-group="$PRIMARY_INSTANCE_GROUP" \
            --instance-group-zone="$ZONE_A" \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --balancing-mode=CONNECTION \
            --max-connections=50 \
            --quiet 2>/dev/null || true
            
        gcloud compute backend-services add-backend "$service_name" \
            --instance-group="$STANDBY_INSTANCE_GROUP" \
            --instance-group-zone="$ZONE_A" \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --balancing-mode=CONNECTION \
            --max-connections=50 \
            --quiet 2>/dev/null || true
    fi
}

# Update DNS records (if using Cloud DNS)
update_dns_records() {
    local current_primary_ip="$1"
    local operation="$2"
    
    info "Updating Cloud DNS records for $operation"
    
    # DNS Zone (adjust according to your setup)
    local dns_zone="nprd-ipa-edu-sa-internal"
    local write_dns_name="pg-write.db.internal.nprd.ipa.edu.sa."
    local read_dns_name="pg-read.db.internal.nprd.ipa.edu.sa."
    
    # Update write DNS to point to current primary
    info "Updating write DNS to point to $current_primary_ip"
    gcloud dns record-sets transaction start \
        --zone="$dns_zone" \
        --project="$PROJECT_ID" || return 1
        
    # Remove old write record
    gcloud dns record-sets transaction remove \
        --zone="$dns_zone" \
        --project="$PROJECT_ID" \
        --name="$write_dns_name" \
        --type=A \
        --ttl=60 \
        "192.168.14.20" 2>/dev/null || true  # Current write LB IP
        
    # Add new write record pointing to current primary
    gcloud dns record-sets transaction add \
        --zone="$dns_zone" \
        --project="$PROJECT_ID" \
        --name="$write_dns_name" \
        --type=A \
        --ttl=60 \
        "$current_primary_ip"
        
    # Execute DNS transaction
    gcloud dns record-sets transaction execute \
        --zone="$dns_zone" \
        --project="$PROJECT_ID" || {
        gcloud dns record-sets transaction abort --zone="$dns_zone" --project="$PROJECT_ID" 2>/dev/null
        error "Failed to update DNS records"
        return 1
    }
    
    success "DNS records updated successfully"
}

# Create or update health checks
setup_health_checks() {
    info "Setting up health checks for PostgreSQL nodes..."
    
    # Write health check (only checks if node is primary)
    gcloud compute health-checks create http "$WRITE_HEALTH_CHECK" \
        --project="$PROJECT_ID" \
        --port=8001 \
        --request-path="/health" \
        --check-interval=10s \
        --timeout=5s \
        --unhealthy-threshold=2 \
        --healthy-threshold=1 \
        --description="PostgreSQL Write Health Check - Only PRIMARY nodes pass" \
        2>/dev/null || info "Write health check already exists"
    
    # Read health check (checks if PostgreSQL is responsive)
    gcloud compute health-checks create http "$READ_HEALTH_CHECK" \
        --project="$PROJECT_ID" \
        --port=8001 \
        --request-path="/health" \
        --check-interval=10s \
        --timeout=5s \
        --unhealthy-threshold=2 \
        --healthy-threshold=1 \
        --description="PostgreSQL Read Health Check - Any responsive PostgreSQL node passes" \
        2>/dev/null || info "Read health check already exists"
}

# Create instance groups
setup_instance_groups() {
    info "Setting up instance groups..."
    
    # Primary instance group
    gcloud compute instance-groups unmanaged create "$PRIMARY_INSTANCE_GROUP" \
        --zone="$ZONE_A" \
        --project="$PROJECT_ID" \
        --description="PostgreSQL Primary Instance Group" \
        2>/dev/null || info "Primary instance group already exists"
        
    gcloud compute instance-groups unmanaged add-instances "$PRIMARY_INSTANCE_GROUP" \
        --instances="$PRIMARY_INSTANCE" \
        --zone="$ZONE_A" \
        --project="$PROJECT_ID" \
        2>/dev/null || true
    
    # Standby instance group  
    gcloud compute instance-groups unmanaged create "$STANDBY_INSTANCE_GROUP" \
        --zone="$ZONE_A" \
        --project="$PROJECT_ID" \
        --description="PostgreSQL Standby Instance Group" \
        2>/dev/null || info "Standby instance group already exists"
        
    gcloud compute instance-groups unmanaged add-instances "$STANDBY_INSTANCE_GROUP" \
        --instances="$STANDBY_INSTANCE" \
        --zone="$ZONE_A" \
        --project="$PROJECT_ID" \
        2>/dev/null || true
}

# Create backend services
setup_backend_services() {
    info "Setting up backend services..."
    
    # Write backend service
    gcloud compute backend-services create "$WRITE_BACKEND_SERVICE" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --load-balancing-scheme=INTERNAL \
        --protocol=TCP \
        --health-checks-region="$REGION" \
        --health-checks="$WRITE_HEALTH_CHECK" \
        --description="PostgreSQL Write Backend Service" \
        2>/dev/null || info "Write backend service already exists"
    
    # Read backend service
    gcloud compute backend-services create "$READ_BACKEND_SERVICE" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --load-balancing-scheme=INTERNAL \
        --protocol=TCP \
        --health-checks-region="$REGION" \
        --health-checks="$READ_HEALTH_CHECK" \
        --description="PostgreSQL Read Backend Service" \
        2>/dev/null || info "Read backend service already exists"
}

# Main function to handle failover/failback
handle_failover_failback() {
    local operation="$1"  # "failover" or "failback"
    local target_primary_ip="$2"  # IP of the node that should become primary
    
    info "Handling $operation - target primary: $target_primary_ip"
    
    # Wait for PostgreSQL to be ready on new primary
    info "Waiting for PostgreSQL to be ready on $target_primary_ip..."
    local retry_count=0
    while ! is_primary "$target_primary_ip"; do
        retry_count=$((retry_count + 1))
        if [[ $retry_count -ge 30 ]]; then
            error "Timeout waiting for $target_primary_ip to become primary"
            return 1
        fi
        sleep 2
    done
    
    success "New primary is ready at $target_primary_ip"
    
    # Update load balancer
    update_backend_service "$WRITE_BACKEND_SERVICE" "$target_primary_ip" "$operation"
    update_backend_service "$READ_BACKEND_SERVICE" "$target_primary_ip" "$operation"
    
    # Update DNS (optional - comment out if not using)
    # update_dns_records "$target_primary_ip" "$operation"
    
    # Verify the changes
    sleep 10
    info "Verifying load balancer configuration..."
    
    # Test write connectivity through load balancer
    local write_lb_ip="192.168.14.20"  # Your write load balancer IP
    local pg_pass="${PG_SUPER_PASS:-'?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'}"
    
    if timeout 5 env PGPASSWORD="$pg_pass" psql -h "$write_lb_ip" -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        success "Write load balancer is routing correctly"
    else
        warn "Write load balancer may not be routing correctly yet (may take a few minutes)"
    fi
    
    success "$operation completed successfully!"
}

# Setup initial infrastructure
setup_infrastructure() {
    info "Setting up load balancer infrastructure..."
    
    setup_health_checks
    setup_instance_groups
    setup_backend_services
    
    # Initial configuration - route writes to current primary
    local current_primary
    current_primary=$(detect_current_primary)
    handle_failover_failback "initial_setup" "$current_primary"
    
    success "Infrastructure setup completed"
}

# Show current status
show_status() {
    info "Current PostgreSQL HA Status:"
    
    # Get password from environment or use default
    local pg_pass="${PG_SUPER_PASS:-'?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'}"
    
    # Check node roles
    local primary_role standby_role
    primary_role=$(timeout 5 env PGPASSWORD="$pg_pass" psql -h "$PRIMARY_IP" -p 6432 -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    standby_role=$(timeout 5 env PGPASSWORD="$pg_pass" psql -h "$STANDBY_IP" -p 6432 -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    
    info "  • $PRIMARY_IP ($PRIMARY_INSTANCE): $primary_role"
    info "  • $STANDBY_IP ($STANDBY_INSTANCE): $standby_role"
    
    # Check backend services
    info "Load Balancer Backend Services:"
    gcloud compute backend-services describe "$WRITE_BACKEND_SERVICE" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="table(name,backends[].group:label=BACKEND_GROUP)" 2>/dev/null || warn "Cannot get write backend status"
        
    gcloud compute backend-services describe "$READ_BACKEND_SERVICE" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="table(name,backends[].group:label=BACKEND_GROUP)" 2>/dev/null || warn "Cannot get read backend status"
}

# Main menu
case "${1:-}" in
    "setup")
        setup_infrastructure
        ;;
    "failover")
        target_primary="${2:-$STANDBY_IP}"
        handle_failover_failback "failover" "$target_primary"
        ;;
    "failback")
        target_primary="${2:-$PRIMARY_IP}"
        handle_failover_failback "failback" "$target_primary"
        ;;
    "status")
        show_status
        ;;
    "detect")
        detect_current_primary
        ;;
    *)
        echo "Usage: $0 {setup|failover|failback|status|detect} [target_primary_ip]"
        echo ""
        echo "Commands:"
        echo "  setup                   - Setup load balancer infrastructure"
        echo "  failover [ip]           - Handle failover to specified IP (default: $STANDBY_IP)"
        echo "  failback [ip]           - Handle failback to specified IP (default: $PRIMARY_IP)"
        echo "  status                  - Show current cluster and load balancer status"
        echo "  detect                  - Detect current primary node"
        echo ""
        echo "Examples:"
        echo "  $0 setup"
        echo "  $0 failover $STANDBY_IP"
        echo "  $0 failback $PRIMARY_IP"
        echo "  $0 status"
        exit 1
        ;;
esac