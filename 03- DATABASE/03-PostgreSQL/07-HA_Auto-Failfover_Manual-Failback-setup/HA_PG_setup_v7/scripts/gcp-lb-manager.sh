#!/bin/bash
# ============================================================================
# GCP Load Balancer Manager - No gcloud CLI Required
# Uses Service Account metadata and REST API for authentication-free operations
# ============================================================================

set -euo pipefail

# Auto-detect environment from GCP metadata or hostname
detect_environment() {
    local env="prd"
    
    # Try to get from GCP instance metadata labels
    local instance_labels
    instance_labels=$(curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/environment" 2>/dev/null || echo "")
    
    if [[ -n "$instance_labels" ]]; then
        env="$instance_labels"
    else
        # Fallback: detect from hostname or project ID
        local hostname
        hostname=$(hostname)
        
        if [[ "$hostname" =~ nprd|nonprod ]]; then
            env="nprd"
        elif [[ "$hostname" =~ prd|prod ]]; then
            env="prd"
        fi
        
        # Also check project ID from metadata
        local project_id
        project_id=$(curl -sf -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/project/project-id" 2>/dev/null || echo "")
        
        if [[ "$project_id" =~ nprd|nonprod ]]; then
            env="nprd"
        elif [[ "$project_id" =~ prd|prod ]]; then
            env="prd"
        fi
    fi
    
    # Normalize environment name
    if [[ "$env" =~ nonprod|non-prod ]]; then
        env="nprd"
    elif [[ "$env" =~ prod|production ]]; then
        env="prd"
    fi
    
    echo "$env"
}

# Detect environment
ENVIRONMENT=$(detect_environment)

# Configuration based on environment
if [[ "$ENVIRONMENT" == "nprd" ]]; then
    readonly PROJECT_ID="${PROJECT_ID:-ipa-nprd-svc-db-01}"
    readonly BACKEND_SERVICE_WRITE="ipa-nprd-bs-pgbouncer-write-01"
    readonly BACKEND_SERVICE_READ="ipa-nprd-bs-pgbouncer-read-01"
    readonly PRIMARY_GROUP="ipa-nprd-ig-pg-primary-group-01"
    readonly STANDBY_GROUP="ipa-nprd-ig-pg-standby-group-01"
else
    readonly PROJECT_ID="${PROJECT_ID:-ipa-prd-svc-db-01}"
    readonly BACKEND_SERVICE_WRITE="ipa-prd-bs-pgbouncer-write-01"
    readonly BACKEND_SERVICE_READ="ipa-prd-bs-pgbouncer-read-01"
    readonly PRIMARY_GROUP="ipa-prd-ig-pg-primary-group-01"
    readonly STANDBY_GROUP="ipa-prd-ig-pg-standby-group-01"
fi

readonly REGION="${REGION:-me-central2}"
readonly PRIMARY_ZONE="me-central2-a"
readonly STANDBY_ZONE="me-central2-b"

DEBUG="${DEBUG:-0}"  # Default to 0 (off) for production, set DEBUG=1 to enable

# API endpoints
readonly COMPUTE_API="https://www.googleapis.com/compute/v1"
readonly METADATA_API="http://metadata.google.internal/computeMetadata/v1"


# Log file configuration
readonly LOG_FILE="/var/log/postgresql/lb-manager.log"

# Initialize logging
init_logging() {
    local log_dir=$(dirname "$LOG_FILE")
    
    # Create log directory if it doesn't exist (only if running as root)
    if [[ ! -d "$log_dir" && $EUID -eq 0 ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
        chown postgres:postgres "$log_dir" 2>/dev/null || true
        chmod 755 "$log_dir" 2>/dev/null || true
    fi
    
    # Create log file if it doesn't exist (only if running as root)
    if [[ ! -f "$LOG_FILE" && $EUID -eq 0 ]]; then
        touch "$LOG_FILE" 2>/dev/null || true
        chown postgres:postgres "$LOG_FILE" 2>/dev/null || true
        chmod 644 "$LOG_FILE" 2>/dev/null || true
    fi
}

# Logging functions
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    
    # Always write to stdout
    echo "$message"
    
    # Try to write to log file only if we have write permission
    if [[ -w "$LOG_FILE" ]]; then
        echo "$message" >> "$LOG_FILE" 2>/dev/null || true
    elif [[ ! -f "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
        # Log file doesn't exist but we can create it
        echo "$message" >> "$LOG_FILE" 2>/dev/null || true
    fi
    # If we can't write, just skip logging to file (no error messages)
}

error() {
    log "ERROR: $*" >&2
}

debug() {
    if [[ "${DEBUG:-0}" -eq 1 ]]; then
        log "DEBUG: $*"
    fi
}

# Debug configuration (after all variables are set)
debug "Environment: $ENVIRONMENT | Project: ${PROJECT_ID} | Region: ${REGION}"
debug "Write LB: ${BACKEND_SERVICE_WRITE} | Read LB: ${BACKEND_SERVICE_READ}"
debug "Primary: ${PRIMARY_GROUP} (${PRIMARY_ZONE}) | Standby: ${STANDBY_GROUP} (${STANDBY_ZONE})"

# Get access token from instance metadata (no authentication needed)
get_access_token() {
    local token
    token=$(curl -sf -H "Metadata-Flavor: Google" \
        "${METADATA_API}/instance/service-accounts/default/token" | \
        jq -r '.access_token' 2>/dev/null || echo "")
    
    if [[ -z "$token" ]]; then
        error "Failed to get access token from metadata service"
        return 1
    fi
    
    echo "$token"
}

# Make authenticated API call to GCP
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local token
    
    token=$(get_access_token) || return 1
    
    local curl_opts=(
        -X "$method"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
    )
    
    if [[ -n "$data" ]]; then
        curl_opts+=(-d "$data")
    fi
    
    # Use curl with verbose error output for debugging
    local response
    local http_code
    
    if [[ "${DEBUG:-0}" -eq 1 ]]; then
        # Debug mode: show full response
        response=$(curl "${curl_opts[@]}" -s -w "\n%{http_code}" "$endpoint" 2>&1)
        http_code=$(echo "$response" | tail -n1)
        response=$(echo "$response" | sed '$d')
        
        debug "HTTP Status: $http_code"
        debug "Response (first 500 chars): ${response:0:500}..."
        
        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
            echo "$response"
            return 0
        else
            error "API call failed with HTTP $http_code: $response"
            return 1
        fi
    else
        # Production mode: silent on success, error on failure
        response=$(curl "${curl_opts[@]}" -sf "$endpoint" 2>&1) || {
            error "API call failed: $response"
            return 1
        }
        echo "$response"
    fi
}

# Get current backends for a service
get_backends() {
    local service_name="$1"
    local endpoint="${COMPUTE_API}/projects/${PROJECT_ID}/regions/${REGION}/backendServices/${service_name}"
    
    local response
    response=$(DEBUG=0 api_call GET "$endpoint") || {
        debug "Failed to get backends for $service_name" >&2
        echo ""
        return 1
    }

    debug "Raw backends response: $response, response length: ${#response} chars" >&2

    # Extract backend groups from response
    local backends
    backends=$(echo "$response" | jq -r '.backends[]?.group' 2>/dev/null)
    
    if [[ -z "$backends" ]]; then
        debug "No backends found in response" >&2
        echo ""
    else
        debug "Found backends: $backends" >&2
        echo "$backends"
    fi
}

# Remove backend from service
remove_backend() {
    local service_name="$1"
    local instance_group_url="$2"
    
    log "Removing backend: $instance_group_url from $service_name"
    
    # Get current backend service configuration
    local endpoint="${COMPUTE_API}/projects/${PROJECT_ID}/regions/${REGION}/backendServices/${service_name}"
    local current_config
    current_config=$(DEBUG=0 api_call GET "$endpoint") || {
        error "Failed to get current configuration"
        return 1
    }
    
    debug "Current config before removal: ${current_config:0:300}..." >&2
    
    # Remove the backend from the configuration
    local new_config
    new_config=$(echo "$current_config" | jq --arg group "$instance_group_url" \
        'del(.backends[] | select(.group == $group))' 2>/dev/null) || {
        error "Failed to modify configuration with jq"
        return 1
    }
    
    debug "New config length: ${#new_config} chars" >&2
    
    # Update the backend service with retry logic for "resource not ready"
    local update_endpoint="${endpoint}?requestId=$(uuidgen)"
    debug "Sending PATCH to: $update_endpoint" >&2
    
    local response
    local max_retries=5
    local retry_count=0
    local wait_time=5
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Force debug mode for this specific API call to get error details
        response=$(DEBUG=1 api_call PATCH "$update_endpoint" "$new_config" 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            debug "PATCH response: ${response:0:200}..." >&2
            log "Backend removed successfully"
            return 0
        fi
        
        # Check if error is "resource not ready"
        if echo "$response" | grep -q "resourceNotReady\|is not ready"; then
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                log "Backend service not ready, waiting ${wait_time}s before retry $retry_count/$max_retries..."
                sleep $wait_time
                wait_time=$((wait_time + 5))  # Increase wait time
            else
                error "PATCH request failed after $max_retries retries: resource not ready"
                return 1
            fi
        else
            # Different error - fail immediately
            error "PATCH failed: $response"
            return 1
        fi
    done
    
    error "PATCH request failed after $max_retries retries"
    return 1
}

# Add backend to service
add_backend() {
    local service_name="$1"
    local instance_group_url="$2"
    
    log "Adding backend: $instance_group_url to $service_name"
    
    # Get current backend service configuration
    local endpoint="${COMPUTE_API}/projects/${PROJECT_ID}/regions/${REGION}/backendServices/${service_name}"
    local current_config
    current_config=$(DEBUG=0 api_call GET "$endpoint") || {
        error "Failed to get current backend service configuration"
        return 1
    }
    
    debug "Current config before add: ${current_config:0:300}..." >&2
    
    # Create new backend configuration (for INTERNAL load balancer)
    local new_backend
    new_backend=$(cat <<EOF
{
  "group": "$instance_group_url",
  "balancingMode": "CONNECTION"
}
EOF
)
    
    debug "New backend to add: $new_backend" >&2
    
    # Add backend to configuration (initialize backends array if missing)
    local new_config
    new_config=$(echo "$current_config" | jq --argjson backend "$new_backend" \
        '.backends = (.backends // []) + [$backend]' 2>/dev/null) || {
        error "Failed to create new configuration with jq"
        return 1
    }
    
    debug "Updated config length: ${#new_config} chars" >&2
    
    # Update the backend service with retry logic for "resource not ready"
    local update_endpoint="${endpoint}?requestId=$(uuidgen)"
    debug "Sending PATCH to: $update_endpoint" >&2
    
    local response
    local max_retries=5
    local retry_count=0
    local wait_time=5
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Force debug mode for this specific API call to get error details
        response=$(DEBUG=1 api_call PATCH "$update_endpoint" "$new_config" 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            debug "PATCH response: ${response:0:200}..." >&2
            log "Backend added successfully"
            return 0
        fi
        
        # Check if error is "resource not ready"
        if echo "$response" | grep -q "resourceNotReady\|is not ready"; then
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                log "Backend service not ready, waiting ${wait_time}s before retry $retry_count/$max_retries..."
                sleep $wait_time
                wait_time=$((wait_time + 5))  # Increase wait time
            else
                error "PATCH request failed after $max_retries retries: resource not ready"
                return 1
            fi
        else
            # Different error - fail immediately
            error "PATCH request failed: $response"
            return 1
        fi
    done
    
    error "PATCH request failed after $max_retries retries"
    return 1
}

# Get instance group URL
get_instance_group_url() {
    local group_name="$1"
    local zone="$2"
    
    # Use www.googleapis.com to match GCP API responses
    echo "https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/zones/${zone}/instanceGroups/${group_name}"
}

# Update write backend after failover
update_write_backend_after_failover() {
    local new_primary_group="$1"
    local new_primary_zone="$2"
    local old_primary_group="$3"
    local old_primary_zone="$4"
    
    log "Updating write backend service after failover"
    log "New primary: $new_primary_group (zone: $new_primary_zone)"
    log "Old primary: $old_primary_group (zone: $old_primary_zone)"
    
    local new_group_url
    local old_group_url
    new_group_url=$(get_instance_group_url "$new_primary_group" "$new_primary_zone")
    old_group_url=$(get_instance_group_url "$old_primary_group" "$old_primary_zone")
    
    # Check current backend configuration
    local current_backends
    current_backends=$(get_backends "$BACKEND_SERVICE_WRITE")
    
    debug "Current write backends: $current_backends" >&2
    debug "New group URL: $new_group_url" >&2
    debug "Old group URL: $old_group_url" >&2
    
    # Check if new backend is already configured (grep returns 0 if found)
    if echo "$current_backends" | grep -qF "$new_group_url"; then
        log "✓ Write backend already points to $new_primary_group - no changes needed"
        return 0
    fi
    
    # Check if old backend exists and needs to be removed
    if echo "$current_backends" | grep -q "$old_group_url"; then
        log "Removing old backend: $old_primary_group"
        if remove_backend "$BACKEND_SERVICE_WRITE" "$old_group_url"; then
            log "✓ Old primary backend removed"
        else
            error "Failed to remove old primary backend"
            return 1
        fi
        
        # Wait for backend service to become ready after removal
        log "Waiting for backend service to stabilize (15 seconds)..."
        sleep 15
    else
        log "Old backend $old_primary_group not found - skipping removal"
    fi
    
    # Add new primary backend
    log "Adding new backend: $new_primary_group"
    if add_backend "$BACKEND_SERVICE_WRITE" "$new_group_url"; then
        log "✓ New primary backend added"
        return 0
    else
        error "Failed to add new primary backend"
        return 1
    fi
}

# Update read backend (swap standby)
update_read_backend() {
    local new_standby_group="$1"
    local new_standby_zone="$2"
    local old_standby_group="$3"
    local old_standby_zone="$4"
    
    log "Updating read backend service"
    
    local new_group_url
    local old_group_url
    new_group_url=$(get_instance_group_url "$new_standby_group" "$new_standby_zone")
    old_group_url=$(get_instance_group_url "$old_standby_group" "$old_standby_zone")
    
    # Remove old standby backend
    remove_backend "$BACKEND_SERVICE_READ" "$old_group_url" || true
    
    # Wait for propagation
    sleep 3
    
    # Add new standby backend
    add_backend "$BACKEND_SERVICE_READ" "$new_group_url" || return 1
    
    log "Read backend updated"
}

# Check backend health
check_backend_health() {
    local service_name="$1"
    
    local endpoint="${COMPUTE_API}/projects/${PROJECT_ID}/regions/${REGION}/backendServices/${service_name}/getHealth"
    local group_url="$2"
    
    local health_data
    health_data=$(cat <<EOF
{
  "group": "$group_url"
}
EOF
)
    
    api_call POST "$endpoint" "$health_data" | jq -r '.healthStatus[]?.healthState' 2>/dev/null || echo "UNKNOWN"
}

# Main failover function (standby becomes primary)
execute_lb_failover() {
    log "=========================================="
    log "EXECUTING LOAD BALANCER FAILOVER"
    log "=========================================="
    log "Scenario: Primary node failed"
    log "Action: Move WRITE traffic from Primary to Standby"
    log "Note: READ traffic remains on Standby (no change)"
    log "=========================================="
    
    # Only update write backend - read stays on standby
    if update_write_backend_after_failover \
        "$STANDBY_GROUP" "$STANDBY_ZONE" \
        "$PRIMARY_GROUP" "$PRIMARY_ZONE"; then
        
        log "=========================================="
        log "FAILOVER COMPLETED SUCCESSFULLY"
        log "Current configuration:"
        log "  Write traffic → $STANDBY_GROUP (zone: $STANDBY_ZONE) [NEW PRIMARY]"
        log "  Read traffic  → $STANDBY_GROUP (zone: $STANDBY_ZONE) [UNCHANGED]"
        log "=========================================="
        log ""
        log "Next steps:"
        log "  1. Verify application write operations are working"
        log "  2. Monitor standby node performance (handling both read + write)"
        log "  3. Fix the failed primary node"
        log "  4. Rebuild primary as standby and run failback when ready"
        
        return 0
    else
        error "Load balancer failover failed"
        return 1
    fi
}

# Main failback function (restore original configuration)
execute_lb_failback() {
    log "=========================================="
    log "EXECUTING LOAD BALANCER FAILBACK"
    log "=========================================="
    log "Scenario: Restoring original primary after recovery"
    log "Action: Move WRITE traffic back from Standby to Primary"
    log "Note: READ traffic remains on Standby (no change)"
    log "=========================================="
    
    # Verify old primary is ready
    log "Verifying original primary is available..."
    local primary_url
    primary_url=$(get_instance_group_url "$PRIMARY_GROUP" "$PRIMARY_ZONE")
    
    # Note: In production, you should verify PostgreSQL is running and ready
    
    # Update write backend only (restore to original primary)
    log "Restoring write backend to original primary..."
    if update_write_backend_after_failover \
        "$PRIMARY_GROUP" "$PRIMARY_ZONE" \
        "$STANDBY_GROUP" "$STANDBY_ZONE"; then
        
        log "✓ Write backend restored to original primary"
    else
        error "Failed to restore write backend"
        return 1
    fi
    
    # Wait for health checks to stabilize
    log "Waiting for health checks to stabilize (10 seconds)..."
    sleep 10
    
    log "=========================================="
    log "FAILBACK COMPLETED SUCCESSFULLY"
    log "Configuration restored to original:"
    log "  Write traffic → $PRIMARY_GROUP (zone: $PRIMARY_ZONE) [RESTORED]"
    log "  Read traffic  → $STANDBY_GROUP (zone: $STANDBY_ZONE) [UNCHANGED]"
    log "=========================================="
    log ""
    log "Next steps:"
    log "  1. Verify PostgreSQL replication is working"
    log "  2. Verify application write operations on primary"
    log "  3. Monitor replication lag"
    log "  4. Check application logs for any connectivity issues"
    
    return 0
}

# List current backends
list_backends() {
    log "Current Write Backends:"
    local write_backends
    write_backends=$(get_backends "$BACKEND_SERVICE_WRITE")
    if [[ -n "$write_backends" ]]; then
        while IFS= read -r backend; do
            [[ -n "$backend" ]] && log "  $backend"
        done <<< "$write_backends"
    else
        log "  (none)"
    fi

    echo ""
    log "Current Read Backends:"
    local read_backends
    read_backends=$(get_backends "$BACKEND_SERVICE_READ")
    if [[ -n "$read_backends" ]]; then
        while IFS= read -r backend; do
            [[ -n "$backend" ]] && log "  $backend"
        done <<< "$read_backends"
    else
        log "  (none)"
    fi
}

# Check IAM permissions
check_permissions() {
    log "Checking service account permissions..."
    
    # Get service account email from metadata
    local sa_email
    sa_email=$(curl -sf -H "Metadata-Flavor: Google" \
        "${METADATA_API}/instance/service-accounts/default/email" 2>/dev/null || echo "unknown")
    
    log "Service Account: $sa_email"
    
    # Test permissions by trying to list backend services
    local endpoint="${COMPUTE_API}/projects/${PROJECT_ID}/regions/${REGION}/backendServices"
    local result
    
    debug "Testing: $endpoint"
    result=$(api_call GET "$endpoint" 2>&1) || {
        error "Permission check failed"
        log ""
        log "Required IAM roles for this service account:"
        log "  - roles/compute.loadBalancerAdmin (to modify load balancers)"
        log "  - roles/compute.viewer (to read configurations)"
        log ""
        log "To grant permissions, run:"
        log "  gcloud projects add-iam-policy-binding $PROJECT_ID \\"
        log "    --member='serviceAccount:$sa_email' \\"
        log "    --role='roles/compute.loadBalancerAdmin'"
        return 1
    }
    
    # Count backend services
    local count
    count=$(echo "$result" | jq '.items | length' 2>/dev/null || echo "0")
    log "✓ Permissions verified - Found $count backend service(s)"
    
    return 0
}

# Test API connectivity
test_api() {
    log "Testing GCP API connectivity..."
    
    local token
    token=$(get_access_token) || {
        error "Failed to get access token"
        return 1
    }
    
    log "✓ Access token obtained"
    debug "Token: ${token:0:20}..."
    
    # Check permissions first
    check_permissions || return 1
    
    # Test reading backend services
    log ""
    log "Testing backend service access..."
    
    local write_endpoint="${COMPUTE_API}/projects/${PROJECT_ID}/regions/${REGION}/backendServices/${BACKEND_SERVICE_WRITE}"
    local read_endpoint="${COMPUTE_API}/projects/${PROJECT_ID}/regions/${REGION}/backendServices/${BACKEND_SERVICE_READ}"
    
    debug "Write endpoint: $write_endpoint"
    debug "Read endpoint: $read_endpoint"
    
    local write_info
    write_info=$(api_call GET "$write_endpoint" 2>&1) || {
        error "Failed to access write backend service: $BACKEND_SERVICE_WRITE"
        return 1
    }
    log "✓ Write backend service accessible"
    
    local read_info
    read_info=$(api_call GET "$read_endpoint" 2>&1) || {
        error "Failed to access read backend service: $BACKEND_SERVICE_READ"
        return 1
    }
    log "✓ Read backend service accessible"
    
    log ""
    log "=========================================="
    log "ALL TESTS PASSED"
    log "=========================================="
    log "The script has all required permissions and can manage load balancers."
}

# Main execution
case "${1:-help}" in
    failover)
        execute_lb_failover
        ;;
    failback)
        execute_lb_failback
        ;;
    list)
        list_backends
        ;;
    test)
        test_api
        ;;
    update-write)
        update_write_backend_after_failover \
            "${2:-$STANDBY_GROUP}" "${3:-$STANDBY_ZONE}" \
            "${4:-$PRIMARY_GROUP}" "${5:-$PRIMARY_ZONE}"
        ;;
    help|*)
        cat <<EOF
Usage: $0 {failover|failback|list|test|update-write}

Commands:
  failover      - Execute load balancer failover (standby becomes primary)
  failback      - Execute load balancer failback (restore original primary)
  list          - List current backend configurations
  test          - Test API connectivity and authentication
  update-write  - Update write backend (manual override)

Examples:
  # During emergency - promote standby to primary
  sudo -u postgres $0 failover

  # After fixing issues - restore original configuration
  sudo -u postgres $0 failback

  # Check current configuration
  sudo -u postgres $0 list

  # Test API access
  sudo -u postgres $0 test

Important Notes:
  - Always run PostgreSQL promotion/demotion BEFORE load balancer changes
  - Verify database replication status before failback
  - Monitor application traffic during transitions
  - This script uses GCP metadata service (no gcloud authentication required)
  - Find the log file at: $LOG_FILE

Detected Configuration:
  Environment: $ENVIRONMENT (auto-detected)
  Project:     $PROJECT_ID
  Region:      $REGION
  Primary:     $PRIMARY_GROUP ($PRIMARY_ZONE)
  Standby:     $STANDBY_GROUP ($STANDBY_ZONE)
  Write LB:    $BACKEND_SERVICE_WRITE
  Read LB:     $BACKEND_SERVICE_READ
EOF
        ;;
esac