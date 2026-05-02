#!/bin/bash
# High Availability PostgreSQL bootstrap for GCE VMs using pg_auto_failover
# - Ubuntu 24.04 LTS minimal
# - PostgreSQL 17 (PGDG)
# - pg_auto_failover (CitusData packages)
# - TLS from Secret Manager (CA/cert/key)
# - SCRAM-SHA-256 auth
# - Idempotent: safe to re-run

set -euo pipefail

LOG="/var/log/ha-postgresql-setup.log"

ts() { date --rfc-3339=seconds; }
NC='\033[0m'; RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'
_log() {
  local lvl="$1"; shift; local color="$NC"
  case "$lvl" in
    INFO) color="$GRN";; WARN) color="$YEL";; ERROR) color="$RED";; DEBUG) color="$BLU";; *) color="$NC";;
  esac
  echo -e "[$(ts)] [$lvl] $*" | sed "s|^|${color}|;s|$|${NC}|" | tee -a "$LOG"
}
log() { _log "${1:-INFO}" "${*:2}"; }
info(){ _log INFO "$*"; }
warn(){ _log WARN "$*"; }
error(){ _log ERROR "$*"; }
debug(){ _log DEBUG "$*"; }
die(){ _log ERROR "$*"; exit 1; }
retry() { # retry <n> <delay> <cmd...>
  local -i n=$1; shift; local -i delay=$1; shift; local i=0
  until "$@"; do i=$((i+1)); if (( i >= n )); then return 1; fi; sleep "$delay"; done
}

require_root() { if [[ $(id -u) -ne 0 ]]; then echo "Must run as root"; exit 1; fi; }

metadata() { curl -fsH "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/$1"; }
meta_attr() { metadata "instance/attributes/$1" 2>/dev/null || true; }

detect_env() {
  HOSTNAME_FQDN=$(hostname)
  ORG_CODE=${HOSTNAME_FQDN%%-*}
  ENV_CODE=$(echo "$HOSTNAME_FQDN" | awk -F- '{print $2}')
  ROLE=$(meta_attr role | tr 'A-Z' 'a-z' || true)
  ROLE=${ROLE:-unknown}
  CANDIDATE_PRIORITY=$(meta_attr candidate_priority || echo "")
  REPLICATION_QUORUM=$(meta_attr replication_quorum || echo "")
  CLUSTER_ID=$(meta_attr pg_cluster_id || echo "prod-ha-cluster-01")
  ZONE=$(basename "$(metadata instance/zone)")
  PROJECT=$(metadata project/project-id)
  INTERNAL_IP=$(metadata instance/network-interfaces/0/ip)
  log "[INFO]" "env: ORG=$ORG_CODE ENV=$ENV_CODE ROLE=$ROLE ZONE=$ZONE PROJECT=$PROJECT IP=$INTERNAL_IP CLUSTER=$CLUSTER_ID"
}

add_apt_repos() {
  . /etc/os-release
  local codename=${UBUNTU_CODENAME:-noble}
  install -d /etc/apt/keyrings
  # PGDG
  retry 5 2 curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor >/etc/apt/keyrings/postgresql.gpg
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" >/etc/apt/sources.list.d/pgdg.list
  # Citus (pg_auto_failover)
  retry 5 2 curl -fsSL https://packagecloud.io/citusdata/community/gpgkey | gpg --dearmor >/etc/apt/keyrings/citusdata.gpg
  echo "deb [signed-by=/etc/apt/keyrings/citusdata.gpg] https://packages.citusdata.com/community/ubuntu ${codename} main" >/etc/apt/sources.list.d/citusdata.list
  apt-get update -y
}

install_packages() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    jq lsb-release ca-certificates gnupg curl \
    postgresql-17 postgresql-client-17 \
  pg-auto-failover pg-auto-failover-cli \\
  chrony coreutils ufw apparmor apparmor-utils auditd openssh-server openssl
}

setup_time_sync() {
  systemctl enable --now chrony || true
}

ensure_fs() {
  local dev="$1" mountpoint="$2" fstype="ext4" opts="defaults,noatime,nodiratime,discard"
  install -d -m 0755 "$mountpoint"
  if ! blkid "$dev" >/dev/null 2>&1; then
    log "[INFO]" "Formatting $dev as $fstype"
    mkfs.$fstype -F "$dev"
  fi
  if ! mountpoint -q "$mountpoint"; then
    echo "$dev $mountpoint $fstype $opts 0 2" >>/etc/fstab
    retry 5 2 mount "$mountpoint" || (log "[ERROR]" "Failed mounting $mountpoint"; exit 1)
  fi
}

discover_google_disk() { # discover_google_disk <contains>
  local contains="$1"
  local path
  for path in /dev/disk/by-id/google-*; do
    if [[ "$(basename "$path")" == *"$contains"* ]]; then
      readlink -f "$path"; return 0
    fi
  done
  return 1
}

prepare_disks() {
  case "$ROLE" in
    monitor)
      local mnt=/pgmonitor
      local dev
      if dev=$(discover_google_disk "pg-monitor"); then
        ensure_fs "$dev" "$mnt"
      else
        log "[WARN]" "Monitor disk not found; using root disk"
        install -d -m 0700 "$mnt"
      fi
      ;;
    primary|standby)
      local data_dev wal_dev
      if data_dev=$(discover_google_disk "pg-data"); then
        ensure_fs "$data_dev" /pgdata
      else
        log "[WARN]" "Data disk not found; using root disk"
        install -d -m 0700 /pgdata
      fi
      if wal_dev=$(discover_google_disk "pg-wal"); then
        ensure_fs "$wal_dev" /pgwal
      else
        log "[WARN]" "WAL disk not found; using root disk"
        install -d -m 0700 /pgwal
      fi
      install -d -m 0700 /pgdata/17
      install -d -m 0700 /pgwal/17
      ;;
    *) log "[ERROR]" "Unknown role: $ROLE"; exit 1;;
  esac
}

get_sa_token() {
  metadata instance/service-accounts/default/token | jq -r .access_token
}

# -------- Secret Manager integration ---------
# Access latest version of a secret and output decoded payload
sm_access() { # sm_access <secret_id>
  local sid="$1"
  local token
  token=$(get_sa_token)
  local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${sid}/versions/latest:access"
  local b64
  b64=$(curl -fsSL -H "Authorization: Bearer $token" "$url" | jq -r '.payload.data' 2>>"$LOG" || true)
  if [[ -z "$b64" || "$b64" == "null" ]]; then
    log "[ERROR]" "Secret access failed for $sid"
    return 1
  fi
  echo "$b64" | base64 -d
}

derive_secret_ids() {
  # Matches Terraform local.secret_ids naming
  PG_SUPERUSER_SID="${ORG_CODE}-${ENV_CODE}-sec-pg-superuser-password-01"
  PG_REPL_SID="${ORG_CODE}-${ENV_CODE}-sec-pg-replication-password-01"
  PG_MONITOR_SID="${ORG_CODE}-${ENV_CODE}-sec-pg-monitor-password-01"
  PGBOUNCER_SID="${ORG_CODE}-${ENV_CODE}-sec-pgbouncer-auth-01"
  TLS_CA_SID="${ORG_CODE}-${ENV_CODE}-sec-tls-ca-01"
  TLS_CRT_SID="${ORG_CODE}-${ENV_CODE}-sec-tls-server-crt-01"
  TLS_KEY_SID="${ORG_CODE}-${ENV_CODE}-sec-tls-server-key-01"
  PGBACKREST_KEY_SID="${ORG_CODE}-${ENV_CODE}-sec-pgbackrest-gcs-key-01"
}

install_tls_from_sm() {
  install -d -m 0755 /etc/postgresql/ssl
  local ca crt key
  ca=$(sm_access "$TLS_CA_SID") || return 1
  crt=$(sm_access "$TLS_CRT_SID") || return 1
  key=$(sm_access "$TLS_KEY_SID") || return 1
  printf "%s" "$ca" >/etc/postgresql/ssl/ca.crt
  printf "%s" "$crt" >/etc/postgresql/ssl/server.crt
  printf "%s" "$key" >/etc/postgresql/ssl/server.key
  chown -R postgres:postgres /etc/postgresql/ssl
  chmod 644 /etc/postgresql/ssl/ca.crt /etc/postgresql/ssl/server.crt
  chmod 600 /etc/postgresql/ssl/server.key
}

tls_available() {
  [[ -f /etc/postgresql/ssl/server.crt && -f /etc/postgresql/ssl/server.key && -f /etc/postgresql/ssl/ca.crt ]]
}

fetch_monitor_ip() {
  # Try metadata IP (if on monitor)
  if [[ "$ROLE" == "monitor" ]]; then echo "$INTERNAL_IP"; return; fi
  # Try attribute specifying a static IP (optional future use)
  local hint=$(meta_attr monitor_ip || echo "")
  if [[ -n "$hint" ]]; then echo "$hint"; return; fi
  # Discover by label across all zones using aggregated list in Compute API
  local token project zone
  token=$(get_sa_token) || true
  project="$PROJECT"; zone="$ZONE"
  local url="https://compute.googleapis.com/compute/v1/projects/${project}/aggregated/instances?filter=labels.role%3Dmonitor"
  local ip
  ip=$(curl -fsSL -H "Authorization: Bearer $token" "$url" | jq -r '..|.networkInterfaces? // empty | .[0].networkIP' 2>/dev/null | head -n1 || true)
  if [[ -z "$ip" || "$ip" == "null" ]]; then
    log "[ERROR]" "Failed to discover monitor IP"; return 1
  fi
  echo "$ip"
}

fetch_subnet_cidr() {
  # Discover this NIC's subnet CIDR using Compute API
  local sub_url token
  sub_url=$(metadata instance/network-interfaces/0/subnetwork)
  token=$(get_sa_token) || true
  curl -fsSL -H "Authorization: Bearer $token" "https://compute.googleapis.com/compute/v1/${sub_url#projects/}" | jq -r '.ipCidrRange'
}

configure_postgres_scram() {
  # Ensure SCRAM is default
  local conf="/etc/postgresql/17/main/postgresql.conf"
  if [[ ! -f "$conf" ]]; then
    install -d -m 0755 /etc/postgresql/17/main
    touch "$conf"
  fi
  sed -i -E "s|^[#[:space:]]*password_encryption[[:space:]]*=.*|password_encryption = scram-sha-256|" "$conf" || echo "password_encryption = scram-sha-256" >>"$conf"
}

replace_or_append_conf() { # replace_or_append_conf <conf> <key> <value>
  local conf="$1" key="$2" val="$3"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" "$conf"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$conf"
  else
    echo "${key} = ${val}" >>"$conf"
  fi
}

configure_postgres_tls_conf() {
  local conf="/etc/postgresql/17/main/postgresql.conf"
  # Enforce TLS settings; create conf if missing (initdb creates it).
  if [[ ! -f "$conf" ]]; then
    install -d -m 0755 /etc/postgresql/17/main
    touch "$conf"
  fi
  replace_or_append_conf "$conf" ssl on
  replace_or_append_conf "$conf" ssl_cert_file "'/etc/postgresql/ssl/server.crt'"
  replace_or_append_conf "$conf" ssl_key_file "'/etc/postgresql/ssl/server.key'"
  replace_or_append_conf "$conf" ssl_ca_file "'/etc/postgresql/ssl/ca.crt'"
}

configure_postgres_ha_tuning() {
  local conf="/etc/postgresql/17/main/postgresql.conf"
  [[ -f "$conf" ]] || return 0
  replace_or_append_conf "$conf" listen_addresses "'*'"
  replace_or_append_conf "$conf" port 5432
  # WAL / replication
  replace_or_append_conf "$conf" wal_level replica
  replace_or_append_conf "$conf" synchronous_commit remote_apply
  replace_or_append_conf "$conf" max_wal_senders 16
  replace_or_append_conf "$conf" max_replication_slots 16
  replace_or_append_conf "$conf" wal_keep_size "'2GB'"
  replace_or_append_conf "$conf" hot_standby on
  # Performance (conservative defaults; adjust later)
  replace_or_append_conf "$conf" shared_buffers "'8GB'"
  replace_or_append_conf "$conf" effective_cache_size "'24GB'"
  replace_or_append_conf "$conf" work_mem "'32MB'"
  replace_or_append_conf "$conf" maintenance_work_mem "'1GB'"
  replace_or_append_conf "$conf" wal_compression on
  replace_or_append_conf "$conf" checkpoint_timeout "'15min'"
  replace_or_append_conf "$conf" checkpoint_completion_target 0.9
  # Logging
  replace_or_append_conf "$conf" logging_collector on
  replace_or_append_conf "$conf" log_destination "'csvlog'"
  replace_or_append_conf "$conf" log_line_prefix "'%m [%p] %u@%d %r %a %e %c '"
  replace_or_append_conf "$conf" log_min_duration_statement 250
  replace_or_append_conf "$conf" log_checkpoint on
  replace_or_append_conf "$conf" log_connections on
  replace_or_append_conf "$conf" log_disconnections on
  # pg_stat_statements preload
  if grep -qE "^[#[:space:]]*shared_preload_libraries" "$conf"; then
    sed -i -E "s|^[#[:space:]]*shared_preload_libraries[[:space:]]*=.*|shared_preload_libraries = 'pg_stat_statements'|" "$conf"
  else
    echo "shared_preload_libraries = 'pg_stat_statements'" >>"$conf"
  fi
  replace_or_append_conf "$conf" pg_stat_statements.track all
}

configure_pgbackrest() {
  # Install and configure pgBackRest for GCS
  DEBIAN_FRONTEND=noninteractive apt-get install -y pgbackrest || true
  install -d -m 0750 /etc/pgbackrest
  install -d -m 0750 /var/lib/pgbackrest
  chown -R postgres:postgres /etc/pgbackrest /var/lib/pgbackrest
  local key_json
  key_json=$(sm_access "$PGBACKREST_KEY_SID" || echo "")
  if [[ -z "$key_json" ]]; then
    warn "pgBackRest key not available; skipping configuration"
    return 0
  fi
  printf "%s" "$key_json" >/etc/pgbackrest/gcs-key.json
  chown postgres:postgres /etc/pgbackrest/gcs-key.json
  chmod 600 /etc/pgbackrest/gcs-key.json

  # Fetch bucket name from Terraform output is not available on-VM; derive from naming convention
  local bucket
  bucket=$(echo "${ORG_CODE}-${ENV_CODE}-bkt-pgbackrest-01" | tr 'A-Z' 'a-z')

  cat >/etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-type=gcs
repo1-path=/pgbackrest
repo1-gcs-bucket=${bucket}
repo1-gcs-key=/etc/pgbackrest/gcs-key.json
process-max=4
compress-type=zst

[${CLUSTER_ID}]
pg1-path=/pgdata/17/main
EOF
  chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
  chmod 640 /etc/pgbackrest/pgbackrest.conf

  # Configure archiving
  local conf="/etc/postgresql/17/main/postgresql.conf"
  replace_or_append_conf "$conf" archive_mode on
  replace_or_append_conf "$conf" archive_command "'pgbackrest --stanza=${CLUSTER_ID} archive-push %p'"
}

configure_pg_hba() {
  local pgdata="/pgdata/17/main" hba="$pgdata/pg_hba.conf"
  [[ -d "$pgdata" ]] || return 0
  local cidr
  cidr=$(fetch_subnet_cidr || echo "192.168.24.0/22")
  # Preserve local line, ensure hostssl rules for clients, replication, monitor
  cat >"$hba" <<EOF
# Local
local   all             all                                     peer

# Localhost over TLS for agents/tools
hostssl all             all             127.0.0.1/32             scram-sha-256
hostssl all             all             ::1/128                  scram-sha-256

# Client SSL with SCRAM
hostssl all             all             $cidr                    scram-sha-256

# Replication SSL
hostssl replication     replicator      $cidr                    scram-sha-256

# Monitor SSL (if using monitor user to connect)
hostssl all             pgaf_monitor    $cidr                    scram-sha-256
EOF
  chown postgres:postgres "$hba"; chmod 640 "$hba"
}

# ---------- Observability: Ops Agent (metrics + logs) ----------
install_ops_agent() {
  if command -v google-cloud-ops-agent >/dev/null 2>&1; then
    info "Ops Agent already installed"
    return 0
  fi
  curl -sSfL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh | bash || warn "Ops Agent repo setup failed"
  DEBIAN_FRONTEND=noninteractive apt-get install -y google-cloud-ops-agent || warn "Ops Agent install failed"
}

configure_ops_agent() {
  # Configure Ops Agent for logs on all nodes; add PostgreSQL metrics only on data nodes
  install -d -m 0750 /etc/google-cloud-ops-agent
  local pw=""
  if [[ "$ROLE" == "primary" || "$ROLE" == "standby" ]]; then
    pw=$(sm_access "$PG_MONITOR_SID" || echo "")
    if [[ -z "$pw" ]]; then
      warn "Monitor user password not found; Ops Agent Postgres metrics may fail"
    fi
  # Escape double quotes for safe YAML
  pw=${pw//"/\\"}
  fi

  if [[ "$ROLE" == "monitor" ]]; then
    cat >/etc/google-cloud-ops-agent/config.yaml <<EOF
logging:
  receivers:
    pg_journald:
      type: journald
      include_units:
        - pgautofailover-monitor.service
    setup_log:
      type: files
      include_paths:
        - /var/log/ha-postgresql-setup.log
  service:
    pipelines:
      default:
        receivers: [pg_journald, setup_log]
metrics:
  service:
    pipelines:
      default: {}
EOF
  else
    cat >/etc/google-cloud-ops-agent/config.yaml <<EOF
logging:
  receivers:
    postgresql_csv:
      type: files
      include_paths:
        - /pgdata/17/main/log/*.csv
      record_log_file_path: true
    pg_journald:
      type: journald
      include_units:
        - postgresql@17-main.service
        - pgautofailover.service
    setup_log:
      type: files
      include_paths:
        - /var/log/ha-postgresql-setup.log
  service:
    pipelines:
      default:
        receivers: [postgresql_csv, pg_journald, setup_log]

metrics:
  receivers:
    postgresql:
      type: postgresql
      endpoint: localhost:5432
      database: postgres
      username: pgaf_monitor
      password: "$pw"
      ca_file: /etc/postgresql/ssl/ca.crt
  insecure: false
  insecure_skip_verify: true
      collection_interval: 60s
      collect_database_metrics: true
  service:
    pipelines:
      default:
        receivers: [postgresql]
EOF
  fi

  systemctl enable --now google-cloud-ops-agent || true
  systemctl restart google-cloud-ops-agent || true
}

# ---------- TLS Certificate Expiry Checker ----------
install_tls_expiry_checker() {
  cat >/usr/local/bin/check_tls_expiry.sh <<'EOS'
#!/bin/bash
set -euo pipefail
CRT="/etc/postgresql/ssl/server.crt"
THRESHOLD_DAYS="30"
LOGTAG="tls-expiry-check"
if [[ ! -f "$CRT" ]]; then
  logger -t "$LOGTAG" "Certificate not found at $CRT"
  exit 0
fi
enddate=$(openssl x509 -enddate -noout -in "$CRT" | cut -d= -f2)
end_ts=$(date -j -f "%b %d %T %Y %Z" "$enddate" +%s 2>/dev/null || date -d "$enddate" +%s)
now_ts=$(date +%s)
days_left=$(( (end_ts - now_ts) / 86400 ))
if (( days_left <= THRESHOLD_DAYS )); then
  logger -p user.warning -t "$LOGTAG" "TLS_CERT_EXPIRY_WARNING days_left=${days_left} threshold=${THRESHOLD_DAYS}"
fi
EOS
  chmod +x /usr/local/bin/check_tls_expiry.sh

  cat >/etc/systemd/system/tls-expiry-check.service <<'EOF'
[Unit]
Description=TLS certificate expiry check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check_tls_expiry.sh
EOF
  cat >/etc/systemd/system/tls-expiry-check.timer <<'EOF'
[Unit]
Description=Run TLS certificate expiry check daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now tls-expiry-check.timer || true
}

# ---------- OS Hardening (CIS-aligned minimal) ----------
configure_chrony() {
  # Point to GCE internal NTP (metadata.google.internal) when available
  if [[ -f /etc/chrony/chrony.conf ]]; then
    sed -i -E 's|^server .*||g' /etc/chrony/chrony.conf
    grep -q 'metadata.google.internal' /etc/chrony/chrony.conf || echo 'server metadata.google.internal iburst' >> /etc/chrony/chrony.conf
    grep -q '^makestep' /etc/chrony/chrony.conf || echo 'makestep 1.0 3' >> /etc/chrony/chrony.conf
  fi
  systemctl enable --now chrony || true
}

configure_ufw() {
  ufw --force reset || true
  ufw default deny incoming || true
  ufw default allow outgoing || true
  # Allow essential ports; network-level firewalls still apply
  ufw allow 22/tcp || true
  ufw allow 5432/tcp || true
  ufw allow 5431/tcp || true
  ufw allow 6432/tcp || true
  ufw --force enable || true
}

configure_apparmor() {
  systemctl enable --now apparmor || true
}

configure_auditd() {
  install -d -m 0755 /etc/audit/rules.d
  cat >/etc/audit/rules.d/postgresql.rules <<'EOF'
## Audit PostgreSQL binaries and configuration changes
-w /usr/lib/postgresql/ -p wa -k postgres_bin
-w /etc/postgresql/ -p wa -k postgres_conf
-w /var/lib/postgresql/ -p wa -k postgres_data
-w /usr/bin/pg_autoctl -p x -k pgaf
-w /etc/pgbouncer/ -p wa -k pgbouncer_conf
EOF
  systemctl enable --now auditd || true
  augenrules --load || true
}

harden_ssh() {
  local f=/etc/ssh/sshd_config
  sed -i -E "s|^[#[:space:]]*PasswordAuthentication.*|PasswordAuthentication no|" "$f" || true
  sed -i -E "s|^[#[:space:]]*PermitRootLogin.*|PermitRootLogin no|" "$f" || true
  sed -i -E "s|^[#[:space:]]*ChallengeResponseAuthentication.*|ChallengeResponseAuthentication no|" "$f" || true
  systemctl restart ssh || systemctl restart sshd || true
}

apply_sysctl() {
  local f=/etc/sysctl.d/99-hardening.conf
  cat >"$f" <<'EOF'
kernel.kptr_restrict=2
kernel.unprivileged_bpf_disabled=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "$f" || true
}

reinit_cluster_to_pgdata() {
  # Move default cluster to /pgdata if not already there
  local target=/pgdata/17/main
  if [[ -d "$target" ]]; then return 0; fi
  systemctl stop postgresql || true
  install -d -m 0700 "$target"
  sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D "$target" -k --data-checksums
  # Point service to custom data dir via systemd override
  install -d /etc/systemd/system/postgresql@17-main.service.d
  cat >/etc/systemd/system/postgresql@17-main.service.d/override.conf <<EOF
[Service]
Environment=PGDATA=$target
EOF
  systemctl daemon-reload
}

create_pgaf_systemd() {
  local pgdata="$1" svc_name="$2"
  local unit
  unit=$(pg_autoctl -q show systemd --pgdata "$pgdata" || true)
  if [[ -z "$unit" ]]; then
    log "[WARN]" "pg_autoctl did not return a unit for $pgdata"
    return 0
  fi
  local path="/etc/systemd/system/${svc_name}.service"
  echo "$unit" >"$path"
  systemctl daemon-reload
  systemctl enable "$svc_name"
  systemctl restart "$svc_name"
}

setup_monitor() {
  local pgdata=/pgmonitor
  if [[ ! -f "$pgdata/PG_VERSION" ]]; then
    log "[INFO]" "Creating pg_auto_failover monitor"
    if tls_available; then
      pg_autoctl create monitor \
        --pgdata "$pgdata" \
        --hostname "$INTERNAL_IP" \
        --monitor-port 5431 \
        --auth scram-sha-256 \
        --ssl-ca-file /etc/postgresql/ssl/ca.crt \
        --ssl-crt-file /etc/postgresql/ssl/server.crt \
        --ssl-key-file /etc/postgresql/ssl/server.key \
        --nodename "$INTERNAL_IP" \
        --formation default
    else
      log "[WARN]" "TLS secrets not available; using self-signed for monitor"
      pg_autoctl create monitor \
        --pgdata "$pgdata" \
        --hostname "$INTERNAL_IP" \
        --monitor-port 5431 \
        --auth scram-sha-256 \
        --ssl-self-signed \
        --nodename "$INTERNAL_IP" \
        --formation default
    fi
  else
    log "[INFO]" "Monitor data directory already initialized"
  fi
  create_pgaf_systemd "$pgdata" "pgautofailover-monitor"
}

setup_keeper() {
  local pgdata=/pgdata/17/main
  # Ensure cluster exists in /pgdata
  if [[ ! -f "$pgdata/PG_VERSION" ]]; then
    reinit_cluster_to_pgdata
  fi
  configure_postgres_scram
  if tls_available; then
    configure_postgres_tls_conf
  else
    log "[WARN]" "TLS secrets not available; skipping PostgreSQL TLS config for now"
  fi
  local monitor_ip
  monitor_ip=$(fetch_monitor_ip)
  local quorum_flag
  quorum_flag=$([[ "$REPLICATION_QUORUM" =~ ^(true|1|yes)$ ]] && echo "--replication-quorum" || echo "--no-replication-quorum")
  local prio_flag=""
  [[ -n "$CANDIDATE_PRIORITY" ]] && prio_flag="--candidate-priority $CANDIDATE_PRIORITY"

  if [[ ! -f "$pgdata/pg_autoctl/state.gz" && ! -f "$pgdata/pg_autoctl.cfg" ]]; then
    log "[INFO]" "Creating pg_auto_failover keeper for Postgres"
    if tls_available; then
      pg_autoctl create postgres \
        --pgdata "$pgdata" \
        --monitor "postgres://autoctl_node@${monitor_ip}:5431/pg_auto_failover" \
        --ssl-ca-file /etc/postgresql/ssl/ca.crt \
        --ssl-crt-file /etc/postgresql/ssl/server.crt \
        --ssl-key-file /etc/postgresql/ssl/server.key \
        --auth scram-sha-256 \
        --nodename "$INTERNAL_IP" \
        --dbname postgres \
        $quorum_flag \
        $prio_flag
    else
      log "[WARN]" "TLS secrets not available; using self-signed for keeper"
      pg_autoctl create postgres \
        --pgdata "$pgdata" \
        --monitor "postgres://autoctl_node@${monitor_ip}:5431/pg_auto_failover" \
        --ssl-self-signed \
        --auth scram-sha-256 \
        --nodename "$INTERNAL_IP" \
        --dbname postgres \
        $quorum_flag \
        $prio_flag
    fi
  else
    log "[INFO]" "Keeper already initialized"
  fi
  create_pgaf_systemd "$pgdata" "pgautofailover"
}

maybe_configure_db_users() {
  # Only on data nodes and only if primary (not in recovery)
  [[ "$ROLE" == "primary" || "$ROLE" == "standby" ]] || return 0
  # Wait until server responds
  local psql_cmd="sudo -u postgres psql -Atqc"
  retry 20 3 bash -lc "$psql_cmd 'SELECT 1' >/dev/null"
  local in_recovery
  in_recovery=$(sudo -u postgres psql -Atqc "select pg_is_in_recovery()")
  if [[ "$in_recovery" == "f" ]]; then
    log "[INFO]" "Configuring database users on primary"
  local supw replpw monpw pgbpw
    supw=$(sm_access "$PG_SUPERUSER_SID") || { log "[WARN]" "Missing superuser secret, skipping"; return 0; }
    replpw=$(sm_access "$PG_REPL_SID") || true
    monpw=$(sm_access "$PG_MONITOR_SID") || true
  pgbpw=$(sm_access "$PGBOUNCER_SID") || true
    sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOSQL
DO $$
BEGIN
  PERFORM 1;
END $$;
EOSQL
    # Set postgres password
    sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOSQL
ALTER ROLE postgres WITH PASSWORD '$supw';
EOSQL
    # Create/alter replication user
    if [[ -n "$replpw" ]]; then
      sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOSQL
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='replicator') THEN
    CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD '$replpw';
  ELSE
    ALTER ROLE replicator WITH LOGIN REPLICATION PASSWORD '$replpw';
  END IF;
END $$;
EOSQL
    fi
    # Monitoring user (no superuser)
    if [[ -n "$monpw" ]]; then
      sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOSQL
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='pgaf_monitor') THEN
    CREATE ROLE pgaf_monitor WITH LOGIN PASSWORD '$monpw';
  ELSE
    ALTER ROLE pgaf_monitor WITH LOGIN PASSWORD '$monpw';
  END IF;
END $$;
GRANT pg_monitor TO pgaf_monitor;
EOSQL
    fi
    # PgBouncer auth user and auth function (SECURITY DEFINER)
    if [[ -n "$pgbpw" ]]; then
      sudo -u postgres psql -v ON_ERROR_STOP=1 <<'EOSQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='pgbouncer') THEN
    CREATE ROLE pgbouncer WITH LOGIN PASSWORD 'REPLACE_PGBOUNCER_PW';
  ELSE
    ALTER ROLE pgbouncer WITH LOGIN PASSWORD 'REPLACE_PGBOUNCER_PW';
  END IF;
END $$;
EOSQL
      sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION postgres;"
      sudo -u postgres psql -v ON_ERROR_STOP=1 <<'EOSQL'
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(IN uname name, OUT username text, OUT passwd text)
RETURNS RECORD
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT r.rolname::text, r.rolpassword
  FROM pg_authid r
  WHERE r.rolname = uname;
$$;
REVOKE ALL ON FUNCTION pgbouncer.get_auth(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(name) TO pgbouncer;
EOSQL
      # Replace placeholder secret safely
      sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE pgbouncer WITH PASSWORD '$(printf "%s" "$pgbpw" | sed -e "s/'/''/g")';"
    fi
  else
    log "[INFO]" "Standby node detected; skipping user management"
  fi
}

install_backup_schedules() {
  [[ "$ROLE" == "primary" || "$ROLE" == "standby" ]] || return 0
  # Run backups on standby if in recovery, otherwise primary (fallback)
  local in_recovery
  in_recovery=$(sudo -u postgres psql -Atqc "select pg_is_in_recovery()" || echo "t")
  if [[ "$in_recovery" != "t" ]]; then
    # If primary, still install but timers will run here only if needed
    :
  fi
  cat >/usr/local/bin/run_pgbackrest_full.sh <<'EOS'
#!/bin/bash
set -euo pipefail
sudo -u postgres pgbackrest --stanza="${CLUSTER_ID}" --type=full backup
EOS
  cat >/usr/local/bin/run_pgbackrest_diff.sh <<'EOS'
#!/bin/bash
set -euo pipefail
sudo -u postgres pgbackrest --stanza="${CLUSTER_ID}" --type=diff backup
EOS
  cat >/usr/local/bin/validate_restore.sh <<'EOS'
#!/bin/bash
set -euo pipefail
# Dry-run restore to check integrity
sudo -u postgres pgbackrest --stanza="${CLUSTER_ID}" check || exit 1
EOS
  chmod +x /usr/local/bin/run_pgbackrest_full.sh /usr/local/bin/run_pgbackrest_diff.sh /usr/local/bin/validate_restore.sh

  cat >/etc/systemd/system/pgbackrest-full.service <<'EOF'
[Unit]
Description=pgBackRest full backup

[Service]
Type=oneshot
Environment=CLUSTER_ID=%i
ExecStart=/usr/local/bin/run_pgbackrest_full.sh
EOF
  cat >/etc/systemd/system/pgbackrest-full.timer <<'EOF'
[Unit]
Description=Daily full backup

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat >/etc/systemd/system/pgbackrest-diff.service <<'EOF'
[Unit]
Description=pgBackRest differential backup

[Service]
Type=oneshot
Environment=CLUSTER_ID=%i
ExecStart=/usr/local/bin/run_pgbackrest_diff.sh
EOF
  cat >/etc/systemd/system/pgbackrest-diff.timer <<'EOF'
[Unit]
Description=Hourly differential backup

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat >/etc/systemd/system/pgbackrest-validate.timer <<'EOF'
[Unit]
Description=Periodic backup validation

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  cat >/etc/systemd/system/pgbackrest-validate.service <<'EOF'
[Unit]
Description=Validate pgBackRest repo integrity

[Service]
Type=oneshot
Environment=CLUSTER_ID=%i
ExecStart=/usr/local/bin/validate_restore.sh
EOF

  systemctl daemon-reload
  systemctl enable --now pgbackrest-full.timer pgbackrest-diff.timer pgbackrest-validate.timer || true
}

main() {
  require_root
  log "[INFO]" "HA PostgreSQL setup starting"
  detect_env
  add_apt_repos
  install_packages
  setup_time_sync
  # OS hardening (Module 4)
  configure_chrony || warn "chrony configuration failed"
  configure_ufw || warn "ufw configuration failed"
  configure_apparmor || warn "apparmor configuration failed"
  configure_auditd || warn "auditd configuration failed"
  harden_ssh || warn "ssh hardening failed"
  apply_sysctl || warn "sysctl hardening failed"
  derive_secret_ids
  install_tls_from_sm || log "[WARN]" "TLS install from Secret Manager failed; proceeding without TLS may break connectivity"
  prepare_disks

  case "$ROLE" in
    monitor) setup_monitor ;;
    primary|standby) setup_keeper ;;
    *) log "[ERROR]" "Unsupported role: $ROLE"; exit 1 ;;
  esac

  # Apply DB configs after services are up
  if [[ "$ROLE" == "primary" || "$ROLE" == "standby" ]]; then
    configure_pg_hba || warn "pg_hba configuration failed"
    configure_postgres_ha_tuning || warn "HA tuning failed"
  configure_pgbackrest || warn "pgBackRest configuration failed"
    systemctl reload postgresql || true
    maybe_configure_db_users || warn "User configuration step encountered issues"
    # Enable pg_stat_statements extension on primary
    if sudo -u postgres psql -Atqc "select pg_is_in_recovery()" | grep -q '^f$'; then
      sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" || warn "Failed to enable pg_stat_statements"
    fi
  install_backup_schedules || warn "Backup schedules failed"
  fi

  # Observability
  install_ops_agent || warn "Ops Agent installation failed"
  configure_ops_agent || warn "Ops Agent configuration failed"
  install_tls_expiry_checker || warn "TLS expiry checker setup failed"
  log "[INFO]" "HA PostgreSQL setup complete"
}

main "$@"
