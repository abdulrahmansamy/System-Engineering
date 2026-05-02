#!/bin/bash
# High Availability PostgreSQL bootstrap for GCE VMs using repmgr (Phase 2 realignment)
# - Ubuntu 24.04 LTS minimal
# - PostgreSQL 17 (PGDG)
# - repmgr orchestrated primary/standby (+ optional witness) with PgBouncer & health endpoint

set -euo pipefail

# Script version marker for operational verification
SCRIPT_VERSION="0.4.14"

# Enable bash xtrace when BOOTSTRAP_TRACE=1 for deeper diagnostics
if [[ "${BOOTSTRAP_TRACE:-0}" == "1" ]]; then
  export PS4='\nTRACE [$LINENO] >> '
  set -x
fi

# -------- Robust Logging Setup --------
LOG_DIR="/var/log/pg-bootstrap"
LOG_FILE="$LOG_DIR/bootstrap.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE" || true

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
  # Flexible usage:
  #   log INFO message...
  #   log "message..."  (defaults to INFO)
  local lvl msg
  case "$1" in
    INFO|WARN|ERROR|DEBUG) lvl="$1"; shift; msg="$*" ;;
    *) lvl=INFO; msg="$*" ;;
  esac
  local line="$(ts) [$lvl] $msg"
  echo "$line" >> "$LOG_FILE"
  if command -v systemd-cat >/dev/null 2>&1; then
    echo "$line" | systemd-cat -t pg-bootstrap || true
  fi
  if [[ -t 1 ]]; then
    local color='\033[0m'
    case "$lvl" in
      INFO) color='\033[0;32m';; WARN) color='\033[0;33m';; ERROR) color='\033[0;31m';; DEBUG) color='\033[0;34m';; esac
    printf "%b%s\033[0m\n" "$color" "$line"
  fi
}

info(){ log INFO "$*"; }
warn(){ log WARN "$*"; }
error(){ log ERROR "$*"; }
debug(){ [[ "${BOOTSTRAP_DEBUG:-false}" =~ ^(true|1)$ ]] && log DEBUG "$*" || true; }
die(){ log ERROR "$*"; exit 1; }

retry() { # retry <n> <delay> <cmd...>
  local -i n=$1; shift; local -i delay=$1; shift; local i=0
  until "$@"; do
    i=$((i+1))
    if (( i >= n )); then return 1; fi
    sleep "$delay"
  done
}

# Trap failures to record exit code
trap 'rc=$?; if (( rc != 0 )); then log ERROR "Bootstrap script exiting with code $rc (last cmd: $BASH_COMMAND line $LINENO)"; fi' EXIT
trap 'log ERROR "Error trapped at line $LINENO during: $BASH_COMMAND"' ERR

info "Bootstrap logging initialized (file: $LOG_FILE; script_version=${SCRIPT_VERSION})"
export DEBIAN_FRONTEND=noninteractive
info "Environment set: DEBIAN_FRONTEND=$DEBIAN_FRONTEND"

ROLE="${ROLE:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_role || echo unknown)}"
COOLDOWN="${COOLDOWN:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_controller_cooldown || echo 600)}"

# Optional environment override file to survive sudo environment scrubbing
ENV_FILE="/etc/pg-ha/env.conf"
if [[ -f "$ENV_FILE" ]]; then
  info "Sourcing environment overrides from $ENV_FILE"
  set -a; source "$ENV_FILE"; set +a || true
fi

# -------- Constants & Paths --------
PG_VERSION="17"
PG_CLUSTER_NAME="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
REPMGR_CONF_DIR="/etc/repmgr"
REPMGR_CONF_FILE="${REPMGR_CONF_DIR}/repmgr.conf"
REPMGR_LOG_DIR="/var/log/repmgr"
REPMGR_EVENTS_DIR="/etc/repmgr/events"
PG_HBA="${PG_DATA_DIR}/pg_hba.conf"
PG_CONF="${PG_DATA_DIR}/postgresql.conf"
if [[ -f "/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/pg_hba.conf" ]]; then
  PG_HBA="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/pg_hba.conf"
fi
if [[ -f "/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/postgresql.conf" ]]; then
  PG_CONF="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/postgresql.conf"
fi
debug "Config paths resolved: PG_CONF=${PG_CONF} PG_HBA=${PG_HBA} DATA_DIR=${PG_DATA_DIR}"
SENTINEL_DIR="/var/lib/postgresql/.bootstrap"
SENTINEL_BOOTSTRAP="${SENTINEL_DIR}/done"
SENTINEL_PRIMARY_INIT="${SENTINEL_DIR}/primary.init"
SENTINEL_STANDBY_CLONED="${SENTINEL_DIR}/standby.cloned"
SENTINEL_WITNESS_REGISTERED="${SENTINEL_DIR}/witness.registered"
HEALTH_BIN="/usr/local/bin/pg-ha-health.sh"
HEALTH_SERVICE="pg-ha-health.service"

mkdir -p "$REPMGR_CONF_DIR" "$REPMGR_LOG_DIR" "$REPMGR_EVENTS_DIR" "$SENTINEL_DIR"

# -------- Metadata Helpers --------
md() { curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/$1"; }
PROJECT_ID="${PROJECT_ID:-$(md project/project-id || echo unknown)}"
ROLE="${ROLE:-${ROLE:-$(md instance/attributes/pg_role || echo unknown)}}"
CLUSTER_ID="${CLUSTER_ID:-$(md instance/attributes/pg_cluster_id || echo ha)}"
REPMGR_PRIMARY_HOST="${REPMGR_PRIMARY_HOST:-$(md instance/attributes/repmgr_primary_host || echo pg-primary)}"
REPMGR_DB="${REPMGR_DB:-$(md instance/attributes/repmgr_db || echo repmgr)}"
REPMGR_USER="${REPMGR_USER:-$(md instance/attributes/repmgr_user || echo repmgr)}"
HEALTH_PORT="${HEALTH_PORT:-$(md instance/attributes/pg_health_port || echo 8001)}"
EVENT_WEBHOOK="${EVENT_WEBHOOK:-$(md instance/attributes/repmgr_event_webhook || echo '')}"

info "Metadata resolved: role=$ROLE cluster=$CLUSTER_ID project=$PROJECT_ID primary_host=$REPMGR_PRIMARY_HOST repmgr_db=$REPMGR_DB health_port=$HEALTH_PORT"

# -------- Secret Manager Access --------
TOKEN_CACHE="/run/pg-secrets/token.json"
SECRET_CACHE_DIR="/run/pg-secrets"
mkdir -p "$SECRET_CACHE_DIR"

_fetch_token() {
  local now exp
  if [[ -f $TOKEN_CACHE ]]; then
    exp=$(jq -r '.expiration // 0' "$TOKEN_CACHE" 2>/dev/null || echo 0)
    [[ $exp =~ ^[0-9]+$ ]] || exp=0
    now=$(date +%s)
    if (( now+60 < exp )); then return 0; fi
  fi
  local raw
  raw=$(curl -sf -H 'Metadata-Flavor: Google' \
       'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token') || return 1
  echo "$raw" > "$TOKEN_CACHE"
}

get_secret() {
  local name="$1" sid="$2" cache="$SECRET_CACHE_DIR/$name"
  if [[ -s $cache ]]; then cat "$cache"; return 0; fi
  retry 3 5 _fetch_token || { warn "Token fetch failed for $sid"; return 1; }
  local token=$(jq -r '.access_token' "$TOKEN_CACHE" 2>/dev/null || true)
  if [[ -z $token ]]; then warn "Empty token for $sid"; return 1; fi
  local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${sid}/versions/latest:access"
  local body
  if ! body=$(curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$url"); then
    warn "Failed to retrieve secret $sid"; return 1
  fi
  echo "$body" | jq -r '.payload.data' | base64 -d > "$cache" 2>/dev/null || { warn "Decode failed for secret $sid"; return 1; }
  chmod 600 "$cache"
  cat "$cache"
}

# -------- Helper Functions --------
sanitize_id() { echo "${1}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g'; }

auto_detect_role() {
  if [[ -z "${ROLE}" || "${ROLE}" == "unknown" ]]; then
    if [[ -f "${PG_DATA_DIR}/PG_VERSION" ]]; then
      if sudo -u postgres psql -Atqc "select pg_is_in_recovery()" postgres 2>/dev/null | grep -q '^t'; then ROLE="standby"; else ROLE="primary"; fi
    else
      if [[ -n "${REPMGR_PRIMARY_HOST}" && "${REPMGR_PRIMARY_HOST}" != "pg-primary" && "${REPMGR_PRIMARY_HOST}" != "localhost" ]]; then
        if timeout 2 bash -c "</dev/tcp/${REPMGR_PRIMARY_HOST}/5432" 2>/dev/null; then ROLE="standby"; else ROLE="primary"; fi
      else
        ROLE="primary"
      fi
    fi
    info "Auto-detected ROLE=${ROLE}"
  fi
  if [[ "$ROLE" == "primary" && ( -z "${REPMGR_PRIMARY_HOST}" || "${REPMGR_PRIMARY_HOST}" == "pg-primary" ) ]]; then
    local self_ip
    self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}')
    [[ -n "$self_ip" ]] && REPMGR_PRIMARY_HOST="$self_ip" && export REPMGR_PRIMARY_HOST && info "Set REPMGR_PRIMARY_HOST=$REPMGR_PRIMARY_HOST"
  fi
}

ensure_pgpass() {
  local pgpass="/var/lib/postgresql/.pgpass" lines=() self_ip
  self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
  lines+=("localhost:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}")
  lines+=("${REPMGR_PRIMARY_HOST}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}")
  lines+=("localhost:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}")
  lines+=("${REPMGR_PRIMARY_HOST}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}")
  if [[ -n "$self_ip" && "$self_ip" != "localhost" && "$self_ip" != "$REPMGR_PRIMARY_HOST" ]]; then
    lines+=("${self_ip}:5432:${REPMGR_DB}:${REPMGR_USER}:${REPMGR_PASSWORD}")
    lines+=("${self_ip}:5432:replication:${REPMGR_USER}:${REPMGR_PASSWORD}")
  fi
  if [[ -f "$pgpass" ]]; then
    local tmp=$(mktemp)
    if [[ -n "$self_ip" ]]; then
      grep -v -E "^(${self_ip}|localhost|${REPMGR_PRIMARY_HOST}):5432:(${REPMGR_DB}|replication):${REPMGR_USER}:" "$pgpass" > "$tmp" 2>/dev/null || true
    else
      grep -v -E "^(localhost|${REPMGR_PRIMARY_HOST}):5432:(${REPMGR_DB}|replication):${REPMGR_USER}:" "$pgpass" > "$tmp" 2>/dev/null || true
    fi
    mv "$tmp" "$pgpass"
  fi
  for l in "${lines[@]}"; do echo "$l" >> "$pgpass"; done
  chown postgres:postgres "$pgpass" || true
  chmod 600 "$pgpass" || true
  debug ".pgpass updated (self_ip=${self_ip:-none}) entries=${#lines[@]}"
}

load_secrets() {
  set +e
  info "Loading secrets from Secret Manager"
  PG_SUPER_PASS="${PG_SUPER_PASS:-$(get_secret pg_superuser ${PG_SUPERUSER_SECRET_ID:-ipa-nprd-sec-pg-superuser-password-01} 2>/dev/null || echo changeMe)}"
  PG_REPL_PASS="${PG_REPL_PASS:-$(get_secret pg_repl ${PG_REPLICATION_SECRET_ID:-ipa-nprd-sec-pg-replication-password-01} 2>/dev/null || echo changeMe)}"
  PG_MONITOR_PASS="${PG_MONITOR_PASS:-$(get_secret pg_monitor ${PG_MONITOR_SECRET_ID:-ipa-nprd-sec-pg-monitor-password-01} 2>/dev/null || echo changeMe)}"
  REPMGR_PASSWORD="${REPMGR_PASSWORD:-$(get_secret pg_repmgr ${REPMGR_SECRET_ID:-} 2>/dev/null || echo '')}"
  [[ -z "$REPMGR_PASSWORD" ]] && REPMGR_PASSWORD="$PG_SUPER_PASS"
  
  gen_pw() { command -v openssl >/dev/null 2>&1 && openssl rand -base64 24 2>/dev/null | tr -d '=+/' | cut -c1-32 || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c32; }
  if [[ -z "$PG_SUPER_PASS" || "$PG_SUPER_PASS" == changeMe ]]; then
    if [[ "$ROLE" == "primary" && ! -f $SENTINEL_PRIMARY_INIT ]]; then PG_SUPER_PASS="$(gen_pw)"; warn "Generated random superuser password (secret unavailable)"; fi
  fi
  if [[ -z "$PG_REPL_PASS"  || "$PG_REPL_PASS" == changeMe ]]; then PG_REPL_PASS="$(gen_pw)"; warn "Generated random replication password (secret unavailable)"; fi
  if [[ -z "$PG_MONITOR_PASS" || "$PG_MONITOR_PASS" == changeMe ]]; then PG_MONITOR_PASS="$(gen_pw)"; warn "Generated random monitor password (secret unavailable)"; fi
  
  export PGPASSWORD="$PG_SUPER_PASS"
  ensure_pgpass || true
  set -e
  return 0
}

# -------- Package Installation --------
install_packages() {
  info "Ensuring required packages installed"
  retry 3 5 apt-get update || die "apt update failed"
  local base_pkgs=(wget gnupg lsb-release jq netcat-openbsd curl ca-certificates openssl)
  retry 3 5 apt-get install -y --no-install-recommends "${base_pkgs[@]}" || die "base packages install failed"

  if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/pgdg.gpg
    info "PGDG repo added"
    retry 3 5 apt-get update || die "apt update PGDG failed"
  fi

  local needed=()
  for p in postgresql-${PG_VERSION} postgresql-client-${PG_VERSION} pgbouncer; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then needed+=("$p"); fi
  done
  if ((${#needed[@]})); then
    retry 3 5 apt-get install -y "${needed[@]}" || die "package install failed (${needed[*]})"
  fi

  # Set ownership after postgres user exists
  if id -u postgres >/dev/null 2>&1; then
    chown -R postgres:postgres "$REPMGR_CONF_DIR" "$REPMGR_EVENTS_DIR" || true
    chmod 750 "$REPMGR_CONF_DIR" "$REPMGR_EVENTS_DIR" || true
  fi
}

install_repmgr_if_needed() {
  if command -v repmgr >/dev/null 2>&1; then
    debug "repmgr already installed"
    return 0
  fi
  info "Installing repmgr for PostgreSQL ${PG_VERSION}"
  
  if apt-cache show "repmgr${PG_VERSION}" >/dev/null 2>&1; then
    apt-get install -y "repmgr${PG_VERSION}" && return 0
  fi
  
  if apt-cache show repmgr >/dev/null 2>&1; then
    apt-get install -y repmgr && return 0
  fi
  
  # Build from source as fallback
  info "Building repmgr from source"
  apt-get install -y --no-install-recommends build-essential git libpq-dev pkg-config
  local src_dir="/usr/local/src/repmgr"
  rm -rf "$src_dir" && mkdir -p "$src_dir"
  git clone --depth 1 https://github.com/EnterpriseDB/repmgr.git "$src_dir"
  (cd "$src_dir" && make USE_PGXS=1 && make install) || die "repmgr source build failed"
  command -v repmgr >/dev/null 2>&1 || die "repmgr not found after source build"
  info "repmgr built from source successfully"
}

configure_postgresql() {
  info "Configuring postgresql.conf and pg_hba.conf"
  grep -q '^wal_level' "$PG_CONF" 2>/dev/null || {
    cat >> "$PG_CONF" <<EOF
# Added by HA bootstrap
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
wal_keep_size = '1024MB'
hot_standby = on
shared_preload_libraries = 'repmgr'
archive_mode = off
EOF
  }
  configure_pg_hba
}

configure_pg_hba() {
  local auth_method="md5"
  local enc
  enc=$(sudo -u postgres psql -Atqc "show password_encryption" 2>/dev/null || echo '')
  if [[ "$enc" == "scram-sha-256" ]]; then auth_method="scram-sha-256"; fi
  
  # Detect internal CIDR for basic access
  local allow_cidr="10.0.0.0/8"
  local self_ip
  self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
  if [[ -n "$self_ip" ]]; then
    case "$self_ip" in
      10.*) allow_cidr="10.0.0.0/8" ;;
      192.168.*) allow_cidr="192.168.0.0/16" ;;
      172.1[6-9].*|172.2[0-9].*|172.3[01].*) allow_cidr="172.16.0.0/12" ;;
      *) allow_cidr="${self_ip%.*}.0/24" ;;
    esac
  fi
  
  if ! grep -q '# BEGIN-HA-HBA' "$PG_HBA" 2>/dev/null; then
    cat >> "$PG_HBA" <<EOF
# BEGIN-HA-HBA (managed)
local   all             all                                     peer
host    replication     replication       ${allow_cidr}         ${auth_method}
host    ${REPMGR_DB}    ${REPMGR_USER}    ${allow_cidr}         ${auth_method}
host    all             ${REPMGR_USER}    ${allow_cidr}         ${auth_method}
host    all             replication       ${allow_cidr}         ${auth_method}
host    replication     ${REPMGR_USER}    ${allow_cidr}         ${auth_method}
# END-HA-HBA
EOF
    info "pg_hba configured with CIDR ${allow_cidr}"
    systemctl reload postgresql || true
  fi
  
  # Add specific IP entries for self and primary host
  local changed=0
  if [[ -n "$self_ip" ]]; then
    if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${self_ip}/32" "$PG_HBA" 2>/dev/null; then
      echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${self_ip}/32    ${auth_method}" >> "$PG_HBA"
      echo "host    replication     replication       ${self_ip}/32    ${auth_method}" >> "$PG_HBA"
      echo "host    replication     ${REPMGR_USER}    ${self_ip}/32    ${auth_method}" >> "$PG_HBA"
      changed=1
    fi
  fi
  
  if [[ -n "$REPMGR_PRIMARY_HOST" && "$REPMGR_PRIMARY_HOST" != "pg-primary" && "$REPMGR_PRIMARY_HOST" != "$self_ip" ]]; then
    if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${REPMGR_PRIMARY_HOST}/32" "$PG_HBA" 2>/dev/null; then
      echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${REPMGR_PRIMARY_HOST}/32    ${auth_method}" >> "$PG_HBA"
      echo "host    replication     replication       ${REPMGR_PRIMARY_HOST}/32    ${auth_method}" >> "$PG_HBA"
      echo "host    replication     ${REPMGR_USER}    ${REPMGR_PRIMARY_HOST}/32    ${auth_method}" >> "$PG_HBA"
      changed=1
    fi
  fi
  
  if (( changed == 1 )); then
    info "Reloading PostgreSQL to apply pg_hba.conf changes"
    systemctl reload postgresql || true
  fi
}

generate_repmgr_conf() {
  info "Generating repmgr.conf"
  local node_id cluster_name host_part="localhost" cand_ip
  case "$ROLE" in primary) node_id=1 ;; standby) node_id=2 ;; witness) node_id=9 ;; *) node_id=0 ;; esac
  cluster_name=$(echo "${CLUSTER_ID:-ha_cluster}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_]/_/g')
  cand_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
  [[ -n "$cand_ip" ]] && host_part="$cand_ip"
  
  cat > "$REPMGR_CONF_FILE" <<EOF
cluster='${cluster_name}'
node_id=${node_id}
node_name='${ROLE}'
conninfo='host=${host_part} user=${REPMGR_USER} dbname=${REPMGR_DB}'
data_directory='${PG_DATA_DIR}'
pg_bindir='/usr/lib/postgresql/${PG_VERSION}/bin'
use_replication_slots=yes
log_file='${REPMGR_LOG_DIR}/repmgrd.log'
log_level=INFO
monitor_interval_secs=5
failover=automatic
promote_command='repmgr standby promote -f ${REPMGR_CONF_FILE}'
follow_command='repmgr standby follow -f ${REPMGR_CONF_FILE} --upstream-node-id=%n'
retry_promote_interval_secs=5
primary_follow_timeout=60
reconnect_attempts=6
reconnect_interval=5
event_notifications=all
event_notification_command='${REPMGR_EVENTS_DIR}/exec.sh %n %e %s %t %d %p %r'
EOF
  chown postgres:postgres "$REPMGR_CONF_FILE" || true
  chmod 640 "$REPMGR_CONF_FILE" || true
}

init_primary() {
  [[ -f $SENTINEL_PRIMARY_INIT ]] && { info "Primary already initialized"; return 0; }
  info "Initializing primary cluster"
  systemctl enable postgresql || true
  systemctl stop postgresql || true
  configure_postgresql
  systemctl start postgresql || true
  retry 10 3 sudo -u postgres psql -Atqc 'select 1' postgres || die "PostgreSQL not responding"
  
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REPMGR_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE ROLE ${REPMGR_USER} WITH LOGIN SUPERUSER PASSWORD '${REPMGR_PASSWORD}';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${REPMGR_DB}'" | grep -q 1 || \
    sudo -u postgres createdb -O ${REPMGR_USER} ${REPMGR_DB}
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='replication'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE ROLE replication WITH REPLICATION LOGIN ENCRYPTED PASSWORD '${PG_REPL_PASS}';"
  
  touch "$SENTINEL_PRIMARY_INIT"
}

wait_for_primary() {
  local host="$1" port="${2:-5432}" max="${3:-10}" delay="${4:-6}" ok=0 attempt
  info "Waiting for primary $host:$port"
  for attempt in $(seq 1 "$max"); do
    if nc -z "$host" "$port" 2>/dev/null; then ok=1; break; fi
    sleep "$delay"
  done
  (( ok == 1 )) || die "Primary not reachable"
}

clone_standby() {
  [[ -f $SENTINEL_STANDBY_CLONED ]] && { info "Standby already cloned"; return 0; }
  info "Cloning standby from $REPMGR_PRIMARY_HOST"
  systemctl stop postgresql || true
  mkdir -p "${PG_DATA_DIR}" && chown -R postgres:postgres "${PG_DATA_DIR}" || true
  find "${PG_DATA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  ensure_pgpass
  local clone_log="/var/log/pg-bootstrap/repmgr_clone.log"
  sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" -f "$REPMGR_CONF_FILE" standby clone >"$clone_log" 2>&1 || die "repmgr standby clone failed"
  systemctl start postgresql || die "Failed to start postgres after clone"
  touch "$SENTINEL_STANDBY_CLONED"
}

register_node() {
  case "$ROLE" in
    primary) sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" primary register || true ;;
    standby) sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" standby register || true ;;
    witness) sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" witness register --force || true; touch "$SENTINEL_WITNESS_REGISTERED" ;;
  esac
}

ensure_replication_slots() {
  [[ "$ROLE" != "primary" ]] && return 0
  local slots_meta slots cid
  cid=$(echo "$CLUSTER_ID" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_]/_/g')
  slots="${cid}_standby_1"
  
  sudo -u postgres psql -Atqc "select slot_name from pg_replication_slots where slot_name='${slots}'" postgres | grep -q "${slots}" || \
    sudo -u postgres psql -c "select * from pg_create_physical_replication_slot('${slots}');" postgres || warn "Failed creating slot $slots"
  
  local rs="repmgr_slot_2"
  sudo -u postgres psql -Atqc "select slot_name from pg_replication_slots where slot_name='${rs}'" postgres | grep -q "${rs}" || \
    sudo -u postgres psql -c "select * from pg_create_physical_replication_slot('${rs}');" postgres || warn "Failed creating slot ${rs}"
}

start_repmgrd() { 
  systemctl enable repmgrd || true
  systemctl restart repmgrd || true
}

deploy_event_hooks() {
  mkdir -p "$REPMGR_EVENTS_DIR"
  cat > "${REPMGR_EVENTS_DIR}/exec.sh" <<'EOF'
#!/bin/bash
EVT="$1"; shift || true
ROLE_STATE="unknown"; REC="unknown"
if psql -U postgres -d postgres -Atqc 'select 1' >/dev/null 2>&1; then
  REC=$(psql -Atqc 'select pg_is_in_recovery()' 2>/dev/null || echo unknown)
  [[ "$REC" == "f" ]] && ROLE_STATE=primary || ROLE_STATE=standby
fi
PAYLOAD=$(jq -n --arg evt "$EVT" --arg role "$ROLE_STATE" --arg rec "$REC" --arg ts "$(date -u +%FT%TZ)" '{timestamp:$ts,event:$evt,role:$role,is_in_recovery:$rec}')
echo "$PAYLOAD" >> /var/log/repmgr/events.log
exit 0
EOF
  chmod +x "${REPMGR_EVENTS_DIR}/exec.sh" || true
}

health_endpoint_setup() {
  cat > "$HEALTH_BIN" <<'EOS_HEALTH'
#!/bin/bash
### PG HA Health Endpoint
set -euo pipefail
PORT=__PORT__
NC_BIN="/usr/bin/nc"
while true; do
  role="unknown"; rec="unknown"
  if psql -U postgres -d postgres -Atqc 'select 1' >/dev/null 2>&1; then
    rec=$(psql -U postgres -d postgres -Atqc 'select pg_is_in_recovery()' 2>/dev/null || echo unknown)
    [[ "$rec" == "f" ]] && role=primary || role=standby
  fi
  body="{\"role\":\"$role\",\"ts\":\"$(date -u +%FT%TZ)\",\"is_in_recovery\":\"$rec\"}"
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: %s\r\n\r\n%s' "${#body}" "$body" | "$NC_BIN" -l -p "$PORT" -q 1 >/dev/null 2>&1 || sleep 1
done
EOS_HEALTH
  sed -i "s/__PORT__/${HEALTH_PORT}/" "$HEALTH_BIN"
  chmod +x "$HEALTH_BIN"
  
  cat > /etc/systemd/system/${HEALTH_SERVICE} <<EOF
[Unit]
Description=PG HA Role Health Endpoint
After=network.target postgresql.service
[Service]
ExecStart=${HEALTH_BIN}
Restart=always
RestartSec=2
User=postgres
Group=postgres
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || true
  systemctl enable ${HEALTH_SERVICE} || true
  systemctl restart ${HEALTH_SERVICE} || true
}

# ensure_post_config: remediation/verification function that always runs
ensure_post_config() {
  info "Post-config: ensuring critical HA artifacts present"
  
  # Regenerate repmgr.conf if missing
  [[ -f "$REPMGR_CONF_FILE" ]] || { warn "repmgr.conf missing; regenerating"; generate_repmgr_conf; }
  
  # Re-deploy event hook script and ensure it is executable
  deploy_event_hooks || warn "Event hooks deploy failed"
  [[ -x "${REPMGR_EVENTS_DIR}/exec.sh" ]] || warn "Event hook script missing/executable issue"
  
  # Ensure health endpoint script/service exists and (re)starts it if inactive
  health_endpoint_setup || warn "Health endpoint ensure failed"
  systemctl is-active --quiet ${HEALTH_SERVICE} || systemctl restart ${HEALTH_SERVICE} || true
  
  # Ensure repmgrd is enabled and running
  systemctl is-enabled --quiet repmgrd || systemctl enable repmgrd || true
  systemctl is-active --quiet repmgrd || systemctl restart repmgrd || true
  
  # Re-create replication slots on the primary if needed
  if [[ "$ROLE" == "primary" ]]; then ensure_replication_slots || true; fi
  
  # For primary role, ensure PostgreSQL is listening on all interfaces and pg_hba is configured
  if [[ "$ROLE" == "primary" ]]; then
    local current_listen
    current_listen=$(sudo -u postgres psql -Atqc "show listen_addresses" 2>/dev/null || echo '')
    if [[ "$current_listen" != "*" ]]; then
      info "Setting listen_addresses to '*' for external connections"
      sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = '*';" || true
      systemctl restart postgresql || true
      sleep 3
      # Re-configure pg_hba after restart
      configure_pg_hba || true
    fi
  fi
  
  # Try repmgr cluster show; if registration incomplete, attempt node registration again
  if command -v repmgr >/dev/null 2>&1; then
    if ! sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" cluster show >/dev/null 2>&1; then
      info "Cluster not fully registered; attempting node registration"
      register_node || warn "Registration attempt failed"
    fi
  fi
  
  # Emit a concise summary (artifacts / health service / repmgrd status)
  local artifacts_status="$([[ -f $REPMGR_CONF_FILE ]] && echo ok || echo missing)"
  local health_status="$(systemctl is-active ${HEALTH_SERVICE} 2>/dev/null || echo inactive)"
  local repmgrd_status="$(systemctl is-active repmgrd 2>/dev/null || echo inactive)"
  info "Post-config summary: Artifacts:${artifacts_status};HealthSvc:${health_status};repmgrd:${repmgrd_status}"
}

# -------- Main Bootstrap Logic --------
main() {
  info "--- BOOTSTRAP START (initial role hint=$ROLE) ---"
  info "Step 1: install base & PG packages"; install_packages
  info "Step 2: install / verify repmgr"; install_repmgr_if_needed
  info "Step 3: detect role"; auto_detect_role
  info "Step 4: load secrets"; load_secrets
  info "Step 5: generate repmgr.conf"; generate_repmgr_conf
  info "Step 6: role-specific init (role=$ROLE)"
  case "$ROLE" in
    primary) init_primary ;;
    standby) wait_for_primary "$REPMGR_PRIMARY_HOST" 5432 12 5; clone_standby ;;
    witness) systemctl enable postgresql || true; systemctl start postgresql || true ;;
    *) die "Unknown ROLE=$ROLE" ;;
  esac
  info "Step 7: register node"; register_node
  info "Step 8: ensure replication slots"; ensure_replication_slots
  info "Step 9: deploy event hooks"; deploy_event_hooks
  info "Step 10: start repmgrd"; start_repmgrd
  info "Step 11: health endpoint setup"; health_endpoint_setup
  info "Step 12: finalize"; touch "$SENTINEL_BOOTSTRAP"
  ensure_post_config
  info "--- BOOTSTRAP COMPLETE (role=$ROLE) ---"
}

# Invoke main if sentinel absent, otherwise run post-config checks
if [[ ! -f $SENTINEL_BOOTSTRAP ]]; then
  main || die "Bootstrap failed"
else
  info "Bootstrap already completed (sentinel present); running post-config checks"
  ensure_post_config || warn "Post-config remediation encountered issues"
fi