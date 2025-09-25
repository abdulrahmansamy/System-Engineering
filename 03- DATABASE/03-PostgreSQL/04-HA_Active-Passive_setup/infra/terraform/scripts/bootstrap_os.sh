#!/usr/bin/env bash
# pg-ha OS bootstrap and hardening
set -Eeuo pipefail

LOG_DIR="/var/log/pg-ha"
LOG_FILE="$LOG_DIR/bootstrap.log"
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

# Colors
CLR_RESET="\033[0m"; CLR_INFO="\033[1;34m"; CLR_WARN="\033[1;33m"; CLR_ERR="\033[1;31m"; CLR_OK="\033[1;32m"
ts() { date -Is; }
log() { level="$1"; shift; color="$2"; echo -e "[$(ts)] ${color}${level}${CLR_RESET} $*"; }
info() { log INFO "$CLR_INFO" "$@"; }
warn() { log WARN "$CLR_WARN" "$@"; }
error(){ log ERROR "$CLR_ERR" "$@"; }
ok(){ log OK "$CLR_OK" "$@"; }

trap 'rc=$?; [ $rc -eq 0 ] || error "Bootstrap failed with exit code $rc"; exit $rc' EXIT

info "Starting OS bootstrap and hardening"

# Ensure root
if [ "$(id -u)" -ne 0 ]; then error "Must run as root"; exit 1; fi

# Apt refresh and base packages
info "Updating apt cache and upgrading base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -yq

info "Installing base packages"
apt-get install -yq \
  ufw fail2ban unattended-upgrades apt-listchanges \
  ca-certificates curl jq unzip gnupg rsyslog \
  auditd audispd-plugins apparmor apparmor-utils \
  systemd-timesyncd smartmontools net-tools

# Journald persistent storage
info "Configuring journald persistent storage"
sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf || true
sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=1G/' /etc/systemd/journald.conf || true
systemctl restart systemd-journald

# Unattended upgrades
info "Enabling unattended upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
sed -i 's#^//\s*"${distro_id}:${distro_codename}-security";#        "${distro_id}:${distro_codename}-security";#' /etc/apt/apt.conf.d/50unattended-upgrades || true
systemctl enable unattended-upgrades --now

# SSH hardening (conservative)
info "Hardening SSHd"
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/pg-ha.conf <<'EOF'
# pg-ha baseline
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
UsePAM yes
EOF
systemctl reload ssh || systemctl reload sshd || true

# UFW rules
info "Configuring UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
# Internal DB and health ports from VPC CIDR
VPC_CIDR="${VPC_CIDR:-$(detect_vpc_cidr)}"
ufw allow from "$VPC_CIDR" to any port 5432 proto tcp
ufw allow from "$VPC_CIDR" to any port 8008 proto tcp
ufw --force enable
ufw status verbose | sed 's/^/[UFW] /'

# Sysctl hardening and PG-friendly tuning
info "Applying sysctl hardening"
cat >/etc/sysctl.d/99-pg-ha.conf <<'EOF'
# Security hardening
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1

# Network/IO
net.core.somaxconn = 1024
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300

# FS and VM
fs.file-max = 2097152
vm.swappiness = 1
vm.overcommit_memory = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
EOF
sysctl --system || true

# NTP with Google
info "Configuring time synchronization (systemd-timesyncd)"
sed -i 's/^#\?NTP=.*/NTP=time.google.com time2.google.com time3.google.com time4.google.com/' /etc/systemd/timesyncd.conf || true
systemctl enable systemd-timesyncd --now

# Timezone configuration
set_timezone() {
  local meta_tz
  meta_tz=$(curl -sf -H "Metadata-Flavor: Google" \
    http://metadata/computeMetadata/v1/instance/attributes/timezone || true)
  local tz="${TIMEZONE:-$meta_tz}"
  tz=${tz:-Etc/UTC}
  if [ -e "/usr/share/zoneinfo/$tz" ]; then
    info "Setting timezone to $tz"
    timedatectl set-timezone "$tz" || ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    systemctl restart systemd-timesyncd || true
  else
    warn "Timezone '$tz' not found under /usr/share/zoneinfo; keeping current timezone"
  fi
}
set_timezone

# auditd baseline
info "Configuring auditd"
cat >/etc/audit/rules.d/pg-ha.rules <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /var/lib/postgresql -p wa -k pgdata
-w /etc/postgresql -p wa -k pgcfg
-e 2
EOF
augenrules --load || true
systemctl enable auditd --now

# fail2ban minimal config
info "Configuring fail2ban"
cat >/etc/fail2ban/jail.d/pg-ha-sshd.conf <<'EOF'
[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5
EOF
systemctl enable fail2ban --now

# AppArmor ensure enabled
info "Ensuring AppArmor is enabled"
systemctl enable apparmor --now || true

# SMART monitoring
info "Enabling smartmontools"
systemctl enable smartd --now || true

# TLS install via Secret Manager
info "Installing TLS materials from Secret Manager"
PROJECT_ID=$(curl -sH "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/project/project-id)
TOKEN=$(curl -sH "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)
SM() { local name="$1"; curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${name}/versions/latest:access" | jq -r .payload.data | base64 -d; }

NODENAME=$(hostname -s)
# Determine node role from instance metadata (fallback to hostname)
NODE_ROLE=$(curl -sf -H "Metadata-Flavor: Google" \
  http://metadata/computeMetadata/v1/instance/attributes/noderole || true)
# Normalize to pg-* variants
NODE_ROLE=$(echo "${NODE_ROLE:-}" | tr 'A-Z' 'a-z')
case "$NODE_ROLE" in
  primary|pgprimary|pg-primary)      NODE_ROLE="pg-primary" ;;
  secondary|pgsecondary|pg-secondary) NODE_ROLE="pg-secondary" ;;
  monitor|pgmonitor|pg-monitor)      NODE_ROLE="pg-monitor" ;;
  "") ;; # leave empty for fallback
  *)  ;;  # unknown value; will fallback if empty below
esac
if [ -z "$NODE_ROLE" ]; then
  case "$NODENAME" in
    pg-primary)   NODE_ROLE="pg-primary" ;;
    pg-secondary) NODE_ROLE="pg-secondary" ;;
    pg-monitor)   NODE_ROLE="pg-monitor" ;;
    *)            NODE_ROLE="other" ;;
  esac
fi
info "Detected node role: $NODE_ROLE  for the instance : $NODENAME"

CERT_DIR=/etc/ssl/pg
ensure_tls_permissions() {
  local dir="${1:-/etc/ssl/pg}"
  if id -u postgres >/dev/null 2>&1; then
    chown -R postgres:postgres "$dir"
    rm -f /opt/pg-ha/.tls_needs_chown 2>/dev/null || true
  else
    mkdir -p /opt/pg-ha
    touch /opt/pg-ha/.tls_needs_chown
  fi
}
install_tls() {
  mkdir -p "$CERT_DIR" && chmod 755 "$CERT_DIR"
  local ca_secret="tls-ca-cert"
  local key_secret="tls-${NODENAME}-key"
  local crt_secret="tls-${NODENAME}-cert"
  info "Fetching secrets: $ca_secret, $key_secret, $crt_secret"
  SM "$ca_secret" >"$CERT_DIR/ca.crt"
  SM "$key_secret" >"$CERT_DIR/server.key"
  SM "$crt_secret" >"$CERT_DIR/server.crt"
  chmod 600 "$CERT_DIR/server.key" "$CERT_DIR/server.crt"
  chmod 644 "$CERT_DIR/ca.crt"
  ensure_tls_permissions "$CERT_DIR"
  ok "TLS materials installed at $CERT_DIR"
}

# PostgreSQL installation and configuration for data nodes
provision_postgres() {
  info "Starting PostgreSQL provisioning"

  if [ -f /opt/pg-ha/.pg_provisioned ]; then
    ok "PostgreSQL already provisioned; skipping"
    return 0
  fi

  apt-get update -y
  apt-get install -yq xfsprogs lsb-release gnupg wget

  # Prepare disks
  DATA_DEV="/dev/disk/by-id/google-pgdata"
  WAL_DEV="/dev/disk/by-id/google-pgwal"
  DATA_MNT="/var/lib/postgresql"
  WAL_MNT="/var/lib/postgresql/wal"

  mkdir -p "$DATA_MNT" "$WAL_MNT"

  fs_ok() { lsblk -no FSTYPE "$1" | grep -qE 'xfs|ext4'; }
  if [ -b "$DATA_DEV" ] && ! fs_ok "$DATA_DEV"; then
    info "Formatting data disk $DATA_DEV as XFS"
    mkfs.xfs -f "$DATA_DEV"
  fi
  if [ -b "$WAL_DEV" ] && ! fs_ok "$WAL_DEV"; then
    info "Formatting WAL disk $WAL_DEV as XFS"
    mkfs.xfs -f "$WAL_DEV"
  fi

  ensure_fstab_entry() {
    local dev="$1" mountpoint="$2" fstype="$3" opts="$4"
    local uuid
    uuid=$(blkid -s UUID -o value "$dev" || true)
    if [ -n "$uuid" ]; then
      if ! grep -q "UUID=$uuid" /etc/fstab; then
        echo "UUID=$uuid $mountpoint $fstype $opts 0 2" >> /etc/fstab
        info "Added fstab entry for $mountpoint"
      fi
    fi
  }

  if [ -b "$DATA_DEV" ]; then
    ensure_fstab_entry "$DATA_DEV" "$DATA_MNT" xfs "noatime,nodiratime,discard"
    mkdir -p "$DATA_MNT"
    mount -a || true
  else
    warn "Data disk $DATA_DEV not found"
  fi

  if [ -b "$WAL_DEV" ]; then
    ensure_fstab_entry "$WAL_DEV" "$WAL_MNT" xfs "noatime,nosuid,noexec,discard"
    mkdir -p "$WAL_MNT"
    mount -a || true
  else
    warn "WAL disk $WAL_DEV not found"
  fi

  chown -R postgres:postgres "$DATA_MNT" "$WAL_MNT" || true
  chmod 700 "$DATA_MNT" || true

  # Install PostgreSQL 17 (PGDG)
  if ! command -v psql >/dev/null 2>&1; then
    info "Installing PostgreSQL 17"
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" >/etc/apt/sources.list.d/pgdg.list
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    apt-get update -y
    apt-get install -yq postgresql-17 postgresql-client-17 postgresql-common
  fi

  # Recreate cluster to use mounted data dir
  if [ -d "/etc/postgresql/17/main" ]; then
    systemctl stop postgresql || true
    if [ -d "/var/lib/postgresql/17/main" ] && [ "$(ls -A /var/lib/postgresql/17/main 2>/dev/null | wc -l)" -gt 0 ]; then
      info "Cluster seems initialized; keeping existing data"
    else
      info "Creating cluster in $DATA_MNT/17/main"
      pg_dropcluster --stop 17 main || true
      pg_createcluster 17 main --datadir "$DATA_MNT/17/main"
    fi
  else
    info "Creating cluster in $DATA_MNT/17/main (fresh)"
    pg_createcluster 17 main --datadir "$DATA_MNT/17/main"
  fi

  # Ensure TLS files exist
  CERT_DIR=/etc/ssl/pg
  if [ ! -s "$CERT_DIR/server.crt" ] || [ ! -s "$CERT_DIR/server.key" ]; then
    warn "TLS materials missing, attempting re-install"
    install_tls || true
  fi
  # Ensure correct ownership now that postgres user exists
  ensure_tls_permissions "$CERT_DIR"

  # Configure postgresql.conf
  PGDATA="$DATA_MNT/17/main"
  CONF="$PGDATA/postgresql.conf"
  HBA="$PGDATA/pg_hba.conf"

  sed -i "s/^#\?listen_addresses.*/listen_addresses = '*' /" "$CONF" || true
  sed -i "s#^#\?ssl = .*#ssl = on#" "$CONF" || true
  grep -q "ssl = on" "$CONF" || echo "ssl = on" >>"$CONF"
  echo "ssl_cert_file = '$CERT_DIR/server.crt'" >>"$CONF"
  echo "ssl_key_file  = '$CERT_DIR/server.key'" >>"$CONF"
  echo "ssl_ca_file   = '$CERT_DIR/ca.crt'" >>"$CONF"
  echo "password_encryption = 'scram-sha-256'" >>"$CONF"
  echo "wal_level = replica" >>"$CONF"
  echo "hot_standby = on" >>"$CONF"
  echo "max_wal_senders = 20" >>"$CONF"
  echo "max_replication_slots = 20" >>"$CONF"
  echo "wal_compression = on" >>"$CONF"
  echo "synchronous_commit = remote_apply" >>"$CONF"
  echo "archive_mode = on" >>"$CONF"
  echo "archive_command = 'pgbackrest --stanza=main archive-push %p'" >>"$CONF"

  # pg_hba rules (VPC CIDR)
  VPC_CIDR="${VPC_CIDR:-$(detect_vpc_cidr)}"
  cat >>"$HBA" <<EOF
hostssl all             all           $VPC_CIDR    scram-sha-256 clientcert=verify-full
hostssl replication     all           $VPC_CIDR    scram-sha-256 clientcert=verify-full
EOF

  # Ensure WAL on dedicated disk via bind mount
  if mountpoint -q "$WAL_MNT"; then
    systemctl stop postgresql || true
    rsync -a --delete "$PGDATA/pg_wal/" "$WAL_MNT/" || true
    mkdir -p "$PGDATA/pg_wal"
    mountpoint -q "$PGDATA/pg_wal" || {
      echo "$WAL_MNT $PGDATA/pg_wal none bind 0 0" >> /etc/fstab
      mount "$PGDATA/pg_wal" || mount -a || true
    }
  else
    warn "WAL mount $WAL_MNT not mounted; continuing without bind mount"
  fi

  # Start Postgres and set credentials
  systemctl enable postgresql --now
  su - postgres -c "pg_isready" || sleep 3

  # Secrets: passwords
  SUPER_PW=$(SM "pg-superuser-password" || true)
  REPL_PW=$(SM "pg-repl-password" || true)
  PGBOUNCER_PW=$(SM "pgbouncer-auth-password" || true)
  MON_PW=$(SM "pg-monitoring-password" || true)
  if [ -n "$SUPER_PW" ]; then
    su - postgres -c "psql -tAc \"ALTER USER postgres WITH PASSWORD '${SUPER_PW}';\"" || warn "Failed to set postgres password"
  fi
  if [ -n "$REPL_PW" ]; then
    su - postgres -c "psql -tAc \"DO $$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='repl') THEN CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD '${REPL_PW}'; END IF; END$$;\"" || warn "Failed to ensure repl role"
  fi
  if [ -n "$PGBOUNCER_PW" ]; then
    su - postgres -c "psql -tAc \"DO $$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='pgbouncer') THEN CREATE ROLE pgbouncer WITH LOGIN SUPERUSER PASSWORD '${PGBOUNCER_PW}'; ELSE ALTER ROLE pgbouncer WITH PASSWORD '${PGBOUNCER_PW}'; END IF; END$$;\"" || warn "Failed to ensure pgbouncer role"
  fi
  if [ -n "$MON_PW" ]; then
    su - postgres -c "psql -tAc \"DO $$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='monitoring') THEN CREATE ROLE monitoring WITH LOGIN PASSWORD '${MON_PW}'; END IF; GRANT pg_monitor TO monitoring;\"" || warn "Failed to ensure monitoring role"
  fi

  touch /opt/pg-ha/.pg_provisioned
  ok "PostgreSQL provisioning completed"
}

# PgBouncer and Health Agent provisioning
provision_pgbouncer() {
  info "Configuring PgBouncer and health agent"
  if [ -f /opt/pg-ha/.pgb_provisioned ]; then
    ok "PgBouncer already configured; skipping"
    return 0
  fi

  apt-get update -y
  apt-get install -yq pgbouncer socat

  install_tls || true

  # UFW allow PgBouncer from VPC
  VPC_CIDR="${VPC_CIDR:-$(detect_vpc_cidr)}"
  ufw allow from "$VPC_CIDR" to any port 6432 proto tcp || true

  mkdir -p /etc/pgbouncer
  cat >/etc/pgbouncer/pgbouncer.ini <<'INI'
[databases]
* = host=127.0.0.1 port=5432 pool_mode=transaction

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_user = pgbouncer
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename = $1
server_reset_query = DISCARD ALL
max_client_conn = 1000
default_pool_size = 100
min_pool_size = 10
ignore_startup_parameters = extra_float_digits
pidfile = /run/pgbouncer/pgbouncer.pid
admin_users = postgres, pgbouncer
server_tls_sslmode = verify-full
server_tls_ca_file = /etc/ssl/pg/ca.crt
server_tls_cert_file = /etc/ssl/pg/server.crt
server_tls_key_file = /etc/ssl/pg/server.key
client_tls_sslmode = require
client_tls_ca_file = /etc/ssl/pg/ca.crt
client_tls_cert_file = /etc/ssl/pg/server.crt
client_tls_key_file = /etc/ssl/pg/server.key
logfile = /var/log/pg-ha/pgbouncer.log
INI
  chown -R pgbouncer:pgbouncer /etc/pgbouncer
  chmod 640 /etc/pgbouncer/pgbouncer.ini || true

  systemctl enable --now pgbouncer

  # Health agent: expose port 8008 only on primary
  cat >/usr/local/bin/pgha_is_primary.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PGDATA="/var/lib/postgresql/17/main"
NODENAME=$(hostname -s)
# Check if local node line shows primary
if su - postgres -c "pg_autoctl show state --pgdata '$PGDATA'" | awk -F'|' -v n="$NODENAME" 'index($0,n) && /primary/ { found=1 } END { exit(found?0:1) }'; then
  exit 0
else
  exit 1
fi
SH
  chmod +x /usr/local/bin/pgha_is_primary.sh

  cat >/usr/local/bin/pgha_health.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG=/var/log/pg-ha/health.log
PORT=8008
echo "[$(date -Is)] starting health agent on port $PORT" >> "$LOG"
while true; do
  if /usr/local/bin/pgha_is_primary.sh; then
    if ! pgrep -f "socat TCP-LISTEN:$PORT" >/dev/null; then
      echo "[$(date -Is)] PRIMARY: starting listener" >> "$LOG"
      nohup socat TCP-LISTEN:$PORT,fork,reuseaddr SYSTEM:"/bin/echo -e 'HTTP/1.1 200 OK\r\n\r\nPRIMARY'" >> "$LOG" 2>&1 &
    fi
  else
    if pgrep -f "socat TCP-LISTEN:$PORT" >/dev/null; then
      echo "[$(date -Is)] not primary: stopping listener" >> "$LOG"
      pkill -f "socat TCP-LISTEN:$PORT" || true
    fi
  fi
  sleep 2
done
SH
  chmod +x /usr/local/bin/pgha_health.sh

  cat >/etc/systemd/system/pgha-health.service <<'UNIT'
[Unit]
Description=pg-ha primary health endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pgha_health.sh
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now pgha-health

  touch /opt/pg-ha/.pgb_provisioned
  ok "PgBouncer and health agent configured"
}

# pg_auto_failover Monitor provisioning
provision_monitor() {
  info "Starting pg_auto_failover monitor provisioning"

  if [ -f /opt/pg-ha/.monitor_provisioned ]; then
    ok "Monitor already provisioned; skipping"
    return 0
  fi

  apt-get update -y
  apt-get install -yq lsb-release gnupg curl wget
  # Ensure PGDG repo present for auto-failover extension
  if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" >/etc/apt/sources.list.d/pgdg.list
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    apt-get update -y
  fi

  # Install packages (try both naming schemes)
  apt-get install -yq postgresql-17 postgresql-client-17 || true
  apt-get install -yq postgresql-17-auto-failover || true
  apt-get install -yq pg-auto-failover-cli || true

  install_tls || true
  ensure_tls_permissions "$CERT_DIR"

  MON_PGDATA="/var/lib/postgresql/17/monitor"
  MON_PORT=5431
  mkdir -p "$MON_PGDATA"
  chown -R postgres:postgres "$MON_PGDATA"
  chmod 700 "$MON_PGDATA"

  MON_IP=$(curl -sH "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/instance/network-interfaces/0/ip)

  su - postgres -c "pg_autoctl create monitor \
    --pgdata '$MON_PGDATA' \
    --pgport $MON_PORT \
    --hostname '$MON_IP' \
    --auth scram \
    --ssl-ca-file '/etc/ssl/pg/ca.crt' \
    --ssl-cert-file '/etc/ssl/pg/server.crt' \
    --ssl-key-file '/etc/ssl/pg/server.key'" || error "Monitor initialization failed"

  cat >/etc/systemd/system/pgautofailover-monitor.service <<'UNIT'
[Unit]
Description=pg_auto_failover monitor
After=network-online.target
Wants=network-online.target

[Service]
User=postgres
ExecStart=/usr/bin/pg_autoctl run --pgdata /var/lib/postgresql/17/monitor
Restart=on-failure
RestartSec=3s
Environment=PG_AUTOCTL_LOG_LEVEL=info

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now pgautofailover-monitor

  # Enforce synchronous replication for RPO=0
  su - postgres -c "pg_autoctl set formation number-sync-standbys 1 --formation default" || warn "Failed to set number-sync-standbys"

  install_failback_orchestrator || warn "Failed to install failback orchestrator"

  su - postgres -c "pg_autoctl show uri --pgdata '$MON_PGDATA' --monitor" > /opt/pg-ha/monitor_uri.txt || true
  touch /opt/pg-ha/.monitor_provisioned
  ok "Monitor provisioning completed"
}

# Auto-failover enrollment for data nodes
provision_auto_failover_node() {
  info "Configuring pg_auto_failover on data node"
  if [ -f /opt/pg-ha/.af_node_provisioned ]; then
    ok "pg_auto_failover already configured; skipping"
    return 0
  fi

  apt-get update -y
  apt-get install -yq pg-auto-failover-cli || apt-get install -yq postgresql-17-auto-failover || true

  install_tls || true
  ensure_tls_permissions "$CERT_DIR"

  PGDATA="/var/lib/postgresql/17/main"
  MON_DSN="postgresql://autoctl_node@pg-monitor.db-ha.internal:5431/pg_auto_failover?sslmode=verify-full&sslrootcert=/etc/ssl/pg/ca.crt&sslcert=/etc/ssl/pg/server.crt&sslkey=/etc/ssl/pg/server.key"

  # Stop native postgres service; pg_autoctl will manage postgres
  systemctl disable --now postgresql || true

  su - postgres -c "pg_autoctl create postgres \
    --pgdata '$PGDATA' \
    --monitor '$MON_DSN' \
    --ssl-ca-file '/etc/ssl/pg/ca.crt' \
    --ssl-cert-file '/etc/ssl/pg/server.crt' \
    --ssl-key-file '/etc/ssl/pg/server.key' \
    --auth scram" || error "pg_autoctl create postgres failed"

  # Systemd service for pg_autoctl
  cat >/etc/systemd/system/pgautofailover-node.service <<'UNIT'
[Unit]
Description=pg_auto_failover node manager
After=network-online.target
Wants=network-online.target

[Service]
User=postgres
ExecStart=/usr/bin/pg_autoctl run --pgdata /var/lib/postgresql/17/main
Restart=always
RestartSec=3s
Environment=PG_AUTOCTL_LOG_LEVEL=info

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now pgautofailover-node

  # Set candidate priority: prefer pg-primary
  if [ "$NODE_ROLE" = "pg-primary" ]; then
    su - postgres -c "pg_autoctl set node candidate-priority 100 --pgdata '$PGDATA'" || warn "Failed to set candidate priority for primary"
  else
    su - postgres -c "pg_autoctl set node candidate-priority 50 --pgdata '$PGDATA'" || warn "Failed to set candidate priority for secondary"
  fi

  # Wait until Postgres is ready under pg_autoctl, then set passwords
  for i in {1..30}; do
    su - postgres -c "pg_isready" && break || sleep 2
  done
  SUPER_PW=$(SM "pg-superuser-password" || true)
  REPL_PW=$(SM "pg-repl-password" || true)
  if [ -n "$SUPER_PW" ]; then
    su - postgres -c "psql -tAc \"ALTER USER postgres WITH PASSWORD '${SUPER_PW}';\"" || warn "Failed to set postgres password"
  fi
  if [ -n "$REPL_PW" ]; then
    su - postgres -c "psql -tAc \"DO $$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='repl') THEN CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD '${REPL_PW}'; END IF; END$$;\"" || warn "Failed to ensure repl role"
  fi

  touch /opt/pg-ha/.af_node_provisioned
  ok "pg_auto_failover node configured"
}

# Failback orchestrator (monitor-only)
install_failback_orchestrator() {
  info "Installing automatic failback orchestrator (monitor)"

  cat >/usr/local/bin/pgha_failback.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG=/var/log/pg-ha/failback.log
exec >> "$LOG" 2>&1

echo "[$(date -Is)] failback tick"
MON_URI_FILE=/opt/pg-ha/monitor_uri.txt
[ -s "$MON_URI_FILE" ] || { echo "monitor URI missing"; exit 0; }
MON_URI=$(cat "$MON_URI_FILE")
STATE_JSON=$(su - postgres -c "pg_autoctl show state --json --monitor '$MON_URI'" || true)
[ -n "$STATE_JSON" ] || { echo "no state json"; exit 0; }

jq -e . >/dev/null 2>&1 <<<"$STATE_JSON" || { echo "invalid json"; exit 0; }

cur_primary=$(jq -r '.[]? // .Nodes? | map(select((.ReportedState // .reportedState // .state) | ascii_downcase == "primary")) | .[0].Name // .[0].name' <<<"$STATE_JSON")
pg_primary=$(jq -r '.[]? // .Nodes? | map(select((.Name // .name) | test("^pg-primary"))) | .[0].Name // .[0].name' <<<"$STATE_JSON")

if [ -z "$cur_primary" ] || [ -z "$pg_primary" ]; then echo "missing node names"; exit 0; fi
if [ "$cur_primary" = "$pg_primary" ]; then echo "already primary"; exit 0; fi

# Ensure pg-primary is healthy and secondary
pg_primary_state=$(jq -r '.[]? // .Nodes? | map(select((.Name // .name) | test("^pg-primary"))) | .[0].ReportedState // .[0].reportedState // .[0].state' <<<"$STATE_JSON" | tr 'A-Z' 'a-z')
pg_primary_health=$(jq -r '.[]? // .Nodes? | map(select((.Name // .name) | test("^pg-primary"))) | .[0].Health // .[0].health // 0' <<<"$STATE_JSON")
if [ "$pg_primary_state" != "secondary" ] || [ "$pg_primary_health" -lt 1 ]; then echo "pg-primary not ready ($pg_primary_state/$pg_primary_health)"; exit 0; fi

# Stabilization window: require N consecutive confirmations
STATE_FILE=/opt/pg-ha/failback.state
now=$(date +%s)
min_interval=600
last=$(awk -F= '/last_switchover=/{print $2}' "$STATE_FILE" 2>/dev/null || echo 0)
if [ $((now - last)) -lt $min_interval ]; then echo "cooldown active"; exit 0; fi

ok_count=$(awk -F= '/ok_count=/{print $2}' "$STATE_FILE" 2>/dev/null || echo 0)
ok_count=$((ok_count+1))
need=3

echo "ok_count=$ok_count need=$need"
if [ $ok_count -lt $need ]; then
  { echo "ok_count=$ok_count"; echo "last_switchover=$last"; } > "$STATE_FILE"
  exit 0
fi

# Ensure synchronous standby is pg-primary (RPO=0 with remote_apply)
cur_primary_host=$cur_primary
PGSSL="sslmode=verify-full sslrootcert=/etc/ssl/pg/ca.crt sslcert=/etc/ssl/pg/server.crt sslkey=/etc/ssl/pg/server.key"
PGPASS=$(curl -s -H "Authorization: Bearer $(curl -sH 'Metadata-Flavor: Google' http://metadata/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)" \
  -H 'Content-Type: application/json' "https://secretmanager.googleapis.com/v1/projects/$(curl -sH 'Metadata-Flavor: Google' http://metadata/computeMetadata/v1/project/project-id)/secrets/pg-superuser-password/versions/latest:access" | jq -r .payload.data | base64 -d)

SQL="SELECT application_name, sync_state FROM pg_stat_replication WHERE sync_state='sync' AND application_name LIKE 'pg-primary%';"
if PGPASSWORD="$PGPASS" psql "host=$cur_primary_host port=5432 user=postgres dbname=postgres $PGSSL" -Atc "$SQL" | grep -q '^pg-primary'; then
  echo "conditions satisfied; performing switchover to prefer pg-primary"
  su - postgres -c "pg_autoctl perform switchover --monitor '$MON_URI' --formation default" || { echo "switchover failed"; exit 0; }
  { echo "ok_count=0"; echo "last_switchover=$now"; } > "$STATE_FILE"
else
  echo "pg-primary not synchronous standby yet"
  { echo "ok_count=0"; echo "last_switchover=$last"; } > "$STATE_FILE"
fi
SH
  chmod +x /usr/local/bin/pgha_failback.sh

  cat >/etc/systemd/system/pgha-failback.service <<'UNIT'
[Unit]
Description=pg-ha automatic failback orchestrator
After=pgautofailover-monitor.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pgha_failback.sh
Restart=always
RestartSec=30s

[Install]
WantedBy=multi-user.target
UNIT

  cat >/etc/systemd/system/pgha-failback.timer <<'UNIT'
[Unit]
Description=Run pg-ha failback orchestrator periodically

[Timer]
OnBootSec=2m
OnUnitActiveSec=1m
AccuracySec=15s

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now pgha-failback.timer
}

# pgBackRest with GCS (via gcsfuse) provisioning
provision_pgbackrest() {
  info "Configuring pgBackRest with GCS via gcsfuse"
  if [ -f /opt/pg-ha/.pgbr_provisioned ]; then
    ok "pgBackRest already configured; skipping"
    return 0
  fi

  apt-get update -y
  # Install pgbackrest
  apt-get install -yq pgbackrest
  # Install gcsfuse
  . /etc/os-release
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  apt-get update -y
  apt-get install -yq gcsfuse

  mkdir -p /etc/pgbackrest /var/lib/pgbackrest/repo
  chown -R postgres:postgres /etc/pgbackrest /var/lib/pgbackrest
  chmod 750 /etc/pgbackrest /var/lib/pgbackrest

  # Configure pgbackrest
  cat >/etc/pgbackrest/pgbackrest.conf <<'CONF'
[global]
repo1-type=posix
repo1-path=/var/lib/pgbackrest/repo
start-fast=y
compress-type=zstd
compress-level=3
process-max=4
retention-full=7

[main]
pg1-path=/var/lib/postgresql/17/main
CONF
  chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
  chmod 640 /etc/pgbackrest/pgbackrest.conf

  # Mount GCS bucket using gcsfuse (ADC via instance SA)
  BUCKET_NAME="${BACKUP_BUCKET_NAME:-$(curl -s http://metadata.google.internal/computeMetadata/v1/project/attributes/backup-bucket -H 'Metadata-Flavor: Google' || true)}"
  if [ -z "$BUCKET_NAME" ]; then
    # Fallback: try terraform output file if present
    BUCKET_NAME_FILE=/opt/pg-ha/backup_bucket.txt
    [ -s "$BUCKET_NAME_FILE" ] && BUCKET_NAME=$(cat "$BUCKET_NAME_FILE") || true
  fi
  if [ -z "$BUCKET_NAME" ]; then
    warn "Backup bucket name not found; skipping gcsfuse mount"
  else
    echo "gcsfuse#$BUCKET_NAME /var/lib/pgbackrest/repo fuse.gcsfuse rw,allow_other,file_mode=0770,dir_mode=0770,implicit_dirs,uid=postgres,gid=postgres 0 0" >> /etc/fstab
    mkdir -p /var/lib/pgbackrest/repo
    mount -a || true
  fi

  # Create stanza if possible
  su - postgres -c "pgbackrest --stanza=main --log-level-console=info stanza-create" || warn "stanza-create failed (may require DB ready)"

  # Backup scripts and timers (prefer standby)
  cat >/usr/local/bin/pgbackrest_backup.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG=/var/log/pg-ha/pgbackrest-backup.log
exec >> "$LOG" 2>&1
PGDATA=/var/lib/postgresql/17/main
if su - postgres -c "pg_autoctl show state --pgdata '$PGDATA'" | grep -iq "secondary"; then
  echo "[$(date -Is)] Running backup on standby"
  su - postgres -c "pgbackrest --stanza=main --type=incr backup --log-level-console=info" || exit 0
else
  echo "[$(date -Is)] Skipping backup (not standby)"
fi
SH
  chmod +x /usr/local/bin/pgbackrest_backup.sh

  cat >/usr/local/bin/pgbackrest_full.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG=/var/log/pg-ha/pgbackrest-backup.log
exec >> "$LOG" 2>&1
PGDATA=/var/lib/postgresql/17/main
if su - postgres -c "pg_autoctl show state --pgdata '$PGDATA'" | grep -iq "secondary"; then
  echo "[$(date -Is)] Running FULL backup on standby"
  su - postgres -c "pgbackrest --stanza=main --type=full backup --log-level-console=info" || exit 0
else
  echo "[$(date -Is)] Skipping full backup (not standby)"
fi
SH
  chmod +x /usr/local/bin/pgbackrest_full.sh

  cat >/etc/systemd/system/pgbackrest-incr.timer <<'UNIT'
[Unit]
Description=Daily incremental pgBackRest backup

[Timer]
OnCalendar=*-*-* 01:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  cat >/etc/systemd/system/pgbackrest-incr.service <<'UNIT'
[Unit]
Description=Run incremental pgBackRest backup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pgbackrest_backup.sh
UNIT

  cat >/etc/systemd/system/pgbackrest-full.timer <<'UNIT'
[Unit]
Description=Weekly full pgBackRest backup

[Timer]
OnCalendar=Sun 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  cat >/etc/systemd/system/pgbackrest-full.service <<'UNIT'
[Unit]
Description=Run full pgBackRest backup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pgbackrest_full.sh
UNIT

  systemctl daemon-reload
  systemctl enable --now pgbackrest-incr.timer pgbackrest-full.timer

  touch /opt/pg-ha/.pgbr_provisioned
  ok "pgBackRest configured"
}

# Google Ops Agent (metrics/logs) provisioning
provision_ops_agent() {
  info "Installing Google Ops Agent"
  if ! systemctl is-enabled google-cloud-ops-agent >/dev/null 2>&1; then
    curl -sS https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh | bash || true
    apt-get update -y
    apt-get install -yq google-cloud-ops-agent || true
  fi

  # Build Ops Agent config
  mkdir -p /etc/google-cloud-ops-agent
  cat >/etc/google-cloud-ops-agent/config.yaml <<'YAML'
logging:
  receivers:
    syslog:
      type: files
      include_paths: [/var/log/syslog]
    pgbouncer:
      type: files
      include_paths: [/var/log/pg-ha/pgbouncer.log]
  service:
    pipelines:
      default_pipeline:
        receivers: [syslog, pgbouncer]
metrics:
  receivers:
    hostmetrics:
      type: hostmetrics
      collection_interval: 60s
  service:
    pipelines:
      default_pipeline:
        receivers: [hostmetrics]
YAML

  # If data node, append PostgreSQL receiver to metrics and logs
  if [[ "$NODE_ROLE" == "pg-primary" || "$NODE_ROLE" == "pg-secondary" ]]; then
    MON_PW=$(SM "pg-monitoring-password" || true)
    if [ -n "$MON_PW" ]; then
      cat >>/etc/google-cloud-ops-agent/config.yaml <<YAML
metrics:
  receivers:
    postgresql:
      type: postgresql
      endpoint: 127.0.0.1:5432
      username: monitoring
      password: "$MON_PW"
      database: postgres
  service:
    pipelines:
      postgresql_pipeline:
        receivers: [postgresql]
logging:
  receivers:
    postgreslog:
      type: files
      include_paths: [/var/log/postgresql/*.log]
  service:
    pipelines:
      pg_pipeline:
        receivers: [postgreslog]
YAML
    else
      warn "Monitoring password not available; configuring ops agent without PostgreSQL receiver"
    fi
  fi

  systemctl restart google-cloud-ops-agent || true
  ok "Google Ops Agent configured"
}

# Compliance & Logging hardening
provision_compliance() {
  info "Applying compliance & logging hardening"

  # Logrotate for pg-ha logs
  cat >/etc/logrotate.d/pg-ha <<'ROT'
/var/log/pg-ha/*.log {
  daily
  rotate 14
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
}
ROT

  # Extra auditd watches
  cat >/etc/audit/rules.d/pg-ha-extra.rules <<'AUD'
-w /etc/pgbouncer -p wa -k pgbouncer_conf
-w /etc/pgbackrest -p wa -k pgbackrest_conf
-w /etc/ssl/pg -p wa -k pg_tls
-w /var/lib/postgresql -p wa -k pgdata
-w /usr/lib/postgresql/17/bin -p x -k pg_bin
AUD
  augenrules --load || true

  # Tighten permissions on sensitive dirs
  chmod 750 /etc/pgbouncer /etc/pgbackrest /etc/ssl/pg 2>/dev/null || true

  # Conservative umask for interactive shells
  echo 'umask 027' >/etc/profile.d/pg-ha-umask.sh
  chmod 644 /etc/profile.d/pg-ha-umask.sh

  ok "Compliance & logging hardening applied"
}

# Utility: detect VPC CIDR from metadata or local routing (fallback to loopback)
detect_vpc_cidr() {
  local md
  md=$(curl -sf -H "Metadata-Flavor: Google" \
       http://metadata.google.internal/computeMetadata/v1/instance/attributes/vpc-cidr || \
       curl -sf -H "Metadata-Flavor: Google" \
       http://metadata.google.internal/computeMetadata/v1/project/attributes/vpc-cidr || true)
  if [ -n "${VPC_CIDR:-}" ]; then echo "$VPC_CIDR"; return; fi
  if [ -n "$md" ]; then echo "$md"; return; fi
  local dev cidr
  dev=$(ip route | awk '/default/ {print $5; exit}')
  cidr=$(ip -o route show dev "$dev" proto kernel scope link | awk '{print $1; exit}')
  echo "${cidr:-127.0.0.1/32}"
}

case "$NODE_ROLE" in
  pg-primary|pg-secondary)
    provision_postgres || error "PostgreSQL provisioning failed"
    provision_auto_failover_node || error "pg_auto_failover node provisioning failed"
    provision_pgbouncer || error "PgBouncer provisioning failed"
    provision_pgbackrest || error "pgBackRest provisioning failed"
    provision_compliance || warn "Compliance provisioning failed"
    provision_ops_agent || warn "Ops Agent provisioning failed"
    ;;
  pg-monitor)
    provision_monitor || error "Monitor provisioning failed"
    provision_compliance || warn "Compliance provisioning failed"
    provision_ops_agent || warn "Ops Agent provisioning failed"
    ;;
  *)
    info "Node role $NODE_ROLE is not a data node; skipping PostgreSQL provisioning"
    provision_compliance || true
    provision_ops_agent || true
    ;;
 esac
