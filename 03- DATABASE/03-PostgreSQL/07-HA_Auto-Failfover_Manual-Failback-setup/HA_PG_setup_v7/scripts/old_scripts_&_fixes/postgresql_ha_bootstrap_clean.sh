#!/bin/bash
# PostgreSQL High Availability Cluster Bootstrap Script - Production Ready
# Fully automated startup script for GCP Compute Engine instances
# 
# Features:
# - Fully automated single-run execution with comprehensive error handling
# - Secret Manager integration for secure credential management
# - Terraform infrastructure-aware configuration
# - PostgreSQL 17 + repmgr HA cluster with automatic failover
# - PgBouncer connection pooling with health endpoints for GCP ILB
# - Comprehensive logging and diagnostics
# 
# Version: 3.0.1

set -euo pipefailostgreSQL High Availability Cluster Bootstrap Script - Production Ready
# Fully automated startup script for GCP Compute Engine instances
# 
# Features:
# - Fully automated single-run execution with comprehensive error handling
# - Secret Manager integration for secure credential management
# - Terraform infrastructure-aware configuration
# - PostgreSQL 17 + repmgr HA cluster with automatic failover
# - PgBouncer connection pooling with health endpoints for GCP ILB
# - Comprehensive logging and diagnostics
# 
# Version: 3.0.0

set -euo pipefail

# ============================================================================
# CONFIGURATION & GLOBAL VARIABLES
# ============================================================================

readonly SCRIPT_VERSION="3.0.0"
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
readonly PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
readonly PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
readonly PG_CONF_FILE="${PG_CONF_DIR}/postgresql.conf"
readonly PG_HBA_FILE="${PG_CONF_DIR}/pg_hba.conf"

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

# Health endpoint configuration
readonly PG_HEALTH_BIN="/usr/local/bin/pg-ha-health.sh"
readonly PG_HEALTH_PORT=8001
readonly PGBOUNCER_HEALTH_BIN="/usr/local/bin/pgbouncer-health.sh"
readonly PGBOUNCER_HEALTH_PORT=8002

# Secret Manager configuration
readonly SECRET_CACHE_DIR="/run/pg-secrets"
readonly TOKEN_CACHE="${SECRET_CACHE_DIR}/token.json"

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
  local lvl msg color='\033[0m'
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
    printf "%b%s\033[0m\n" "$color" "$line"
  fi
}

info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }
debug() { [[ "${BOOTSTRAP_DEBUG:-false}" =~ ^(true|1)$ ]] && log DEBUG "$*" || true; }
die() { log ERROR "$*"; exit 1; }
success() { log SUCCESS "✓ $*"; }

retry() {
  local retries=$1; shift
  local count=0
  until "$@"; do
    exit=$?
    count=$((count + 1))
    if [ $count -lt "$retries" ]; then
      warn "Command failed. Attempt $count/$retries. Retrying in 5 seconds..."
      sleep 5
    else
      error "Command failed after $retries attempts. Giving up."
      return $exit
    fi
  done
  return 0
}

# Error handling
trap 'rc=$?; if (( rc != 0 )); then log ERROR "Bootstrap script exiting with code $rc (last cmd: $BASH_COMMAND line $LINENO)"; fi' EXIT
trap 'log ERROR "Error trapped at line $LINENO during: $BASH_COMMAND"' ERR

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

get_metadata() {
  local key="$1"
  curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}"
}

detect_configuration() {
  info "Detecting node configuration from instance metadata..."
  ROLE=$(get_metadata "pg_role")
  PG_CLUSTER_ID=$(get_metadata "pg_cluster_id")
  REPMGR_PRIMARY_HOST=$(get_metadata "repmgr_primary_host")
  REPMGR_STANDBY_HOST=$(get_metadata "repmgr_standby_host")
  REPMGR_USER=$(get_metadata "repmgr_user")
  REPMGR_DB=$(get_metadata "repmgr_db")
  PG_SUPERUSER_SECRET_ID=$(get_metadata "pg_superuser_secret_id")
  PG_REPLICATION_SECRET_ID=$(get_metadata "pg_replication_secret_id")
  PG_MONITOR_SECRET_ID=$(get_metadata "pg_monitor_secret_id" || echo "")
  REPMGR_SECRET_ID=$(get_metadata "repmgr_secret_id")
  PGBOUNCER_SECRET_ID=$(get_metadata "pgbouncer_secret_id")

  # Environmental codes for naming consistency
  ORG_CODE=$(get_metadata "org_code" || echo "ipa")
  ENV_CODE=$(get_metadata "env_code" || echo "nprd")

  # Validate required metadata
  if [[ -z "$ROLE" || -z "$REPMGR_PRIMARY_HOST" || -z "$PG_SUPERUSER_SECRET_ID" ]]; then
    die "Required metadata (pg_role, repmgr_primary_host, pg_superuser_secret_id) not found. Aborting."
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

  success "Configuration detected: ROLE=${ROLE}, PRIMARY=${REPMGR_PRIMARY_HOST}, CLUSTER_ID=${PG_CLUSTER_ID}"
}

get_secret() {
  local secret_id="$1" project_id
  project_id=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
  
  if [[ ! -f "$TOKEN_CACHE" || $(date +%s -r "$TOKEN_CACHE" 2>/dev/null || echo 0) -lt $(($(date +%s) - 3000)) ]]; then
    info "Fetching new GCP auth token..."
    mkdir -p "$(dirname "$TOKEN_CACHE")"
    curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" > "$TOKEN_CACHE"
  fi
  
  local token
  token=$(jq -r .access_token < "$TOKEN_CACHE")
  
  local response
  response=$(curl -sf -X GET "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${secret_id}/versions/latest:access" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json")
  
  if echo "$response" | jq -e '.payload.data' > /dev/null; then
    echo "$response" | jq -r '.payload.data' | base64 -d
  else
    error "Failed to retrieve secret: ${secret_id}. Response: ${response}"
    return 1
  fi
}

load_secrets() {
  info "Loading secrets from Secret Manager..."
  PG_SUPER_PASS=$(get_secret "$PG_SUPERUSER_SECRET_ID")
  PG_REPL_PASS=$(get_secret "$PG_REPLICATION_SECRET_ID")
  REPMGR_PASSWORD=$(get_secret "$REPMGR_SECRET_ID")
  PGBOUNCER_PASSWORD=$(get_secret "$PGBOUNCER_SECRET_ID")

  if [[ -z "$PG_SUPER_PASS" || -z "$PG_REPL_PASS" || -z "$REPMGR_PASSWORD" || -z "$PGBOUNCER_PASSWORD" ]]; then
    die "Failed to load one or more critical secrets. Aborting."
  fi
  
  export PG_SUPER_PASS PG_REPL_PASS REPMGR_PASSWORD PGBOUNCER_PASSWORD
  success "All secrets loaded successfully."
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

install_packages() {
  info "Updating package lists and installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  
  retry 5 apt-get update -y
  retry 5 apt-get install -y wget ca-certificates gnupg lsb-release curl gpg
  
  # Add PostgreSQL repository
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
  echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  
  # Add PgBouncer repository
  curl -fsSL https://pgbouncer.github.io/keys/pgbouncer.key | gpg --dearmor -o /usr/share/keyrings/pgbouncer-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/pgbouncer-archive-keyring.gpg] https://pgbouncer.github.io/repos/debian $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/pgbouncer.list
  
  retry 5 apt-get update -y
  retry 5 apt-get install -y \
    postgresql-${PG_VERSION} \
    postgresql-client-${PG_VERSION} \
    postgresql-${PG_VERSION}-repmgr \
    pgbouncer \
    socat \
    netcat-openbsd \
    jq \
    systemd-container
  
  success "All required packages installed."
}

configure_postgresql() {
  info "Configuring PostgreSQL..."
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
  success "PostgreSQL configuration file updated."
}

configure_pg_hba() {
  info "Configuring PostgreSQL client authentication (pg_hba.conf)..."
  
  cat > "$PG_HBA_FILE" <<EOF
# PostgreSQL Client Authentication Configuration File (managed by bootstrap script)

# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     peer

# IPv4/IPv6 local connections - Use md5 for pgbouncer compatibility
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5

# Cluster network access for replication and management
host    replication     replication     0.0.0.0/0               scram-sha-256
host    ${REPMGR_DB}    ${REPMGR_USER}  0.0.0.0/0               md5
host    all             postgres        0.0.0.0/0               md5
EOF
  success "pg_hba.conf configured."
}

# ============================================================================
# REPMGR CONFIGURATION
# ============================================================================

generate_repmgr_conf() {
  info "Generating repmgr configuration..."
  local node_id
  local conninfo_host
  
  if [[ "$ROLE" == "primary" ]]; then
    node_id=1
    conninfo_host=$REPMGR_PRIMARY_HOST
  elif [[ "$ROLE" == "standby" ]]; then
    node_id=2
    conninfo_host=$REPMGR_STANDBY_HOST
  elif [[ "$ROLE" == "witness" ]]; then
    node_id=3
    conninfo_host=$(hostname -I | awk '{print $1}')
  else
    die "Unknown role: ${ROLE}"
  fi

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
EOF

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

configure_pgbouncer() {
  info "Configuring PgBouncer..."
  local pool_mode="session"
  local max_client_conn="$PGBOUNCER_MAX_CLIENT_CONN"
  
  if [[ "$ROLE" == "standby" ]]; then
    pool_mode="transaction"
    max_client_conn="$PGBOUNCER_MAX_CLIENT_CONN"
  fi

  cat > "$PGBOUNCER_CONF_FILE" <<EOF
;; PgBouncer HA configuration (managed by bootstrap script)

[databases]
postgres = host=127.0.0.1 port=5432 dbname=postgres
template1 = host=127.0.0.1 port=5432 dbname=template1
${REPMGR_DB} = host=127.0.0.1 port=5432 dbname=${REPMGR_DB}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${PGBOUNCER_PORT}

auth_type = md5
auth_file = ${PGBOUNCER_USERLIST_FILE}

pool_mode = ${pool_mode}
max_client_conn = ${max_client_conn}
default_pool_size = ${PGBOUNCER_POOL_SIZE}
reserve_pool_size = 5
max_db_connections = $((${PGBOUNCER_POOL_SIZE} * 2))

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
  success "PgBouncer configuration file updated."
}

create_pgbouncer_userlist() {
  info "Creating PgBouncer userlist file..."
  
  local postgres_md5=$(md5_hash "postgres" "$PG_SUPER_PASS")
  local pgbouncer_admin_md5=$(md5_hash "pgbouncer_admin" "$PGBOUNCER_PASSWORD")
  local repmgr_md5=$(md5_hash "$REPMGR_USER" "$REPMGR_PASSWORD")
  
  cat > "$PGBOUNCER_USERLIST_FILE" <<EOF
;; PgBouncer MD5 Authentication File (managed by bootstrap script)
"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"${REPMGR_USER}" "md5${repmgr_md5}"
EOF
  
  chmod 640 "$PGBOUNCER_USERLIST_FILE"
  chown root:pgbouncer "$PGBOUNCER_USERLIST_FILE"
  success "PgBouncer userlist created."
}

# Generate MD5 hash for PostgreSQL password (compatible with PgBouncer)
md5_hash() {
  local username="$1" password="$2"
  echo -n "${password}${username}" | md5sum | cut -d' ' -f1
}

# ============================================================================
# CLUSTER INITIALIZATION
# ============================================================================

init_primary() {
  info "Initializing primary node..."
  
  # Stop PostgreSQL if it's running
  systemctl stop postgresql || true
  
  # Initialize PostgreSQL cluster if data directory is empty
  if [ ! -d "${PG_DATA_DIR}/base" ]; then
    sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/initdb -D "$PG_DATA_DIR" --auth=scram-sha-256 --pwfile=<(echo "$PG_SUPER_PASS")
  else
    warn "Data directory not empty. Skipping initdb."
  fi
  
  systemctl start postgresql
  
  info "Creating database users and repmgr database..."
  sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${PG_SUPER_PASS}';"
  sudo -u postgres psql -c "CREATE USER ${REPMGR_USER} WITH SUPERUSER PASSWORD '${REPMGR_PASSWORD}';" || warn "User ${REPMGR_USER} already exists."
  sudo -u postgres psql -c "CREATE USER replication WITH REPLICATION PASSWORD '${PG_REPL_PASS}';" || warn "User replication already exists."
  sudo -u postgres psql -c "CREATE DATABASE ${REPMGR_DB} WITH OWNER = ${REPMGR_USER};" || warn "Database ${REPMGR_DB} already exists."
  
  info "Installing repmgr extension..."
  sudo -u postgres psql -d "${REPMGR_DB}" -c "CREATE EXTENSION IF NOT EXISTS repmgr;"
  
  info "Registering primary node with repmgr..."
  retry 5 sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" primary register --force
  
  touch "$SENTINEL_PRIMARY_INIT"
  success "Primary node initialization complete."
}

init_standby() {
  info "Initializing standby node..."
  
  # Stop PostgreSQL if it's running
  systemctl stop postgresql || true
  
  info "Waiting for primary node to be ready..."
  retry 20 nc -zv "$REPMGR_PRIMARY_HOST" 5432
  
  info "Cloning data from primary node..."
  rm -rf "${PG_DATA_DIR:?}/"*
  retry 3 sudo -u postgres repmgr -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF_FILE" standby clone --dry-run
  retry 3 sudo -u postgres repmgr -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF_FILE" standby clone
  
  systemctl start postgresql
  
  info "Registering standby node with repmgr..."
  retry 5 sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" standby register --force
  
  touch "$SENTINEL_STANDBY_CLONED"
  success "Standby node initialization complete."
}

sync_database_passwords() {
  info "Syncing additional database users and passwords..."
  sudo -u postgres psql <<EOF || warn "Some users may already exist"
-- Set password_encryption to md5 temporarily for pgbouncer compatibility
SET password_encryption = 'md5';

-- Create pgbouncer_admin user
CREATE ROLE pgbouncer_admin WITH LOGIN PASSWORD '${PGBOUNCER_PASSWORD}';

-- Grant necessary permissions for PgBouncer admin operations
GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
GRANT CONNECT ON DATABASE template1 TO pgbouncer_admin;
GRANT CONNECT ON DATABASE ${REPMGR_DB} TO pgbouncer_admin;

-- Grant usage on public schema and basic table permissions
GRANT USAGE ON SCHEMA public TO pgbouncer_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgbouncer_admin;

-- Make sure pgbouncer_admin can access pgbouncer's internal stats
ALTER ROLE pgbouncer_admin SET log_statement = 'none';

-- Reset password_encryption
RESET password_encryption;
EOF
  success "PgBouncer admin user configured."
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
Requires=postgresql.service

[Service]
Type=notify
User=pgbouncer
Group=pgbouncer
ExecStart=/usr/sbin/pgbouncer ${PGBOUNCER_CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/var/run/pgbouncer/pgbouncer.pid
Restart=always
RestartSec=5

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
ExecStart=/usr/bin/repmgrd -f ${REPMGR_CONF_FILE} --daemonize=false
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/pg-ha-health.service <<EOF
[Unit]
Description=PostgreSQL HA Health Check Endpoint
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
ExecStart=${PG_HEALTH_BIN} ${PG_HEALTH_PORT}
Restart=always
RestartSec=5
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/pgbouncer-health.service <<EOF
[Unit]
Description=PgBouncer HA Health Check Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
ExecStart=${PGBOUNCER_HEALTH_BIN} ${PGBOUNCER_HEALTH_PORT}
Restart=always
RestartSec=5
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

  success "Systemd service files created."
}

start_services() {
  info "Starting and enabling services..."
  systemctl daemon-reload
  
  # Start PostgreSQL first
  systemctl enable postgresql
  systemctl start postgresql
  
  # Start PgBouncer if not witness node
  if [[ "$ROLE" != "witness" ]]; then
    systemctl enable pgbouncer
    systemctl start pgbouncer
  fi
  
  # Only start repmgrd after successful registration
  if [[ -f "$SENTINEL_PRIMARY_INIT" || -f "$SENTINEL_STANDBY_CLONED" ]]; then
    systemctl enable repmgrd
    systemctl start repmgrd
  fi
  
  # Start health endpoints
  systemctl enable pg-ha-health.service
  systemctl start pg-ha-health.service
  
  if [[ "$ROLE" != "witness" ]]; then
    systemctl enable pgbouncer-health.service
    systemctl start pgbouncer-health.service
  fi
  
  success "All services started successfully."
}

# ============================================================================
# HEALTH ENDPOINTS
# ============================================================================

setup_health_endpoints() {
  info "Setting up health check endpoints..."
  
  cat > "$PG_HEALTH_BIN" <<'PG_HEALTH_EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8001}

handle_request() {
  local status_code="503"
  local role="unknown"
  local response_body=""
  
  if systemctl is-active --quiet postgresql; then
    if sudo -u postgres psql -tAc "SELECT NOT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
      status_code="200"
      role="primary"
    else
      status_code="503"
      role="standby"
    fi
  fi
  
  response_body="{\"status\": \"$([ "$status_code" = "200" ] && echo healthy || echo unhealthy)\", \"role\": \"$role\", \"timestamp\": \"$(date -Iseconds)\"}"
  content_length=${#response_body}
  
  if [[ "$status_code" = "200" ]]; then
    cat <<RESP_EOF
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: $content_length

$response_body
RESP_EOF
  else
    cat <<RESP_EOF
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
Content-Length: $content_length

$response_body
RESP_EOF
  fi
}

if command -v socat >&/dev/null; then
  while true; do
    handle_request | socat -T 3 - TCP-LISTEN:$PORT,reuseaddr,fork
  done
else
  while true; do
    nc -l -p $PORT -c 'handle_request'
  done
fi
PG_HEALTH_EOF

  cat > "$PGBOUNCER_HEALTH_BIN" <<'PGBOUNCER_EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8002}

check_pgbouncer() {
  if systemctl is-active --quiet pgbouncer && nc -zv localhost 6432 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

handle_request() {
  local status_code="503"
  local service_status="unhealthy"
  local response_body=""
  
  if check_pgbouncer; then
    status_code="200"
    service_status="healthy"
  fi
  
  response_body="{\"status\": \"$service_status\", \"service\": \"pgbouncer\", \"timestamp\": \"$(date -Iseconds)\"}"
  content_length=${#response_body}
  
  if [[ "$status_code" = "200" ]]; then
    cat <<RESP_EOF
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: $content_length

$response_body
RESP_EOF
  else
    cat <<RESP_EOF
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
Content-Length: $content_length

$response_body
RESP_EOF
  fi
}

if command -v socat >&/dev/null; then
  while true; do
    handle_request | socat -T 3 - TCP-LISTEN:$PORT,reuseaddr,fork
  done
else
  while true; do
    nc -l -p $PORT -c 'handle_request'
  done
fi
PGBOUNCER_EOF

  chmod +x "$PG_HEALTH_BIN" "$PGBOUNCER_HEALTH_BIN"
  success "Health endpoint scripts created."
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
  info "Starting PostgreSQL HA bootstrap (version $SCRIPT_VERSION)..."
  
  # Check if already bootstrapped
  if [[ -f "$SENTINEL_BOOTSTRAP" ]]; then
    warn "Bootstrap already completed. Exiting."
    exit 0
  fi
  
  # Load configuration from metadata
  detect_configuration
  load_secrets
  
  # Install packages and configure PostgreSQL
  install_packages
  configure_postgresql
  configure_pg_hba
  
  # Generate repmgr configuration
  generate_repmgr_conf
  setup_pgpass
  
  # Configure PgBouncer (skip for witness nodes)
  if [[ "$ROLE" != "witness" ]]; then
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
  
  local duration=$(($(date +%s) - BOOTSTRAP_START_TIME))
  success "Bootstrap completed successfully in ${duration}s. Role: $ROLE"
  
  # Display connection information
  info "Node Information:"
  info "  Role: $ROLE"
  info "  Cluster ID: $PG_CLUSTER_ID"
  info "  Primary Host: $REPMGR_PRIMARY_HOST"
  info "  PostgreSQL Port: 5432"
  if [[ "$ROLE" != "witness" ]]; then
    info "  PgBouncer Port: $PGBOUNCER_PORT"
    info "  PgBouncer Health: http://$(hostname -I | awk '{print $1}'):$PGBOUNCER_HEALTH_PORT"
  fi
  info "  PostgreSQL Health: http://$(hostname -I | awk '{print $1}'):$PG_HEALTH_PORT"
}

# Run main function
main "$@"