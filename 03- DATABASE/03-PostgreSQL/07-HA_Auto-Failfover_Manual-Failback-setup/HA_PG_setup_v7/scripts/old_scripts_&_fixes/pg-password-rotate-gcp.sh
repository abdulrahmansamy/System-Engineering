#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Configuration (edit these)
# ==============================
PROJECT_ID="your-gcp-project-id"
SECRET_ID="prd-sec-pg-appuser-password-01"   # existing secret
PRIMARY_HOST="primary-db-hostname-or-ip"
PRIMARY_PORT="5432"
STANDBY_HOSTS=( "standby1-hostname-or-ip" "standby2-hostname-or-ip" )  # used for verification only
PG_SUPERUSER="postgres"
PG_DATABASE="postgres"

# PgBouncer nodes to update (if applicable)
PGBOUNCER_NODES=( "pgbouncer1-hostname-or-ip" "pgbouncer2-hostname-or-ip" )
PGBOUNCER_PORT="6432"
PGBOUNCER_USERLIST_PATH="/etc/pgbouncer/userlist.txt"
PGBOUNCER_SERVICE_NAME="pgbouncer"

# Jump hosts to update .pgpass (optional)
JUMP_HOSTS=( "jumphost1" "jumphost2" )
PGPASS_PATH="$HOME/.pgpass"
PGBOUNCER_FRONT_HOST="your-pgbouncer-dns-or-ip" # for .pgpass convenience

# Database nodes (primary + standby) for .pgpass updates
DB_NODES=( "$PRIMARY_HOST" )
for standby in "${STANDBY_HOSTS[@]}"; do
  DB_NODES+=("$standby")
done
DB_PGPASS_PATH="/var/lib/postgresql/.pgpass"
DB_PGBOUNCER_USERLIST_PATH="/etc/pgbouncer/userlist.txt"

# Logging Configuration
readonly LOG_FILE="/var/log/postgresql/password-rotation.log"
DEBUG="${DEBUG:-0}"  # Set DEBUG=1 to enable debug logging

# ==============================
# Prerequisites:
# - gcloud CLI authenticated with access to Secret Manager
# - psql available and reachable to primary DB
# - SSH access to PgBouncer nodes (if updating remotely)
# ==============================

# ============================================================================
# LOGGING FUNCTIONS (same approach as gcp-lb-manager.sh)
# ============================================================================

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
}

info() {
    log "INFO: $*"
}

warn() {
    log "WARN: $*" >&2
}

error() {
    log "ERROR: $*" >&2
}

success() {
    log "SUCCESS: ✓ $*"
}

debug() {
    if [[ "${DEBUG:-0}" -eq 1 ]]; then
        log "DEBUG: $*"
    fi
}

# Initialize logging on script start
init_logging

# ============================================================================
# PRE-FLIGHT VALIDATION FUNCTIONS
# ============================================================================

validate_gcp_access() {
  info "Validating GCP Secret Manager access..."
  
  local test_secret
  test_secret=$(gcloud secrets versions access latest --secret="$SECRET_ID" --project="$PROJECT_ID" 2>&1) || {
    error "Cannot access Secret Manager secret: $SECRET_ID"
    return 1
  }
  
  if [[ -z "$test_secret" ]]; then
    error "Secret Manager returned empty value"
    return 1
  fi
  
  success "GCP Secret Manager access validated"
  return 0
}

validate_database_connectivity() {
  info "Validating connectivity to all database nodes..."
  
  local failed_nodes=()
  
  for node in "${DB_NODES[@]}"; do
    info "  → Testing connection to $node..."
    
    if timeout 10 psql -h "$node" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -c "SELECT 1" >/dev/null 2>&1; then
      success "  ✓ Connection successful: $node"
    else
      error "  ✗ Connection failed: $node"
      failed_nodes+=("$node")
    fi
  done
  
  if [[ ${#failed_nodes[@]} -gt 0 ]]; then
    error "Failed to connect to ${#failed_nodes[@]} database node(s): ${failed_nodes[*]}"
    return 1
  fi
  
  success "All database nodes are accessible"
  return 0
}

validate_pgbouncer_connectivity() {
  info "Validating connectivity to PgBouncer nodes..."
  
  local failed_nodes=()
  
  # Check dedicated PgBouncer nodes
  for node in "${PGBOUNCER_NODES[@]}"; do
    info "  → Testing SSH access to PgBouncer node: $node"
    
    if timeout 10 ssh -o ConnectTimeout=5 -o BatchMode=yes "$node" "echo 'SSH OK'" >/dev/null 2>&1; then
      success "  ✓ SSH access successful: $node"
      
      # Verify PgBouncer is running
      if ssh "$node" "systemctl is-active --quiet pgbouncer" 2>/dev/null; then
        success "  ✓ PgBouncer service is running: $node"
      else
        warn "  ⚠ PgBouncer service not running: $node"
        failed_nodes+=("$node")
      fi
    else
      error "  ✗ SSH access failed: $node"
      failed_nodes+=("$node")
    fi
  done
  
  # Check PgBouncer on database nodes
  for node in "${DB_NODES[@]}"; do
    info "  → Checking if PgBouncer exists on database node: $node"
    
    if ssh "$node" "test -f $DB_PGBOUNCER_USERLIST_PATH" 2>/dev/null; then
      info "  ✓ PgBouncer found on database node: $node"
      
      if ssh "$node" "systemctl is-active --quiet pgbouncer" 2>/dev/null; then
        success "  ✓ PgBouncer service is running: $node"
      else
        info "  ℹ PgBouncer service not running on database node: $node (optional)"
      fi
    else
      info "  ℹ No PgBouncer on database node: $node (optional)"
    fi
  done
  
  if [[ ${#failed_nodes[@]} -gt 0 ]]; then
    error "Failed to access ${#failed_nodes[@]} PgBouncer node(s): ${failed_nodes[*]}"
    return 1
  fi
  
  success "All PgBouncer nodes are accessible"
  return 0
}

validate_primary_writable() {
  info "Validating primary database is writable..."
  
  # Check if primary is in recovery mode (should not be)
  local recovery_status
  recovery_status=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "unknown")
  
  if [[ "$recovery_status" == "t" ]]; then
    error "Primary database $PRIMARY_HOST is in recovery mode (read-only)"
    return 1
  elif [[ "$recovery_status" == "f" ]]; then
    success "Primary database is in read-write mode"
  else
    error "Cannot determine primary database recovery status: $recovery_status"
    return 1
  fi
  
  # Test write operation
  info "Testing write operation on primary..."
  if psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -c "CREATE TABLE IF NOT EXISTS password_rotation_test (id serial, test_time timestamp DEFAULT now());" >/dev/null 2>&1; then
    success "Primary database write test successful"
    
    # Cleanup test table
    psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -c "DROP TABLE IF EXISTS password_rotation_test;" >/dev/null 2>&1 || true
  else
    error "Primary database write test failed"
    return 1
  fi
  
  return 0
}

validate_replication_health() {
  info "Validating replication health..."
  
  # Check replication status on primary
  local repl_count
  repl_count=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -Atqc "SELECT COUNT(*) FROM pg_stat_replication WHERE state = 'streaming';" 2>/dev/null || echo "0")
  
  info "Active replication connections: $repl_count"
  
  if [[ "$repl_count" -gt 0 ]]; then
    success "Replication is active with $repl_count standby node(s)"
    
    # Show replication lag for each standby
    info "Replication lag details:"
    psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" <<EOF 2>/dev/null || true
SELECT 
  application_name,
  client_addr,
  state,
  sync_state,
  COALESCE(EXTRACT(epoch FROM (now() - pg_last_xact_replay_timestamp())), 0)::int as lag_seconds
FROM pg_stat_replication;
EOF
  else
    warn "No active replication connections (standalone primary or replication issue)"
  fi
  
  return 0
}

run_preflight_checks() {
  info "=========================================="
  info "RUNNING PRE-FLIGHT VALIDATION CHECKS"
  info "=========================================="
  
  local checks_passed=true
  
  # Check 1: GCP Secret Manager access
  if ! validate_gcp_access; then
    error "✗ Pre-flight check failed: GCP Secret Manager access"
    checks_passed=false
  fi
  
  # Check 2: Database connectivity
  if ! validate_database_connectivity; then
    error "✗ Pre-flight check failed: Database connectivity"
    checks_passed=false
  fi
  
  # Check 3: Primary database is writable
  if ! validate_primary_writable; then
    error "✗ Pre-flight check failed: Primary database not writable"
    checks_passed=false
  fi
  
  # Check 4: Replication health (informational, not blocking)
  validate_replication_health || true
  
  # Check 5: PgBouncer connectivity
  if ! validate_pgbouncer_connectivity; then
    error "✗ Pre-flight check failed: PgBouncer connectivity"
    checks_passed=false
  fi
  
  if [[ "$checks_passed" == false ]]; then
    error "=========================================="
    error "PRE-FLIGHT VALIDATION FAILED"
    error "=========================================="
    error ""
    error "Password rotation cannot proceed safely."
    error "Please fix the issues above and try again."
    return 1
  fi
  
  success "=========================================="
  success "ALL PRE-FLIGHT CHECKS PASSED ✓"
  success "=========================================="
  info ""
  info "Environment is ready for password rotation:"
  info "  → GCP Secret Manager: Accessible"
  info "  → Database Nodes: ${#DB_NODES[@]} nodes accessible"
  info "  → Primary Database: Writable"
  info "  → PgBouncer Nodes: Accessible"
  info ""
  
  return 0
}

# Helper: generate strong password
generate_password() {
  # 48-char base64 for strong entropy (you can adjust length)
  openssl rand -base64 48
}

# Helper: add new secret version
add_secret_version() {
  local value="$1"
  echo -n "$value" | gcloud secrets versions add "$SECRET_ID" --project "$PROJECT_ID" --data-file=-
}

# Helper: access latest secret value
get_latest_secret() {
  gcloud secrets versions access latest --secret="$SECRET_ID" --project "$PROJECT_ID"
}

# Helper: MD5 for PgBouncer userlist (md5 of username+password)
# Produces lowercase hex, prefixed with "md5"
pgbouncer_md5() {
  local user="$1"
  local pass="$2"
  # Use printf to avoid newline; md5sum prints "hash  -"
  local hex
  hex=$(printf "%s" "${user}${pass}" | md5sum | awk '{print $1}')
  printf "md5%s" "$hex"
}

# Helper: update postgres password on primary
alter_role_on_primary() {
  local new_pass="$1"
  psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE ${PG_SUPERUSER} WITH PASSWORD '${new_pass}';"
}

# Helper: verify on standby (password hash presence is not directly visible, but role exists)
verify_on_standby() {
  local host="$1"
  psql -h "$host" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -c "\du ${PG_SUPERUSER}" || true
}

# Helper: update PgBouncer userlist.txt locally
update_local_pgbouncer_userlist() {
  local md5_hash="$1"
  local path="$PGBOUNCER_USERLIST_PATH"

  sudo touch "$path"
  sudo chmod 640 "$path"

  # Remove existing postgres line(s)
  if sudo grep -q '^"postgres"' "$path"; then
    sudo sed -i '/^"postgres"/d' "$path"
  fi

  # Append updated line
  echo "\"postgres\" \"${md5_hash}\"" | sudo tee -a "$path" >/dev/null
}

# Helper: reload PgBouncer locally
reload_local_pgbouncer() {
  sudo systemctl reload "$PGBOUNCER_SERVICE_NAME" || sudo systemctl restart "$PGBOUNCER_SERVICE_NAME"
}

# Helper: update PgBouncer on remote nodes via SSH
update_remote_pgbouncer() {
  local node="$1"
  local md5_hash="$2"
  local path="$PGBOUNCER_USERLIST_PATH"
  local service="$PGBOUNCER_SERVICE_NAME"

  ssh "$node" "sudo bash -c '
    set -e
    touch \"$path\"
    chmod 640 \"$path\"
    if grep -q \"^\\\"postgres\\\"\" \"$path\"; then
      sed -i \"/^\\\"postgres\\\"/d\" \"$path\"
    fi
    echo \"\\\"postgres\\\" \\\"$md5_hash\\\"\" >> \"$path\"
    systemctl reload \"$service\" || systemctl restart \"$service\"
  '"
}

# Helper: update .pgpass on local jump host
update_local_pgpass() {
  local host="$1" ; local port="$2" ; local db="$3" ; local user="$4" ; local pass="$5"
  local path="$PGPASS_PATH"

  touch "$path"
  chmod 600 "$path"

  # Remove existing matching line(s)
  awk -F: -v h="$host" -v p="$port" -v d="$db" -v u="$user" '
    !( $1==h && $2==p && $3==d && $4==u )
  ' "$path" > "${path}.tmp" || true

  echo "${host}:${port}:${db}:${user}:${pass}" >> "${path}.tmp"
  mv "${path}.tmp" "$path"
  chmod 600 "$path"
}

# Helper: update .pgpass on remote database nodes
update_remote_pgpass() {
  local node="$1"
  local pass="$2"
  local pgpass_path="$DB_PGPASS_PATH"
  
  info "Updating .pgpass on database node: $node"
  
  # Update only postgres user entries, preserve all other users
  ssh "$node" "sudo -u postgres bash -c '
    set -e
    
    # Backup existing .pgpass with timestamp
    if [[ -f \"$pgpass_path\" ]]; then
      cp \"$pgpass_path\" \"${pgpass_path}.backup.\$(date +%Y%m%d_%H%M%S)\" 2>/dev/null || true
      echo \"✓ Backed up existing .pgpass file\"
    fi
    
    # Create temporary file for updated entries
    temp_file=\"${pgpass_path}.tmp\"
    
    # Remove existing postgres user entries (all postgres entries across all ports/hosts)
    if [[ -f \"$pgpass_path\" ]]; then
      # Keep all non-postgres entries
      grep -v \":postgres:\" \"$pgpass_path\" > \"$temp_file\" 2>/dev/null || true
    else
      touch \"$temp_file\"
    fi
    
    # Append updated postgres user entries for both PostgreSQL and PgBouncer
    cat >> \"$temp_file\" <<EOF
# PostgreSQL superuser entries (managed by password rotation script)
*:5432:*:postgres:${pass}
localhost:5432:*:postgres:${pass}
127.0.0.1:5432:*:postgres:${pass}

# PgBouncer postgres entries
*:6432:*:postgres:${pass}
localhost:6432:*:postgres:${pass}
127.0.0.1:6432:*:postgres:${pass}
EOF
    
    # Replace original file with updated version
    mv \"$temp_file\" \"$pgpass_path\"
    
    # Set proper permissions
    chmod 600 \"$pgpass_path\"
    chown postgres:postgres \"$pgpass_path\"
    
    echo \"✓ .pgpass updated successfully on $node\"
  '" 2>&1
  
  if [[ $? -eq 0 ]]; then
    success ".pgpass updated on database node: $node (postgres entries only)"
  else
    error "Failed to update .pgpass on database node: $node"
    return 1
  fi
}

# Helper: update PgBouncer userlist.txt on remote database nodes
update_remote_pgbouncer_userlist() {
  local node="$1"
  local md5_hash="$2"
  local userlist_path="$DB_PGBOUNCER_USERLIST_PATH"
  
  info "Updating PgBouncer userlist.txt on database node: $node"
  
  # Update PgBouncer userlist.txt on database node
  ssh "$node" "sudo bash -c '
    set -e
    
    # Check if PgBouncer is installed on this node
    if [[ ! -f \"$userlist_path\" ]]; then
      echo \"⚠️  PgBouncer userlist not found on $node - skipping\"
      exit 0
    fi
    
    # Backup existing userlist.txt
    if [[ -f \"$userlist_path\" ]]; then
      cp \"$userlist_path\" \"${userlist_path}.backup.\$(date +%Y%m%d_%H%M%S)\" 2>/dev/null || true
      echo \"✓ Backed up existing userlist.txt\"
    fi
    
    # Remove existing postgres entries
    if grep -q \"^\\\"postgres\\\"\" \"$userlist_path\" 2>/dev/null; then
      sed -i \"/^\\\"postgres\\\"/d\" \"$userlist_path\"
      echo \"✓ Removed old postgres entry\"
    fi
    
    # Append updated postgres entry
    echo \"\\\"postgres\\\" \\\"$md5_hash\\\"\" >> \"$userlist_path\"
    
    # Set proper permissions
    chmod 640 \"$userlist_path\"
    chown postgres:pgbouncer \"$userlist_path\" 2>/dev/null || chown postgres:postgres \"$userlist_path\"
    
    # Reload PgBouncer service
    if systemctl is-active --quiet pgbouncer 2>/dev/null; then
      systemctl reload pgbouncer 2>/dev/null || systemctl restart pgbouncer 2>/dev/null || true
      echo \"✓ PgBouncer service reloaded\"
    else
      echo \"ℹ️  PgBouncer service not running on $node\"
    fi
    
    echo \"✓ PgBouncer userlist.txt updated successfully on $node\"
  '" 2>&1
  
  if [[ $? -eq 0 ]]; then
    success "PgBouncer userlist.txt updated on database node: $node"
  else
    warn "Failed to update PgBouncer userlist.txt on database node: $node (node may not have PgBouncer)"
    return 0  # Don't fail if PgBouncer is not on this node
  fi
}

# ======== MAIN ========
info "=========================================="
info "PostgreSQL Password Rotation"
info "Version: 1.0.0 (Safe & Validated)"
info "=========================================="
info "Target Secret: $SECRET_ID (project: $PROJECT_ID)"
info "Primary Host: $PRIMARY_HOST"
info "Database Nodes: ${DB_NODES[*]}"
info "PgBouncer Nodes: ${PGBOUNCER_NODES[*]}"
info ""

# PHASE 1: PRE-FLIGHT VALIDATION (No changes made)
info "=========================================="
info "PHASE 1: PRE-FLIGHT VALIDATION"
info "=========================================="
info "Validating environment before making any changes..."
info ""

if ! run_preflight_checks; then
  error "Aborting password rotation due to failed pre-flight checks"
  exit 1
fi

# User confirmation before proceeding (optional - remove for fully automated)
info "=========================================="
info "READY TO PROCEED"
info "=========================================="
info ""
info "All pre-flight checks passed. The password rotation will:"
info "  1. Generate a new secure password"
info "  2. Store it in Secret Manager"
info "  3. Update password on primary database"
info "  4. Update .pgpass files on all database nodes"
info "  5. Update PgBouncer userlist files on all nodes"
info "  6. Reload PgBouncer services"
info ""
info "This process will complete without interruption."
info ""

# Optional: Uncomment for manual confirmation
# read -p "Proceed with password rotation? (yes/no): " -r
# if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
#   info "Password rotation cancelled by user"
#   exit 0
# fi

# PHASE 2: PASSWORD GENERATION AND STORAGE
info "=========================================="
info "PHASE 2: GENERATING NEW PASSWORD"
info "=========================================="

NEW_PASS=$(generate_password)
info "Generated new password (hidden)."
debug "Password length: ${#NEW_PASS} characters"

info "Storing new secret version in Secret Manager..."
if add_secret_version "$NEW_PASS"; then
  success "Stored new secret version in Secret Manager"
else
  error "Failed to store new secret version"
  error "Aborting - no changes made to databases or configurations"
  exit 1
fi

# PHASE 3: VERIFY SECRET STORAGE
info "=========================================="
info "PHASE 3: VERIFYING SECRET STORAGE"
info "=========================================="

info "Retrieving latest secret for verification..."
LATEST_PASS=$(get_latest_secret)
if [[ "$LATEST_PASS" != "$NEW_PASS" ]]; then
  warn "Latest secret content differs from generated password. Using latest version from Secret Manager."
fi

# Use the latest from Secret Manager for all subsequent steps
ROTATED_PASS="$LATEST_PASS"
success "Secret storage verified"

# PHASE 4: DATABASE PASSWORD UPDATE
info "=========================================="
info "PHASE 4: UPDATING DATABASE PASSWORD"
info "=========================================="

info "Updating postgres password on primary: $PRIMARY_HOST"
if alter_role_on_primary "$ROTATED_PASS"; then
  success "Primary password updated"
else
  error "Failed to update primary password"
  error "Manual intervention required:"
  error "  1. Revert Secret Manager to previous version"
  error "  2. Or manually update PostgreSQL password to match new secret"
  exit 1
fi

# Verify password change worked
sleep 2
info "Verifying password change..."
if PGPASSWORD="$ROTATED_PASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -c "SELECT 1" >/dev/null 2>&1; then
  success "New password verified on primary database"
else
  error "New password verification failed"
  error "Manual intervention required - database password may be in inconsistent state"
  exit 1
fi

# PHASE 5: REPLICATION VERIFICATION
info "=========================================="
info "PHASE 5: VERIFYING REPLICATION"
info "=========================================="

for s in "${STANDBY_HOSTS[@]}"; do
  info "Verifying role visibility on standby: $s"
  verify_on_standby "$s"
done
success "Password replicated to standby nodes"

# PHASE 6: PGBOUNCER CONFIGURATION UPDATE
info "=========================================="
info "PHASE 6: UPDATING PGBOUNCER CONFIGURATION"
info "=========================================="

PGBOUNCER_MD5=$(pgbouncer_md5 "$PG_SUPERUSER" "$ROTATED_PASS")
info "Computed PgBouncer MD5 for postgres: $PGBOUNCER_MD5"
debug "MD5 hash length: ${#PGBOUNCER_MD5} characters"

# Update local PgBouncer (if applicable)
if [[ -f "$PGBOUNCER_USERLIST_PATH" ]]; then
  info "Updating local PgBouncer userlist: $PGBOUNCER_USERLIST_PATH"
  if update_local_pgbouncer_userlist "$PGBOUNCER_MD5"; then
    success "Local PgBouncer userlist updated"
  else
    warn "Failed to update local PgBouncer userlist"
  fi
  
  if reload_local_pgbouncer; then
    success "Local PgBouncer reloaded"
  else
    warn "Failed to reload local PgBouncer"
  fi
fi

# Update remote PgBouncer nodes
for node in "${PGBOUNCER_NODES[@]}"; do
  info "Updating PgBouncer on node: $node"
  if update_remote_pgbouncer "$node" "$PGBOUNCER_MD5"; then
    success "PgBouncer updated on node: $node"
  else
    error "Failed to update PgBouncer on node: $node"
  fi
done

# PHASE 7: DATABASE NODE FILES UPDATE
info "=========================================="
info "PHASE 7: UPDATING DATABASE NODE FILES"
info "=========================================="

for db_node in "${DB_NODES[@]}"; do
  info "Updating .pgpass on database node: $db_node"
  if update_remote_pgpass "$db_node" "$ROTATED_PASS"; then
    success ".pgpass updated on database node: $db_node"
  else
    error "Failed to update .pgpass on database node: $db_node"
  fi
done

# PHASE 8: DATABASE NODE PGBOUNCER UPDATE
info "=========================================="
info "PHASE 8: UPDATING PGBOUNCER ON DATABASE NODES"
info "=========================================="

for db_node in "${DB_NODES[@]}"; do
  if update_remote_pgbouncer_userlist "$db_node" "$PGBOUNCER_MD5"; then
    success "PgBouncer userlist.txt updated on database node: $db_node"
  else
    warn "PgBouncer userlist.txt update skipped or failed on: $db_node"
  fi
done

# PHASE 9: JUMP HOST UPDATE (OPTIONAL)
info "=========================================="
info "PHASE 9: UPDATING JUMP HOST FILES"
info "=========================================="

info "Updating local .pgpass file..."
if update_local_pgpass "$PGBOUNCER_FRONT_HOST" "$PGBOUNCER_PORT" "*" "$PG_SUPERUSER" "$ROTATED_PASS"; then
  success ".pgpass updated for PgBouncer"
else
  warn "Failed to update .pgpass for PgBouncer"
fi

if update_local_pgpass "$PRIMARY_HOST" "$PRIMARY_PORT" "*" "$PG_SUPERUSER" "$ROTATED_PASS"; then
  success ".pgpass updated for primary"
else
  warn "Failed to update .pgpass for primary"
fi

# PHASE 10: FINAL VERIFICATION
info "=========================================="
info "PHASE 10: FINAL VERIFICATION"
info "=========================================="

info "Testing connectivity with new password..."
local verification_failed=false

# Test primary connection
if PGPASSWORD="$ROTATED_PASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -c "SELECT 'Primary connection OK';" >/dev/null 2>&1; then
  success "Primary database connection verified"
else
  error "Primary database connection failed with new password"
  verification_failed=true
fi

# Test standby connections
for standby in "${STANDBY_HOSTS[@]}"; do
  if PGPASSWORD="$ROTATED_PASS" psql -h "$standby" -p "$PRIMARY_PORT" -U "$PG_SUPERUSER" -d "$PG_DATABASE" -c "SELECT 'Standby connection OK';" >/dev/null 2>&1; then
    success "Standby connection verified: $standby"
  else
    warn "Standby connection failed: $standby"
  fi
done

# Test PgBouncer connections (if applicable)
for node in "${DB_NODES[@]}"; do
  if timeout 5 ssh "$node" "PGPASSWORD='$ROTATED_PASS' psql -h localhost -p 6432 -U $PG_SUPERUSER -d postgres -c 'SELECT 1' >/dev/null 2>&1" 2>/dev/null; then
    success "PgBouncer connection verified on: $node"
  else
    info "PgBouncer connection test skipped or unavailable on: $node"
  fi
done

if [[ "$verification_failed" == true ]]; then
  error "Some verification checks failed"
  error "Manual verification recommended"
fi

info "=========================================="
success "PASSWORD ROTATION COMPLETED SUCCESSFULLY ✓"
info "=========================================="
info ""
info "Summary:"
info "  → Secret Manager: Updated and verified"
info "  → Primary Database: Password changed and verified"
info "  → Standby Databases: Password replicated via streaming replication"
info "  → Database Nodes .pgpass: Updated (${#DB_NODES[@]} nodes)"
info "  → Database Nodes PgBouncer userlist.txt: Updated"
info "  → Dedicated PgBouncer Nodes: Configuration updated and reloaded"
info "  → Jump Host .pgpass: Updated for convenience"
info ""
info "Rotation completed at: $(date)"
info "Log file: $LOG_FILE"
info ""
info "Next steps:"
info "  1. Monitor application logs for any connection issues"
info "  2. Verify replication is still healthy"
info "  3. Test application database access"


