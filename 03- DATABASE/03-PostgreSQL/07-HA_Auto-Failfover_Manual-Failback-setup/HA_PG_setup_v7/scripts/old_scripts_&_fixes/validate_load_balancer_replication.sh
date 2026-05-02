#!/bin/bash
# PostgreSQL HA Load Balancer Validation Script
# Validates replication through GCP Internal Load Balancer endpoints
# Tests both FQDN and IP-based connections to write/read endpoints
#
# Version: 1.0.0 - Comprehensive Load Balancer Testing

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly VALIDATION_START_TIME=$(date +%s)

# Load Balancer Configuration (based on your Terraform setup)
readonly ORG_CODE="${ORG_CODE:-ipa}"
readonly ENV_CODE="${ENV_CODE:-nprd}"
readonly BASE_DOMAIN="${BASE_DOMAIN:-ipa.edu.sa}"
readonly INTERNAL_DB_DNS_ZONE="${INTERNAL_DB_DNS_ZONE:-db.internal}"

# DNS and IP Configuration based on your Terraform load_balancer.tf
readonly WRITE_FQDN="pg-write.${INTERNAL_DB_DNS_ZONE}.${ENV_CODE}.${BASE_DOMAIN}"
readonly READ_FQDN="pg-read.${INTERNAL_DB_DNS_ZONE}.${ENV_CODE}.${BASE_DOMAIN}"
readonly PGBOUNCER_PORT=6432
readonly POSTGRES_PORT=5432

# Connection Details
readonly DB_NAME="postgres"
readonly DB_USER="postgres"
readonly TEST_TABLE="lb_validation_test"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
  case "$1" in
    INFO) color="$CYAN"; lvl="INFO"; shift ;;
    WARN) color="$YELLOW"; lvl="WARN"; shift ;;
    ERROR) color="$RED"; lvl="ERROR"; shift ;;
    SUCCESS) color="$GREEN"; lvl="SUCCESS"; shift ;;
    *) color="$NC"; lvl="INFO" ;;
  esac
  printf "%b[%s] [%s] %s%b\n" "$color" "$(ts)" "$lvl" "$*" "$NC"
}

info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }
success() { log SUCCESS "✓ $*"; }

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
# UTILITY FUNCTIONS
# ============================================================================

get_load_balancer_ips() {
  info "Discovering load balancer IP addresses..."
  
  # Try to resolve DNS names to get IPs
  if command -v nslookup >/dev/null 2>&1; then
    WRITE_IP=$(nslookup "$WRITE_FQDN" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1 || echo "")
    READ_IP=$(nslookup "$READ_FQDN" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1 || echo "")
  elif command -v dig >/dev/null 2>&1; then
    WRITE_IP=$(dig +short "$WRITE_FQDN" | head -1 || echo "")
    READ_IP=$(dig +short "$READ_FQDN" | head -1 || echo "")
  else
    warn "Neither nslookup nor dig available - using Terraform output method"
    # Fallback: try to get from Terraform output if available
    if [[ -f "terraform.tfstate" ]]; then
      WRITE_IP=$(terraform output -raw pgbouncer_write_ip 2>/dev/null || echo "")
      READ_IP=$(terraform output -raw pgbouncer_read_ip 2>/dev/null || echo "")
    fi
  fi
  
  # Manual IP input if discovery fails
  if [[ -z "$WRITE_IP" ]]; then
    read -p "Enter write load balancer IP address: " WRITE_IP
  fi
  if [[ -z "$READ_IP" ]]; then
    read -p "Enter read load balancer IP address: " READ_IP
  fi
  
  info "Write endpoint: $WRITE_FQDN -> $WRITE_IP"
  info "Read endpoint: $READ_FQDN -> $READ_IP"
}

test_dns_resolution() {
  print_section "DNS Resolution Tests"
  
  local dns_tests=0
  local dns_passed=0
  
  # Test write FQDN resolution
  ((dns_tests++))
  if nslookup "$WRITE_FQDN" >/dev/null 2>&1; then
    success "Write FQDN resolves: $WRITE_FQDN"
    ((dns_passed++))
  else
    error "Write FQDN resolution failed: $WRITE_FQDN"
  fi
  
  # Test read FQDN resolution
  ((dns_tests++))
  if nslookup "$READ_FQDN" >/dev/null 2>&1; then
    success "Read FQDN resolves: $READ_FQDN"
    ((dns_passed++))
  else
    error "Read FQDN resolution failed: $READ_FQDN"
  fi
  
  info "DNS Resolution: $dns_passed/$dns_tests tests passed"
  return $((dns_tests - dns_passed))
}

test_connectivity() {
  print_section "Network Connectivity Tests"
  
  local conn_tests=0
  local conn_passed=0
  
  # Test endpoints
  local endpoints=(
    "$WRITE_FQDN:$PGBOUNCER_PORT"
    "$READ_FQDN:$PGBOUNCER_PORT"
    "$WRITE_IP:$PGBOUNCER_PORT"
    "$READ_IP:$PGBOUNCER_PORT"
  )
  
  for endpoint in "${endpoints[@]}"; do
    ((conn_tests++))
    local host=$(echo "$endpoint" | cut -d: -f1)
    local port=$(echo "$endpoint" | cut -d: -f2)
    
    if timeout 5 nc -z "$host" "$port" 2>/dev/null; then
      success "Connectivity OK: $endpoint"
      ((conn_passed++))
    else
      error "Connectivity failed: $endpoint"
    fi
  done
  
  info "Connectivity: $conn_passed/$conn_tests tests passed"
  return $((conn_tests - conn_passed))
}

test_database_connection() {
  local endpoint="$1"
  local port="$2"
  local expected_role="$3"
  local description="$4"
  
  info "Testing $description: $endpoint:$port"
  
  # Test basic connectivity
  if ! timeout 10 psql -h "$endpoint" -p "$port" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
    error "$description: Connection failed"
    return 1
  fi
  
  # Get node role
  local role_result
  role_result=$(timeout 10 psql -h "$endpoint" -p "$port" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
  
  if [[ "$role_result" == "$expected_role" ]]; then
    success "$description: Connected to $expected_role node as expected"
  else
    warn "$description: Connected to $role_result node (expected: $expected_role)"
  fi
  
  # Test read operation
  local read_test
  read_test=$(timeout 10 psql -h "$endpoint" -p "$port" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT current_timestamp;" 2>/dev/null || echo "failed")
  
  if [[ "$read_test" != "failed" ]]; then
    success "$description: Read operation successful"
  else
    error "$description: Read operation failed"
    return 1
  fi
  
  # Test write operation (only if primary)
  if [[ "$expected_role" == "primary" ]]; then
    local write_test_id=$((RANDOM % 10000))
    if timeout 10 psql -h "$endpoint" -p "$port" -U "$DB_USER" -d "$DB_NAME" -c "
      CREATE TABLE IF NOT EXISTS $TEST_TABLE (id INT, test_time TIMESTAMP, endpoint TEXT);
      INSERT INTO $TEST_TABLE VALUES ($write_test_id, current_timestamp, '$description');
    " >/dev/null 2>&1; then
      success "$description: Write operation successful (ID: $write_test_id)"
    else
      error "$description: Write operation failed"
      return 1
    fi
  fi
  
  return 0
}

test_load_balancer_endpoints() {
  print_section "Load Balancer Database Connection Tests"
  
  local lb_tests=0
  local lb_passed=0
  
  # Test write endpoint (should connect to primary)
  ((lb_tests++))
  if test_database_connection "$WRITE_FQDN" "$PGBOUNCER_PORT" "primary" "Write FQDN"; then
    ((lb_passed++))
  fi
  
  ((lb_tests++))
  if test_database_connection "$WRITE_IP" "$PGBOUNCER_PORT" "primary" "Write IP"; then
    ((lb_passed++))
  fi
  
  # Test read endpoint (could connect to either, but preferably standby)
  ((lb_tests++))
  if test_database_connection "$READ_FQDN" "$PGBOUNCER_PORT" "standby" "Read FQDN"; then
    ((lb_passed++))
  fi
  
  ((lb_tests++))
  if test_database_connection "$READ_IP" "$PGBOUNCER_PORT" "standby" "Read IP"; then
    ((lb_passed++))
  fi
  
  info "Load Balancer Tests: $lb_passed/$lb_tests tests passed"
  return $((lb_tests - lb_passed))
}

test_replication_lag() {
  print_section "Replication Lag and Consistency Tests"
  
  local repl_tests=0
  local repl_passed=0
  
  # Insert test data on write endpoint
  local test_id=$((RANDOM % 10000))
  local test_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  info "Inserting test data via write endpoint..."
  ((repl_tests++))
  if timeout 15 psql -h "$WRITE_FQDN" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
    CREATE TABLE IF NOT EXISTS $TEST_TABLE (id INT, test_time TIMESTAMP, endpoint TEXT, replication_test BOOLEAN DEFAULT TRUE);
    INSERT INTO $TEST_TABLE VALUES ($test_id, '$test_timestamp', 'replication_test', TRUE);
  " >/dev/null 2>&1; then
    success "Test data inserted successfully (ID: $test_id)"
    ((repl_passed++))
  else
    error "Failed to insert test data"
    return 1
  fi
  
  # Wait for replication
  info "Waiting 5 seconds for replication..."
  sleep 5
  
  # Check if data is replicated to read endpoint
  ((repl_tests++))
  local replicated_count
  replicated_count=$(timeout 10 psql -h "$READ_FQDN" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "
    SELECT COUNT(*) FROM $TEST_TABLE WHERE id = $test_id AND replication_test = TRUE;
  " 2>/dev/null || echo "0")
  
  if [[ "$replicated_count" == "1" ]]; then
    success "Data successfully replicated to standby (ID: $test_id found)"
    ((repl_passed++))
  else
    error "Data not found on standby after replication (expected ID: $test_id)"
  fi
  
  # Check replication lag
  ((repl_tests++))
  local lag_info
  lag_info=$(timeout 10 psql -h "$READ_FQDN" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "
    SELECT CASE WHEN pg_is_in_recovery() THEN 
      COALESCE(EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp()), 0)
      ELSE 0 END;
  " 2>/dev/null || echo "999")
  
  local lag_seconds=${lag_info%%.*}
  if [[ "$lag_seconds" -lt 60 ]]; then
    success "Replication lag acceptable: ${lag_seconds} seconds"
    ((repl_passed++))
  else
    warn "Replication lag high: ${lag_seconds} seconds"
  fi
  
  info "Replication Tests: $repl_passed/$repl_tests tests passed"
  return $((repl_tests - repl_passed))
}

test_health_endpoints() {
  print_section "Health Check Endpoint Tests"
  
  local health_tests=0
  local health_passed=0
  
  # Get backend IPs (primary and standby nodes)
  local primary_ip="192.168.14.21"  # Based on your setup
  local standby_ip="192.168.14.22"  # Based on your setup
  
  # Test PostgreSQL health endpoints
  for node_ip in "$primary_ip" "$standby_ip"; do
    ((health_tests++))
    local health_response
    health_response=$(timeout 5 curl -s "http://${node_ip}:8001" 2>/dev/null || echo "failed")
    
    if echo "$health_response" | grep -q '"status":"healthy"'; then
      success "PostgreSQL health endpoint OK: $node_ip:8001"
      ((health_passed++))
    else
      error "PostgreSQL health endpoint failed: $node_ip:8001"
    fi
    
    # Test PgBouncer health endpoints
    ((health_tests++))
    local pgb_health_response
    pgb_health_response=$(timeout 5 curl -s "http://${node_ip}:8002" 2>/dev/null || echo "failed")
    
    if echo "$pgb_health_response" | grep -q '"service":"pgbouncer"'; then
      success "PgBouncer health endpoint OK: $node_ip:8002"
      ((health_passed++))
    else
      error "PgBouncer health endpoint failed: $node_ip:8002"
    fi
  done
  
  info "Health Endpoint Tests: $health_passed/$health_tests tests passed"
  return $((health_tests - health_passed))
}

cleanup_test_data() {
  print_section "Cleanup Test Data"
  
  info "Cleaning up test data..."
  if timeout 10 psql -h "$WRITE_FQDN" -p "$PGBOUNCER_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
    DELETE FROM $TEST_TABLE WHERE endpoint LIKE '%test%' OR replication_test = TRUE;
  " >/dev/null 2>&1; then
    success "Test data cleaned up successfully"
  else
    warn "Failed to clean up test data (may not exist)"
  fi
}

generate_manual_commands() {
  print_section "Manual Validation Commands"
  
  cat << EOF

📋 MANUAL VALIDATION COMMANDS

1️⃣  DNS Resolution Tests:
   nslookup $WRITE_FQDN
   nslookup $READ_FQDN
   dig +short $WRITE_FQDN
   dig +short $READ_FQDN

2️⃣  Network Connectivity Tests:
   nc -zv $WRITE_FQDN $PGBOUNCER_PORT
   nc -zv $READ_FQDN $PGBOUNCER_PORT
   nc -zv $WRITE_IP $PGBOUNCER_PORT
   nc -zv $READ_IP $PGBOUNCER_PORT

3️⃣  Database Connection Tests:
   # Write endpoint (Primary)
   psql -h $WRITE_FQDN -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT current_timestamp, pg_is_in_recovery();"
   psql -h $WRITE_IP -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT current_timestamp, pg_is_in_recovery();"
   
   # Read endpoint (Standby preferred)
   psql -h $READ_FQDN -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT current_timestamp, pg_is_in_recovery();"
   psql -h $READ_IP -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT current_timestamp, pg_is_in_recovery();"

4️⃣  Replication Test:
   # Insert on write endpoint
   psql -h $WRITE_FQDN -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "
   CREATE TABLE IF NOT EXISTS lb_test (id SERIAL, message TEXT, created_at TIMESTAMP DEFAULT NOW());
   INSERT INTO lb_test (message) VALUES ('Load balancer test at ' || NOW());
   SELECT * FROM lb_test ORDER BY created_at DESC LIMIT 5;"
   
   # Verify on read endpoint (wait 5 seconds)
   sleep 5
   psql -h $READ_FQDN -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "
   SELECT * FROM lb_test ORDER BY created_at DESC LIMIT 5;"

5️⃣  Health Endpoint Tests:
   curl -s http://192.168.14.21:8001 | jq
   curl -s http://192.168.14.22:8001 | jq
   curl -s http://192.168.14.21:8002 | jq
   curl -s http://192.168.14.22:8002 | jq

6️⃣  Load Balancer Backend Tests:
   # Test direct backend connections
   psql -h 192.168.14.21 -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT 'Primary Backend', pg_is_in_recovery();"
   psql -h 192.168.14.22 -p $PGBOUNCER_PORT -U $DB_USER -d $DB_NAME -c "SELECT 'Standby Backend', pg_is_in_recovery();"

7️⃣  Connection String Examples:
   # Application connection strings
   Write: postgresql://$DB_USER:password@$WRITE_FQDN:$PGBOUNCER_PORT/$DB_NAME
   Read:  postgresql://$DB_USER:password@$READ_FQDN:$PGBOUNCER_PORT/$DB_NAME
   
   # Direct IP connections
   Write: postgresql://$DB_USER:password@$WRITE_IP:$PGBOUNCER_PORT/$DB_NAME
   Read:  postgresql://$DB_USER:password@$READ_IP:$PGBOUNCER_PORT/$DB_NAME

EOF
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
  print_header "PostgreSQL HA Load Balancer Validation"
  
  info "Starting load balancer validation (version $SCRIPT_VERSION)"
  info "Environment: $ENV_CODE"
  info "Organization: $ORG_CODE"
  
  # Check prerequisites
  if ! command -v psql >/dev/null 2>&1; then
    error "PostgreSQL client (psql) not found. Please install PostgreSQL client tools."
    exit 1
  fi
  
  if ! command -v curl >/dev/null 2>&1; then
    error "curl not found. Please install curl."
    exit 1
  fi
  
  # Get load balancer configuration
  get_load_balancer_ips
  
  # Initialize counters
  local total_tests=0
  local total_passed=0
  local total_failures=0
  
  # Run all tests
  test_dns_resolution || ((total_failures += $?))
  ((total_tests += 2))
  
  test_connectivity || ((total_failures += $?))
  ((total_tests += 4))
  
  test_load_balancer_endpoints || ((total_failures += $?))
  ((total_tests += 4))
  
  test_replication_lag || ((total_failures += $?))
  ((total_tests += 3))
  
  test_health_endpoints || ((total_failures += $?))
  ((total_tests += 4))
  
  # Cleanup
  cleanup_test_data
  
  # Calculate results
  total_passed=$((total_tests - total_failures))
  
  # Generate manual commands
  generate_manual_commands
  
  # Final summary
  print_section "Validation Summary"
  
  local end_time
  end_time=$(($(date +%s) - VALIDATION_START_TIME))
  
  printf "\n%b╔══════════════════════════════════════════════════════════════════════════════╗%b\n" "$BLUE" "$NC"
  printf "%b║                    LOAD BALANCER VALIDATION SUMMARY                         ║%b\n" "$BLUE" "$NC"
  printf "%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n" "$BLUE" "$NC"
  printf "%b║ Validation completed in %2d seconds                                           ║%b\n" "$BLUE" $end_time "$NC"
  
  if [[ $total_failures -eq 0 ]]; then
    printf "%b║ ✅ PASSED: %2d/%2d tests                                                     ║%b\n" "$GREEN" $total_passed $total_tests "$NC"
    printf "%b║ 🎉 EXCELLENT: Load balancer is working perfectly                            ║%b\n" "$GREEN" "$NC"
  elif [[ $total_failures -le 3 ]]; then
    printf "%b║ ⚠️  MOSTLY OK: %2d/%2d tests passed, %2d issues                              ║%b\n" "$YELLOW" $total_passed $total_tests $total_failures "$NC"
    printf "%b║ ✅ GOOD: Load balancer is operational with minor issues                     ║%b\n" "$YELLOW" "$NC"
  else
    printf "%b║ ❌ ISSUES: %2d/%2d tests passed, %2d failures                               ║%b\n" "$RED" $total_passed $total_tests $total_failures "$NC"
    printf "%b║ 🔧 NEEDS ATTENTION: Load balancer requires troubleshooting                 ║%b\n" "$RED" "$NC"
  fi
  
  printf "%b╠══════════════════════════════════════════════════════════════════════════════╣%b\n" "$BLUE" "$NC"
  printf "%b║ Write Endpoint: %-50s ║%b\n" "$BLUE" "$WRITE_FQDN ($WRITE_IP)" "$NC"
  printf "%b║ Read Endpoint:  %-50s ║%b\n" "$BLUE" "$READ_FQDN ($READ_IP)" "$NC"
  printf "%b║ Port:           %-50s ║%b\n" "$BLUE" "$PGBOUNCER_PORT" "$NC"
  printf "%b╚══════════════════════════════════════════════════════════════════════════════╝%b\n" "$BLUE" "$NC"
  
  return $total_failures
}

# Check if running as script or being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi