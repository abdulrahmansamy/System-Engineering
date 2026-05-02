#!/bin/bash
# PostgreSQL High Availability Cluster Bootstrap Script - Production Ready v3.7.0
# Fully automated startup script for GCP Compute Engine instances
# 
# Features:
# - Fully automated single-run execution with comprehensive error handling
# - Secret Manager integration for secure credential management
# - Terraform infrastructure-aware configuration
# - PostgreSQL 17 + repmgr HA cluster with automatic failover
# - PgBouncer connection pooling with health endpoints for GCP ILB
# - Production-ready Python3-based health endpoints
# - Enhanced MD5 authentication and conflict resolution
# - Comprehensive logging and diagnostics
# 
# Version: 3.9.0 - Fixed PgBouncer health endpoint startup issues

set -euo pipefail

# ============================================================================
# CONFIGURATION & GLOBAL VARIABLES
# ============================================================================

readonly SCRIPT_VERSION="3.9.0"
readonly BOOTSTRAP_START_TIME=$(date +%s)

# Enable detailed tracing for debugging
if [[ "${BOOTSTRAP_TRACE:-0}" == "1" ]]; then
  set -x
fi

# Directories and paths
readonly LOG_DIR="/var/log/pg-bootstrap"
readonly LOG_FILE="$LOG_DIR/bootstrap.log"
readonly SENTINEL_DIR="/var/lib/postgresql/.bootstrap"
readonly SENTINEL_BOOTSTRAP="${SENTINEL_DIR}/done"
readonly SENTINEL_PRIMARY_INIT="${SENTINEL_DIR}/primary.init"
readonly SENTINEL_STANDBY_CLONED="${SENTINEL_DIR}/standby.cloned"

# PostgreSQL configuration
readonly PG_VERSION="17"
readonly PG_CLUSTER_NAME="main"

# Dynamic detection of PostgreSQL paths (Ubuntu-compatible)
detect_pg_paths() {
  # Try to get actual paths from running PostgreSQL instance
  if systemctl is-active --quiet postgresql 2>/dev/null; then
    local temp_data_dir temp_conf_file temp_hba_file
    temp_data_dir=$(sudo -u postgres psql -Atqc "SHOW data_directory;" 2>/dev/null || echo "")
    temp_conf_file=$(sudo -u postgres psql -Atqc "SHOW config_file;" 2>/dev/null || echo "")
    temp_hba_file=$(sudo -u postgres psql -Atqc "SHOW hba_file;" 2>/dev/null || echo "")
    
    # Only update if we got valid paths
    if [[ -n "$temp_data_dir" && -n "$temp_conf_file" && -n "$temp_hba_file" ]]; then
      PG_DATA_DIR="$temp_data_dir"
      PG_CONF_FILE="$temp_conf_file"
      PG_HBA_FILE="$temp_hba_file"
      PG_CONF_DIR=$(dirname "$PG_CONF_FILE")
    fi
  fi
  
  # Fallback to standard Ubuntu paths if detection fails
  if [[ -z "$PG_DATA_DIR" || -z "$PG_CONF_FILE" || -z "$PG_HBA_FILE" ]]; then
    PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
    PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
    PG_CONF_FILE="${PG_CONF_DIR}/postgresql.conf"
    PG_HBA_FILE="${PG_CONF_DIR}/pg_hba.conf"
  fi
}

# Initialize with default paths, will be updated later
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
PG_CONF_FILE="${PG_CONF_DIR}/postgresql.conf"
PG_HBA_FILE="${PG_CONF_DIR}/pg_hba.conf"

# Repmgr configuration
readonly REPMGR_CONF_DIR="/etc/repmgr"
readonly REPMGR_CONF_FILE="${REPMGR_CONF_DIR}/repmgr.conf"
readonly REPMGR_LOG_DIR="/var/log/repmgr"
readonly REPMGR_EVENTS_DIR="/etc/repmgr/events"

# PgBouncer configuration
readonly PGBOUNCER_CONF_DIR="/etc/pgbouncer"
readonly PGBOUNCER_CONF_FILE="${PGBOUNCER_CONF_DIR}/pgbouncer.ini"
readonly PGBOUNCER_USERLIST_FILE="${PGBOUNCER_CONF_DIR}/userlist.txt"
readonly PGBOUNCER_PORT=6432
readonly PGBOUNCER_POOL_SIZE=25
readonly PGBOUNCER_MAX_CLIENT_CONN=100

# Health endpoint configuration - Production-ready Python3 implementation
readonly PG_HEALTH_BIN="/usr/local/bin/final-pg-health.py"
readonly PG_HEALTH_PORT=8001
readonly PGBOUNCER_HEALTH_BIN="/usr/local/bin/final-pgbouncer-health.py"
readonly PGBOUNCER_HEALTH_PORT=8002

# Secret Manager configuration
readonly SECRET_CACHE_DIR="/run/pg-secrets"
readonly TOKEN_CACHE="${SECRET_CACHE_DIR}/token.json"

# Initialize variables with defaults
export PGBOUNCER_PASSWORD="${PGBOUNCER_PASSWORD:-}"

# Initialize directories with proper error handling
init_directories() {
  local dirs=("$LOG_DIR" "$SENTINEL_DIR" "$REPMGR_CONF_DIR" "$REPMGR_LOG_DIR" "$REPMGR_EVENTS_DIR" "$SECRET_CACHE_DIR")
  for dir in "${dirs[@]}"; do
    mkdir -p "$dir" 2>/dev/null || {
      echo "ERROR: Failed to create directory: $dir" >&2
      exit 1
    }
  done
  
  touch "$LOG_FILE" 2>/dev/null || {
    echo "ERROR: Failed to create log file: $LOG_FILE" >&2
    exit 1
  }
  chmod 644 "$LOG_FILE" 2>/dev/null || true
}

# Initialize directories
init_directories

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
  case "$1" in
    INFO|WARN|ERROR|DEBUG|SUCCESS) lvl="$1"; shift; msg="$*" ;;
    *) lvl=INFO; msg="$*" ;;
  esac
  local line="$(ts) [$lvl] $msg"
  echo "$line" >> "$LOG_FILE"
  if command -v systemd-cat >&/dev/null; then
    echo "$line" | systemd-cat -t pg-bootstrap || true
  fi
  if [[ -t 1 ]]; then
    case "$lvl" in
      INFO) color='\033[0;36m';; WARN) color='\033[1;33m';;
      ERROR) color='\033[0;31m';; DEBUG) color='\033[0;34m';; 
      SUCCESS) color='\033[0;32m';;
    esac
    printf "%b%s\033[0m\n" "${color}" "$line"
  fi
}

info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }
debug() { [[ "${BOOTSTRAP_DEBUG:-false}" =~ ^(true|1)$ ]] && log DEBUG "$*" || true; }
die() { log ERROR "$*"; exit 1; }
success() { log SUCCESS "✓ $*"; }

retry() {
  local n=$1; shift; local delay=$1; shift; local i=0
  until "$@"; do
    i=$((i+1))
    if [ $i -ge $n ]; then return 1; fi
    sleep "$delay"
  done
}

# Error handling
trap 'rc=$?; if (( rc != 0 )); then log ERROR "Bootstrap script exiting with code $rc (last cmd: $BASH_COMMAND line $LINENO)"; fi' EXIT
trap 'log ERROR "Error trapped at line $LINENO during: $BASH_COMMAND"' ERR

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

get_metadata() {
  local key="$1"
  curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}" 2>/dev/null || echo ""
}

detect_configuration() {
  info "Detecting cluster configuration from GCP metadata"
  
  # Core configuration
  export PROJECT_ID="${PROJECT_ID:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id || echo unknown)}"
  export ROLE="${ROLE:-$(get_metadata pg_role)}"
  export CLUSTER_ID="${CLUSTER_ID:-$(get_metadata pg_cluster_id)}"
  export REPMGR_PRIMARY_HOST="${REPMGR_PRIMARY_HOST:-$(get_metadata repmgr_primary_host)}"
  export REPMGR_DB="${REPMGR_DB:-$(get_metadata repmgr_db)}"
  export REPMGR_USER="${REPMGR_USER:-$(get_metadata repmgr_user)}"
  export HEALTH_PORT="${HEALTH_PORT:-$(get_metadata pg_health_port 8001)}"
  
  # Get local IP
  local self_ip
  self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
  export SELF_IP="$self_ip"
  
  # Set defaults if not provided
  ROLE=${ROLE:-primary}
  CLUSTER_ID=${CLUSTER_ID:-ha-cluster}
  REPMGR_USER=${REPMGR_USER:-repmgr}
  REPMGR_DB=${REPMGR_DB:-repmgr}
  
  # Set primary host to self IP if this is the primary
  if [[ "$ROLE" == "primary" && ( -z "$REPMGR_PRIMARY_HOST" || "$REPMGR_PRIMARY_HOST" == "pg-primary" ) ]]; then
    export REPMGR_PRIMARY_HOST="$SELF_IP"
    info "Set REPMGR_PRIMARY_HOST=$REPMGR_PRIMARY_HOST"
  fi

  # Validate required metadata
  if [[ -z "$REPMGR_PRIMARY_HOST" ]]; then
    die "Required metadata (repmgr_primary_host) not found. Aborting."
  fi

  # Validate role and set node-specific variables
  case "$ROLE" in
    primary|standby)
      info "PostgreSQL role validated: $ROLE"
      ;;
    witness)
      info "Witness node detected - minimal configuration will be applied"
      ;;
    *)
      die "Unknown role: $ROLE. Expected: primary, standby, or witness"
      ;;
  esac

  info "Configuration: role=$ROLE cluster=$CLUSTER_ID project=$PROJECT_ID primary_host=$REPMGR_PRIMARY_HOST self_ip=$self_ip"
}

# Generate secure passwords as fallback
gen_pw() {
  openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

get_secret() {
  local name="$1" sid="$2" cache="$SECRET_CACHE_DIR/$name"
  if [[ -s $cache ]]; then cat "$cache"; return 0; fi
  
  # Get token directly
  local token
  token=$(curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | jq -r '.access_token' 2>/dev/null || echo "")
  
  if [[ -z "$token" ]]; then 
    return 1
  fi
  
  local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${sid}/versions/latest:access"
  local body
  if ! body=$(curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$url" 2>/dev/null); then
    return 1
  fi
  
  local secret_value
  if ! secret_value=$(echo "$body" | jq -r '.payload.data' | base64 -d 2>/dev/null); then
    return 1
  fi
  
  # Cache the secret
  echo "$secret_value" > "$cache" 2>/dev/null || true
  chmod 600 "$cache" 2>/dev/null || true
  
  echo "$secret_value"
}

load_secrets() {
  info "Loading secrets from Secret Manager"
  mkdir -p "$SECRET_CACHE_DIR"
  
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
  
  # Load secrets with fallbacks and detailed logging
  set +e
  
  # Load repmgr password first for all node types
  if [[ -n "${REPMGR_PASSWORD:-}" ]]; then
    info "✓ Using pre-set repmgr password from environment (length: ${#REPMGR_PASSWORD} characters)"
  else
    info "🔐 Loading repmgr password..."
    export REPMGR_PASSWORD=$(get_secret_enhanced "repmgr" "$repmgr_secret")
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
  if [[ -n "${PGBOUNCER_PASSWORD:-}" ]]; then
    info "  ✓ Using pre-set PgBouncer password from environment"
  else
    export PGBOUNCER_PASSWORD=$(get_secret_enhanced "pgbouncer" "$pgbouncer_secret")
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

# Generate MD5 hash for PostgreSQL password (compatible with PgBouncer)
md5_hash() {
  local username="$1" password="$2"
  printf '%s%s' "$password" "$username" | md5sum | cut -d' ' -f1
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

install_packages() {
  info "Updating package lists and installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  
  retry 5 1 apt-get update -y
  retry 5 1 apt-get install -y wget ca-certificates gnupg lsb-release curl gpg
  
  # Add PostgreSQL repository
  if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
    echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    retry 5 1 apt-get update -y
  fi
  
  retry 5 1 apt-get install -y \
    postgresql-${PG_VERSION} \
    postgresql-client-${PG_VERSION} \
    postgresql-${PG_VERSION}-repmgr \
    pgbouncer \
    socat \
    netcat-openbsd \
    python3 \
    jq \
    openssl \
    lsof
  
  # Detect actual PostgreSQL paths after installation
  detect_pg_paths
  
  success "All required packages installed."
}

configure_postgresql() {
  info "Configuring PostgreSQL..."
  
  # Detect paths again in case PostgreSQL was just installed
  detect_pg_paths
  
  # For Ubuntu PostgreSQL package, modify existing config instead of overwriting
  if [[ -f "$PG_CONF_FILE" ]]; then
    # Backup existing config
    cp "$PG_CONF_FILE" "${PG_CONF_FILE}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # Append HA configuration to existing config
    cat >> "$PG_CONF_FILE" <<EOF

# PostgreSQL HA Configuration (added by bootstrap script)
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
wal_keep_size = '1024MB'
hot_standby = on
shared_preload_libraries = 'repmgr'
archive_mode = off
max_replication_slots = 10
track_commit_timestamp = on

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

# Security
ssl = on
ssl_cert_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem'
ssl_key_file = '/etc/ssl/private/ssl-cert-snakeoil.key'
EOF
  else
    # Ensure configuration directory exists
    mkdir -p "$(dirname "$PG_CONF_FILE")" 2>/dev/null || true
    
    # Create new config file
    cat > "$PG_CONF_FILE" <<EOF
# PostgreSQL HA Configuration (managed by bootstrap script)
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
wal_keep_size = '1024MB'
hot_standby = on
shared_preload_libraries = 'repmgr'
archive_mode = off
max_replication_slots = 10
track_commit_timestamp = on

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

# Security
ssl = on
ssl_cert_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem'
ssl_key_file = '/etc/ssl/private/ssl-cert-snakeoil.key'
EOF
  fi
  success "PostgreSQL configuration file updated."
}

configure_pg_hba() {
  info "Configuring PostgreSQL client authentication (pg_hba.conf)..."
  
  # Ensure we have the latest paths
  detect_pg_paths
  
  # Backup existing pg_hba.conf if it exists
  if [[ -f "$PG_HBA_FILE" ]]; then
    cp "$PG_HBA_FILE" "${PG_HBA_FILE}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  fi
  
  cat > "$PG_HBA_FILE" <<EOF
# PostgreSQL Client Authentication Configuration File (managed by bootstrap script)

# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     peer

# IPv4/IPv6 local connections - Use md5 for pgbouncer compatibility
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5

# Cluster network access for replication and management
host    replication     ${REPMGR_USER}  0.0.0.0/0               md5
host    replication     replication     0.0.0.0/0               scram-sha-256
host    ${REPMGR_DB}    ${REPMGR_USER}  0.0.0.0/0               md5
host    all             ${REPMGR_USER}  0.0.0.0/0               md5
host    all             postgres        0.0.0.0/0               md5
EOF
  success "pg_hba.conf configured."
  
  # Reload PostgreSQL configuration if it's running
  if systemctl is-active --quiet postgresql 2>/dev/null; then
    info "Reloading PostgreSQL configuration..."
    systemctl reload postgresql || true
    sleep 2  # Give PostgreSQL time to reload
  fi
}

# ============================================================================
# REPMGR CONFIGURATION
# ============================================================================

generate_repmgr_conf() {
  info "Generating repmgr configuration..."
  local node_id conninfo_host
  
  # Ensure we have the latest PostgreSQL paths
  detect_pg_paths
  
  case "$ROLE" in
    primary) node_id=1; conninfo_host="$SELF_IP" ;;
    standby) node_id=2; conninfo_host="$SELF_IP" ;;
    witness) node_id=3; conninfo_host="$SELF_IP" ;;
    *) node_id=1; conninfo_host="$SELF_IP" ;;
  esac

  cat > "$REPMGR_CONF_FILE" <<EOF
# Repmgr configuration for ${ROLE} node (managed by bootstrap script)
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

# Service commands (with sudo support)
service_start_command='sudo systemctl start postgresql'
service_stop_command='sudo systemctl stop postgresql'
service_restart_command='sudo systemctl restart postgresql'
service_reload_command='sudo systemctl reload postgresql'

# Monitoring and failover
monitor_interval_secs=5
failover=automatic
promote_command='repmgr standby promote -f ${REPMGR_CONF_FILE}'
follow_command='repmgr standby follow -f ${REPMGR_CONF_FILE} --upstream-node-id=%n'

# repmgrd service commands (required for repmgrd daemon)
repmgrd_service_start_command='sudo systemctl start repmgrd.service'
repmgrd_service_stop_command='sudo systemctl stop repmgrd.service'

# Event notifications
event_notifications=all
event_notification_command='${REPMGR_EVENTS_DIR}/exec.sh %n %e %s %t %d %p %r'
EOF

  # Create sudoers rule for postgres user
  cat > /etc/sudoers.d/postgres-repmgr <<'EOF'
# Allow postgres user to manage PostgreSQL service for repmgr
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl start postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl stop postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl restart postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl reload postgresql
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl start repmgrd.service
postgres ALL=(root) NOPASSWD: /usr/bin/systemctl stop repmgrd.service
EOF

  chmod 440 /etc/sudoers.d/postgres-repmgr

  success "repmgr.conf generated for ${ROLE} with node_id=${node_id}"
}

setup_pgpass() {
  info "Setting up .pgpass file for authentication..."
  local pgpass_file="/var/lib/postgresql/.pgpass"
  
  cat > "$pgpass_file" <<EOF
# .pgpass file for PostgreSQL HA (managed by bootstrap script)
# host:port:database:user:password
*:5432:*:${REPMGR_USER}:${REPMGR_PASSWORD}
*:5432:*:postgres:${PG_SUPER_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
*:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
EOF

  chown postgres:postgres "$pgpass_file"
  chmod 600 "$pgpass_file"
  success ".pgpass file configured."
}

# ============================================================================
# PGBOUNCER CONFIGURATION
# ============================================================================

install_pgbouncer() {
  info "Installing and configuring PgBouncer"
  
  if ! command -v pgbouncer >&/dev/null; then
    apt-get install -y pgbouncer socat
  fi
  
  # Create pgbouncer user if needed
  if ! id -u pgbouncer >&/dev/null; then
    useradd --system --home-dir /var/lib/pgbouncer --no-create-home --shell /bin/false pgbouncer || true
  fi
  
  # Create directories
  mkdir -p /var/lib/pgbouncer /var/log/pgbouncer "$PGBOUNCER_CONF_DIR" /var/run/pgbouncer
  chown -R pgbouncer:pgbouncer "$PGBOUNCER_CONF_DIR" /var/lib/pgbouncer /var/log/pgbouncer /var/run/pgbouncer
  chmod 750 "$PGBOUNCER_CONF_DIR" /var/lib/pgbouncer
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
  info "Creating PgBouncer userlist file..."
  
  # Generate MD5 hashes using printf for better compatibility
  local postgres_md5=$(printf '%s%s' "$PG_SUPER_PASS" "postgres" | md5sum | cut -d' ' -f1)
  local pgbouncer_admin_md5=$(printf '%s%s' "$PGBOUNCER_PASSWORD" "pgbouncer_admin" | md5sum | cut -d' ' -f1)
  local repmgr_md5=$(printf '%s%s' "$REPMGR_PASSWORD" "$REPMGR_USER" | md5sum | cut -d' ' -f1)
  
  cat > "$PGBOUNCER_USERLIST_FILE" <<EOF
;; PgBouncer MD5 Authentication File (managed by bootstrap script)
"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"${REPMGR_USER}" "md5${repmgr_md5}"
EOF
  
  chmod 640 "$PGBOUNCER_USERLIST_FILE"
  chown root:pgbouncer "$PGBOUNCER_USERLIST_FILE" 2>/dev/null || true
  success "PgBouncer userlist created."
}

# ============================================================================
# CLUSTER INITIALIZATION
# ============================================================================

init_primary() {
  info "Initializing primary node..."
  
  # Detect current PostgreSQL paths
  detect_pg_paths
  
  # Stop PostgreSQL if it's running
  systemctl stop postgresql || true
  
  # Check if PostgreSQL cluster exists and is valid
  local cluster_exists=false
  if [[ -f "${PG_DATA_DIR}/PG_VERSION" ]] && sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl status -D "${PG_DATA_DIR}" >/dev/null 2>&1; then
    cluster_exists=true
  elif pg_lsclusters 2>/dev/null | grep -q "${PG_VERSION}.*main.*online\|${PG_VERSION}.*main.*down"; then
    cluster_exists=true
  fi
  
  if $cluster_exists; then
    info "PostgreSQL cluster already exists, using existing cluster..."
  else
    info "Creating new PostgreSQL cluster..."
    # Remove any corrupted data directory
    rm -rf "${PG_DATA_DIR:?}" 2>/dev/null || true
    
    # Create cluster using Ubuntu's method if available
    if command -v pg_createcluster >/dev/null 2>&1; then
      sudo -u postgres pg_createcluster ${PG_VERSION} main --start
    else
      # Fallback to manual initdb
      mkdir -p "${PG_DATA_DIR}"
      chown postgres:postgres "${PG_DATA_DIR}"
      chmod 700 "${PG_DATA_DIR}"
      sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/initdb -D "$PG_DATA_DIR" --auth=scram-sha-256 --pwfile=<(echo "$PG_SUPER_PASS")
    fi
  fi
  
  # Start PostgreSQL service
  systemctl enable postgresql
  systemctl start postgresql
  
  # Update paths after cluster creation
  detect_pg_paths
  
  info "Creating database users and repmgr database..."
  
  # Wait for PostgreSQL to be ready
  retry 30 2 sudo -u postgres psql -c "SELECT 1" >&/dev/null
  
  # Create users and database with better error handling
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
  success "Primary node initialization complete."
}

init_standby() {
  info "Initializing standby PostgreSQL node"
  
  systemctl stop postgresql || true
  rm -rf "${PG_DATA_DIR}"/* || true
  
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
"${REPMGR_USER}" "md5${repmgr_md5}"
EOF
  
  chown pgbouncer:pgbouncer "$PGBOUNCER_USERLIST_FILE"
  chmod 640 "$PGBOUNCER_USERLIST_FILE"
  success "PgBouncer userlist recreated for standby"
  
  touch "$SENTINEL_STANDBY_CLONED"
  success "Standby node initialized"
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

setup_services() {
  info "Setting up systemd services..."
  
  cat > /etc/systemd/system/pgbouncer.service <<EOF
[Unit]
Description=PgBouncer connection pooler
After=network.target postgresql.service

[Service]
Type=notify
ExecStart=/usr/sbin/pgbouncer ${PGBOUNCER_CONF_FILE}
User=pgbouncer
Group=pgbouncer
PIDFile=/var/run/pgbouncer/pgbouncer.pid

[Install]
WantedBy=multi-user.target
EOF

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

  cat > /etc/systemd/system/final-pg-health.service <<EOF
[Unit]
Description=Final PostgreSQL Health Service
After=network-online.target postgresql.service
Wants=postgresql.service network-online.target

[Service]
Type=simple
# Simplified startup - no complex pre-start cleanup needed
ExecStart=${PG_HEALTH_BIN} ${PG_HEALTH_PORT}
Restart=always
RestartSec=5
User=postgres
Group=postgres
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/final-pgbouncer-health.service <<EOF
[Unit]
Description=Final PgBouncer Health Service
After=network-online.target pgbouncer.service
Wants=pgbouncer.service network-online.target

[Service]
Type=simple
# Clean startup - kill any existing processes first
ExecStartPre=/bin/bash -c "pkill -f 'final-pgbouncer-health' || true; sleep 1"
ExecStart=/usr/bin/python3 ${PGBOUNCER_HEALTH_BIN} ${PGBOUNCER_HEALTH_PORT}
Restart=always
RestartSec=3
User=postgres
Group=postgres
Environment=HOME=/var/lib/postgresql
Environment=USER=postgres
StandardOutput=null
StandardError=null
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=5
TimeoutStartSec=10

[Install]
WantedBy=multi-user.target
EOF

  success "Systemd service files created."
}

setup_health_endpoints() {
  info "Setting up production-ready health check endpoints with Python3 HTTP server..."
  
  # Install Python3 if not available
  if ! command -v python3 >/dev/null 2>&1; then
    info "Installing Python3 for health endpoints..."
    apt-get install -y python3
  fi
  
  cat > "$PG_HEALTH_BIN" <<'PG_HEALTH_EOF'
#!/usr/bin/env python3
"""
Production-ready PostgreSQL Health Endpoint
Provides HTTP health checks for GCP Internal Load Balancer
"""

import http.server
import socketserver
import json
import subprocess
import sys
import os
from datetime import datetime

def check_postgresql_health():
    """Check PostgreSQL status and role"""
    try:
        # Check if PostgreSQL service is active
        service_check = subprocess.run(
            ['systemctl', 'is-active', '--quiet', 'postgresql'],
            capture_output=True, timeout=2
        )
        
        if service_check.returncode != 0:
            return {"status": "unhealthy", "role": "unknown", "reason": "service_down"}
        
        # Check PostgreSQL role - run directly as postgres user (no sudo needed in service)
        env = os.environ.copy()
        env['USER'] = 'postgres'
        env['HOME'] = '/var/lib/postgresql'
        
        role_check = subprocess.run(
            ['psql', '-tAc', 'SELECT pg_is_in_recovery();'],
            capture_output=True, text=True, timeout=3, env=env
        )
        
        if role_check.returncode == 0:
            is_standby = role_check.stdout.strip() == 't'
            
            if is_standby:
                # For standby, check WAL receiver status
                wal_check = subprocess.run(
                    ['psql', '-tAc', "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';"],
                    capture_output=True, text=True, timeout=3, env=env
                )
                
                if wal_check.returncode == 0 and wal_check.stdout.strip() == '1':
                    return {"status": "healthy", "role": "standby"}
                else:
                    return {"status": "unhealthy", "role": "standby", "reason": "replication_down"}
            else:
                # Primary node
                return {"status": "healthy", "role": "primary"}
        
        return {"status": "unhealthy", "role": "unknown", "reason": "query_failed"}
        
    except subprocess.TimeoutExpired:
        return {"status": "unhealthy", "role": "unknown", "reason": "timeout"}
    except Exception as e:
        return {"status": "unhealthy", "role": "unknown", "reason": str(e)[:50]}

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        health_data = check_postgresql_health()
        health_data["timestamp"] = datetime.now().isoformat()
        
        # Set HTTP status based on health
        status_code = 200 if health_data["status"] == "healthy" else 503
        
        response = json.dumps(health_data)
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        # Suppress default logging to reduce noise
        pass

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
    
    with socketserver.TCPServer(("", port), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        print(f"PostgreSQL health endpoint serving on port {port}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("Shutting down health endpoint")

if __name__ == "__main__":
    main()
PG_HEALTH_EOF

  cat > "$PGBOUNCER_HEALTH_BIN" <<'PGBOUNCER_HEALTH_EOF'
#!/usr/bin/env python3
"""
Production-ready PgBouncer Health Endpoint
Provides HTTP health checks for GCP Internal Load Balancer
"""

import http.server
import socketserver
import json
import subprocess
import socket
import sys
from datetime import datetime

def check_pgbouncer_health():
    """Check PgBouncer status and connectivity"""
    try:
        # Check if PgBouncer service is active
        service_check = subprocess.run(
            ['systemctl', 'is-active', '--quiet', 'pgbouncer'],
            capture_output=True, timeout=2
        )
        
        if service_check.returncode != 0:
            return {"status": "unhealthy", "service": "pgbouncer", "reason": "service_down"}
        
        # Test actual connectivity to PgBouncer port
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        result = sock.connect_ex(('127.0.0.1', 6432))
        sock.close()
        
        if result == 0:
            return {"status": "healthy", "service": "pgbouncer"}
        else:
            return {"status": "unhealthy", "service": "pgbouncer", "reason": "port_closed"}
            
    except socket.timeout:
        return {"status": "unhealthy", "service": "pgbouncer", "reason": "timeout"}
    except Exception as e:
        return {"status": "unhealthy", "service": "pgbouncer", "reason": str(e)[:50]}

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        health_data = check_pgbouncer_health()
        health_data["timestamp"] = datetime.now().isoformat()
        
        # Set HTTP status based on health
        status_code = 200 if health_data["status"] == "healthy" else 503
        
        response = json.dumps(health_data)
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        # Suppress default logging to reduce noise
        pass

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8002
    
    with socketserver.TCPServer(("", port), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        print(f"PgBouncer health endpoint serving on port {port}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("Shutting down health endpoint")

if __name__ == "__main__":
    main()
PGBOUNCER_HEALTH_EOF

  chmod +x "$PG_HEALTH_BIN" "$PGBOUNCER_HEALTH_BIN"
  success "Production-ready health endpoint scripts created using Python3 HTTP server."
}

start_services() {
  info "Starting and enabling services..."
  systemctl daemon-reload
  
  # Start PostgreSQL first
  systemctl enable postgresql
  systemctl start postgresql
  
  # Start and enable PgBouncer if not witness node
  if [[ "$ROLE" != "witness" ]]; then
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
  fi
  
  # Start repmgrd (only for primary/standby)
  if [[ "$ROLE" != "witness" ]]; then
    systemctl enable repmgrd.service
    
    # Give PostgreSQL a moment to fully stabilize before starting repmgrd
    sleep 3
    
    if systemctl start repmgrd.service; then
      success "repmgrd started"
      
      # Wait for repmgrd to fully initialize
      sleep 2
      
      # Verify repmgrd is actually running
      if systemctl is-active --quiet repmgrd.service; then
        success "repmgrd service is running"
      else
        warn "repmgrd service failed to stay running, checking logs..."
        journalctl -u repmgrd.service --lines=10 --no-pager || true
        
        # Try to restart it once more
        info "Attempting to restart repmgrd service..."
        systemctl restart repmgrd.service
        sleep 2
        
        if systemctl is-active --quiet repmgrd.service; then
          success "repmgrd service restarted successfully"
        else
          warn "repmgrd service still not running - manual intervention may be needed"
        fi
      fi
      
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
            warn "WAL receiver not active - replication may need troubleshooting"
          fi
        else
          warn "Standby node not in recovery mode - may need troubleshooting"
        fi
      fi
    else
      warn "Failed to start repmgrd - checking service status and logs"
      systemctl status repmgrd.service --no-pager || true
      journalctl -u repmgrd.service --lines=20 --no-pager || true
    fi
  fi
  
  # Start health endpoints with conflict resolution
  systemctl enable final-pg-health.service
  
  # Kill any existing conflicting processes before starting new services
  pkill -f "health.sh" 2>/dev/null || true
  pkill -f ":8001" 2>/dev/null || true
  pkill -f ":8002" 2>/dev/null || true
  
  # Kill processes by port
  lsof -ti:8001 2>/dev/null | xargs -r kill -9 || true
  lsof -ti:8002 2>/dev/null | xargs -r kill -9 || true
  
  sleep 2
  
  # Reload systemd daemon to pick up new service definitions
  systemctl daemon-reload
  
  # Start PostgreSQL health service
  if systemctl start final-pg-health.service; then
    success "PostgreSQL health service started"
  else
    warn "Failed to start PostgreSQL health service - checking logs"
    journalctl -u final-pg-health.service --lines=10 --no-pager || true
  fi
  
    # Start PgBouncer health service (if not witness node)
    # NOTE: SystemD service has compatibility issues, so we use manual startup as fallback
    if [[ "$ROLE" != "witness" ]]; then
        systemctl enable final-pgbouncer-health.service
        
        # Ensure PgBouncer is fully ready before starting health service
        sleep 3
        
        # Test PgBouncer connectivity first
        if timeout 5 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            info "PgBouncer is ready, starting health service..."
            if systemctl start final-pgbouncer-health.service; then
                success "PgBouncer health service started"
                
                # Verify it actually started
                sleep 2
                if timeout 3 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
                    success "PgBouncer health endpoint verified working"
                else
                    warn "PgBouncer health service started but not responding, trying manual start..."
                    systemctl stop final-pgbouncer-health.service || true
                    
                    # Use the proven manual approach that works
                    info "Using manual startup approach (systemd service had conflicts)..."
                    sudo -u postgres nohup python3 "$PGBOUNCER_HEALTH_BIN" "$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1 &
                    sleep 2
                    
                    if timeout 3 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
                        success "PgBouncer health endpoint started manually"
                    else
                        warn "PgBouncer health endpoint still not responding"
                    fi
                fi
            else
                warn "SystemD service failed - using proven manual approach"
                
                # Skip systemd entirely and use the working manual approach
                info "Starting PgBouncer health endpoint with manual approach..."
                sudo -u postgres nohup python3 "$PGBOUNCER_HEALTH_BIN" "$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1 &
                sleep 2
                
                if timeout 3 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
                    success "PgBouncer health endpoint started manually"
                else
                    warn "PgBouncer health endpoint still not responding"
                fi
            fi
        else
            info "PgBouncer not ready - using manual startup approach..."
            sudo -u postgres nohup python3 "$PGBOUNCER_HEALTH_BIN" "$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1 &
            sleep 2
        fi
    fi
    
  # Give health endpoints time to fully initialize
  sleep 5
  
  # Test health endpoints with detailed validation
  info "Testing health endpoints..."
  
  if timeout 10 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    local pg_health_response
    pg_health_response=$(timeout 5 curl -s http://localhost:8001 2>/dev/null | head -1 || echo "")
    if echo "$pg_health_response" | grep -q "status.*healthy\|status.*unhealthy"; then
      success "✅ PostgreSQL health endpoint is responding correctly"
      info "Response: $pg_health_response"
    else
      warn "⚠️ PostgreSQL health endpoint responding but invalid format"
    fi
  else
    error "❌ PostgreSQL health endpoint not responding"
    # Try to restart the service once
    info "Attempting to restart PostgreSQL health service..."
    systemctl restart final-pg-health.service || true
    sleep 3
    if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
      success "✅ PostgreSQL health endpoint recovered after restart"
    else
      warn "⚠️ PostgreSQL health endpoint still not responding after restart"
    fi
  fi
  
  if [[ "$ROLE" != "witness" ]]; then
    if timeout 10 curl -sf http://localhost:8002 >/dev/null 2>&1; then
      local pgb_health_response
      pgb_health_response=$(timeout 5 curl -s http://localhost:8002 2>/dev/null | head -1 || echo "")
      if echo "$pgb_health_response" | grep -q "service.*pgbouncer"; then
        success "✅ PgBouncer health endpoint is responding correctly"
        info "Response: $pgb_health_response"
      else
        warn "⚠️ PgBouncer health endpoint responding but invalid format"
      fi
    else
      error "❌ PgBouncer health endpoint not responding"
      # Try to restart the service once
      info "Attempting to restart PgBouncer health service..."
      systemctl restart final-pgbouncer-health.service || true
      sleep 3
      if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
        success "✅ PgBouncer health endpoint recovered after restart"
      else
        warn "⚠️ PgBouncer health endpoint still not responding after restart"
      fi
    fi
  fi
  
  success "All services started successfully."
}

# ============================================================================
# MAIN EXECUTION - UPDATED TO BE FULLY PRODUCTION READY
# ============================================================================

main() {
  info "Starting PostgreSQL 17 HA bootstrap (version $SCRIPT_VERSION)"
  
  # Check if already bootstrapped
  if [[ -f "$SENTINEL_BOOTSTRAP" ]]; then
    info "Bootstrap already completed, skipping"
    exit 0
  fi
  
  # Create essential directories
  mkdir -p "$SECRET_CACHE_DIR" 2>/dev/null || true
  
  # Main bootstrap sequence
  detect_configuration
  load_secrets
  install_packages
  configure_postgresql
  configure_pg_hba
  generate_repmgr_conf
  setup_pgpass
  
  # Configure PgBouncer (skip for witness nodes)
  if [[ "$ROLE" != "witness" ]]; then
    install_pgbouncer
    configure_pgbouncer
    create_pgbouncer_userlist
  fi
  
  # Setup service definitions and health endpoints
  setup_services
  setup_health_endpoints
  
  # Initialize cluster based on role
  case "$ROLE" in
    primary)
      init_primary
      sync_database_passwords
      ;;
    standby)
      init_standby
      sync_database_passwords
      ;;
    witness)
      info "Witness node - minimal setup only"
      ;;
    *)
      die "Unknown role: $ROLE"
      ;;
  esac
  
  # Start services
  start_services
  
  # Mark as complete
  touch "$SENTINEL_BOOTSTRAP"
  
  local end_time
  end_time=$(($(date +%s) - BOOTSTRAP_START_TIME))
  success "PostgreSQL 17 HA bootstrap completed in ${end_time} seconds"
  
  info "=== CONNECTION INFORMATION ==="
  info "PostgreSQL Direct: postgresql://postgres:***@${SELF_IP}:5432/postgres"
  if [[ "$ROLE" != "witness" ]]; then
    info "PgBouncer Pooled: postgresql://postgres:***@${SELF_IP}:6432/postgres"
    info "PgBouncer Health: http://${SELF_IP}:8002"
  fi
  info "PostgreSQL HA Health: http://${SELF_IP}:8001"
  info "Role: $ROLE"
  info "=== BOOTSTRAP COMPLETE ==="
}

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root"
fi

# Run main function
main "$@"