#!/bin/bash
# High Availability PostgreSQL bootstrap for GCE VMs using repmgr (Phase 2 realignment)
# - Ubuntu 24.04 LTS minimal
# - PostgreSQL 17 (PGDG)
# - repmgr orchestrated primary/standby (+ optional witness) with PgBouncer & health endpoint
# NOTE: This script is being transformed from earlier pg_auto_failover oriented version.
#       Subsequent phases will add: repmgr install & config, standby clone logic, witness setup,
#       wal-g integration, health endpoint server, exporter installation, event hooks.

# - Idempotent: safe to re-run

set -euo pipefail

# Script version marker for operational verification
SCRIPT_VERSION="0.4.13"

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
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a || true
fi

# Phase 2 placeholders (will be implemented in Phase 4):
# - Detect if already initialized (e.g. presence of /var/lib/postgresql/data/PG_VERSION)
# - Install packages: postgresql-17, repmgr, pgbouncer
# - Primary init path
# - Standby clone path using repmgr standby clone
# - Witness minimal registration (if enable_witness)
# - Generate repmgr.conf & postgresql.conf templates
# - Register nodes & enable repmgrd
# - Provide health endpoint script referencing var.pg_health_port

###############################################
# Phase 4: Functional repmgr Bootstrap Logic  #
###############################################

# -------- Constants & Paths --------
PG_VERSION="17"
PG_CLUSTER_NAME="main"               # Debian/Ubuntu cluster name
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
REPMGR_CONF_DIR="/etc/repmgr"
REPMGR_CONF_FILE="${REPMGR_CONF_DIR}/repmgr.conf"
REPMGR_LOG_DIR="/var/log/repmgr"
REPMGR_EVENTS_DIR="/etc/repmgr/events"
# Default to data directory paths; will override with /etc paths if they exist (Debian/Ubuntu layout)
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
# Ensure postgres can read configuration directory (repmgr runs as postgres)
# Adjust initial chown to be deferred if postgres user missing
if id -u postgres >/dev/null 2>&1; then
  chown -R postgres:postgres "$REPMGR_CONF_DIR" || true
else
  DEFERRED_CHOWN=1
  debug "postgres user absent; deferring chown of $REPMGR_CONF_DIR"
fi
chmod 750 "$REPMGR_CONF_DIR" "$REPMGR_EVENTS_DIR" || true

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

# -------- Auto Role Detection --------
# After metadata resolution line we insert the auto role detection call once
# Metadata resolved log already present above; ensure only one auto_detect_role call follows it.
# Ensure auto_detect_role defined before this call (it is defined earlier with secret functions)
# Call only once here:
# auto_detect_role (deferred to main after packages)

# -------- Secret Manager Access (Deferred until packages installed) --------
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

get_secret() { # get_secret <short_name> <secret_id>
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

load_secrets() {
  set +e
  info "Loading secrets from Secret Manager"
  local orig_repmgr_env="${REPMGR_PASSWORD:-}" orig_pg_super_env="${PG_SUPER_PASS:-}" rc=0
  PG_SUPER_PASS="${PG_SUPER_PASS:-$(get_secret pg_superuser ${PG_SUPERUSER_SECRET_ID:-ipa-nprd-sec-pg-superuser-password-01} 2>/dev/null || echo changeMe)}"
  PG_REPL_PASS="${PG_REPL_PASS:-$(get_secret pg_repl ${PG_REPLICATION_SECRET_ID:-ipa-nprd-sec-pg-replication-password-01} 2>/dev/null || echo changeMe)}"
  PG_MONITOR_PASS="${PG_MONITOR_PASS:-$(get_secret pg_monitor ${PG_MONITOR_SECRET_ID:-ipa-nprd-sec-pg-monitor-password-01} 2>/dev/null || echo changeMe)}"
  REPMGR_PASSWORD="${REPMGR_PASSWORD:-$(get_secret pg_repmgr ${REPMGR_SECRET_ID:-} 2>/dev/null || echo '')}"
  [[ -z "$REPMGR_PASSWORD" ]] && REPMGR_PASSWORD="$PG_SUPER_PASS"
  if [[ "$ROLE" == "primary" && -f $SENTINEL_PRIMARY_INIT && -f /var/lib/postgresql/.pgpass ]]; then
    existing_pw=$(grep -E "^(localhost|${REPMGR_PRIMARY_HOST}):5432:${REPMGR_DB}:${REPMGR_USER}:" /var/lib/postgresql/.pgpass | head -n1 | awk -F: '{print $5}') || true
    [[ -n "$existing_pw" ]] && REPMGR_PASSWORD="$existing_pw" && debug "Reusing existing repmgr password (.pgpass)"
  fi
  gen_pw() { command -v openssl >/dev/null 2>&1 && openssl rand -base64 24 2>/dev/null | tr -d '=+/' | cut -c1-32 || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c32; }
  if [[ -z "$PG_SUPER_PASS" || "$PG_SUPER_PASS" == changeMe ]]; then
    if [[ "$ROLE" == "primary" && ! -f $SENTINEL_PRIMARY_INIT ]]; then PG_SUPER_PASS="$(gen_pw)"; warn "Generated random superuser password (secret unavailable)"; else warn "Superuser password placeholder on non-primary"; fi
  fi
  if [[ -z "$PG_REPL_PASS"  || "$PG_REPL_PASS" == changeMe ]]; then PG_REPL_PASS="$(gen_pw)"; warn "Generated random replication password (secret unavailable)"; fi
  if [[ -z "$PG_MONITOR_PASS" || "$PG_MONITOR_PASS" == changeMe ]]; then PG_MONITOR_PASS="$(gen_pw)"; warn "Generated random monitor password (secret unavailable)"; fi
  export PGPASSWORD="$PG_SUPER_PASS"
  [[ -z "$orig_repmgr_env" && -n "$orig_pg_super_env" && "$ROLE" == "standby" ]] && warn "REPMGR_PASSWORD env stripped; falling back to PG_SUPER_PASS"
  ensure_pgpass || rc=1
  persist_password_secrets_if_primary || true
  set -e
  return $rc
}

# -------- Package Installation (Idempotent) --------
install_packages() {
  info "Ensuring required packages installed"
  retry 3 5 apt-get update || die "apt update failed"
  local base_pkgs=(wget gnupg lsb-release jq netcat-openbsd curl ca-certificates openssl)
  info "Installing base utilities (${base_pkgs[*]})"
  retry 3 5 apt-get install -y --no-install-recommends "${base_pkgs[@]}" || die "base packages install failed"

  # Add PGDG repo if not present
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
    info "Installing packages: ${needed[*]}"
    retry 3 5 apt-get install -y "${needed[@]}" || die "package install failed (${needed[*]})"
  else
    debug "Core packages already present (PostgreSQL ${PG_VERSION}, client, pgbouncer)"
  fi

  # Ensure install_packages defers chown
  if [[ "${DEFERRED_CHOWN:-0}" == "1" ]] && id -u postgres >/dev/null 2>&1; then
    chown -R postgres:postgres "$REPMGR_CONF_DIR" "$REPMGR_EVENTS_DIR" || true
    DEFERRED_CHOWN=0
    debug "Applied deferred chown for $REPMGR_CONF_DIR"
  fi
}

# Enhanced repmgr installation logic (handles absence of versioned package)
install_repmgr_if_needed() {
  if command -v repmgr >/dev/null 2>&1; then
    debug "repmgr already installed ($(repmgr --version 2>/dev/null | awk '{print $2}' || echo unknown))"
    return 0
  fi
  info "Attempting installation of repmgr for PostgreSQL ${PG_VERSION}"
  local tried=()
  local pkg_versioned="repmgr${PG_VERSION}"
  if apt-cache show "$pkg_versioned" >/dev/null 2>&1; then
    info "Found package $pkg_versioned in APT; installing"
    if apt-get install -y "$pkg_versioned"; then return 0; else warn "Install failed for $pkg_versioned"; tried+=("$pkg_versioned (fail)"); fi
  else
    tried+=("$pkg_versioned (not found)")
  fi
  if apt-cache show repmgr >/dev/null 2>&1; then
    info "Trying unversioned 'repmgr' package"
    if apt-get install -y repmgr; then return 0; else warn "Install failed for repmgr"; tried+=("repmgr (fail)"); fi
  else
    tried+=("repmgr (not found)")
  fi
  info "Falling back to source build for repmgr (previous attempts: ${tried[*]})"
  build_repmgr_from_source || die "Failed to build repmgr from source"
}

build_repmgr_from_source() {
  local src_dir="/usr/local/src/repmgr"
  if command -v repmgr >/dev/null 2>&1; then return 0; fi
  info "Building repmgr from source (latest)"
  apt-get install -y --no-install-recommends build-essential git libpq-dev pkg-config clang || die "Build deps install failed"
  rm -rf "$src_dir" && mkdir -p "$src_dir"
  git clone --depth 1 https://github.com/EnterpriseDB/repmgr.git "$src_dir" || die "git clone repmgr failed"
  (cd "$src_dir" && make USE_PGXS=1 && make install) || die "repmgr source build failed"
  if ! command -v repmgr >/dev/null 2>&1; then die "repmgr not found after source build"; fi
  info "repmgr built from source: $(repmgr --version 2>/dev/null || echo unknown)"
}

# -------- Configuration Generation (Idempotent with checksum) --------
write_file_if_changed() { # write_file_if_changed <path> <content>
  local path="$1" tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'__EOF__'
$2
__EOF__
  if [[ ! -f $path ]] || ! cmp -s "$tmp" "$path"; then
    info "Updating file $path"
    mkdir -p "$(dirname "$path")"
    cp "$tmp" "$path"
  fi
  rm -f "$tmp"
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
archive_mode = off   # wal-g to enable later
EOF
  }
  harden_pg_hba
}

# Ensure server is listening on all interfaces (required for remote standbys)
ensure_listen_all() {
  local current source_file
  current=$(sudo -u postgres psql -Atqc "show listen_addresses" 2>/dev/null || echo '')
  if [[ -z "$current" ]]; then
    warn "listen_addresses query returned empty; will attempt ALTER SYSTEM"
  fi
  if [[ "$current" != "*" && "$current" != "0.0.0.0" ]]; then
    info "Adjusting listen_addresses from '$current' to '*' via ALTER SYSTEM"
    sudo -u postgres psql -Atqc "alter system set listen_addresses='*';" || warn "ALTER SYSTEM failed"
    # Check for duplicate entries in postgresql.conf that might override
    if grep -q "listen_addresses" "$PG_CONF"; then
      # Keep first occurrence as '*' comment out others
      awk '/listen_addresses/ && !done {sub(/=.*/, "= '*'"); done=1} /listen_addresses/ && done {print "#"$0; next} {print}' "$PG_CONF" >"${PG_CONF}.tmp" && mv "${PG_CONF}.tmp" "$PG_CONF" || true
    fi
    systemctl restart postgresql || die "Failed to restart postgres after listen_addresses change"
    sleep 2
    local after
    after=$(sudo -u postgres psql -Atqc "show listen_addresses" 2>/dev/null || echo '')
    info "listen_addresses now='$after'"
  fi
  if ! ss -lnpt | grep -q ':5432'; then
    warn "Port 5432 not listening externally yet (still loopback?). Current sockets:"; ss -lnpt | grep 5432 || true
  fi
}

# -------- pg_hba Hardening --------
detect_internal_cidr() {
  # If user/metadata provided explicit allowed CIDR via PG_ALLOWED_CIDR env or metadata key 'pg_allowed_cidr', honor that
  if [[ -n "${PG_ALLOWED_CIDR:-}" ]]; then echo "$PG_ALLOWED_CIDR"; return 0; fi
  local meta_allow
  meta_allow=$(md instance/attributes/pg_allowed_cidr || true)
  if [[ -n $meta_allow ]]; then echo "$meta_allow"; return 0; fi
  # Prefer first RFC1918 address (10., 172.16-31., 192.168.) ignoring link-local 169.254.*
  local cand
  while read -r cidr; do
    local ip=${cidr%/*}
    case "$ip" in
      10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.30.*|172.31.*)
        echo "$(echo "$ip" | awk -F'.' '{printf "%s.%s.%s.0/24", $1,$2,$3}')"; return 0;;
    esac
  done < <(ip -o -4 addr show | awk '!/ lo / {print $4}')
  # Fallback: take first non-loopback address
  ip -o -4 addr show | awk '!/ lo / {print $4}' | head -n1 | sed 's\/[0-9]\{1,2\}//' | awk -F'.' '{printf "%s.%s.%s.0/24", $1,$2,$3}' 2>/dev/null || echo "127.0.0.1/32"
}

harden_pg_hba() {
  local auth_method="md5"
  local enc
  enc=$(sudo -u postgres psql -Atqc "show password_encryption" 2>/dev/null || echo '')
  if [[ "$enc" == "scram-sha-256" ]]; then auth_method="scram-sha-256"; fi
  local allow_meta allow_cidr
  allow_meta=$(md instance/attributes/pg_allowed_cidr || true)
  if [[ -n $allow_meta ]]; then
    allow_cidr=$allow_meta
  else
    allow_cidr=$(detect_internal_cidr)
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
    info "pg_hba hardened to ${allow_cidr}"
  else
    debug "pg_hba already hardened"
    if [[ "$auth_method" == "scram-sha-256" ]]; then
      if awk '/# BEGIN-HA-HBA/{f=1} f && / md5$/{found=1} /# END-HA-HBA/{f=0} END{exit !found}' "$PG_HBA"; then
        info "Upgrading managed pg_hba block to scram-sha-256"
        sed -i '/# BEGIN-HA-HBA/,/# END-HA-HBA/ s/ md5$/ scram-sha-256/' "$PG_HBA" || true
        systemctl reload postgresql || true
      fi
    fi
  fi

  # Always evaluate explicit standby IPs (comma/space separated) from metadata or env STANDBY_IPS.
  # This solves clone failures: FATAL no pg_hba.conf entry for host <standbyIP>, user "repmgr"...
  local standby_ips
  standby_ips="${STANDBY_IPS:-$(md instance/attributes/pg_standby_ips || true)}"
  local changed=0
  if [[ -n $standby_ips ]]; then
    # Normalize separators to spaces
    standby_ips=${standby_ips//,/ }
    for ip in $standby_ips; do
      [[ -z $ip ]] && continue
      # Allow both replication user and repmgr DB user from each explicit IP (/32 specificity)
      if ! grep -qE "^host\s+${REPMGR_DB}\s+${REPMGR_USER}\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for ${REPMGR_USER} @ ${ip}";
      fi
      if ! grep -qE "^host\s+replication\s+replication\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     replication       ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for replication @ ${ip}";
      fi
      if ! grep -qE "^host\s+replication\s+${REPMGR_USER}\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     ${REPMGR_USER}    ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for replication db using ${REPMGR_USER} @ ${ip}";
      fi
    done
  fi
  if (( changed == 1 )); then
    info "Reloading PostgreSQL to apply new pg_hba.conf entries"
    systemctl reload postgresql || systemctl restart postgresql || true
  fi

  # Extra CIDRs (space/comma separated) via env/metadata key pg_hba_extra_cidrs
  local extra_cidrs raw_extra
  raw_extra="${PG_HBA_EXTRA_CIDRS:-$(md instance/attributes/pg_hba_extra_cidrs || true)}"
  if [[ -n $raw_extra ]]; then
    raw_extra=${raw_extra//,/ }
    for cidr in $raw_extra; do
      [[ -z $cidr ]] && continue
      if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for repmgr user: $cidr"; fi
      if ! grep -qE "^host\\s+replication\\s+replication\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     replication       ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for replication: $cidr"; fi
      if ! grep -qE "^host\\s+replication\\s+${REPMGR_USER}\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     ${REPMGR_USER}    ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for replication (repmgr user): $cidr"; fi
    done
  fi

  # Ensure self primary IP(s) have /32 entries (covers local TCP connects using instance IP rather than localhost)
  local self_ips
  self_ips=$(ip -o -4 addr show | awk '!/ lo / {print $4}' | cut -d/ -f1 | sort -u)
  for sip in $self_ips; do
    [[ -z $sip ]] && continue
    if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for repmgr user: ${sip}"; fi
    if ! grep -qE "^host\\s+replication\\s+replication\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    replication     replication       ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for replication: ${sip}"; fi
    if ! grep -qE "^host\\s+replication\\s+${REPMGR_USER}\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    replication     ${REPMGR_USER}    ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for replication (repmgr user): ${sip}"; fi
  done

  # Upgrade any previously inserted md5 lines for this cluster scope if scram is enabled
  if [[ "$auth_method" == "scram-sha-256" ]]; then
    if grep -qE "host\s+.*\s+(md5)$" "$PG_HBA"; then
      sed -i "s/\(host[[:space:]].*[[:space:]]\)md5$/\1scram-sha-256/" "$PG_HBA" || true
      systemctl reload postgresql || true
    fi
  fi

  if (( changed == 1 )); then
    info "Reloading PostgreSQL after adding extra/self IP HBA lines"
    systemctl reload postgresql || systemctl restart postgresql || true
  fi

  # Ensure managed block appears early (before any broad REJECT or restrictive rules) once per run
  if ! grep -q '# HA-HBA-PRIORITIZED' "$PG_HBA" 2>/dev/null; then
    # Extract managed and non-managed sections; reassemble with managed first
    local tmp managed nonmanaged
    tmp=$(mktemp)
    managed=$(awk '/# BEGIN-HA-HBA/{flag=1} flag{print} /# END-HA-HBA/{flag=0} END{exit !flag}' "$PG_HBA" 2>/dev/null)
    if [[ -n $managed ]]; then
      nonmanaged=$(awk 'BEGIN{skip=0} /# BEGIN-HA-HBA/{skip=1} /# END-HA-HBA/{skip=0;next} !skip{print}' "$PG_HBA" 2>/dev/null)
      {
        echo "# HA-HBA-PRIORITIZED (managed block moved near top by bootstrap)";
        printf '%s\n' "$managed";
        printf '%s\n' "$nonmanaged";
      } > "$tmp" && cat "$tmp" > "$PG_HBA" && rm -f "$tmp" || true
      info "Reordered pg_hba.conf to prioritize managed HA block at top"
      systemctl reload postgresql || true
    fi
  fi
}

# Remove early auto_detect_role usage if present
# sanitize_id() { echo "${1}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g'; }
# auto_detect_role() {
#   # Safe even if PG not installed yet; will rely on metadata primarily.
#   if [[ -z "${ROLE}" || "${ROLE}" == "unknown" ]]; then
#     if [[ -n "${PG_DATA_DIR}" && -d "${PG_DATA_DIR}" && -f "${PG_DATA_DIR}/PG_VERSION" ]]; then
#       if sudo -u postgres psql -Atqc "select pg_is_in_recovery()" postgres 2>/dev/null | grep -q '^t'; then ROLE="standby"; else ROLE="primary"; fi
#     else
#       # Probe metadata-declared primary host; if reachable assume this is standby else primary
#       if [[ -n "${REPMGR_PRIMARY_HOST}" && "${REPMGR_PRIMARY_HOST}" != "pg-primary" && "${REPMGR_PRIMARY_HOST}" != "localhost" ]]; then
#         if timeout 2 bash -c "</dev/tcp/${REPMGR_PRIMARY_HOST}/5432" 2>/dev/null; then ROLE="standby"; else ROLE="primary"; fi
#       else
#         ROLE="primary"
#       fi
#     fi
#     info "Auto-detected ROLE=${ROLE}"
#   fi
#   if [[ "$ROLE" == "primary" && ( -z "${REPMGR_PRIMARY_HOST}" || "${REPMGR_PRIMARY_HOST}" == "pg-primary" ) ]]; then
#     local self_ip
#     self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}')
#     [[ -n "$self_ip" ]] && REPMGR_PRIMARY_HOST="$self_ip" && export REPMGR_PRIMARY_HOST && info "Set REPMGR_PRIMARY_HOST=$REPMGR_PRIMARY_HOST"
#   fi
# }
# sm_api() { local m="$1"; shift; local u="$1"; shift || true; local d="$1"; shift || true; retry 3 2 curl -sf -H "Authorization: Bearer $(jq -r '.access_token' ${TOKEN_CACHE} 2>/dev/null)" -H 'Content-Type: application/json' -X "$m" ${d:+-d "$d"} "$u" 2>/dev/null; }
# ensure_secret_exists() { local sid="$1" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}"; sm_api GET "${base}/secrets/${sid}" >/dev/null 2>&1 && return 0; info "Creating secret $sid"; sm_api POST "${base}/secrets?secretId=${sid}" '{"replication":{"automatic":{}},"labels":{"cluster":"'"${CLUSTER_ID}"'"}}' >/dev/null 2>&1 || warn "Create failed for $sid"; }
# add_secret_version() { local sid="$1" val="$2" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}" b64; b64=$(printf '%s' "$val" | base64 | tr -d '\n'); sm_api POST "${base}/secrets/${sid}:addVersion" '{"payload":{"data":"'"${b64}"'"}}' >/dev/null 2>&1 || warn "Add version failed for $sid"; }
# persist_password_secrets_if_primary() { [[ "$ROLE" != "primary" ]] && return 0; [[ -f $SENTINEL_PRIMARY_INIT ]] && return 0; _fetch_token || { warn "No token; skip secret persistence"; return 0; }; local prefix; prefix=$(sanitize_id "${CLUSTER_ID:-ha}"); PG_SUPERUSER_SECRET_ID="${PG_SUPERUSER_SECRET_ID:-${prefix}-pg-superuser-password}"; PG_REPLICATION_SECRET_ID="${PG_REPLICATION_SECRET_ID:-${prefix}-pg-replication-password}"; PG_MONITOR_SECRET_ID="${PG_MONITOR_SECRET_ID:-${prefix}-pg-monitor-password}"; REPMGR_SECRET_ID="${REPMGR_SECRET_ID:-${prefix}-pg-repmgr-password}"; export PG_SUPERUSER_SECRET_ID PG_REPLICATION_SECRET_ID PG_MONITOR_SECRET_ID REPMGR_SECRET_ID; for s in "$PG_SUPERUSER_SECRET_ID" "$PG_REPLICATION_SECRET_ID" "$PG_MONITOR_SECRET_ID" "$REPMGR_SECRET_ID"; do ensure_secret_exists "$s"; done; info "Persisting initial passwords to Secret Manager"; add_secret_version "$PG_SUPERUSER_SECRET_ID" "$PG_SUPER_PASS"; add_secret_version "$PG_REPLICATION_SECRET_ID" "$PG_REPL_PASS"; add_secret_version "$PG_MONITOR_SECRET_ID" "$PG_MONITOR_PASS"; [[ "$REPMGR_PASSWORD" != "$PG_SUPER_PASS" ]] && add_secret_version "$REPMGR_SECRET_ID" "$REPMGR_PASSWORD"; }
# fi

# Helper functions (only add if not already defined earlier)
if ! declare -f auto_detect_role >/dev/null 2>&1; then
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
  sm_api() { local m="$1"; shift; local u="$1"; shift || true; local d="$1"; shift || true; retry 3 2 curl -sf -H "Authorization: Bearer $(jq -r '.access_token' ${TOKEN_CACHE} 2>/dev/null)" -H 'Content-Type: application/json' -X "$m" ${d:+-d "$d"} "$u" 2>/dev/null; }
  ensure_secret_exists() { local sid="$1" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}"; sm_api GET "${base}/secrets/${sid}" >/dev/null 2>&1 && return 0; info "Creating secret $sid"; sm_api POST "${base}/secrets?secretId=${sid}" '{"replication":{"automatic":{}},"labels":{"cluster":"'"${CLUSTER_ID}"'"}}' >/dev/null 2>&1 || warn "Create failed for $sid"; }
  add_secret_version() { local sid="$1" val="$2" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}" b64; b64=$(printf '%s' "$val" | base64 | tr -d '\n'); sm_api POST "${base}/secrets/${sid}:addVersion" '{"payload":{"data":"'"${b64}"'"}}' >/dev/null 2>&1 || warn "Add version failed for $sid"; }
  persist_password_secrets_if_primary() { [[ "$ROLE" != "primary" ]] && return 0; [[ -f $SENTINEL_PRIMARY_INIT ]] && return 0; _fetch_token || { warn "No token; skip secret persistence"; return 0; }; local prefix; prefix=$(sanitize_id "${CLUSTER_ID:-ha}"); PG_SUPERUSER_SECRET_ID="${PG_SUPERUSER_SECRET_ID:-${prefix}-pg-superuser-password}"; PG_REPLICATION_SECRET_ID="${PG_REPLICATION_SECRET_ID:-${prefix}-pg-replication-password}"; PG_MONITOR_SECRET_ID="${PG_MONITOR_SECRET_ID:-${prefix}-pg-monitor-password}"; REPMGR_SECRET_ID="${REPMGR_SECRET_ID:-${prefix}-pg-repmgr-password}"; export PG_SUPERUSER_SECRET_ID PG_REPLICATION_SECRET_ID PG_MONITOR_SECRET_ID REPMGR_SECRET_ID; for s in "$PG_SUPERUSER_SECRET_ID" "$PG_REPLICATION_SECRET_ID" "$PG_MONITOR_SECRET_ID" "$REPMGR_SECRET_ID"; do ensure_secret_exists "$s"; done; info "Persisting initial passwords to Secret Manager"; add_secret_version "$PG_SUPERUSER_SECRET_ID" "$PG_SUPER_PASS"; add_secret_version "$PG_REPLICATION_SECRET_ID" "$PG_REPL_PASS"; add_secret_version "$PG_MONITOR_SECRET_ID" "$PG_MONITOR_PASS"; [[ "$REPMGR_PASSWORD" != "$PG_SUPER_PASS" ]] && add_secret_version "$REPMGR_SECRET_ID" "$REPMGR_PASSWORD"; }
fi

# -------- Package Installation (Idempotent) --------
install_packages() {
  info "Ensuring required packages installed"
  retry 3 5 apt-get update || die "apt update failed"
  local base_pkgs=(wget gnupg lsb-release jq netcat-openbsd curl ca-certificates openssl)
  info "Installing base utilities (${base_pkgs[*]})"
  retry 3 5 apt-get install -y --no-install-recommends "${base_pkgs[@]}" || die "base packages install failed"

  # Add PGDG repo if not present
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
    info "Installing packages: ${needed[*]}"
    retry 3 5 apt-get install -y "${needed[@]}" || die "package install failed (${needed[*]})"
  else
    debug "Core packages already present (PostgreSQL ${PG_VERSION}, client, pgbouncer)"
  fi

  # Ensure install_packages defers chown
  if [[ "${DEFERRED_CHOWN:-0}" == "1" ]] && id -u postgres >/dev/null 2>&1; then
    chown -R postgres:postgres "$REPMGR_CONF_DIR" "$REPMGR_EVENTS_DIR" || true
    DEFERRED_CHOWN=0
    debug "Applied deferred chown for $REPMGR_CONF_DIR"
  fi
}

# Enhanced repmgr installation logic (handles absence of versioned package)
install_repmgr_if_needed() {
  if command -v repmgr >/dev/null 2>&1; then
    debug "repmgr already installed ($(repmgr --version 2>/dev/null | awk '{print $2}' || echo unknown))"
    return 0
  fi
  info "Attempting installation of repmgr for PostgreSQL ${PG_VERSION}"
  local tried=()
  local pkg_versioned="repmgr${PG_VERSION}"
  if apt-cache show "$pkg_versioned" >/dev/null 2>&1; then
    info "Found package $pkg_versioned in APT; installing"
    if apt-get install -y "$pkg_versioned"; then return 0; else warn "Install failed for $pkg_versioned"; tried+=("$pkg_versioned (fail)"); fi
  else
    tried+=("$pkg_versioned (not found)")
  fi
  if apt-cache show repmgr >/dev/null 2>&1; then
    info "Trying unversioned 'repmgr' package"
    if apt-get install -y repmgr; then return 0; else warn "Install failed for repmgr"; tried+=("repmgr (fail)"); fi
  else
    tried+=("repmgr (not found)")
  fi
  info "Falling back to source build for repmgr (previous attempts: ${tried[*]})"
  build_repmgr_from_source || die "Failed to build repmgr from source"
}

build_repmgr_from_source() {
  local src_dir="/usr/local/src/repmgr"
  if command -v repmgr >/dev/null 2>&1; then return 0; fi
  info "Building repmgr from source (latest)"
  apt-get install -y --no-install-recommends build-essential git libpq-dev pkg-config clang || die "Build deps install failed"
  rm -rf "$src_dir" && mkdir -p "$src_dir"
  git clone --depth 1 https://github.com/EnterpriseDB/repmgr.git "$src_dir" || die "git clone repmgr failed"
  (cd "$src_dir" && make USE_PGXS=1 && make install) || die "repmgr source build failed"
  if ! command -v repmgr >/dev/null 2>&1; then die "repmgr not found after source build"; fi
  info "repmgr built from source: $(repmgr --version 2>/dev/null || echo unknown)"
}

# -------- Configuration Generation (Idempotent with checksum) --------
write_file_if_changed() { # write_file_if_changed <path> <content>
  local path="$1" tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'__EOF__'
$2
__EOF__
  if [[ ! -f $path ]] || ! cmp -s "$tmp" "$path"; then
    info "Updating file $path"
    mkdir -p "$(dirname "$path")"
    cp "$tmp" "$path"
  fi
  rm -f "$tmp"
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
archive_mode = off   # wal-g to enable later
EOF
  }
  harden_pg_hba
}

# Ensure server is listening on all interfaces (required for remote standbys)
ensure_listen_all() {
  local current source_file
  current=$(sudo -u postgres psql -Atqc "show listen_addresses" 2>/dev/null || echo '')
  if [[ -z "$current" ]]; then
    warn "listen_addresses query returned empty; will attempt ALTER SYSTEM"
  fi
  if [[ "$current" != "*" && "$current" != "0.0.0.0" ]]; then
    info "Adjusting listen_addresses from '$current' to '*' via ALTER SYSTEM"
    sudo -u postgres psql -Atqc "alter system set listen_addresses='*';" || warn "ALTER SYSTEM failed"
    # Check for duplicate entries in postgresql.conf that might override
    if grep -q "listen_addresses" "$PG_CONF"; then
      # Keep first occurrence as '*' comment out others
      awk '/listen_addresses/ && !done {sub(/=.*/, "= '*'"); done=1} /listen_addresses/ && done {print "#"$0; next} {print}' "$PG_CONF" >"${PG_CONF}.tmp" && mv "${PG_CONF}.tmp" "$PG_CONF" || true
    fi
    systemctl restart postgresql || die "Failed to restart postgres after listen_addresses change"
    sleep 2
    local after
    after=$(sudo -u postgres psql -Atqc "show listen_addresses" 2>/dev/null || echo '')
    info "listen_addresses now='$after'"
  fi
  if ! ss -lnpt | grep -q ':5432'; then
    warn "Port 5432 not listening externally yet (still loopback?). Current sockets:"; ss -lnpt | grep 5432 || true
  fi
}

# -------- pg_hba Hardening --------
detect_internal_cidr() {
  # If user/metadata provided explicit allowed CIDR via PG_ALLOWED_CIDR env or metadata key 'pg_allowed_cidr', honor that
  if [[ -n "${PG_ALLOWED_CIDR:-}" ]]; then echo "$PG_ALLOWED_CIDR"; return 0; fi
  local meta_allow
  meta_allow=$(md instance/attributes/pg_allowed_cidr || true)
  if [[ -n $meta_allow ]]; then echo "$meta_allow"; return 0; fi
  # Prefer first RFC1918 address (10., 172.16-31., 192.168.) ignoring link-local 169.254.*
  local cand
  while read -r cidr; do
    local ip=${cidr%/*}
    case "$ip" in
      10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.30.*|172.31.*)
        echo "$(echo "$ip" | awk -F'.' '{printf "%s.%s.%s.0/24", $1,$2,$3}')"; return 0;;
    esac
  done < <(ip -o -4 addr show | awk '!/ lo / {print $4}')
  # Fallback: take first non-loopback address
  ip -o -4 addr show | awk '!/ lo / {print $4}' | head -n1 | sed 's\/[0-9]\{1,2\}//' | awk -F'.' '{printf "%s.%s.%s.0/24", $1,$2,$3}' 2>/dev/null || echo "127.0.0.1/32"
}

harden_pg_hba() {
  local auth_method="md5"
  local enc
  enc=$(sudo -u postgres psql -Atqc "show password_encryption" 2>/dev/null || echo '')
  if [[ "$enc" == "scram-sha-256" ]]; then auth_method="scram-sha-256"; fi
  local allow_meta allow_cidr
  allow_meta=$(md instance/attributes/pg_allowed_cidr || true)
  if [[ -n $allow_meta ]]; then
    allow_cidr=$allow_meta
  else
    allow_cidr=$(detect_internal_cidr)
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
    info "pg_hba hardened to ${allow_cidr}"
  else
    debug "pg_hba already hardened"
    if [[ "$auth_method" == "scram-sha-256" ]]; then
      if awk '/# BEGIN-HA-HBA/{f=1} f && / md5$/{found=1} /# END-HA-HBA/{f=0} END{exit !found}' "$PG_HBA"; then
        info "Upgrading managed pg_hba block to scram-sha-256"
        sed -i '/# BEGIN-HA-HBA/,/# END-HA-HBA/ s/ md5$/ scram-sha-256/' "$PG_HBA" || true
        systemctl reload postgresql || true
      fi
    fi
  fi

  # Always evaluate explicit standby IPs (comma/space separated) from metadata or env STANDBY_IPS.
  # This solves clone failures: FATAL no pg_hba.conf entry for host <standbyIP>, user "repmgr"...
  local standby_ips
  standby_ips="${STANDBY_IPS:-$(md instance/attributes/pg_standby_ips || true)}"
  local changed=0
  if [[ -n $standby_ips ]]; then
    # Normalize separators to spaces
    standby_ips=${standby_ips//,/ }
    for ip in $standby_ips; do
      [[ -z $ip ]] && continue
      # Allow both replication user and repmgr DB user from each explicit IP (/32 specificity)
      if ! grep -qE "^host\s+${REPMGR_DB}\s+${REPMGR_USER}\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for ${REPMGR_USER} @ ${ip}";
      fi
      if ! grep -qE "^host\s+replication\s+replication\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     replication       ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for replication @ ${ip}";
      fi
      if ! grep -qE "^host\s+replication\s+${REPMGR_USER}\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     ${REPMGR_USER}    ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for replication db using ${REPMGR_USER} @ ${ip}";
      fi
    done
  fi
  if (( changed == 1 )); then
    info "Reloading PostgreSQL to apply new pg_hba.conf entries"
    systemctl reload postgresql || systemctl restart postgresql || true
  fi

  # Extra CIDRs (space/comma separated) via env/metadata key pg_hba_extra_cidrs
  local extra_cidrs raw_extra
  raw_extra="${PG_HBA_EXTRA_CIDRS:-$(md instance/attributes/pg_hba_extra_cidrs || true)}"
  if [[ -n $raw_extra ]]; then
    raw_extra=${raw_extra//,/ }
    for cidr in $raw_extra; do
      [[ -z $cidr ]] && continue
      if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for repmgr user: $cidr"; fi
      if ! grep -qE "^host\\s+replication\\s+replication\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     replication       ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for replication: $cidr"; fi
      if ! grep -qE "^host\\s+replication\\s+${REPMGR_USER}\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     ${REPMGR_USER}    ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for replication (repmgr user): $cidr"; fi
    done
  fi

  # Ensure self primary IP(s) have /32 entries (covers local TCP connects using instance IP rather than localhost)
  local self_ips
  self_ips=$(ip -o -4 addr show | awk '!/ lo / {print $4}' | cut -d/ -f1 | sort -u)
  for sip in $self_ips; do
    [[ -z $sip ]] && continue
    if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for repmgr user: ${sip}"; fi
    if ! grep -qE "^host\\s+replication\\s+replication\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    replication     replication       ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for replication: ${sip}"; fi
    if ! grep -qE "^host\\s+replication\\s+${REPMGR_USER}\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    replication     ${REPMGR_USER}    ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for replication (repmgr user): ${sip}"; fi
  done

  # Upgrade any previously inserted md5 lines for this cluster scope if scram is enabled
  if [[ "$auth_method" == "scram-sha-256" ]]; then
    if grep -qE "host\s+.*\s+(md5)$" "$PG_HBA"; then
      sed -i "s/\(host[[:space:]].*[[:space:]]\)md5$/\1scram-sha-256/" "$PG_HBA" || true
      systemctl reload postgresql || true
    fi
  fi

  if (( changed == 1 )); then
    info "Reloading PostgreSQL after adding extra/self IP HBA lines"
    systemctl reload postgresql || systemctl restart postgresql || true
  fi

  # Ensure managed block appears early (before any broad REJECT or restrictive rules) once per run
  if ! grep -q '# HA-HBA-PRIORITIZED' "$PG_HBA" 2>/dev/null; then
    # Extract managed and non-managed sections; reassemble with managed first
    local tmp managed nonmanaged
    tmp=$(mktemp)
    managed=$(awk '/# BEGIN-HA-HBA/{flag=1} flag{print} /# END-HA-HBA/{flag=0} END{exit !flag}' "$PG_HBA" 2>/dev/null)
    if [[ -n $managed ]]; then
      nonmanaged=$(awk 'BEGIN{skip=0} /# BEGIN-HA-HBA/{skip=1} /# END-HA-HBA/{skip=0;next} !skip{print}' "$PG_HBA" 2>/dev/null)
      {
        echo "# HA-HBA-PRIORITIZED (managed block moved near top by bootstrap)";
        printf '%s\n' "$managed";
        printf '%s\n' "$nonmanaged";
      } > "$tmp" && cat "$tmp" > "$PG_HBA" && rm -f "$tmp" || true
      info "Reordered pg_hba.conf to prioritize managed HA block at top"
      systemctl reload postgresql || true
    fi
  fi
}

# Remove early auto_detect_role usage if present
# sanitize_id() { echo "${1}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g'; }
# auto_detect_role() {
#   # Safe even if PG not installed yet; will rely on metadata primarily.
#   if [[ -z "${ROLE}" || "${ROLE}" == "unknown" ]]; then
#     if [[ -n "${PG_DATA_DIR}" && -d "${PG_DATA_DIR}" && -f "${PG_DATA_DIR}/PG_VERSION" ]]; then
#       if sudo -u postgres psql -Atqc "select pg_is_in_recovery()" postgres 2>/dev/null | grep -q '^t'; then ROLE="standby"; else ROLE="primary"; fi
#     else
#       # Probe metadata-declared primary host; if reachable assume this is standby else primary
#       if [[ -n "${REPMGR_PRIMARY_HOST}" && "${REPMGR_PRIMARY_HOST}" != "pg-primary" && "${REPMGR_PRIMARY_HOST}" != "localhost" ]]; then
#         if timeout 2 bash -c "</dev/tcp/${REPMGR_PRIMARY_HOST}/5432" 2>/dev/null; then ROLE="standby"; else ROLE="primary"; fi
#       else
#         ROLE="primary"
#       fi
#     fi
#     info "Auto-detected ROLE=${ROLE}"
#   fi
#   if [[ "$ROLE" == "primary" && ( -z "${REPMGR_PRIMARY_HOST}" || "${REPMGR_PRIMARY_HOST}" == "pg-primary" ) ]]; then
#     local self_ip
#     self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}')
#     [[ -n "$self_ip" ]] && REPMGR_PRIMARY_HOST="$self_ip" && export REPMGR_PRIMARY_HOST && info "Set REPMGR_PRIMARY_HOST=$REPMGR_PRIMARY_HOST"
#   fi
# }
# sm_api() { local m="$1"; shift; local u="$1"; shift || true; local d="$1"; shift || true; retry 3 2 curl -sf -H "Authorization: Bearer $(jq -r '.access_token' ${TOKEN_CACHE} 2>/dev/null)" -H 'Content-Type: application/json' -X "$m" ${d:+-d "$d"} "$u" 2>/dev/null; }
# ensure_secret_exists() { local sid="$1" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}"; sm_api GET "${base}/secrets/${sid}" >/dev/null 2>&1 && return 0; info "Creating secret $sid"; sm_api POST "${base}/secrets?secretId=${sid}" '{"replication":{"automatic":{}},"labels":{"cluster":"'"${CLUSTER_ID}"'"}}' >/dev/null 2>&1 || warn "Create failed for $sid"; }
# add_secret_version() { local sid="$1" val="$2" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}" b64; b64=$(printf '%s' "$val" | base64 | tr -d '\n'); sm_api POST "${base}/secrets/${sid}:addVersion" '{"payload":{"data":"'"${b64}"'"}}' >/dev/null 2>&1 || warn "Add version failed for $sid"; }
# persist_password_secrets_if_primary() { [[ "$ROLE" != "primary" ]] && return 0; [[ -f $SENTINEL_PRIMARY_INIT ]] && return 0; _fetch_token || { warn "No token; skip secret persistence"; return 0; }; local prefix; prefix=$(sanitize_id "${CLUSTER_ID:-ha}"); PG_SUPERUSER_SECRET_ID="${PG_SUPERUSER_SECRET_ID:-${prefix}-pg-superuser-password}"; PG_REPLICATION_SECRET_ID="${PG_REPLICATION_SECRET_ID:-${prefix}-pg-replication-password}"; PG_MONITOR_SECRET_ID="${PG_MONITOR_SECRET_ID:-${prefix}-pg-monitor-password}"; REPMGR_SECRET_ID="${REPMGR_SECRET_ID:-${prefix}-pg-repmgr-password}"; export PG_SUPERUSER_SECRET_ID PG_REPLICATION_SECRET_ID PG_MONITOR_SECRET_ID REPMGR_SECRET_ID; for s in "$PG_SUPERUSER_SECRET_ID" "$PG_REPLICATION_SECRET_ID" "$PG_MONITOR_SECRET_ID" "$REPMGR_SECRET_ID"; do ensure_secret_exists "$s"; done; info "Persisting initial passwords to Secret Manager"; add_secret_version "$PG_SUPERUSER_SECRET_ID" "$PG_SUPER_PASS"; add_secret_version "$PG_REPLICATION_SECRET_ID" "$PG_REPL_PASS"; add_secret_version "$PG_MONITOR_SECRET_ID" "$PG_MONITOR_PASS"; [[ "$REPMGR_PASSWORD" != "$PG_SUPER_PASS" ]] && add_secret_version "$REPMGR_SECRET_ID" "$REPMGR_PASSWORD"; }
# fi

# Helper functions (only add if not already defined earlier)
if ! declare -f auto_detect_role >/dev/null 2>&1; then
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
  sm_api() { local m="$1"; shift; local u="$1"; shift || true; local d="$1"; shift || true; retry 3 2 curl -sf -H "Authorization: Bearer $(jq -r '.access_token' ${TOKEN_CACHE} 2>/dev/null)" -H 'Content-Type: application/json' -X "$m" ${d:+-d "$d"} "$u" 2>/dev/null; }
  ensure_secret_exists() { local sid="$1" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}"; sm_api GET "${base}/secrets/${sid}" >/dev/null 2>&1 && return 0; info "Creating secret $sid"; sm_api POST "${base}/secrets?secretId=${sid}" '{"replication":{"automatic":{}},"labels":{"cluster":"'"${CLUSTER_ID}"'"}}' >/dev/null 2>&1 || warn "Create failed for $sid"; }
  add_secret_version() { local sid="$1" val="$2" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}" b64; b64=$(printf '%s' "$val" | base64 | tr -d '\n'); sm_api POST "${base}/secrets/${sid}:addVersion" '{"payload":{"data":"'"${b64}"'"}}' >/dev/null 2>&1 || warn "Add version failed for $sid"; }
  persist_password_secrets_if_primary() { [[ "$ROLE" != "primary" ]] && return 0; [[ -f $SENTINEL_PRIMARY_INIT ]] && return 0; _fetch_token || { warn "No token; skip secret persistence"; return 0; }; local prefix; prefix=$(sanitize_id "${CLUSTER_ID:-ha}"); PG_SUPERUSER_SECRET_ID="${PG_SUPERUSER_SECRET_ID:-${prefix}-pg-superuser-password}"; PG_REPLICATION_SECRET_ID="${PG_REPLICATION_SECRET_ID:-${prefix}-pg-replication-password}"; PG_MONITOR_SECRET_ID="${PG_MONITOR_SECRET_ID:-${prefix}-pg-monitor-password}"; REPMGR_SECRET_ID="${REPMGR_SECRET_ID:-${prefix}-pg-repmgr-password}"; export PG_SUPERUSER_SECRET_ID PG_REPLICATION_SECRET_ID PG_MONITOR_SECRET_ID REPMGR_SECRET_ID; for s in "$PG_SUPERUSER_SECRET_ID" "$PG_REPLICATION_SECRET_ID" "$PG_MONITOR_SECRET_ID" "$REPMGR_SECRET_ID"; do ensure_secret_exists "$s"; done; info "Persisting initial passwords to Secret Manager"; add_secret_version "$PG_SUPERUSER_SECRET_ID" "$PG_SUPER_PASS"; add_secret_version "$PG_REPLICATION_SECRET_ID" "$PG_REPL_PASS"; add_secret_version "$PG_MONITOR_SECRET_ID" "$PG_MONITOR_PASS"; [[ "$REPMGR_PASSWORD" != "$PG_SUPER_PASS" ]] && add_secret_version "$REPMGR_SECRET_ID" "$REPMGR_PASSWORD"; }
fi

# -------- Package Installation (Idempotent) --------
install_packages() {
  info "Ensuring required packages installed"
  retry 3 5 apt-get update || die "apt update failed"
  local base_pkgs=(wget gnupg lsb-release jq netcat-openbsd curl ca-certificates openssl)
  info "Installing base utilities (${base_pkgs[*]})"
  retry 3 5 apt-get install -y --no-install-recommends "${base_pkgs[@]}" || die "base packages install failed"

  # Add PGDG repo if not present
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
    info "Installing packages: ${needed[*]}"
    retry 3 5 apt-get install -y "${needed[@]}" || die "package install failed (${needed[*]})"
  else
    debug "Core packages already present (PostgreSQL ${PG_VERSION}, client, pgbouncer)"
  fi

  # Ensure install_packages defers chown
  if [[ "${DEFERRED_CHOWN:-0}" == "1" ]] && id -u postgres >/dev/null 2>&1; then
    chown -R postgres:postgres "$REPMGR_CONF_DIR" "$REPMGR_EVENTS_DIR" || true
    DEFERRED_CHOWN=0
    debug "Applied deferred chown for $REPMGR_CONF_DIR"
  fi
}

# Enhanced repmgr installation logic (handles absence of versioned package)
install_repmgr_if_needed() {
  if command -v repmgr >/dev/null 2>&1; then
    debug "repmgr already installed ($(repmgr --version 2>/dev/null | awk '{print $2}' || echo unknown))"
    return 0
  fi
  info "Attempting installation of repmgr for PostgreSQL ${PG_VERSION}"
  local tried=()
  local pkg_versioned="repmgr${PG_VERSION}"
  if apt-cache show "$pkg_versioned" >/dev/null 2>&1; then
    info "Found package $pkg_versioned in APT; installing"
    if apt-get install -y "$pkg_versioned"; then return 0; else warn "Install failed for $pkg_versioned"; tried+=("$pkg_versioned (fail)"); fi
  else
    tried+=("$pkg_versioned (not found)")
  fi
  if apt-cache show repmgr >/dev/null 2>&1; then
    info "Trying unversioned 'repmgr' package"
    if apt-get install -y repmgr; then return 0; else warn "Install failed for repmgr"; tried+=("repmgr (fail)"); fi
  else
    tried+=("repmgr (not found)")
  fi
  info "Falling back to source build for repmgr (previous attempts: ${tried[*]})"
  build_repmgr_from_source || die "Failed to build repmgr from source"
}

build_repmgr_from_source() {
  local src_dir="/usr/local/src/repmgr"
  if command -v repmgr >/dev/null 2>&1; then return 0; fi
  info "Building repmgr from source (latest)"
  apt-get install -y --no-install-recommends build-essential git libpq-dev pkg-config clang || die "Build deps install failed"
  rm -rf "$src_dir" && mkdir -p "$src_dir"
  git clone --depth 1 https://github.com/EnterpriseDB/repmgr.git "$src_dir" || die "git clone repmgr failed"
  (cd "$src_dir" && make USE_PGXS=1 && make install) || die "repmgr source build failed"
  if ! command -v repmgr >/dev/null 2>&1; then die "repmgr not found after source build"; fi
  info "repmgr built from source: $(repmgr --version 2>/dev/null || echo unknown)"
}

# -------- Configuration Generation (Idempotent with checksum) --------
write_file_if_changed() { # write_file_if_changed <path> <content>
  local path="$1" tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'__EOF__'
$2
__EOF__
  if [[ ! -f $path ]] || ! cmp -s "$tmp" "$path"; then
    info "Updating file $path"
    mkdir -p "$(dirname "$path")"
    cp "$tmp" "$path"
  fi
  rm -f "$tmp"
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
archive_mode = off   # wal-g to enable later
EOF
  }
  harden_pg_hba
}

# Ensure server is listening on all interfaces (required for remote standbys)
ensure_listen_all() {
  local current source_file
  current=$(sudo -u postgres psql -Atqc "show listen_addresses" 2>/dev/null || echo '')
  if [[ -z "$current" ]]; then
    warn "listen_addresses query returned empty; will attempt ALTER SYSTEM"
  fi
  if [[ "$current" != "*" && "$current" != "0.0.0.0" ]]; then
    info "Adjusting listen_addresses from '$current' to '*' via ALTER SYSTEM"
    sudo -u postgres psql -Atqc "alter system set listen_addresses='*';" || warn "ALTER SYSTEM failed"
    # Check for duplicate entries in postgresql.conf that might override
    if grep -q "listen_addresses" "$PG_CONF"; then
      # Keep first occurrence as '*' comment out others
      awk '/listen_addresses/ && !done {sub(/=.*/, "= '*'"); done=1} /listen_addresses/ && done {print "#"$0; next} {print}' "$PG_CONF" >"${PG_CONF}.tmp" && mv "${PG_CONF}.tmp" "$PG_CONF" || true
    fi
    systemctl restart postgresql || die "Failed to restart postgres after listen_addresses change"
    sleep 2
    local after
    after=$(sudo -u postgres psql -Atqc "show listen_addresses" 2>/dev/null || echo '')
    info "listen_addresses now='$after'"
  fi
  if ! ss -lnpt | grep -q ':5432'; then
    warn "Port 5432 not listening externally yet (still loopback?). Current sockets:"; ss -lnpt | grep 5432 || true
  fi
}

# -------- pg_hba Hardening --------
detect_internal_cidr() {
  # If user/metadata provided explicit allowed CIDR via PG_ALLOWED_CIDR env or metadata key 'pg_allowed_cidr', honor that
  if [[ -n "${PG_ALLOWED_CIDR:-}" ]]; then echo "$PG_ALLOWED_CIDR"; return 0; fi
  local meta_allow
  meta_allow=$(md instance/attributes/pg_allowed_cidr || true)
  if [[ -n $meta_allow ]]; then echo "$meta_allow"; return 0; fi
  # Prefer first RFC1918 address (10., 172.16-31., 192.168.) ignoring link-local 169.254.*
  local cand
  while read -r cidr; do
    local ip=${cidr%/*}
    case "$ip" in
      10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.30.*|172.31.*)
        echo "$(echo "$ip" | awk -F'.' '{printf "%s.%s.%s.0/24", $1,$2,$3}')"; return 0;;
    esac
  done < <(ip -o -4 addr show | awk '!/ lo / {print $4}')
  # Fallback: take first non-loopback address
  ip -o -4 addr show | awk '!/ lo / {print $4}' | head -n1 | sed 's\/[0-9]\{1,2\}//' | awk -F'.' '{printf "%s.%s.%s.0/24", $1,$2,$3}' 2>/dev/null || echo "127.0.0.1/32"
}

harden_pg_hba() {
  local auth_method="md5"
  local enc
  enc=$(sudo -u postgres psql -Atqc "show password_encryption" 2>/dev/null || echo '')
  if [[ "$enc" == "scram-sha-256" ]]; then auth_method="scram-sha-256"; fi
  local allow_meta allow_cidr
  allow_meta=$(md instance/attributes/pg_allowed_cidr || true)
  if [[ -n $allow_meta ]]; then
    allow_cidr=$allow_meta
  else
    allow_cidr=$(detect_internal_cidr)
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
    info "pg_hba hardened to ${allow_cidr}"
  else
    debug "pg_hba already hardened"
    if [[ "$auth_method" == "scram-sha-256" ]]; then
      if awk '/# BEGIN-HA-HBA/{f=1} f && / md5$/{found=1} /# END-HA-HBA/{f=0} END{exit !found}' "$PG_HBA"; then
        info "Upgrading managed pg_hba block to scram-sha-256"
        sed -i '/# BEGIN-HA-HBA/,/# END-HA-HBA/ s/ md5$/ scram-sha-256/' "$PG_HBA" || true
        systemctl reload postgresql || true
      fi
    fi
  fi

  # Always evaluate explicit standby IPs (comma/space separated) from metadata or env STANDBY_IPS.
  # This solves clone failures: FATAL no pg_hba.conf entry for host <standbyIP>, user "repmgr"...
  local standby_ips
  standby_ips="${STANDBY_IPS:-$(md instance/attributes/pg_standby_ips || true)}"
  local changed=0
  if [[ -n $standby_ips ]]; then
    # Normalize separators to spaces
    standby_ips=${standby_ips//,/ }
    for ip in $standby_ips; do
      [[ -z $ip ]] && continue
      # Allow both replication user and repmgr DB user from each explicit IP (/32 specificity)
      if ! grep -qE "^host\s+${REPMGR_DB}\s+${REPMGR_USER}\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for ${REPMGR_USER} @ ${ip}";
      fi
      if ! grep -qE "^host\s+replication\s+replication\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     replication       ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for replication @ ${ip}";
      fi
      if ! grep -qE "^host\s+replication\s+${REPMGR_USER}\s+${ip}/32\s+${auth_method}" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     ${REPMGR_USER}    ${ip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba entry for replication db using ${REPMGR_USER} @ ${ip}";
      fi
    done
  fi
  if (( changed == 1 )); then
    info "Reloading PostgreSQL to apply new pg_hba.conf entries"
    systemctl reload postgresql || systemctl restart postgresql || true
  fi

  # Extra CIDRs (space/comma separated) via env/metadata key pg_hba_extra_cidrs
  local extra_cidrs raw_extra
  raw_extra="${PG_HBA_EXTRA_CIDRS:-$(md instance/attributes/pg_hba_extra_cidrs || true)}"
  if [[ -n $raw_extra ]]; then
    raw_extra=${raw_extra//,/ }
    for cidr in $raw_extra; do
      [[ -z $cidr ]] && continue
      if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for repmgr user: $cidr"; fi
      if ! grep -qE "^host\\s+replication\\s+replication\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     replication       ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for replication: $cidr"; fi
      if ! grep -qE "^host\\s+replication\\s+${REPMGR_USER}\\s+${cidr}\\s+" "$PG_HBA" 2>/dev/null; then
        echo "host    replication     ${REPMGR_USER}    ${cidr}    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added pg_hba extra CIDR for replication (repmgr user): $cidr"; fi
    done
  fi

  # Ensure self primary IP(s) have /32 entries (covers local TCP connects using instance IP rather than localhost)
  local self_ips
  self_ips=$(ip -o -4 addr show | awk '!/ lo / {print $4}' | cut -d/ -f1 | sort -u)
  for sip in $self_ips; do
    [[ -z $sip ]] && continue
    if ! grep -qE "^host\\s+${REPMGR_DB}\\s+${REPMGR_USER}\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    ${REPMGR_DB}    ${REPMGR_USER}    ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for repmgr user: ${sip}"; fi
    if ! grep -qE "^host\\s+replication\\s+replication\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    replication     replication       ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for replication: ${sip}"; fi
    if ! grep -qE "^host\\s+replication\\s+${REPMGR_USER}\\s+${sip}/32\\s+" "$PG_HBA" 2>/dev/null; then
      echo "host    replication     ${REPMGR_USER}    ${sip}/32    ${auth_method}" >> "$PG_HBA"; changed=1; info "Added self-IP pg_hba entry for replication (repmgr user): ${sip}"; fi
  done

  # Upgrade any previously inserted md5 lines for this cluster scope if scram is enabled
  if [[ "$auth_method" == "scram-sha-256" ]]; then
    if grep -qE "host\s+.*\s+(md5)$" "$PG_HBA"; then
      sed -i "s/\(host[[:space:]].*[[:space:]]\)md5$/\1scram-sha-256/" "$PG_HBA" || true
      systemctl reload postgresql || true
    fi
  fi

  if (( changed == 1 )); then
    info "Reloading PostgreSQL after adding extra/self IP HBA lines"
    systemctl reload postgresql || systemctl restart postgresql || true
  fi

  # Ensure managed block appears early (before any broad REJECT or restrictive rules) once per run
  if ! grep -q '# HA-HBA-PRIORITIZED' "$PG_HBA" 2>/dev/null; then
    # Extract managed and non-managed sections; reassemble with managed first
    local tmp managed nonmanaged
    tmp=$(mktemp)
    managed=$(awk '/# BEGIN-HA-HBA/{flag=1} flag{print} /# END-HA-HBA/{flag=0} END{exit !flag}' "$PG_HBA" 2>/dev/null)
    if [[ -n $managed ]]; then
      nonmanaged=$(awk 'BEGIN{skip=0} /# BEGIN-HA-HBA/{skip=1} /# END-HA-HBA/{skip=0;next} !skip{print}' "$PG_HBA" 2>/dev/null)
      {
        echo "# HA-HBA-PRIORITIZED (managed block moved near top by bootstrap)";
        printf '%s\n' "$managed";
        printf '%s\n' "$nonmanaged";
      } > "$tmp" && cat "$tmp" > "$PG_HBA" && rm -f "$tmp" || true
      info "Reordered pg_hba.conf to prioritize managed HA block at top"
      systemctl reload postgresql || true
    fi
  fi
}

# Remove early auto_detect_role usage if present
# sanitize_id() { echo "${1}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g'; }
# auto_detect_role() {
#   # Safe even if PG not installed yet; will rely on metadata primarily.
#   if [[ -z "${ROLE}" || "${ROLE}" == "unknown" ]]; then
#     if [[ -n "${PG_DATA_DIR}" && -d "${PG_DATA_DIR}" && -f "${PG_DATA_DIR}/PG_VERSION" ]]; then
#       if sudo -u postgres psql -Atqc "select pg_is_in_recovery()" postgres 2>/dev/null | grep -q '^t'; then ROLE="standby"; else ROLE="primary"; fi
#     else
#       # Probe metadata-declared primary host; if reachable assume this is standby else primary
#       if [[ -n "${REPMGR_PRIMARY_HOST}" && "${REPMGR_PRIMARY_HOST}" != "pg-primary" && "${REPMGR_PRIMARY_HOST}" != "localhost" ]]; then
#         if timeout 2 bash -c "</dev/tcp/${REPMGR_PRIMARY_HOST}/5432" 2>/dev/null; then ROLE="standby"; else ROLE="primary"; fi
#       else
#         ROLE="primary"
#       fi
#     fi
#     info "Auto-detected ROLE=${ROLE}"
#   fi
#   if [[ "$ROLE" == "primary" && ( -z "${REPMGR_PRIMARY_HOST}" || "${REPMGR_PRIMARY_HOST}" == "pg-primary" ) ]]; then
#     local self_ip
#     self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}')
#     [[ -n "$self_ip" ]] && REPMGR_PRIMARY_HOST="$self_ip" && export REPMGR_PRIMARY_HOST && info "Set REPMGR_PRIMARY_HOST=$REPMGR_PRIMARY_HOST"
#   fi
# }
# sm_api() { local m="$1"; shift; local u="$1"; shift || true; local d="$1"; shift || true; retry 3 2 curl -sf -H "Authorization: Bearer $(jq -r '.access_token' ${TOKEN_CACHE} 2>/dev/null)" -H 'Content-Type: application/json' -X "$m" ${d:+-d "$d"} "$u" 2>/dev/null; }
# ensure_secret_exists() { local sid="$1" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}"; sm_api GET "${base}/secrets/${sid}" >/dev/null 2>&1 && return 0; info "Creating secret $sid"; sm_api POST "${base}/secrets?secretId=${sid}" '{"replication":{"automatic":{}},"labels":{"cluster":"'"${CLUSTER_ID}"'"}}' >/dev/null 2>&1 || warn "Create failed for $sid"; }
# add_secret_version() { local sid="$1" val="$2" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}" b64; b64=$(printf '%s' "$val" | base64 | tr -d '\n'); sm_api POST "${base}/secrets/${sid}:addVersion" '{"payload":{"data":"'"${b64}"'"}}' >/dev/null 2>&1 || warn "Add version failed for $sid"; }
# persist_password_secrets_if_primary() { [[ "$ROLE" != "primary" ]] && return 0; [[ -f $SENTINEL_PRIMARY_INIT ]] && return 0; _fetch_token || { warn "No token; skip secret persistence"; return 0; }; local prefix; prefix=$(sanitize_id "${CLUSTER_ID:-ha}"); PG_SUPERUSER_SECRET_ID="${PG_SUPERUSER_SECRET_ID:-${prefix}-pg-superuser-password}"; PG_REPLICATION_SECRET_ID="${PG_REPLICATION_SECRET_ID:-${prefix}-pg-replication-password}"; PG_MONITOR_SECRET_ID="${PG_MONITOR_SECRET_ID:-${prefix}-pg-monitor-password}"; REPMGR_SECRET_ID="${REPMGR_SECRET_ID:-${prefix}-pg-repmgr-password}"; export PG_SUPERUSER_SECRET_ID PG_REPLICATION_SECRET_ID PG_MONITOR_SECRET_ID REPMGR_SECRET_ID; for s in "$PG_SUPERUSER_SECRET_ID" "$PG_REPLICATION_SECRET_ID" "$PG_MONITOR_SECRET_ID" "$REPMGR_SECRET_ID"; do ensure_secret_exists "$s"; done; info "Persisting initial passwords to Secret Manager"; add_secret_version "$PG_SUPERUSER_SECRET_ID" "$PG_SUPER_PASS"; add_secret_version "$PG_REPLICATION_SECRET_ID" "$PG_REPL_PASS"; add_secret_version "$PG_MONITOR_SECRET_ID" "$PG_MONITOR_PASS"; [[ "$REPMGR_PASSWORD" != "$PG_SUPER_PASS" ]] && add_secret_version "$REPMGR_SECRET_ID" "$REPMGR_PASSWORD"; }
# fi

# Helper functions (only add if not already defined earlier)
if ! declare -f auto_detect_role >/dev/null 2>&1; then
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
  sm_api() { local m="$1"; shift; local u="$1"; shift || true; local d="$1"; shift || true; retry 3 2 curl -sf -H "Authorization: Bearer $(jq -r '.access_token' ${TOKEN_CACHE} 2>/dev/null)" -H 'Content-Type: application/json' -X "$m" ${d:+-d "$d"} "$u" 2>/dev/null; }
  ensure_secret_exists() { local sid="$1" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}"; sm_api GET "${base}/secrets/${sid}" >/dev/null 2>&1 && return 0; info "Creating secret $sid"; sm_api POST "${base}/secrets?secretId=${sid}" '{"replication":{"automatic":{}},"labels":{"cluster":"'"${CLUSTER_ID}"'"}}' >/dev/null 2>&1 || warn "Create failed for $sid"; }
  add_secret_version() { local sid="$1" val="$2" base="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}" b64; b64=$(printf '%s' "$val" | base64 | tr -d '\n'); sm_api POST "${base}/secrets/${sid}:addVersion" '{"payload":{"data":"'"${b64}"'"}}' >/dev/null 2>&1 || warn "Add version failed for $sid"; }
  persist_password_secrets_if_primary() { [[ "$ROLE" != "primary" ]] && return 0; [[ -f $SENTINEL_PRIMARY_INIT ]] && return 0; _fetch_token || { warn "No token; skip secret persistence"; return 0; }; local prefix; prefix=$(sanitize_id "${CLUSTER_ID:-ha}"); PG_SUPERUSER_SECRET_ID="${PG_SUPERUSER_SECRET_ID:-${prefix}-pg-superuser-password}"; PG_REPLICATION_SECRET_ID="${PG_REPLICATION_SECRET_ID:-${prefix}-pg-replication-password}"; PG_MONITOR_SECRET_ID="${PG_MONITOR_SECRET_ID:-${prefix}-pg-monitor-password}"; REPMGR_SECRET_ID="${REPMGR_SECRET_ID:-${prefix}-pg-repmgr-password}"; export PG_SUPERUSER_SECRET_ID PG_REPLICATION_SECRET_ID PG_MONITOR_SECRET_ID REPMGR_SECRET_ID; for s in "$PG_SUPERUSER_SECRET_ID" "$PG_REPLICATION_SECRET_ID" "$PG_MONITOR_SECRET_ID" "$REPMGR_SECRET_ID"; do ensure_secret_exists "$s"; done; info "Persisting initial passwords to Secret Manager"; add_secret_version "$PG_SUPERUSER_SECRET_ID" "$PG_SUPER_PASS"; add_secret_version "$PG_REPLICATION_SECRET_ID" "$PG_REPL_PASS"; add_secret_version "$PG_MONITOR_SECRET_ID" "$PG_MONITOR_PASS"; [[ "$REPMGR_PASSWORD" != "$PG_SUPER_PASS" ]] && add_secret_version "$REPMGR_SECRET_ID" "$REPMGR_PASSWORD"; }
fi

# -------- Package Installation (Idempotent) --------
install_packages() {
  info "Ensuring required packages installed"
  retry 3 5 apt-get update || die "apt update failed"
  local base_pkgs=(wget gnupg lsb-release jq netcat-openbsd curl ca-certificates openssl)
  info "Installing base utilities (${base_pkgs[*]})"
  retry 3 5 apt-get install -y --no-install-recommends "${base_pkgs[@]}" || die "base packages install failed"

  # Add PGDG repo if not present
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
    info "Installing packages: ${needed[*]}"
    retry 3 5 apt-get install -y "${needed[@]}" || die "package install failed (${needed[*]})"
  else
    debug "Core packages already present (PostgreSQL ${PG_VERSION}, client, pgbouncer)"
  fi

  # Ensure install_packages defers chown
  if [[ "${DEFERRED_CHOWN:-0}" == "1" ]] && id -u postgres >/dev/null 2>&1; then
    chown -R postgres:postgres "$REPMGR_CONF_DIR" "$REPMGR_EVENTS_DIR" || true
    DEFERRED_CHOWN=0
    debug "Applied deferred chown for $REPMGR_CONF_DIR"
  fi
}

# Enhanced repmgr installation logic (handles absence of versioned package)
install_repmgr_if_needed() {
  if command -v repmgr >/dev/null 2>&1; then
    debug "repmgr already installed ($(repmgr --version 2>/dev/null | awk '{print $2}' || echo unknown))"
    return 0
  fi
  info "Attempting installation of repmgr for PostgreSQL ${PG_VERSION}"
  local tried=()
  local pkg_versioned="repmgr${PG_VERSION}"
  if apt-cache show "$pkg_versioned" >/dev/null 2>&1; then
    info "Found package $pkg_versioned in APT; installing"
    if apt-get install -y "$pkg_versioned"; then return 0; else warn "Install failed for $pkg_versioned"; tried+=("$pkg_versioned (fail)"); fi
  else
    tried+=("$pkg_versioned (not found)")
  fi
  if apt-cache show repmgr >/dev/null 2>&1; then
    info "Trying unversioned 'repmgr' package"
    if apt-get install -y repmgr; then return 0; else warn "Install failed for repmgr"; tried+=("repmgr (fail)"); fi
  else
    tried+=("repmgr (not found)")
  fi
  info "Falling back to source build for repmgr (previous attempts: ${tried[*]})"
  build_repmgr_from_source || die "Failed to build repmgr from source"
}

build_repmgr_from_source() {
  local src_dir="/usr/local/src/repmgr"
  if command -v repmgr >/dev/null 2>&1; then return 0; fi
  info "Building repmgr from source (latest)"
  apt-get install -y --no-install-recommends build-essential git libpq-dev pkg-config clang || die "Build deps install failed"
  rm -rf "$src_dir" && mkdir -p "$src_dir"
  git clone --depth 1 https://github.com/EnterpriseDB/repmgr.git "$src_dir" || die "git clone repmgr failed"
  (cd "$src_dir" && make USE_PGXS=1 && make install) || die "repmgr source build failed"
  if ! command -v repmgr >/dev/null 2>&1; then die "repmgr not found after source build"; fi
  info "repmgr built from source: $(repmgr --version 2>/dev/null || echo unknown)"
}

# -------- Configuration Generation (Idempotent with checksum) --------
write_file_if_changed() { # write_file_if_changed <path> <content>
  local path="$1" tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'__EOF__'
$2
__EOF__
  if [[ ! -f $path ]] || ! cmp -s "$tmp" "$path"; then
    info "Updating file $path"
    mkdir -p "$(dirname "$path")"
    cp "$tmp" "$path"
  fi
  rm -f "$tmp"
}

# Override generate_repmgr_conf with enhanced validation & parameters
unset -f generate_repmgr_conf 2>/dev/null || true
generate_repmgr_conf() {
  info "Generating repmgr.conf (enhanced)"
  local node_id cluster_name host_part="localhost" cand_ip
  case "$ROLE" in primary) node_id=1 ;; standby) node_id=2 ;; witness) node_id=9 ;; *) node_id=0 ;; esac
  cluster_name=$(echo "${CLUSTER_ID:-ha_cluster}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_]/_/g')
  cand_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)
  [[ -n "$cand_ip" ]] && host_part="$cand_ip"
  cat > "$REPMGR_CONF_FILE" <<EOF
# Auto-generated by ha_postgresql_setup.sh ${SCRIPT_VERSION}
# cluster logical name (informational)
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
promote_action='repmgr standby promote -f ${REPMGR_CONF_FILE}'
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
  [[ $node_id -gt 0 ]] || warn "Node id is 0 (role=$ROLE) — registration may fail until role clarified"
}

# Always-run post configuration remediation & validation
ensure_post_config() {
  info "Post-config: ensuring critical artifacts present"
  [[ -f "$REPMGR_CONF_FILE" ]] || { warn "repmgr.conf missing; regenerating"; generate_repmgr_conf; }
  deploy_event_hooks || warn "Event hooks deploy failed"
  [[ -x "${REPMGR_EVENTS_DIR}/exec.sh" ]] || warn "Event hook script missing/executable issue"
  health_endpoint_setup || warn "Health endpoint ensure failed"
  systemctl is-active --quiet ${HEALTH_SERVICE} || systemctl restart ${HEALTH_SERVICE} || true
  systemctl is-enabled --quiet repmgrd || systemctl enable repmgrd || true
  systemctl is-active --quiet repmgrd || systemctl restart repmgrd || true
  if [[ "$ROLE" == "primary" ]]; then ensure_replication_slots || true; fi
  # Validate registration; register if needed
  if command -v repmgr >/dev/null 2>&1; then
    if ! sudo -u postgres repmgr -f "$REPMGR_CONF_FILE" cluster show >/dev/null 2>&1; then
      info "Cluster not fully registered; attempting node registration"
      register_node || warn "Registration attempt failed"
    fi
  fi
  # Quick health summary
  local summary="Artifacts:$( [[ -f $REPMGR_CONF_FILE ]] && echo ok || echo miss );HealthSvc:$(systemctl is-active ${HEALTH_SERVICE} 2>/dev/null || echo na);repmgrd:$(systemctl is-active repmgrd 2>/dev/null || echo na)"
  info "Post-config summary: $summary"
}

# -------- Main Bootstrap Logic --------
main() {
  info "--- BOOTSTRAP START (initial role hint=$ROLE) ---"
  info "Step 1: install base & PG packages"; install_packages
  info "Step 2: install / verify repmgr"; install_repmgr_if_needed
  info "Step 3: detect role"; auto_detect_role
  info "Step 4: load secrets"; if ! load_secrets; then warn "load_secrets non-fatal issues"; fi; info "Step 4 complete"
  info "Step 5: generate repmgr.conf"
  if generate_repmgr_conf; then [[ -f "$REPMGR_CONF_FILE" ]] || die "repmgr.conf generation success but file missing"; else die "Failed to generate repmgr.conf"; fi
  info "Step 6: role-specific init (role=$ROLE)"
  case "$ROLE" in
    primary) init_primary ;;
    standby) wait_for_primary "$REPMGR_PRIMARY_HOST" 5432 12 5; clone_standby; harden_pg_hba || true ;;
    witness) systemctl enable postgresql || true; systemctl start postgresql || true ;;
    *) die "Unknown ROLE=$ROLE" ;;
  esac
  info "Step 7: register node"; register_node || warn "Node registration returned non-zero"
  info "Step 8: ensure replication slots (primary only)"; ensure_replication_slots || warn "Replication slot ensure failed"
  info "Step 9: deploy event hooks"; deploy_event_hooks || warn "Event hooks deployment failed"
  info "Step 10: start repmgrd"; start_repmgrd || warn "repmgrd start failed"
  info "Step 11: health endpoint setup"; health_endpoint_setup || warn "Health endpoint setup failed"; [[ -x "$HEALTH_BIN" ]] && info "Health script present" || warn "Health script missing"
  info "Step 12: finalize"; touch "$SENTINEL_BOOTSTRAP"
  ensure_post_config
  info "--- BOOTSTRAP COMPLETE (role=$ROLE) ---"
}

# Invoke main if sentinel absent
if [[ ! -f $SENTINEL_BOOTSTRAP ]]; then
  main || die "Bootstrap failed"
else
  info "Bootstrap already completed (sentinel present); running post-config checks"
  ensure_post_config || warn "Post-config remediation encountered issues"
fi