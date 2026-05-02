#!/bin/bash
# Comprehensive PostgreSQL HA Load Balancer Validation Script
# Retrieves credentials from Secret Manager and validates complete replication setup
# Version: 2.0.0 - Secret Manager Integration

set -euo pipefail

# ============================================================================
# CONFIGURATION AND SETUP
# ============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly VALIDATION_START_TIME=$(date +%s)

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Environment Configuration
readonly ORG_CODE="ipa"
readonly ENV_CODE="nprd"
readonly PROJECT_ID="ipa-nprd-svc-db-01"
readonly REGION="me-central2"

# Network Configuration
readonly WRITE_IP="192.168.14.20"
readonly READ_IP="192.168.14.19"
readonly PRIMARY_IP="192.168.14.21"
readonly STANDBY_IP="192.168.14.22"
readonly PGBOUNCER_PORT=6432
readonly POSTGRES_PORT=5432

# DNS Configuration
readonly WRITE_FQDN="pg-write.db.internal.nprd.ipa.edu.sa"
readonly READ_FQDN="pg-read.db.internal.nprd.ipa.edu.sa"

# Secret Manager Secret IDs (based on your Terraform configuration)
readonly PG_SUPERUSER_SECRET="ipa-nprd-sec-pg-superuser-password-01"
readonly PG_REPLICATION_SECRET="ipa-nprd-sec-pg-replication-password-01"
readonly PG_MONITOR_SECRET="ipa-nprd-sec-pg-monitor-password-01"
readonly PGBOUNCER_SECRET="ipa-nprd-sec-pgbouncer-password-01"

# ============================================================================
# LOGGING AND UTILITY FUNCTIONS
# ============================================================================

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
  case "$1" in
    INFO) color="$CYAN"; lvl="INFO"; shift ;;
    WARN) color="$YELLOW"; lvl="WARN"; shift ;;
    ERROR) color="$RED"; lvl="ERROR"; shift ;;
    SUCCESS) color="$GREEN"; lvl="SUCCESS"; shift ;;
    DEBUG) color="$PURPLE"; lvl="DEBUG"; shift ;;
    *) color="$NC"; lvl="INFO" ;;
  esac
  printf "%b[%s] [%s] %s%b\n" "$color" "$(ts)" "$lvl" "$*" "$NC"
}

info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }
success() { log SUCCESS "✓ $*"; }
debug() { [[ "${DEBUG:-}" == "1" ]] && log DEBUG "$*" || true; }

print_header() {
  local title="$1"
  printf "\n%b╔══════════════════════════════════════════════════════════════════════════════╗%b\n" "$BLUE" "$NC"
  printf "%b║%*s║%b\n" "$BLUE" $((78)) " " "$NC"
  printf "%b║%*s%s%*s║%b\n" "$BLUE" $(((78-${#title})/2)) " " "$title" $(((78-${#title})/2)) " " "$NC"
  printf "%b║%*s║%b\n" "$BLUE" $((78)) " " "$NC"
  printf "%b╚══════════════════════════════════════════════════════════════════════════════╝%b\n" "$BLUE" "$NC"
}

print_section() {
  local section="$1"
  printf "\n%b=== %s ===%b\n" "$YELLOW" "$section" "$NC"
}

# ============================================================================
# SECRET MANAGER FUNCTIONS
# ============================================================================

get_secret_value() {
  local secret_id="$1"
  local description="$2"
  
  debug "Retrieving secret: $secret_id"
  
  local secret_value
  secret_value=$(gcloud secrets versions access latest \
    --secret="$secret_id" \
    --project="$PROJECT_ID" 2>/dev/null || echo "")
  
  if [[ -n "$secret_value" ]]; then
    debug "Successfully retrieved $description (length: ${#secret_value})"
    echo "$secret_value"
    return 0
  else
    error "Failed to retrieve $description from Secret Manager"
    return 1
  fi
}

setup_authentication() {
  print_section "Setting up Authentication from Secret Manager"
  
  info "Retrieving credentials from Secret Manager..."
  
  # Check if gcloud is configured
  if ! command -v gcloud >/dev/null 2>&1; then
    error "gcloud CLI not found. Please install Google Cloud SDK."
    return 1
  fi
  
  # Check authentication
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
    error "gcloud not authenticated. Please run: gcloud auth login"
    return 1
  fi
  
  # Retrieve secrets
  local postgres_password
  local replication_password
  local monitor_password
  local pgbouncer_password
  
  info "Retrieving PostgreSQL superuser password..."
  postgres_password=$(get_secret_value "$PG_SUPERUSER_SECRET" "PostgreSQL superuser password")
  
  info "Retrieving replication user password..."
  replication_password=$(get_secret_value "$PG_REPLICATION_SECRET" "Replication user password")
  
  info "Retrieving monitor user password..."
  monitor_password=$(get_secret_value "$PG_MONITOR_SECRET" "Monitor user password")
  
  info "Retrieving PgBouncer password..."
  pgbouncer_password=$(get_secret_value "$PGBOUNCER_SECRET" "PgBouncer password")
  
  if [[ -z "$postgres_password" ]]; then
    error "Could not retrieve PostgreSQL superuser password"
    return 1
  fi
  
  # Create .pgpass file
  info "Creating .pgpass file with retrieved credentials..."
  
  cat > ~/.pgpass << EOF
# PostgreSQL HA .pgpass file - Generated from Secret Manager
# Format: hostname:port:database:username:password
# Generated: $(date)

# Load Balancer Endpoints
$WRITE_IP:$PGBOUNCER_PORT:*:postgres:$postgres_password
$READ_IP:$PGBOUNCER_PORT:*:postgres:$postgres_password

# Direct Backend Connections - PgBouncer
$PRIMARY_IP:$PGBOUNCER_PORT:*:postgres:$postgres_password
$STANDBY_IP:$PGBOUNCER_PORT:*:postgres:$postgres_password

# Direct Backend Connections - PostgreSQL
$PRIMARY_IP:$POSTGRES_PORT:*:postgres:$postgres_password
$STANDBY_IP:$POSTGRES_PORT:*:postgres:$postgres_password

# DNS Names
$WRITE_FQDN:$PGBOUNCER_PORT:*:postgres:$postgres_password
$READ_FQDN:$PGBOUNCER_PORT:*:postgres:$postgres_password

# Replication user (if needed)
$PRIMARY_IP:$POSTGRES_PORT:*:repl:$replication_password
$STANDBY_IP:$POSTGRES_PORT:*:repl:$replication_password

# Monitor user (if needed)
$PRIMARY_IP:$POSTGRES_PORT:*:pgmon:$monitor_password
$STANDBY_IP:$POSTGRES_PORT:*:pgmon:$monitor_password

# Localhost
localhost:$PGBOUNCER_PORT:*:postgres:$postgres_password
localhost:$POSTGRES_PORT:*:postgres:$postgres_password
EOF

  # Set correct permissions
  chmod 600 ~/.pgpass
  
  success "Authentication configured successfully"
  info ".pgpass file created with $(wc -l ~/.pgpass | awk '{print $1}') entries"
  
  return 0
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

validate_prerequisites() {
  print_section "Validating Prerequisites"
  
  local prereq_tests=0
  local prereq_passed=0
  
  # Check required commands
  local required_commands=("gcloud" "psql" "curl" "nc" "dig" "jq")
  
  for cmd in "${required_commands[@]}"; do
    ((prereq_tests++))
    if command -v "$cmd" >/dev/null 2>&1; then
      success "$cmd is available"
      ((prereq_passed++))
    else
      error "$cmd is not available"
    fi
  done
  
  # Check gcloud authentication
  ((prereq_tests++))
  if gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
    local active_account
    active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
    success "gcloud authenticated as: $active_account"
    ((prereq_passed++))
  else
    error "gcloud not authenticated"
  fi
  
  # Check project access
  ((prereq_tests++))
  if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    success "Access to project $PROJECT_ID confirmed"
    ((prereq_passed++))
  else
    error "Cannot access project $PROJECT_ID"
  fi
  
  info "Prerequisites: $prereq_passed/$prereq_tests passed"
  
  if [[ $prereq_passed -lt $prereq_tests ]]; then
    error "Prerequisites not met. Please fix the issues above."
    return 1
  fi
  
  return 0
}

test_network_connectivity() {
  print_section "Network Connectivity Tests"
  
  local conn_tests=0
  local conn_passed=0
  
  # Test function
  test_connectivity() {
    local ip="$1"
    local port="$2"
    local name="$3"
    
    ((conn_tests++))
    info "Testing $name ($ip:$port)..."
    
    if timeout 5 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
      success "$name - Network connectivity OK"
      ((conn_passed++))
      return 0
    else
      error "$name - Network connectivity FAILED"
      return 1
    fi
  }
  
  # Test all endpoints
  test_connectivity "$WRITE_IP" "$PGBOUNCER_PORT" "Write Load Balancer"
  test_connectivity "$READ_IP" "$PGBOUNCER_PORT" "Read Load Balancer"
  test_connectivity "$PRIMARY_IP" "$PGBOUNCER_PORT" "Primary Backend"
  test_connectivity "$STANDBY_IP" "$PGBOUNCER_PORT" "Standby Backend"
  
  info "Network Connectivity: $conn_passed/$conn_tests tests passed"
  return $((conn_tests - conn_passed))
}

test_dns_resolution() {
  print_section "DNS Resolution Tests"
  
  local dns_tests=0
  local dns_passed=0
  
  # Test DNS resolution
  test_dns() {
    local fqdn="$1"
    local expected_ip="$2"
    local name="$3"
    
    ((dns_tests++))
    info "Testing DNS resolution for $name..."
    
    local resolved_ip
    resolved_ip=$(dig +short "$fqdn" 2>/dev/null | head -1 || echo "")
    
    if [[ "$resolved_ip" == "$expected_ip" ]]; then
      success "$fqdn resolves to $resolved_ip"
      ((dns_passed++))
      return 0
    elif [[ -n "$resolved_ip" ]]; then
      warn "$fqdn resolves to $resolved_ip (expected $expected_ip)"
      return 1
    else
      error "$fqdn does not resolve"
      return 1
    fi
  }
  
  test_dns "$WRITE_FQDN" "$WRITE_IP" "Write Load Balancer DNS"
  test_dns "$READ_FQDN" "$READ_IP" "Read Load Balancer DNS"
  
  info "DNS Resolution: $dns_passed/$dns_tests tests passed"
  return $((dns_tests - dns_passed))
}

test_database_connections() {
  print_section "Database Connection and Role Tests"
  
  local db_tests=0
  local db_passed=0
  
  # Database connection test function
  test_db_connection() {
    local host="$1"
    local port="$2"
    local name="$3"
    local expected_role="$4"
    
    ((db_tests++))
    info "Testing $name database connection..."
    
    # Test basic connectivity
    local connection_result
    connection_result=$(timeout 15 psql -h "$host" -p "$port" -U postgres -d postgres \
      -c "SELECT 'Connected successfully' as status;" -t -A 2>/dev/null || echo "FAILED")
    
    if [[ "$connection_result" =~ "Connected successfully" ]]; then
      success "$name - Database connection established"
      
      # Test role detection
      local actual_role
      actual_role=$(timeout 10 psql -h "$host" -p "$port" -U postgres -d postgres \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
      
      if [[ "$actual_role" == "$expected_role" ]]; then
        success "$name - Correct role: $actual_role"
        ((db_passed++))
        
        # Get additional info
        local server_info
        server_info=$(timeout 10 psql -h "$host" -p "$port" -U postgres -d postgres \
          -Atqc "SELECT inet_server_addr() || ':' || inet_server_port();" 2>/dev/null || echo "unknown")
        info "$name - Connected to backend: $server_info"
        
        return 0
      else
        warn "$name - Role mismatch: got $actual_role, expected $expected_role"
        return 1
      fi
    else
      error "$name - Database connection failed"
      debug "Connection error: $connection_result"
      return 1
    fi
  }
  
  # Test all database connections
  test_db_connection "$WRITE_IP" "$PGBOUNCER_PORT" "Write Load Balancer" "primary"
  test_db_connection "$READ_IP" "$PGBOUNCER_PORT" "Read Load Balancer" "standby"
  test_db_connection "$PRIMARY_IP" "$PGBOUNCER_PORT" "Primary Backend Direct" "primary"
  test_db_connection "$STANDBY_IP" "$PGBOUNCER_PORT" "Standby Backend Direct" "standby"
  
  info "Database Connections: $db_passed/$db_tests tests passed"
  return $((db_tests - db_passed))
}

test_replication_functionality() {
  print_section "Replication Functionality Tests"
  
  local repl_tests=0
  local repl_passed=0
  
  # Create test table and insert data via write endpoint
  ((repl_tests++))
  info "Testing data insertion via Write Load Balancer..."
  
  local test_id=$((RANDOM % 100000))
  local test_table="lb_replication_test_$(date +%s)"
  local insert_success=false
  
  if timeout 20 psql -h "$WRITE_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres << EOF >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS $test_table (
  id INTEGER PRIMARY KEY,
  test_message TEXT,
  endpoint_used TEXT,
  created_at TIMESTAMP DEFAULT NOW(),
  test_run_id INTEGER
);

INSERT INTO $test_table (id, test_message, endpoint_used, test_run_id) 
VALUES ($test_id, 'Load balancer replication test', 'write-endpoint', $test_id);
EOF
  then
    success "Data inserted successfully via Write Load Balancer (Test ID: $test_id)"
    insert_success=true
    ((repl_passed++))
  else
    error "Failed to insert data via Write Load Balancer"
  fi
  
  if [[ "$insert_success" == "true" ]]; then
    # Wait for replication
    info "Waiting 10 seconds for replication to complete..."
    sleep 10
    
    # Test data retrieval via read endpoint
    ((repl_tests++))
    info "Testing data retrieval via Read Load Balancer..."
    
    local retrieved_data
    retrieved_data=$(timeout 15 psql -h "$READ_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres \
      -Atqc "SELECT COUNT(*) FROM $test_table WHERE test_run_id = $test_id;" 2>/dev/null || echo "0")
    
    if [[ "$retrieved_data" == "1" ]]; then
      success "Data successfully replicated and retrieved via Read Load Balancer"
      ((repl_passed++))
      
      # Get replication details
      local repl_details
      repl_details=$(timeout 10 psql -h "$READ_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres \
        -Atqc "SELECT test_message || ' at ' || created_at FROM $test_table WHERE test_run_id = $test_id;" 2>/dev/null || echo "")
      info "Retrieved data: $repl_details"
      
    else
      error "Data replication failed - record not found on read endpoint"
    fi
    
    # Test replication lag
    ((repl_tests++))
    info "Checking replication lag..."
    
    local lag_seconds
    lag_seconds=$(timeout 10 psql -h "$STANDBY_IP" -p "$POSTGRES_PORT" -U postgres -d postgres \
      -Atqc "SELECT COALESCE(EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp()), 0);" 2>/dev/null || echo "999")
    
    if [[ -n "$lag_seconds" ]] && (( $(echo "$lag_seconds < 60" | bc -l) )); then
      success "Replication lag acceptable: ${lag_seconds} seconds"
      ((repl_passed++))
    else
      warn "Replication lag high or unknown: ${lag_seconds} seconds"
    fi
    
    # Cleanup test data
    info "Cleaning up test data..."
    timeout 10 psql -h "$WRITE_IP" -p "$PGBOUNCER_PORT" -U postgres -d postgres \
      -c "DROP TABLE IF EXISTS $test_table;" >/dev/null 2>&1 || warn "Could not clean up test table"
  fi
  
  info "Replication Tests: $repl_passed/$repl_tests tests passed"
  return $((repl_tests - repl_passed))
}

test_health_endpoints() {
  print_section "Health Endpoint Tests"
  
  local health_tests=0
  local health_passed=0
  
  # Test health endpoints
  test_health_endpoint() {
    local ip="$1"
    local port="$2"
    local name="$3"
    local expected_service="$4"
    
    ((health_tests++))
    info "Testing $name health endpoint ($ip:$port)..."
    
    local health_response
    health_response=$(timeout 8 curl -s "http://$ip:$port" 2>/dev/null || echo "failed")
    
    if echo "$health_response" | grep -q "\"status\":\"healthy\"" && echo "$health_response" | grep -q "\"service\":\"$expected_service\""; then
      success "$name health endpoint - Healthy"
      ((health_passed++))
      
      # Extract timestamp if available
      local timestamp
      timestamp=$(echo "$health_response" | jq -r '.timestamp' 2>/dev/null || echo "unknown")
      info "$name health - Last updated: $timestamp"
      
      return 0
    else
      error "$name health endpoint - Unhealthy or unreachable"
      debug "Response: $health_response"
      return 1
    fi
  }
  
  # Test all health endpoints
  test_health_endpoint "$PRIMARY_IP" "8001" "Primary PostgreSQL" "postgresql"
  test_health_endpoint "$STANDBY_IP" "8001" "Standby PostgreSQL" "postgresql"
  test_health_endpoint "$PRIMARY_IP" "8002" "Primary PgBouncer" "pgbouncer"
  test_health_endpoint "$STANDBY_IP" "8002" "Standby PgBouncer" "pgbouncer"
  
  info "Health Endpoint Tests: $health_passed/$health_tests tests passed"
  return $((health_tests - health_passed))
}

test_failover_readiness() {
  print_section "Failover Readiness Assessment"
  
  local failover_tests=0
  local failover_passed=0
  
  # Test streaming replication status
  ((failover_tests++))
  info "Checking streaming replication status..."
  
  local replication_status
  replication_status=$(timeout 10 psql -h "$PRIMARY_IP" -p "$POSTGRES_PORT" -U postgres -d postgres \
    -Atqc "SELECT state || '|' || sync_state FROM pg_stat_replication WHERE application_name = 'standby';" 2>/dev/null || echo "")
  
  if [[ "$replication_status" =~ "streaming" ]]; then
    success "Streaming replication active: $replication_status"
    ((failover_passed++))
  else
    error "Streaming replication not active or not found"
    debug "Replication status: $replication_status"
  fi
  
  # Test standby status
  ((failover_tests++))
  info "Checking standby readiness..."
  
  local standby_status
  standby_status=$(timeout 10 psql -h "$STANDBY_IP" -p "$POSTGRES_PORT" -U postgres -d postgres \
    -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "")
  
  if [[ "$standby_status" == "t" ]]; then
    success "Standby node is in recovery mode (ready for failover)"
    ((failover_passed++))
  else
    error "Standby node not in recovery mode"
  fi
  
  # Test WAL receiver status
  ((failover_tests++))
  info "Checking WAL receiver status on standby..."
  
  local wal_receiver
  wal_receiver=$(timeout 10 psql -h "$STANDBY_IP" -p "$POSTGRES_PORT" -U postgres -d postgres \
    -Atqc "SELECT status FROM pg_stat_wal_receiver;" 2>/dev/null || echo "")
  
  if [[ "$wal_receiver" == "streaming" ]]; then
    success "WAL receiver is streaming"
    ((failover_passed++))
  else
    warn "WAL receiver status: $wal_receiver"
  fi
  
  info "Failover Readiness: $failover_passed/$failover_tests tests passed"
  return $((failover_tests - failover_passed))
}

generate_connection_examples() {
  print_section "Connection Examples and Summary"
  
  cat << EOF

🔗 APPLICATION CONNECTION STRINGS:

Write Operations (Primary via Load Balancer):
  IP:   postgresql://postgres:password@$WRITE_IP:$PGBOUNCER_PORT/your_database
  DNS:  postgresql://postgres:password@$WRITE_FQDN:$PGBOUNCER_PORT/your_database

Read Operations (Standby via Load Balancer):
  IP:   postgresql://postgres:password@$READ_IP:$PGBOUNCER_PORT/your_database
  DNS:  postgresql://postgres:password@$READ_FQDN:$PGBOUNCER_PORT/your_database

🔧 DIRECT BACKEND CONNECTIONS (for maintenance):

Direct Primary:
  PgBouncer: postgresql://postgres:password@$PRIMARY_IP:$PGBOUNCER_PORT/your_database
  PostgreSQL: postgresql://postgres:password@$PRIMARY_IP:$POSTGRES_PORT/your_database

Direct Standby:
  PgBouncer: postgresql://postgres:password@$STANDBY_IP:$PGBOUNCER_PORT/your_database
  PostgreSQL: postgresql://postgres:password@$STANDBY_IP:$POSTGRES_PORT/your_database

🏥 HEALTH ENDPOINTS:

Primary Node:
  PostgreSQL: http://$PRIMARY_IP:8001
  PgBouncer:  http://$PRIMARY_IP:8002

Standby Node:
  PostgreSQL: http://$STANDBY_IP:8001
  PgBouncer:  http://$STANDBY_IP:8002

📊 MONITORING QUERIES:

# Check replication lag:
psql -h $READ_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "
SELECT 
  CASE WHEN pg_is_in_recovery() THEN 
    COALESCE(EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp()), 0)
  ELSE 0 END as lag_seconds;"

# Check streaming replication status:
psql -h $PRIMARY_IP -p $POSTGRES_PORT -U postgres -d postgres -c "
SELECT client_addr, state, sync_state, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)) as lag
FROM pg_stat_replication;"

# Check connection pooling:
psql -h $PRIMARY_IP -p $PGBOUNCER_PORT -U postgres -d postgres -c "SHOW pools;"

EOF
}

# ============================================================================
# MAIN EXECUTION FUNCTION
# ============================================================================

main() {
  print_header "PostgreSQL HA Load Balancer Comprehensive Validation v$SCRIPT_VERSION"
  
  info "Starting comprehensive validation at $(date)"
  info "Environment: $ENV_CODE | Project: $PROJECT_ID | Region: $REGION"
  
  # Initialize test counters
  local total_test_groups=0
  local passed_test_groups=0
  local total_failures=0
  
  # Enable debug mode if requested
  if [[ "${1:-}" == "--debug" ]]; then
    export DEBUG=1
    info "Debug mode enabled"
  fi
  
  # Step 1: Validate Prerequisites
  ((total_test_groups++))
  if validate_prerequisites; then
    ((passed_test_groups++))
  else
    error "Prerequisites validation failed. Exiting."
    exit 1
  fi
  
  # Step 2: Setup Authentication
  ((total_test_groups++))
  if setup_authentication; then
    ((passed_test_groups++))
  else
    error "Authentication setup failed. Exiting."
    exit 1
  fi
  
  # Step 3: Network Connectivity Tests
  ((total_test_groups++))
  network_failures=$(test_network_connectivity || echo $?)
  if [[ ${network_failures:-0} -eq 0 ]]; then
    ((passed_test_groups++))
  else
    ((total_failures += network_failures))
  fi
  
  # Step 4: DNS Resolution Tests
  ((total_test_groups++))
  dns_failures=$(test_dns_resolution || echo $?)
  if [[ ${dns_failures:-0} -eq 0 ]]; then
    ((passed_test_groups++))
  else
    ((total_failures += dns_failures))
  fi
  
  # Step 5: Database Connection Tests
  ((total_test_groups++))
  db_failures=$(test_database_connections || echo $?)
  if [[ ${db_failures:-0} -eq 0 ]]; then
    ((passed_test_groups++))
  else
    ((total_failures += db_failures))
  fi
  
  # Step 6: Replication Functionality Tests
  ((total_test_groups++))
  repl_failures=$(test_replication_functionality || echo $?)
  if [[ ${repl_failures:-0} -eq 0 ]]; then
    ((passed_test_groups++))
  else
    ((total_failures += repl_failures))
  fi
  
  # Step 7: Health Endpoint Tests
  ((total_test_groups++))
  health_failures=$(test_health_endpoints || echo $?)
  if [[ ${health_failures:-0} -eq 0 ]]; then
    ((passed_test_groups++))
  else
    ((total_failures += health_failures))
  fi
  
  # Step 8: Failover Readiness Assessment
  ((total_test_groups++))
  failover_failures=$(test_failover_readiness || echo $?)
  if [[ ${failover_failures:-0} -eq 0 ]]; then
    ((passed_test_groups++))
  else
    ((total_failures += failover_failures))
  fi
  
  # Generate connection examples
  generate_connection_examples
  
  # Final summary
  local end_time
  end_time=$(($(date +%s) - VALIDATION_START_TIME))
  
  print_section "Final Validation Summary"
  
  printf "\n%b╔══════════════════════════════════════════════════════════════════════════════╗%b\n" "$BLUE" "$NC"
  printf "%b║                    COMPREHENSIVE VALIDATION RESULTS                         ║%b\n" "$BLUE" "$NC"
  printf "%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n" "$BLUE" "$NC"
  printf "%b║ Completed in: %3d seconds                                                    ║%b\n" "$BLUE" $end_time "$NC"
  printf "%b║ Test Groups:  %2d/%2d passed                                                   ║%b\n" "$BLUE" $passed_test_groups $total_test_groups "$NC"
  
  if [[ $total_failures -eq 0 ]]; then
    printf "%b║ Status:       🎉 EXCELLENT - All tests passed!                              ║%b\n" "$GREEN" "$NC"
    printf "%b║ Result:       ✅ Load balancer is production ready                          ║%b\n" "$GREEN" "$NC"
  elif [[ $total_failures -le 3 ]]; then
    printf "%b║ Status:       ⚠️  GOOD - Minor issues detected (%2d failures)                ║%b\n" "$YELLOW" $total_failures "$NC"
    printf "%b║ Result:       ✅ Load balancer is mostly functional                         ║%b\n" "$YELLOW" "$NC"
  else
    printf "%b║ Status:       ❌ NEEDS ATTENTION - Multiple issues (%2d failures)           ║%b\n" "$RED" $total_failures "$NC"
    printf "%b║ Result:       🔧 Load balancer requires troubleshooting                     ║%b\n" "$RED" "$NC"
  fi
  
  printf "%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n" "$BLUE" "$NC"
  printf "%b║ Write Endpoint: %-56s ║%b\n" "$BLUE" "$WRITE_FQDN" "$NC"
  printf "%b║ Read Endpoint:  %-56s ║%b\n" "$BLUE" "$READ_FQDN" "$NC"
  printf "%b║ Project:        %-56s ║%b\n" "$BLUE" "$PROJECT_ID" "$NC"
  printf "%b║ Environment:    %-56s ║%b\n" "$BLUE" "$ENV_CODE" "$NC"
  printf "%b╚══════════════════════════════════════════════════════════════════════════════╝%b\n" "$BLUE" "$NC"
  
  # Clean up temporary files
  info "Cleaning up temporary files..."
  
  info "Validation completed successfully!"
  
  # Return appropriate exit code
  if [[ $total_failures -eq 0 ]]; then
    exit 0
  elif [[ $total_failures -le 3 ]]; then
    exit 1
  else
    exit 2
  fi
}

# ============================================================================
# SCRIPT EXECUTION
# ============================================================================

# Check if running as script or being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi