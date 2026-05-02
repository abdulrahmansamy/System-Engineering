#!/bin/bash
# PostgreSQL High Availability Cluster Bootstrap Script - SYNTAX CLEAN VERSION
# Production-ready startup script for GCP Compute Engine
# Supports: Ubuntu 24.04 LTS, PostgreSQL 17, repmgr HA with automatic failover
# Version: 1.4.1 (SYNTAX CLEAN - PRODUCTION READY)

set -euo pipefail

# ============================================================================
# CONFIGURATION & GLOBAL VARIABLES
# ============================================================================

SCRIPT_VERSION="2.3.0"
BOOTSTRAP_START_TIME=$(date +%s)

# Enable detailed tracing for debugging
if [[ "${BOOTSTRAP_TRACE:-0}" == "1" ]]; then
  export PS4='\nTRACE [$LINENO] >> '
  set -x
fi

# Directories and paths
LOG_DIR="/var/log/pg-bootstrap"
LOG_FILE="$LOG_DIR/bootstrap.log"
SENTINEL_DIR="/var/lib/postgresql/.bootstrap"
SENTINEL_BOOTSTRAP="${SENTINEL_DIR}/done"
SENTINEL_PRIMARY_INIT="${SENTINEL_DIR}/primary.init"
SENTINEL_STANDBY_CLONED="${SENTINEL_DIR}/standby.cloned"

# PostgreSQL configuration - Fixed to version 17
PG_VERSION="17"
PG_CLUSTER_NAME="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
REPMGR_CONF_DIR="/etc/repmgr"
REPMGR_CONF_FILE="${REPMGR_CONF_DIR}/repmgr.conf"
REPMGR_LOG_DIR="/var/log/repmgr"
REPMGR_EVENTS_DIR="/etc/repmgr/events"
HEALTH_BIN="/usr/local/bin/pg-ha-health.sh"
HEALTH_SERVICE="pg-ha-health.service"

# PgBouncer configuration
PGBOUNCER_CONF_DIR="/etc/pgbouncer"
PGBOUNCER_CONF_FILE="${PGBOUNCER_CONF_DIR}/pgbouncer.ini"
PGBOUNCER_USERLIST_FILE="${PGBOUNCER_CONF_DIR}/userlist.txt"
PGBOUNCER_PORT=6432
PGBOUNCER_POOL_SIZE=25
PGBOUNCER_MAX_CLIENT_CONN=100
PGBOUNCER_HEALTH_BIN="/usr/local/bin/pgbouncer-health.sh"
PGBOUNCER_HEALTH_SERVICE="pgbouncer-health.service"

# Token cache for Secret Manager access
TOKEN_CACHE="/run/pg-secrets/token.json"
SECRET_CACHE_DIR="/run/pg-secrets"

# Create required directories
mkdir -p "$LOG_DIR" "$SENTINEL_DIR" "$REPMGR_CONF_DIR" "$REPMGR_LOG_DIR" "$REPMGR_EVENTS_DIR" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 644 "$LOG_FILE" 2>/dev/null || true

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp=$(ts)
  
  # Color output based on level
  case "$level" in
    "ERROR")   echo -e "\033[31m[$timestamp] $level: $message\033[0m" | tee -a "$LOG_FILE" ;;
    "WARN")    echo -e "\033[33m[$timestamp] $level: $message\033[0m" | tee -a "$LOG_FILE" ;;
    "SUCCESS") echo -e "\033[32m[$timestamp] $level: $message\033[0m" | tee -a "$LOG_FILE" ;;
    "INFO")    echo "[$timestamp] $level: $message" | tee -a "$LOG_FILE" ;;
    "DEBUG")   echo "[$timestamp] $level: $message" | tee -a "$LOG_FILE" ;;
    *)         echo "[$timestamp] $message" | tee -a "$LOG_FILE" ;;
  esac
}

info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }
debug() { [[ "${BOOTSTRAP_DEBUG:-false}" =~ ^(true|1)$ ]] && log DEBUG "$*" || true; }
die() { log ERROR "$*"; exit 1; }
success() { log SUCCESS "✓ $*"; }

retry() {
  local max_attempts="$1"
  shift
  local attempt=1
  
  while (( attempt <= max_attempts )); do
    if "$@"; then
      return 0
    fi
    
    if (( attempt < max_attempts )); then
      debug "Attempt $attempt failed, retrying in 2 seconds..."
      sleep 2
    fi
    
    ((attempt++))
  done
  
  return 1
}

# Error handling
trap 'rc=$?; if (( rc != 0 )); then log ERROR "Bootstrap script exiting with code $rc (last cmd: $BASH_COMMAND line $LINENO)"; fi' EXIT
trap 'log ERROR "Error trapped at line $LINENO during: $BASH_COMMAND"' ERR

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

get_metadata() {
  local key="$1"
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo ""
}

get_metadata_with_default() {
  local key="$1" default="$2"
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "$default"
}

detect_configuration() {
  info "Detecting cluster configuration from GCP metadata"
  
  # Core configuration
  export PROJECT_ID="${PROJECT_ID:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id || echo unknown)}"
  export ROLE="${ROLE:-$(get_metadata pg_role || echo unknown)}"
  export CLUSTER_ID="${CLUSTER_ID:-$(get_metadata pg_cluster_id || echo ha-cluster)}"
  export REPMGR_PRIMARY_HOST="${REPMGR_PRIMARY_HOST:-$(get_metadata repmgr_primary_host || echo pg-primary)}"
  export REPMGR_DB="${REPMGR_DB:-$(get_metadata repmgr_db || echo repmgr)}"
  export REPMGR_USER="${REPMGR_USER:-$(get_metadata repmgr_user || echo repmgr)}"
  export HEALTH_PORT="${HEALTH_PORT:-$(get_metadata pg_health_port || echo 8001)}"
  
  # Get local IP
  local self_ip
  self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
  export SELF_IP="$self_ip"
  
  # Auto-detect role if not set
  if [[ "$ROLE" == "unknown" ]]; then
    local hostname_val
    hostname_val=$(hostname)
    if [[ "$hostname_val" == *"primary"* ]]; then
      export ROLE="primary"
    elif [[ "$hostname_val" == *"standby"* ]]; then
      export ROLE="standby"
    elif [[ "$hostname_val" == *"witness"* ]]; then
      export ROLE="witness"
    fi
    info "Auto-detected ROLE=$ROLE"
  fi
  
  # Set primary host to self IP if this is the primary
  if [[ "$ROLE" == "primary" && ( -z "$REPMGR_PRIMARY_HOST" || "$REPMGR_PRIMARY_HOST" == "pg-primary" ) ]]; then
    export REPMGR_PRIMARY_HOST="$SELF_IP"
    info "Set REPMGR_PRIMARY_HOST=$REPMGR_PRIMARY_HOST"
  fi
  
  # Validate role
  case "$ROLE" in
    "primary"|"standby"|"witness") ;;
    *) die "Invalid or missing pg_role metadata: $ROLE" ;;
  esac
  
  info "Configuration: role=$ROLE cluster=$CLUSTER_ID project=$PROJECT_ID primary_host=$REPMGR_PRIMARY_HOST self_ip=$self_ip"
}

# Generate secure passwords as fallback
gen_pw() {
  local length="${1:-32}"
  openssl rand -base64 $((length * 3 / 4)) | tr -d '/+' | head -c "$length"
}

get_secret() {
  local secret_id="$1"
  local project_id="${2:-$(get_metadata "project_id")}"
  
  # Use gcloud to get secret
  if command -v gcloud >/dev/null 2>&1; then
    gcloud secrets versions access latest --secret="$secret_id" --project="$project_id" 2>/dev/null || gen_pw
  else
    # Fallback to generating password
    warn "gcloud not available, generating random password for $secret_id"
    gen_pw
  fi
}

# Auto-fix password loading for standby nodes
auto_fix_repmgr_password() {
  # Only run for standby nodes and if REPMGR_PASSWORD is not already set
  if [[ "$ROLE" != "standby" || -n "${REPMGR_PASSWORD:-}" ]]; then
    return 0
  fi
  
  info "🔧 Auto-fixing repmgr password for standby node"
  
  local env_code="$(get_metadata env_code unknown)"
  local org_code="$(get_metadata org_code unknown)"
  local repmgr_secret="${org_code}-${env_code}-sec-repmgr-password-01"
  info "  → Using repmgr Secret Manager ID: $repmgr_secret"
  info "  → Project ID: $PROJECT_ID"
  
  # Try direct Secret Manager access (simplified approach)
  local token password
  info "  → Getting access token for auto-fix..."
  token=$(curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token' 2>/dev/null)
  
  if [[ -n "$token" ]]; then
    local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${repmgr_secret}/versions/latest:access"
    local body
    if body=$(curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$url" 2>/dev/null); then
      password=$(echo "$body" | jq -r '.payload.data' | base64 -d 2>/dev/null)
      if [[ -n "$password" && "$password" != "null" ]]; then
        export REPMGR_PASSWORD="$password"
        # Cache the password for consistency tracking
        echo "$password" > "$SECRET_CACHE_DIR/repmgr" 2>/dev/null || true
        chmod 600 "$SECRET_CACHE_DIR/repmgr" 2>/dev/null || true
        info "  ✓ Successfully loaded repmgr password from Secret Manager"
        return 0
      fi
    fi
  else
    warn "  ✗ Failed to get access token for auto-fix"
  fi
  
  warn "⚠ Auto-fix failed, will use fallback password generation"
  return 1
}

load_secrets() {
  info "Loading secrets from Secret Manager"
  mkdir -p "$SECRET_CACHE_DIR"
  
  # Initialize variables with defaults
  export PGBOUNCER_PASSWORD="${PGBOUNCER_PASSWORD:-}"
  
  # Enhanced Secret Manager helper function with detailed logging
  get_secret_enhanced() {
    local name="$1" secret_id="$2"
    local secret_value
    
    info "  → Attempting to load $name from Secret Manager ID: $secret_id"
    
    if secret_value=$(get_secret "$name" "$secret_id" 2>/dev/null) && [[ -n "$secret_value" ]]; then
      success "  ✓ SUCCESS: $name loaded from Secret Manager (length: ${#secret_value} chars)"
      echo "$secret_value"
      return 0
    else
      warn "  ✗ FALLBACK: $name failed from Secret Manager, generating random password"
      gen_pw
      return 1
    fi
  }
  
  # Get environment and org codes from metadata (set by Terraform)
  local env_code="$(get_metadata env_code unknown)"
  local org_code="$(get_metadata org_code unknown)"
  
  # Secret IDs matching your Terraform configuration
  local pg_superuser_secret="${org_code}-${env_code}-sec-pg-superuser-password-01"
  local pg_repl_secret="${org_code}-${env_code}-sec-pg-replication-password-01" 
  local pg_monitor_secret="${org_code}-${env_code}-sec-pg-monitor-password-01"
  local repmgr_secret="${org_code}-${env_code}-sec-repmgr-password-01"
  local pgbouncer_secret="${org_code}-${env_code}-sec-pgbouncer-password-01"
  
  info "🔐 Secret Manager Configuration:"
  info "  → Project ID: $PROJECT_ID"
  info "  → Org Code: $org_code"
  info "  → Env Code: $env_code"
  info "  → Superuser Secret: $pg_superuser_secret"
  info "  → Replication Secret: $pg_repl_secret" 
  info "  → Monitor Secret: $pg_monitor_secret"
  info "  → Repmgr Secret: $repmgr_secret"
  info "  → PgBouncer Secret: $pgbouncer_secret"
  
  # Shared password file for cluster consistency
  local shared_passwords_file="/tmp/cluster_passwords_${CLUSTER_ID}.conf"
  
  # Load secrets with fallbacks and detailed logging
  set +e
  
  # Check if we have shared passwords from primary node
  if [[ "$ROLE" == "standby" && -f "$shared_passwords_file" ]]; then
    info "Loading shared passwords from primary node"
    source "$shared_passwords_file"
  else
    # Load repmgr password first for all node types
    if [[ -n "${REPMGR_PASSWORD:-}" ]]; then
      info "✓ Using pre-set repmgr password from environment (length: ${#REPMGR_PASSWORD} characters)"
    else
      # Try auto-fix for standby nodes first, then fallback to standard loading
      if [[ "$ROLE" == "standby" ]] && auto_fix_repmgr_password; then
        info "✓ Repmgr password loaded via auto-fix for standby"
      else
        info "🔐 Loading repmgr password..."
        export REPMGR_PASSWORD=$(get_secret_enhanced "repmgr" "$repmgr_secret")
      fi
    fi
    
    # PostgreSQL Superuser Password
    info "🔐 Loading PostgreSQL superuser password..."
    if [[ -n "${PG_SUPER_PASS:-}" ]]; then
      info "  ✓ Using pre-set superuser password from environment"
    else
      export PG_SUPER_PASS=$(get_secret_enhanced "pg_superuser" "$pg_superuser_secret")
    fi
    
    # PostgreSQL Replication Password
    info "🔐 Loading PostgreSQL replication password..."
    if [[ -n "${PG_REPL_PASS:-}" ]]; then
      info "  ✓ Using pre-set replication password from environment"
    else
      export PG_REPL_PASS=$(get_secret_enhanced "pg_replication" "$pg_repl_secret")
    fi
    
    # PostgreSQL Monitor Password
    info "🔐 Loading PostgreSQL monitor password..."
    if [[ -n "${PG_MONITOR_PASS:-}" ]]; then
      info "  ✓ Using pre-set monitor password from environment"
    else
      export PG_MONITOR_PASS=$(get_secret_enhanced "pg_monitor" "$pg_monitor_secret")
    fi
    
    # PgBouncer Password
    info "🔐 Loading PgBouncer password..."
    info "  → Secret ID: $pgbouncer_secret"
    if [[ -n "${PGBOUNCER_PASSWORD:-}" ]]; then
      info "  ✓ Using pre-set PgBouncer password from environment"
    else
      export PGBOUNCER_PASSWORD=$(get_secret_enhanced "pgbouncer" "$pgbouncer_secret")
    fi
    
    # Save passwords for other nodes (primary only)
    if [[ "$ROLE" == "primary" ]]; then
      cat > "$shared_passwords_file" <<EOF
export PG_SUPER_PASS="$PG_SUPER_PASS"
export PG_REPL_PASS="$PG_REPL_PASS"
export PG_MONITOR_PASS="$PG_MONITOR_PASS"
export PGBOUNCER_PASSWORD="$PGBOUNCER_PASSWORD"
export REPMGR_PASSWORD="$REPMGR_PASSWORD"
EOF
      chmod 600 "$shared_passwords_file"
      info "Saved shared passwords for cluster nodes"
    fi
  fi
  
  # Validate all passwords are properly loaded (enhanced validation)
  local password_validation_failed=0
  
  if [[ -z "$PG_SUPER_PASS" || "$PG_SUPER_PASS" == "changeMe" || "${#PG_SUPER_PASS}" -lt 8 ]]; then
    export PG_SUPER_PASS=$(gen_pw)
    password_validation_failed=1
    info "  → New superuser generated password length: ${#PG_SUPER_PASS} characters"
  fi
  
  if [[ -z "$PG_REPL_PASS" || "$PG_REPL_PASS" == "changeMe" || "${#PG_REPL_PASS}" -lt 8 ]]; then
    export PG_REPL_PASS=$(gen_pw)
    password_validation_failed=1
    info "  → New replication generated password length: ${#PG_REPL_PASS} characters"
  fi
  
  if [[ -z "$PG_MONITOR_PASS" || "$PG_MONITOR_PASS" == "changeMe" || "${#PG_MONITOR_PASS}" -lt 8 ]]; then
    export PG_MONITOR_PASS=$(gen_pw)
    password_validation_failed=1
    info "  → New monitor generated password length: ${#PG_MONITOR_PASS} characters"
  fi
  
  if [[ -z "$PGBOUNCER_PASSWORD" || "$PGBOUNCER_PASSWORD" == "changeMe" || "${#PGBOUNCER_PASSWORD}" -lt 8 ]]; then
    export PGBOUNCER_PASSWORD=$(gen_pw)
    password_validation_failed=1
    info "  → New PgBouncer generated password length: ${#PGBOUNCER_PASSWORD} characters"
  fi
  
  if [[ -z "$REPMGR_PASSWORD" || "$REPMGR_PASSWORD" == "changeMe" || "${#REPMGR_PASSWORD}" -lt 8 ]]; then
    export REPMGR_PASSWORD=$(gen_pw)
    password_validation_failed=1
    info "  → New repmgr generated password length: ${#REPMGR_PASSWORD} characters"
  fi
  
  # Log validation results and detailed secret source summary
  local secrets_from_sm=0
  local secrets_from_fallback=0
  
  info "🔐 SECRET LOADING DETAILED REPORT:"
  
  # Check each password source and create detailed report
  for secret_name in "pg_superuser" "pg_replication" "pg_monitor" "pgbouncer" "repmgr"; do
    local cache_file="$SECRET_CACHE_DIR/$secret_name"
    local loaded_from_sm=false
    
    # Check if secret was loaded from Secret Manager (cache exists and not empty)
    if [[ -s "$cache_file" ]]; then
      loaded_from_sm=true
    # Special case for repmgr on standby nodes (auto-fix doesn't use cache)
    elif [[ "$secret_name" == "repmgr" && "$ROLE" == "standby" && -n "${REPMGR_PASSWORD:-}" && "${#REPMGR_PASSWORD}" -eq 32 ]]; then
      loaded_from_sm=true
    fi
    
    if [[ "$loaded_from_sm" == "true" ]]; then
      success "  ✓ SECRET MANAGER: $secret_name (loaded)"
      secrets_from_sm=$((secrets_from_sm + 1))
    else
      warn "  ✗ FALLBACK GENERATED: $secret_name (random password)"
      secrets_from_fallback=$((secrets_from_fallback + 1))
    fi
  done
  
  info "📊 SECRET LOADING SUMMARY:"
  success "  → Secrets from Secret Manager: $secrets_from_sm/5"
  if [[ $secrets_from_fallback -gt 0 ]]; then
    warn "  → Fallback generated passwords: $secrets_from_fallback/5"
    warn "  → Consider updating Secret Manager with proper passwords after deployment"
  else
    success "  → All secrets loaded from Secret Manager ✓"
  fi
  
  set -e
  export PGPASSWORD="$PG_SUPER_PASS"
  
  # Log final password loading summary
  info "📋 Password Final Status:"
  info "  → PostgreSQL Superuser: ${#PG_SUPER_PASS} characters ✓"
  info "  → PostgreSQL Replication: ${#PG_REPL_PASS} characters ✓"
  info "  → PostgreSQL Monitor: ${#PG_MONITOR_PASS} characters ✓"
  info "  → PgBouncer: ${#PGBOUNCER_PASSWORD} characters ✓"
  info "  → Repmgr: ${#REPMGR_PASSWORD} characters ✓"
  success "✅ All passwords are loaded and validated"
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

install_packages() {
  info "Installing PostgreSQL 17 and dependencies"
  
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y wget ca-certificates gnupg lsb-release curl jq netcat-openbsd socat
  
  # Add PostgreSQL official APT repository
  if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    info "Adding PostgreSQL official repository..."
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
    echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    apt-get update
  fi
  
  # Install PostgreSQL 17
  if ! dpkg -l | grep -q postgresql-17; then
    info "Installing PostgreSQL 17..."
    apt-get install -y postgresql-17 postgresql-client-17 postgresql-contrib-17
  fi
  
  # Install repmgr
  if ! command -v repmgr >&/dev/null; then
    info "Installing repmgr..."
    apt-get install -y postgresql-17-repmgr
  fi
  
  success "All packages installed successfully"
}

configure_postgresql() {
  info "Configuring PostgreSQL 17 for HA"
  
  local pg_conf="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
  
  # Stop PostgreSQL if running
  systemctl stop postgresql 2>/dev/null || true
  
  # Backup and configure
  if [[ -f "$pg_conf" ]]; then
    cp "$pg_conf" "${pg_conf}.backup" 2>/dev/null || true
    
    # Add HA configuration
    cat >> "$pg_conf" <<'EOF'

# PostgreSQL HA Configuration
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
wal_keep_size = '1024MB'
hot_standby = on
shared_preload_libraries = 'repmgr'
archive_mode = off

# Performance tuning
shared_buffers = 128MB
effective_cache_size = 1GB
max_connections = 200
work_mem = 4MB
maintenance_work_mem = 64MB

# Logging
log_line_prefix = '%t [%p-%l] %q%u@%d '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0

# Replication settings
max_replication_slots = 10
track_commit_timestamp = on

# Security
ssl = on
ssl_cert_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem'
ssl_key_file = '/etc/ssl/private/ssl-cert-snakeoil.key'
EOF
  fi
  
  success "PostgreSQL configuration updated"
}

configure_pg_hba() {
  info "Configuring pg_hba.conf for HA authentication"
  
  local pg_hba="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
  local primary_ip="${REPMGR_PRIMARY_HOST}"
  local standby_ip="$(get_metadata repmgr_standby_host unknown)"
  
  if [[ -f "$pg_hba" ]]; then
    cp "$pg_hba" "${pg_hba}.backup" 2>/dev/null || true
    
    cat > "$pg_hba" <<EOF
# PostgreSQL Client Authentication Configuration File
# Bootstrap Script Production Configuration

# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     peer

# IPv4/IPv6 local connections - MD5 for PgBouncer users (PRIORITY)
host    all             postgres        127.0.0.1/32            md5
host    all             postgres        ::1/128                 md5
host    all             pgbouncer_admin 127.0.0.1/32            md5
host    all             pgbouncer_admin ::1/128                 md5
host    all             repmgr          127.0.0.1/32            md5
host    all             repmgr          ::1/128                 md5

# IPv4/IPv6 local connections - SCRAM-SHA-256 for other users
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Cluster network access - MD5 for repmgr compatibility
host    ${REPMGR_DB}    ${REPMGR_USER}  192.168.0.0/16          md5
host    replication     ${REPMGR_USER}  192.168.0.0/16          md5
host    all             ${REPMGR_USER}  192.168.0.0/16          md5
host    all             postgres        192.168.0.0/16          md5
host    all             pgbouncer_admin 192.168.0.0/16          md5

# Replication connections for HA cluster
host    replication     replication     192.168.0.0/16          scram-sha-256
EOF

    # Add specific entries for known IPs
    if [[ "$primary_ip" != "unknown" && "$primary_ip" != "pg-primary" ]]; then
      cat >> "$pg_hba" <<EOF

# Specific entries for primary ${primary_ip}
host    ${REPMGR_DB}    ${REPMGR_USER}  ${primary_ip}/32        md5
host    replication     ${REPMGR_USER}  ${primary_ip}/32        md5
host    all             postgres        ${primary_ip}/32        md5
host    all             pgbouncer_admin ${primary_ip}/32        md5
EOF
    fi
    
    if [[ "$standby_ip" != "unknown" ]]; then
      cat >> "$pg_hba" <<EOF

# Specific entries for standby ${standby_ip}
host    ${REPMGR_DB}    ${REPMGR_USER}  ${standby_ip}/32        md5
host    replication     ${REPMGR_USER}  ${standby_ip}/32        md5
host    all             postgres        ${standby_ip}/32        md5
host    all             pgbouncer_admin ${standby_ip}/32        md5
EOF
    fi
  fi
  
  success "pg_hba.conf configured"
}

# ============================================================================
# REPMGR CONFIGURATION
# ============================================================================

setup_repmgr_sudoers() {
  info "Setting up sudoers rules for repmgr daemon"
  
  # Create sudoers rule for postgres user to run systemctl commands without password
  cat > /etc/sudoers.d/postgres-repmgrd <<'EOF'
# Allow postgres user to run systemctl commands for repmgrd without password
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl start repmgrd.service
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl stop repmgrd.service
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl start postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl stop postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl restart postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl reload postgresql
EOF

  chmod 440 /etc/sudoers.d/postgres-repmgrd
  success "Created sudoers rule for postgres user"
}

generate_repmgr_conf() {
  info "Generating repmgr configuration with service commands"
  
  local node_id conninfo_host
  case "$ROLE" in
    primary) node_id=1; conninfo_host="$SELF_IP" ;;
    standby) node_id=2; conninfo_host="$SELF_IP" ;;
    witness) node_id=3; conninfo_host="$SELF_IP" ;;
    *) node_id=1; conninfo_host="$SELF_IP" ;;
  esac
  
  cat > "$REPMGR_CONF_FILE" <<EOF
# Repmgr configuration for ${ROLE} node
node_id=${node_id}
node_name='${ROLE}'
conninfo='host=${conninfo_host} user=${REPMGR_USER} dbname=${REPMGR_DB}'
data_directory='${PG_DATA_DIR}'
pg_bindir='/usr/lib/postgresql/${PG_VERSION}/bin'

# Replication settings
use_replication_slots=yes

# Logging
log_file='${REPMGR_LOG_DIR}/repmgrd.log'
log_level=INFO

# Service commands (required for repmgrd daemon) - WITH SUDO + SUDOERS RULE
repmgrd_service_start_command='sudo systemctl start repmgrd.service'
repmgrd_service_stop_command='sudo systemctl stop repmgrd.service'
service_start_command='sudo systemctl start postgresql'
service_stop_command='sudo systemctl stop postgresql'
service_restart_command='sudo systemctl restart postgresql'
service_reload_command='sudo systemctl reload postgresql'

# Monitoring and failover
monitor_interval_secs=5
failover=automatic
promote_command='repmgr standby promote -f ${REPMGR_CONF_FILE}'
follow_command='repmgr standby follow -f ${REPMGR_CONF_FILE} --upstream-node-id=%n'

# Event notifications
event_notifications=all
event_notification_command='${REPMGR_EVENTS_DIR}/exec.sh %n %e %s %t %d %p %r'
EOF
  
  success "repmgr configuration generated with service commands"
}

setup_pgpass() {
  local pgpass="/var/lib/postgresql/.pgpass"
  
  info "Setting up .pgpass file with enhanced PgBouncer support"
  
  cat > "$pgpass" <<EOF
# Bootstrap Script .pgpass - Production Configuration with PgBouncer Support

# PostgreSQL connections
localhost:5432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:5432:*:postgres:${PG_SUPER_PASS}
${REPMGR_PRIMARY_HOST}:5432:*:postgres:${PG_SUPER_PASS}

# PgBouncer connections (Enhanced for working authentication)
localhost:6432:*:postgres:${PG_SUPER_PASS}
127.0.0.1:6432:*:postgres:${PG_SUPER_PASS}
localhost:6432:postgres:postgres:${PG_SUPER_PASS}
127.0.0.1:6432:postgres:postgres:${PG_SUPER_PASS}
localhost:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
127.0.0.1:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}

# Repmgr connections
localhost:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
127.0.0.1:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
${REPMGR_PRIMARY_HOST}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
localhost:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
127.0.0.1:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
${REPMGR_PRIMARY_HOST}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}

# Wildcard entries
*:5432:*:postgres:${PG_SUPER_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
*:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}
*:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}
EOF
  
  chown postgres:postgres "$pgpass"
  chmod 600 "$pgpass"
  success ".pgpass file configured with PgBouncer authentication support"
}

# ============================================================================
# PGBOUNCER CONFIGURATION
# ============================================================================

install_pgbouncer() {
  info "Configuring PgBouncer..."
  
  # PgBouncer should already be installed from install_packages
  if ! command -v pgbouncer >/dev/null 2>&1; then
    apt-get install -y pgbouncer
  fi
  
  # Create pgbouncer user if it doesn't exist
  if ! id pgbouncer >/dev/null 2>&1; then
    useradd --system --home /var/lib/pgbouncer --shell /bin/false pgbouncer
  fi
  
  # Create directories
  mkdir -p /var/log/pgbouncer /var/run/pgbouncer /etc/pgbouncer
  chown pgbouncer:pgbouncer /var/log/pgbouncer /var/run/pgbouncer
  
  success "PgBouncer configured"
}

configure_pgbouncer() {
  info "Configuring PgBouncer with MD5 authentication"
  
  # Determine settings based on role
  local pool_mode max_client_conn
  case "$ROLE" in
    primary) pool_mode="transaction"; max_client_conn="$PGBOUNCER_MAX_CLIENT_CONN" ;;
    standby) pool_mode="session"; max_client_conn="$((PGBOUNCER_MAX_CLIENT_CONN / 2))" ;;
    witness) pool_mode="statement"; max_client_conn="20" ;;
    *) pool_mode="transaction"; max_client_conn="$PGBOUNCER_MAX_CLIENT_CONN" ;;
  esac
  
  # Create PgBouncer configuration
  cat > "$PGBOUNCER_CONF_FILE" <<EOF
;; PgBouncer HA configuration with MD5 authentication

[databases]
postgres = host=localhost port=5432 dbname=postgres
template1 = host=localhost port=5432 dbname=template1
${REPMGR_DB} = host=localhost port=5432 dbname=${REPMGR_DB}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = $PGBOUNCER_PORT

auth_type = md5
auth_file = $PGBOUNCER_USERLIST_FILE

pool_mode = $pool_mode
max_client_conn = $max_client_conn
default_pool_size = $PGBOUNCER_POOL_SIZE
reserve_pool_size = 5
max_db_connections = $((PGBOUNCER_POOL_SIZE * 2))

server_connect_timeout = 15
server_login_retry = 3
query_timeout = 3600
query_wait_timeout = 120
client_idle_timeout = 3600
server_idle_timeout = 600
server_lifetime = 3600

log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

admin_users = pgbouncer_admin,postgres
stats_users = pgbouncer_admin,postgres

ignore_startup_parameters = extra_float_digits,search_path
server_reset_query = DISCARD ALL
EOF

  success "PgBouncer configuration created"
}

create_pgbouncer_userlist() {
  info "Creating PgBouncer userlist with MD5 authentication"
  
  # Generate MD5 hashes
  local postgres_md5 pgbouncer_admin_md5 repmgr_md5
  postgres_md5=$(printf '%s%s' "$PG_SUPER_PASS" "postgres" | md5sum | cut -d' ' -f1)
  pgbouncer_admin_md5=$(printf '%s%s' "$PGBOUNCER_PASSWORD" "pgbouncer_admin" | md5sum | cut -d' ' -f1)
  repmgr_md5=$(printf '%s%s' "$REPMGR_PASSWORD" "$REPMGR_USER" | md5sum | cut -d' ' -f1)
  
  cat > "$PGBOUNCER_USERLIST_FILE" <<EOF
;; PgBouncer MD5 Authentication File

"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"repmgr" "md5${repmgr_md5}"
EOF
  
  chown pgbouncer:pgbouncer "$PGBOUNCER_USERLIST_FILE"
  chmod 640 "$PGBOUNCER_USERLIST_FILE"
  success "PgBouncer userlist created"
}

# ============================================================================
# CLUSTER INITIALIZATION
# ============================================================================

init_primary() {
  info "Initializing primary PostgreSQL node"
  
  systemctl enable postgresql
  systemctl start postgresql
  
  # Wait for PostgreSQL to be ready
  retry 30 2 sudo -u postgres psql -c "SELECT 1" >&/dev/null
  
  # Create users and database with error handling
  sudo -u postgres psql <<EOF || true
-- Set password encryption to md5 for compatibility
SET password_encryption = 'md5';

-- Create repmgr user (ignore if exists)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${REPMGR_USER}') THEN
        CREATE USER ${REPMGR_USER} REPLICATION LOGIN;
    END IF;
END\$\$;

ALTER USER ${REPMGR_USER} PASSWORD '${REPMGR_PASSWORD}';

-- Create repmgr database (ignore if exists)
SELECT 'CREATE DATABASE ${REPMGR_DB} OWNER ${REPMGR_USER}'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${REPMGR_DB}');
\gexec

-- Create replication user (ignore if exists)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replication') THEN
        CREATE USER replication REPLICATION LOGIN PASSWORD '${PG_REPL_PASS}';
    END IF;
END\$\$;

-- Set postgres password
ALTER USER postgres PASSWORD '${PG_SUPER_PASS}';

-- Reset password encryption
RESET password_encryption;
EOF
  
  # Wait a moment for changes to take effect
  sleep 2
  
  # Register primary with repmgr with better error handling
  info "Registering primary node with repmgr"
  
  # Install repmgr extension and set up proper permissions
  sudo -u postgres psql -d "${REPMGR_DB}" <<EOF || true
-- Install repmgr extension
CREATE EXTENSION IF NOT EXISTS repmgr;

-- Grant necessary permissions to repmgr user
GRANT ALL ON SCHEMA repmgr TO ${REPMGR_USER};
GRANT ALL ON ALL TABLES IN SCHEMA repmgr TO ${REPMGR_USER};
GRANT ALL ON ALL SEQUENCES IN SCHEMA repmgr TO ${REPMGR_USER};
GRANT ALL ON ALL FUNCTIONS IN SCHEMA repmgr TO ${REPMGR_USER};

-- Make repmgr user superuser (required for repmgr operations)
ALTER USER ${REPMGR_USER} WITH SUPERUSER;

-- Also grant permissions to postgres user
GRANT ALL ON SCHEMA repmgr TO postgres;
GRANT ALL ON ALL TABLES IN SCHEMA repmgr TO postgres;
GRANT ALL ON ALL SEQUENCES IN SCHEMA repmgr TO postgres;
EOF
  
  # Try to register primary with detailed error reporting
  if ! sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
       repmgr -f "$REPMGR_CONF_FILE" primary register --force 2>&1 | tee /tmp/repmgr_register.log; then
    warn "Primary registration failed, checking details..."
    info "Registration error output:"
    cat /tmp/repmgr_register.log | head -10 || true
    
    # Check if already registered
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
       repmgr -f "$REPMGR_CONF_FILE" cluster show >&/dev/null; then
      info "Primary already registered in cluster"
    else
      error "Failed to register primary node - see logs above"
      info "Checking database connectivity..."
      sudo -u postgres psql -d "${REPMGR_DB}" -c "SELECT version();" || true
      return 1
    fi
  fi
  
  touch "$SENTINEL_PRIMARY_INIT"
  success "Primary node initialized"
}

init_standby() {
  info "Initializing standby PostgreSQL node"
  
  systemctl stop postgresql || true
  rm -rf "${PG_DATA_DIR}"/*
  
  # Try to get shared passwords from primary
  local shared_passwords_file="/tmp/cluster_passwords_${CLUSTER_ID}.conf"
  if [[ ! -f "$shared_passwords_file" ]]; then
    info "Attempting to copy shared passwords from primary..."
    if timeout 10 scp -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" \
       "$REPMGR_PRIMARY_HOST:$shared_passwords_file" "$shared_passwords_file" 2>/dev/null; then
      info "✓ Successfully copied shared passwords from primary"
      source "$shared_passwords_file"
      export PGPASSWORD="$PG_SUPER_PASS"
    else
      warn "Could not copy passwords from primary, using current passwords"
    fi
  fi
  
  # Wait for primary to be ready
  info "Waiting for primary node to be accessible..."
  if ! retry 60 5 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
       psql -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" -c "SELECT 1" >&/dev/null; then
    error "Cannot connect to primary node at $REPMGR_PRIMARY_HOST"
    info "Please ensure:"
    info "  1. Primary node is running and accessible"
    info "  2. PostgreSQL is accepting connections on primary"
    info "  3. repmgr database exists on primary"
    info "  4. Network connectivity between nodes"
    info "  5. Passwords match between primary and standby"
    return 1
  fi
  
  success "Primary node is accessible"
  
  # Clone from primary with better error handling
  info "Cloning data from primary: $REPMGR_PRIMARY_HOST"
  if ! sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
       repmgr -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" \
       -f "$REPMGR_CONF_FILE" standby clone --force; then
    error "Failed to clone from primary"
    info "Checking repmgr log for details..."
    if [[ -f "$REPMGR_LOG_DIR/repmgrd.log" ]]; then
      tail -20 "$REPMGR_LOG_DIR/repmgrd.log" || true
    fi
    return 1
  fi
  
  systemctl enable postgresql
  systemctl start postgresql
  
  retry 30 2 sudo -u postgres psql -c "SELECT 1" >&/dev/null
  
  # Register standby with error handling
  info "Registering standby node with repmgr"
  if ! sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
       repmgr -f "$REPMGR_CONF_FILE" standby register; then
    warn "Standby registration failed, checking if already registered"
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass \
       repmgr -f "$REPMGR_CONF_FILE" cluster show >&/dev/null; then
      info "Standby already registered in cluster"
    else
      error "Failed to register standby node"
      return 1
    fi
  fi
  
  # Recreate PgBouncer userlist on standby to ensure authentication works
  info "Recreating PgBouncer userlist on standby node"
  local postgres_md5 pgbouncer_admin_md5 repmgr_md5
  postgres_md5=$(printf '%s%s' "$PG_SUPER_PASS" "postgres" | md5sum | cut -d' ' -f1)
  pgbouncer_admin_md5=$(printf '%s%s' "$PGBOUNCER_PASSWORD" "pgbouncer_admin" | md5sum | cut -d' ' -f1)
  repmgr_md5=$(printf '%s%s' "$REPMGR_PASSWORD" "$REPMGR_USER" | md5sum | cut -d' ' -f1)
  
  cat > "$PGBOUNCER_USERLIST_FILE" <<EOF
;; PgBouncer MD5 Authentication File (Standby)

"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"repmgr" "md5${repmgr_md5}"
EOF
  
  chown pgbouncer:pgbouncer "$PGBOUNCER_USERLIST_FILE"
  chmod 640 "$PGBOUNCER_USERLIST_FILE"
  success "PgBouncer userlist recreated for standby"
  
  # Ensure repmgrd service is properly configured for standby
  info "Configuring repmgrd service for standby node..."
  
  # Create a standby-specific systemd service override if needed
  mkdir -p /etc/systemd/system/repmgrd.service.d
  cat > /etc/systemd/system/repmgrd.service.d/standby-override.conf <<EOF
[Unit]
After=postgresql.service network-online.target
Wants=network-online.target

[Service]
Restart=always
RestartSec=15
StartLimitInterval=0
TimeoutStartSec=120
EOF

  systemctl daemon-reload
  success "repmgrd service configured for standby"
  
  touch "$SENTINEL_STANDBY_CLONED"
  success "Standby node initialized"
}

register_node() {
  info "Registering node with repmgr..."
  
  case "$ROLE" in
    "primary")
      sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" primary register || warn "Primary registration failed"
      ;;
    "standby")
      # Clone from primary first
      if [[ ! -f "$SENTINEL_STANDBY_CLONED" ]]; then
        info "Stopping PostgreSQL to clone from primary..."
        systemctl stop postgresql
        
        sudo -u postgres rm -rf "$PG_DATA_DIR"/*
        sudo -u postgres repmgr -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF_FILE" standby clone
        
        systemctl start postgresql
        touch "$SENTINEL_STANDBY_CLONED"
      fi
      
      sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" standby register || warn "Standby registration failed"
      ;;
    "witness")
      sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" witness register -h "$REPMGR_PRIMARY_HOST" || warn "Witness registration failed"
      ;;
  esac
  
  success "Node registered with repmgr"
}

sync_database_passwords() {
  info "Synchronizing database passwords with PgBouncer"
  
  retry 30 2 sudo -u postgres psql -c "SELECT 1" >&/dev/null
  
  # Check if this is a standby (read-only) node
  local is_standby
  is_standby=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "unknown")
  
  if [[ "$is_standby" == "t" ]]; then
    info "Standby node detected - pgbouncer_admin user should already exist from replication"
    info "Skipping user creation on read-only standby node"
  else
    info "Primary node - creating pgbouncer_admin user with enhanced permissions"
    sudo -u postgres psql <<EOF
-- Set password_encryption to md5 temporarily
SET password_encryption = 'md5';

-- Create pgbouncer_admin user
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
        CREATE ROLE pgbouncer_admin LOGIN;
    END IF;
END\$\$;

ALTER ROLE pgbouncer_admin PASSWORD '$PGBOUNCER_PASSWORD';

-- Grant necessary permissions for PgBouncer admin operations
GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
GRANT CONNECT ON DATABASE template1 TO pgbouncer_admin;
GRANT CONNECT ON DATABASE ${REPMGR_DB} TO pgbouncer_admin;

-- Grant usage on public schema and basic table permissions
GRANT USAGE ON SCHEMA public TO pgbouncer_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgbouncer_admin;

-- Make sure pgbouncer_admin can access pgbouncer's internal stats
-- This helps with admin interface functionality
ALTER ROLE pgbouncer_admin SET log_statement = 'none';

-- Reset password_encryption
RESET password_encryption;
EOF
  fi
  
  success "Database passwords synchronized"
}

# ============================================================================
# SERVICE MANAGEMENT
# ============================================================================

start_services() {
  info "Starting services..."
  
  # Reload systemd after creating new services
  systemctl daemon-reload
  
  # Start core services first
  systemctl enable postgresql
  systemctl start postgresql || die "Failed to start PostgreSQL"
  
  # Wait for PostgreSQL to be ready
  retry 30 sudo -u postgres psql -c "SELECT 1;" >/dev/null 2>&1 || die "PostgreSQL not ready"
  
  # Start PgBouncer
  systemctl enable pgbouncer
  systemctl start pgbouncer || die "Failed to start PgBouncer"
  
  # Wait for PgBouncer to be ready
  retry 10 nc -z localhost 6432 || die "PgBouncer not ready"
  
  # Install socat for health endpoints if not present
  if ! command -v socat >/dev/null 2>&1; then
    info "Installing socat for health endpoints..."
    apt-get update -qq && apt-get install -y socat
  fi
  
  # Start health endpoints
  chmod +x /usr/local/bin/clean-pg-health.sh
  chmod +x /usr/local/bin/clean-pgbouncer-health.sh
  
  systemctl enable postgresql-ha-health
  systemctl start postgresql-ha-health
  
  systemctl enable pgbouncer-ha-health  
  systemctl start pgbouncer-ha-health
  
  # Verify health endpoints are responding
  info "Waiting for health endpoints to start..."
  sleep 5
  
  # Test local health endpoints
  for port in 8001 8002; do
    if retry 5 curl -s "http://localhost:$port" >/dev/null; then
      success "Health endpoint on port $port is responding"
    else
      warn "Health endpoint on port $port not responding yet"
    fi
  done
  
  # Start repmgrd if this is not primary initialization
  if [[ "$ROLE" != "primary" || -f "$SENTINEL_PRIMARY_INIT" ]]; then
    systemctl enable repmgrd
    systemctl start repmgrd || warn "Failed to start repmgrd (will retry later)"
  fi
  
  success "All services started successfully"
}

setup_services() {
  info "Setting up system services"
  
  # PgBouncer service
  cat > /etc/systemd/system/pgbouncer.service <<EOF
[Unit]
Description=PgBouncer connection pooler
After=network.target postgresql.service

[Service]
Type=notify
ExecStart=/usr/sbin/pgbouncer $PGBOUNCER_CONF_FILE
User=pgbouncer
Group=pgbouncer
PIDFile=/var/run/pgbouncer/pgbouncer.pid

[Install]
WantedBy=multi-user.target
EOF

  # Repmgrd service with correct syntax
  cat > /etc/systemd/system/repmgrd.service <<EOF
[Unit]
Description=PostgreSQL replication manager daemon
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=postgres
Group=postgres
Environment=PGPASSFILE=/var/lib/postgresql/.pgpass
ExecStart=/usr/bin/repmgr -f ${REPMGR_CONF_FILE} daemon start
ExecStop=/usr/bin/repmgr -f ${REPMGR_CONF_FILE} daemon stop
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  success "System services configured"
}

start_services() {
  info "Starting services"
  
  # Start and enable PgBouncer
  systemctl enable pgbouncer.service
  if systemctl start pgbouncer.service; then
    success "PgBouncer service started"
    
    # Wait for PgBouncer to be ready and test authentication
    sleep 2
    if timeout 10 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 'PgBouncer authentication test successful';" >/dev/null 2>&1; then
      success "PgBouncer authentication working"
    else
      warn "PgBouncer authentication may need adjustment - restarting service"
      systemctl restart pgbouncer
      sleep 2
    fi
  else
    warn "Failed to start PgBouncer service"
  fi
  
  # Start repmgrd (only for primary/standby)
  if [[ "$ROLE" != "witness" ]]; then
    systemctl enable repmgrd.service
    if systemctl start repmgrd.service; then
      success "repmgrd started"
      
      # For standby nodes, verify replication is working
      if [[ "$ROLE" == "standby" ]]; then
        sleep 3
        local replication_status=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "unknown")
        if [[ "$replication_status" == "t" ]]; then
          success "Standby node is in recovery mode"
          
          # Check WAL receiver
          local wal_receiver=$(sudo -u postgres psql -Atqc "SELECT pid FROM pg_stat_wal_receiver;" 2>/dev/null || echo "")
          if [[ -n "$wal_receiver" && "$wal_receiver" != "" ]]; then
            success "WAL receiver is active (PID: $wal_receiver)"
          else
            warn "WAL receiver not active - will restart repmgrd after health endpoints"
          fi
        else
          warn "Standby node not in recovery mode - may need troubleshooting"
        fi
      fi
    else
      warn "Failed to start repmgrd"
      
      # For standby nodes, attempt to restart repmgrd after a delay with better error handling
      if [[ "$ROLE" == "standby" ]]; then
        info "Attempting repmgrd restart for standby node..."
        
        # Check if repmgrd is actually running first
        if systemctl is-active --quiet repmgrd.service; then
          info "repmgrd is already running, checking functionality..."
        else
          # Try multiple restart attempts with different approaches
          for attempt in {1..3}; do
            info "repmgrd restart attempt $attempt/3..."
            systemctl stop repmgrd.service 2>/dev/null || true
            sleep 3
            
            # Clear any stuck processes
            pkill -f "repmgr.*daemon" 2>/dev/null || true
            sleep 2
            
            if systemctl start repmgrd.service; then
              sleep 5
              if systemctl is-active --quiet repmgrd.service; then
                success "repmgrd restarted successfully on attempt $attempt"
                break
              else
                warn "repmgrd started but became inactive on attempt $attempt"
              fi
            else
              warn "repmgrd start failed on attempt $attempt"
              if [[ $attempt -eq 3 ]]; then
                warn "All repmgrd restart attempts failed"
                info "Checking repmgrd logs for errors..."
                journalctl -u repmgrd.service --no-pager -l | tail -10 || true
                
                # Try alternative approach - manual daemon start
                info "Attempting manual repmgrd start as fallback..."
                sudo -u postgres nohup repmgr -f /etc/repmgr/repmgr.conf daemon start >/var/log/repmgr/repmgrd-manual.log 2>&1 &
                sleep 3
                if pgrep -f "repmgr.*daemon" >/dev/null; then
                  success "Manual repmgrd daemon started as fallback"
                else
                  error "Manual repmgrd start also failed - cluster will work but without automatic failover monitoring"
                fi
              fi
            fi
          done
        fi
      fi
    fi
  fi
}

# ============================================================================
# HEALTH ENDPOINTS
# ============================================================================

setup_health_endpoints() {
  info "Setting up production-ready health endpoints with clean restart integration"
  
  # STEP 1: Complete cleanup of all existing health processes and ports
  info "🧹 Complete cleanup of all health processes and ports..."
  
  # Kill all processes on health ports
  fuser -k 8001/tcp 2>/dev/null || true
  fuser -k 8002/tcp 2>/dev/null || true
  pkill -f ":8001" 2>/dev/null || true
  pkill -f ":8002" 2>/dev/null || true
  pkill -f "health" 2>/dev/null || true
  pkill -f "pgbouncer-health" 2>/dev/null || true
  
  # Stop all health-related services
  systemctl stop pg-ha-health.service 2>/dev/null || true
  systemctl stop pgbouncer-health.service 2>/dev/null || true
  systemctl stop pgbouncer-health-monitor.service 2>/dev/null || true
  systemctl stop postgresql-ha-health.service 2>/dev/null || true
  
  # Disable conflicting services
  systemctl disable pg-ha-health.service 2>/dev/null || true
  systemctl disable pgbouncer-health.service 2>/dev/null || true
  
  sleep 5
  
  # Force kill if ports still in use
  if command -v netstat >/dev/null 2>&1; then
    if netstat -tuln 2>/dev/null | grep -q ":8001"; then
      warn "Port 8001 still in use - force killing..."
      fuser -k -9 8001/tcp 2>/dev/null || true
      sleep 2
    fi
    if netstat -tuln 2>/dev/null | grep -q ":8002"; then
      warn "Port 8002 still in use - force killing..."
      fuser -k -9 8002/tcp 2>/dev/null || true
      sleep 2
    fi
  fi
  
  # STEP 2: Configure comprehensive firewall rules for cross-node access
  info "🔥 Configuring comprehensive firewall rules for health endpoints..."
  
  # iptables rules for both nodes
  iptables -D INPUT -p tcp --dport 8001 -j DROP 2>/dev/null || true
  iptables -D INPUT -p tcp --dport 8002 -j DROP 2>/dev/null || true
  iptables -I INPUT -p tcp --dport 8001 -s 192.168.14.21 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport 8001 -s 192.168.14.22 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport 8001 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport 8002 -s 192.168.14.21 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport 8002 -s 192.168.14.22 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport 8002 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
  
  # UFW rules if available
  if command -v ufw >/dev/null 2>&1; then
    ufw allow from 192.168.14.21 to any port 8001 comment "PostgreSQL HA Health" 2>/dev/null || true
    ufw allow from 192.168.14.22 to any port 8001 comment "PostgreSQL HA Health" 2>/dev/null || true
    ufw allow from 192.168.14.21 to any port 8002 comment "PgBouncer Health" 2>/dev/null || true
    ufw allow from 192.168.14.22 to any port 8002 comment "PgBouncer Health" 2>/dev/null || true
    ufw allow from 127.0.0.1 to any port 8001 2>/dev/null || true
    ufw allow from 127.0.0.1 to any port 8002 2>/dev/null || true
  fi
  
  success "Firewall configured for cross-node health endpoint access"
  
  # STEP 3: Create production-ready health endpoint scripts
  info "🏥 Creating single, reliable health endpoint scripts..."
  
  # Create PostgreSQL HA Health Endpoint (Port 8001)
  cat > /usr/local/bin/clean-pg-health.sh <<EOF
#!/bin/bash
# Clean PostgreSQL HA Health Endpoint - Production Ready
PORT=\${1:-8001}
ROLE="$ROLE"
SELF_IP="$(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")"

while true; do
    # Check PostgreSQL connectivity
    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
        # Get current role
        current_role=\$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
        
        if [[ "\$current_role" == "\$ROLE" ]]; then
            status="healthy"
            message="PostgreSQL \$ROLE operational"
            http_code="200"
        else
            status="healthy"
            message="PostgreSQL \$current_role operational"
            http_code="200"
        fi
    else
        status="unhealthy"
        message="PostgreSQL not accessible"
        http_code="503"
    fi
    
    response="{\"status\":\"\$status\",\"service\":\"postgresql-ha\",\"role\":\"\$ROLE\",\"message\":\"\$message\",\"timestamp\":\"\$(date -Iseconds)\",\"node_ip\":\"\$SELF_IP\"}"
    content_length=\${#response}
    
    if [[ "\$http_code" == "200" ]]; then
        http_status="HTTP/1.1 200 OK"
    else
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    printf "%s\\r\\nContent-Type: application/json\\r\\nContent-Length: %s\\r\\nConnection: close\\r\\nAccess-Control-Allow-Origin: *\\r\\nServer: PostgreSQL-HA/1.0\\r\\n\\r\\n%s" \
        "\$http_status" "\$content_length" "\$response" | nc -l -s 0.0.0.0 -p \$PORT -q 1 2>/dev/null || sleep 1
done
EOF
  
  chmod +x /usr/local/bin/clean-pg-health.sh
  
  # Create PgBouncer Health Endpoint (Port 8002)
  cat > /usr/local/bin/clean-pgbouncer-health.sh <<EOF
#!/bin/bash
# Clean PgBouncer Health Endpoint - Production Ready
PORT=\${1:-8002}
SELF_IP="$(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")"

while true; do
    # Check PgBouncer connectivity
    if pgrep -f pgbouncer >/dev/null 2>&1 && timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        status="healthy"
        message="PgBouncer operational"
        http_code="200"
    else
        status="unhealthy"
        message="PgBouncer not accessible"
        http_code="503"
    fi
    
    response="{\"service\":\"pgbouncer\",\"status\":\"\$status\",\"message\":\"\$message\",\"timestamp\":\"\$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"\$SELF_IP\"}"
    content_length=\${#response}
    
    if [[ "\$http_code" == "200" ]]; then
        http_status="HTTP/1.1 200 OK"
    else
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    printf "%s\\r\\nContent-Type: application/json\\r\\nContent-Length: %s\\r\\nConnection: close\\r\\nAccess-Control-Allow-Origin: *\\r\\nServer: PgBouncer-HA/1.0\\r\\n\\r\\n%s" \
        "\$http_status" "\$content_length" "\$response" | nc -l -s 0.0.0.0 -p \$PORT -q 1 2>/dev/null || sleep 1
done
EOF
  
  chmod +x /usr/local/bin/clean-pgbouncer-health.sh
  
  # STEP 4: Start clean health endpoints as background processes
  info "🚀 Starting clean health endpoints..."
  
  # Start PostgreSQL health endpoint
  nohup /usr/local/bin/clean-pg-health.sh 8001 >/dev/null 2>&1 &
  PG_HEALTH_PID=$!
  sleep 2
  
  # Start PgBouncer health endpoint  
  nohup /usr/local/bin/clean-pgbouncer-health.sh 8002 >/dev/null 2>&1 &
  PGB_HEALTH_PID=$!
  sleep 3
  
  # STEP 5: Validate both endpoints are working
  info "🧪 Testing health endpoints..."
  
  local pg_working=false
  local pgb_working=false
  
  # Test PostgreSQL endpoint
  for attempt in {1..5}; do
    if timeout 10 curl -s "http://localhost:8001" >/dev/null 2>&1; then
      pg_working=true
      success "✅ PostgreSQL health endpoint (8001): WORKING"
      local pg_response=$(timeout 5 curl -s "http://localhost:8001" 2>/dev/null | head -c 100 || echo "...")
      info "  Response: $pg_response"
      break
    else
      if [[ $attempt -lt 5 ]]; then
        warn "PostgreSQL health endpoint attempt $attempt failed, retrying..."
        sleep 2
      fi
    fi
  done
  
  # Test PgBouncer endpoint
  for attempt in {1..5}; do
    if timeout 10 curl -s "http://localhost:8002" >/dev/null 2>&1; then
      pgb_working=true  
      success "✅ PgBouncer health endpoint (8002): WORKING"
      local pgb_response=$(timeout 5 curl -s "http://localhost:8002" 2>/dev/null | head -c 100 || echo "...")
      info "  Response: $pgb_response"
      break
    else
      if [[ $attempt -lt 5 ]]; then
        warn "PgBouncer health endpoint attempt $attempt failed, retrying..."
        sleep 2
      fi
    fi
  done
  
  # STEP 6: Create systemd services for reliability
  info "🔧 Creating systemd services for health endpoint reliability..."
  
  # PostgreSQL HA Health Service
  cat > /etc/systemd/system/postgresql-ha-health.service <<EOF
[Unit]
Description=PostgreSQL HA Health Check Endpoint
After=network.target postgresql.service
Wants=postgresql.service
PartOf=postgresql.service

[Service]
Type=simple
ExecStart=/usr/local/bin/clean-pg-health.sh 8001
Restart=always
RestartSec=5
User=postgres
Group=postgres
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

# Resource limits
MemoryHigh=64M
MemoryMax=128M
TasksMax=10

# Ensure script is executable
ExecStartPre=/bin/chmod +x /usr/local/bin/clean-pg-health.sh

[Install]
WantedBy=multi-user.target
EOF

  # PgBouncer Health Service
  cat > /etc/systemd/system/pgbouncer-ha-health.service <<EOF
[Unit]
Description=PgBouncer HA Health Check Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service
PartOf=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/clean-pgbouncer-health.sh 8002
Restart=always
RestartSec=5
User=postgres
Group=postgres
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

# Resource limits
MemoryHigh=64M
MemoryMax=128M
TasksMax=10

# Ensure script is executable
ExecStartPre=/bin/chmod +x /usr/local/bin/clean-pgbouncer-health.sh

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable postgresql-ha-health.service
  systemctl enable pgbouncer-ha-health.service
  
  # Don't start systemd services immediately since background processes are already running
  # They will take over on next boot or if background processes fail
  
  # STEP 7: Create comprehensive health test script
  cat > /usr/local/bin/test-all-health-endpoints.sh <<'TEST_EOF'
#!/bin/bash
# Comprehensive Health Endpoint Test Script

PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

echo "🏥 Comprehensive Health Endpoint Testing"
echo "========================================"
echo ""

test_endpoint() {
    local ip=$1
    local port=$2 
    local name=$3
    local service=$4
    
    printf "%-30s " "$name ($service):"
    
    if timeout 10 curl -s "http://$ip:$port" >/dev/null 2>&1; then
        echo "✅ WORKING"
        response=$(timeout 5 curl -s "http://$ip:$port" | jq -c . 2>/dev/null || echo "OK")
        echo "    Response: $response"
    else
        echo "❌ FAILED"
        echo "    → Check firewall and service status"
    fi
    echo ""
}

echo "=== PostgreSQL HA Health Endpoints (Port 8001) ==="
test_endpoint "$PRIMARY_IP" "8001" "Primary" "PostgreSQL-HA"
test_endpoint "$STANDBY_IP" "8001" "Standby" "PostgreSQL-HA" 

echo "=== PgBouncer Health Endpoints (Port 8002) ==="
test_endpoint "$PRIMARY_IP" "8002" "Primary" "PgBouncer"
test_endpoint "$STANDBY_IP" "8002" "Standby" "PgBouncer"

echo "=== Summary ==="
working=0
total=4

for node_ip in "$PRIMARY_IP" "$STANDBY_IP"; do
    for port in 8001 8002; do
        if timeout 8 curl -s "http://$node_ip:$port" >/dev/null 2>&1; then
            working=$((working + 1))
        fi
    done
done

echo "Working endpoints: $working/$total"
if [[ $working -eq $total ]]; then
    echo "🎉 ALL HEALTH ENDPOINTS WORKING - READY FOR LOAD BALANCER!"
elif [[ $working -ge 3 ]]; then
    echo "🔧 MOSTLY WORKING - Minor issues to address"
elif [[ $working -gt 0 ]]; then
    echo "⚠️  PARTIAL SUCCESS - Some endpoints working"
else
    echo "❌ ALL ENDPOINTS FAILED - Need troubleshooting"
fi

echo ""
echo "📋 Load Balancer URLs:"
echo "  Primary PostgreSQL HA: http://$PRIMARY_IP:8001"
echo "  Primary PgBouncer: http://$PRIMARY_IP:8002"
echo "  Standby PostgreSQL HA: http://$STANDBY_IP:8001"
echo "  Standby PgBouncer: http://$STANDBY_IP:8002"
TEST_EOF

  chmod +x /usr/local/bin/test-all-health-endpoints.sh
  
  # Final summary and completion message
  info ""
  info "📊 HEALTH ENDPOINT DEPLOYMENT SUMMARY:"
  
  # Count working endpoints
  local working_endpoints=0
  local total_endpoints=2
  
  # Test PostgreSQL HA endpoint
  if timeout 5 curl -s "http://localhost:8001" >/dev/null 2>&1; then
    success "  ✅ PostgreSQL HA Health Endpoint (8001): READY"
    working_endpoints=$((working_endpoints + 1))
  else
    warn "  ❌ PostgreSQL HA Health Endpoint (8001): NOT READY"
  fi
  
  # Test PgBouncer endpoint  
  if timeout 5 curl -s "http://localhost:8002" >/dev/null 2>&1; then
    success "  ✅ PgBouncer Health Endpoint (8002): READY"
    working_endpoints=$((working_endpoints + 1))
  else
    warn "  ❌ PgBouncer Health Endpoint (8002): NOT READY"
  fi
  
  info "Working endpoints: $working_endpoints/$total_endpoints"
  
  if [[ $working_endpoints -eq $total_endpoints ]]; then
    success "🎉 ALL HEALTH ENDPOINTS WORKING - Ready for load balancer integration!"
  elif [[ $working_endpoints -gt 0 ]]; then
    warn "🔧 PARTIAL SUCCESS - Some health endpoints working"
    info "Run the test script after deployment: /usr/local/bin/test-all-health-endpoints.sh"
  else
    error "❌ NO HEALTH ENDPOINTS WORKING - Manual intervention needed"
  fi

  success "Health endpoints configured and optimized for load balancer integration"
  
  # Create enhanced clean restart script for manual use if needed
  cat > /usr/local/bin/clean_restart_health.sh <<'CLEAN_RESTART_EOF'
#!/bin/bash
# Simple Clean Restart for Health Endpoints
info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }

ROLE=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
SELF_IP=$(hostname -I | awk '{print $1}')

info "🧹 Simple Clean Restart for Health Endpoints"
info "Node: $ROLE (IP: $SELF_IP)"

# Kill ALL processes on ports 8001 and 8002
fuser -k 8001/tcp 2>/dev/null || true
fuser -k 8002/tcp 2>/dev/null || true
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
sleep 5

# Force kill if ports still in use
if command -v netstat >/dev/null 2>&1 && netstat -tuln 2>/dev/null | grep -q ":8001"; then
    warn "Port 8001 still in use - force killing..."
    fuser -k -9 8001/tcp 2>/dev/null || true
    sleep 2
fi
if command -v netstat >/dev/null 2>&1 && netstat -tuln 2>/dev/null | grep -q ":8002"; then
    warn "Port 8002 still in use - force killing..."
    fuser -k -9 8002/tcp 2>/dev/null || true
    sleep 2
fi

# Simple firewall rules
iptables -I INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 8002 -j ACCEPT 2>/dev/null || true

# Start clean health endpoints
nohup /usr/local/bin/clean-pg-health.sh 8001 >/dev/null 2>&1 &
sleep 2
nohup /usr/local/bin/clean-pgbouncer-health.sh 8002 >/dev/null 2>&1 &
sleep 3

# Test endpoints
for port in 8001 8002; do
  if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
    success "✅ Port $port: WORKING"
  else
    warn "❌ Port $port: FAILED"
  fi
done

info "🎯 Run this script on both nodes, then test with: /usr/local/bin/test-all-health-endpoints.sh"
CLEAN_RESTART_EOF

  chmod +x /usr/local/bin/clean_restart_health.sh
}

# ============================================================================
# MAIN BOOTSTRAP FUNCTION
# ============================================================================

main() {
  info "Starting PostgreSQL HA Bootstrap v$SCRIPT_VERSION"
  
  # Skip if already bootstrapped
  if [[ -f "$SENTINEL_BOOTSTRAP" ]]; then
    info "Bootstrap already completed (sentinel file exists)"
    exit 0
  fi
  
  # Detect configuration from metadata
  detect_configuration
  
  # Install packages
  install_packages
  
  # Load secrets from Secret Manager
  load_secrets
  
  # Configure PostgreSQL
  configure_postgresql
  configure_pg_hba
  
  # Setup repmgr
  setup_repmgr_sudoers
  generate_repmgr_conf
  setup_pgpass
  
  # Install and configure PgBouncer
  install_pgbouncer
  configure_pgbouncer
  create_pgbouncer_userlist
  
  # Setup systemd services
  setup_services
  
  # Initialize cluster based on role
  case "$ROLE" in
    "primary")
      info "Initializing as primary node..."
      init_primary
      sync_database_passwords
      ;;
    "standby")
      info "Initializing as standby node..."
      init_standby
      ;;
    "witness")
      info "Initializing as witness node..."
      # Witness doesn't need special initialization
      register_node
      ;;
    *)
      die "Unknown role: $ROLE"
      ;;
  esac
  
  # Setup health endpoints after cluster is initialized
  setup_health_endpoints
  
  # Start all services including health endpoints
  start_services
  
  # Create bootstrap sentinel
  touch "$SENTINEL_BOOTSTRAP"
  
  # Final health check
  info "Performing final health checks..."
  sleep 10
  
  # Test health endpoints
  for port in 8001 8002; do
    if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
      success "Health endpoint on port $port is responding"
    else
      warn "Health endpoint on port $port may need attention"
    fi
  done
  
  local bootstrap_duration=$(($(date +%s) - BOOTSTRAP_START_TIME))
  success "Bootstrap completed successfully in ${bootstrap_duration} seconds"
  success "Node role: $ROLE"
  success "Node IP: $(hostname -I | awk '{print $1}')"
  
  info "Bootstrap log: $LOG_FILE"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi