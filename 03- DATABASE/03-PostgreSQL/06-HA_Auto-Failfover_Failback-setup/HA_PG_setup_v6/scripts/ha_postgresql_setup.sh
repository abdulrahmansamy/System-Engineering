#!/bin/bash
# High Availability PostgreSQL bootstrap for GCE VMs using pg_auto_failover
# - Ubuntu 24.04 LTS minimal
# - PostgreSQL 17 (PGDG)
# - pg_auto_failover (CitusData packages)
# - TLS from Certificate Manager (CA/cert/key)
# - SCRAM-SHA-256 auth
# - Idempotent: safe to re-run

set -euo pipefail

BOOTSTRAP_DIR="/var/lib/pg-bootstrap"
mkdir -p "$BOOTSTRAP_DIR"

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
trap 'rc=$?; if (( rc != 0 )); then log ERROR "Bootstrap script exiting with code $rc"; fi' EXIT

info "Bootstrap logging initialized (file: $LOG_FILE)"
export DEBIAN_FRONTEND=noninteractive
info "Environment set: DEBIAN_FRONTEND=$DEBIAN_FRONTEND"

ROLE="${ROLE:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_role || echo unknown)}"
COOLDOWN="${COOLDOWN:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_controller_cooldown || echo 600)}"

#############################################
# Module 3: Disks & Filesystem Provisioning
#############################################
DATA_DEV="/dev/sdb"   # Attached data disk (LVM PV)
WAL_DEV="/dev/sdc"    # Attached wal disk (LVM PV)
VG_NAME="pgvg"
LV_DATA="pgdata"
LV_WAL="pgwal"
MNT_DATA="/var/lib/postgresql"
MNT_WAL="$MNT_DATA/wal"

disk_setup() {
	if [[ ! "$ROLE" =~ ^(primary|standby)$ ]]; then
		log "Role $ROLE not a data node; skipping disk setup"
		return 0
	fi

	log "Starting disk setup for role $ROLE"
	apt-get update -y >/dev/null 2>&1 || true
	DEBIAN_FRONTEND=noninteractive apt-get install -y lvm2 xfsprogs >/dev/null 2>&1 || true

	for dev in "$DATA_DEV" "$WAL_DEV"; do
		if [[ ! -b $dev ]]; then
			log "Block device $dev missing; aborting disk setup"
			return 1
		fi
	done

	if ! pvs --noheadings -o pv_name 2>/dev/null | grep -q "^$DATA_DEV$"; then
		log "Initializing PV $DATA_DEV"; pvcreate -ff -y "$DATA_DEV" >/dev/null
	fi
	if ! pvs --noheadings -o pv_name 2>/dev/null | grep -q "^$WAL_DEV$"; then
		log "Initializing PV $WAL_DEV"; pvcreate -ff -y "$WAL_DEV" >/dev/null
	fi

	if ! vgs "$VG_NAME" >/dev/null 2>&1; then
		log "Creating VG $VG_NAME"; vgcreate "$VG_NAME" "$DATA_DEV" "$WAL_DEV" >/dev/null
	fi

	if ! lvs "$VG_NAME/$LV_DATA" >/dev/null 2>&1; then
		log "Creating LV $LV_DATA"; lvcreate -l 70%VG -n "$LV_DATA" "$VG_NAME" >/dev/null
	fi
	if ! lvs "$VG_NAME/$LV_WAL" >/dev/null 2>&1; then
		log "Creating LV $LV_WAL"; lvcreate -l 100%FREE -n "$LV_WAL" "$VG_NAME" >/dev/null
	fi

	if ! blkid | grep -q "/dev/$VG_NAME/$LV_DATA"; then
		log "Formatting data LV"; mkfs.xfs "/dev/$VG_NAME/$LV_DATA" >/dev/null
	fi
	if ! blkid | grep -q "/dev/$VG_NAME/$LV_WAL"; then
		log "Formatting wal LV"; mkfs.xfs "/dev/$VG_NAME/$LV_WAL" >/dev/null
	fi

	mkdir -p "$MNT_DATA" "$MNT_WAL"

	if ! grep -q "$VG_NAME/$LV_DATA" /etc/fstab; then
		echo "/dev/$VG_NAME/$LV_DATA $MNT_DATA xfs defaults,noatime 0 2" >> /etc/fstab
	fi
	if ! grep -q "$VG_NAME/$LV_WAL" /etc/fstab; then
		echo "/dev/$VG_NAME/$LV_WAL $MNT_WAL xfs defaults,noatime 0 2" >> /etc/fstab
	fi

	mountpoint -q "$MNT_DATA" || mount "$MNT_DATA"
	mountpoint -q "$MNT_WAL" || mount "$MNT_WAL"

	chown -R postgres:postgres "$MNT_DATA"
	chmod 700 "$MNT_DATA"
	chown -R postgres:postgres "$MNT_WAL"

	log "Disk/LVM provisioning complete"
	touch "$BOOTSTRAP_DIR/disk_setup.done"
}

if [[ ! -f "$BOOTSTRAP_DIR/disk_setup.done" ]]; then
	disk_setup || { log "Disk setup failed"; exit 1; }
else
	log "Disk setup previously completed; skipping"
fi

log "Module 3 disk provisioning segment finished"

#############################################
# Module 3 Completion: WAL directory linkage
#############################################
# We will later initialize PGDATA under /var/lib/postgresql/17/main (Module 6/7).
# Prepare a hook: if cluster initialized and pg_wal not yet on separate mount, move & symlink.
PG_VERSION="17"
PGDATA_BASE="/var/lib/postgresql/${PG_VERSION}"
PGDATA="${PGDATA_BASE}/main"
WAL_TARGET="$MNT_WAL/pg_wal"

relocate_wal() {
	[[ -d "$PGDATA" ]] || return 0   # Not initialized yet
	[[ -d "$PGDATA/pg_wal" ]] || return 0
	# If already a symlink, skip
	if [[ -L "$PGDATA/pg_wal" ]]; then
		log "pg_wal already symlinked; skipping"
		return 0
	fi
	# Only proceed if WAL target empty or absent
	mkdir -p "$WAL_TARGET"
	if [[ -n "$(ls -A "$WAL_TARGET" 2>/dev/null)" ]]; then
		log "WAL target $WAL_TARGET not empty; aborting relocation to avoid data loss"
		return 0
	fi
	systemctl is-active postgresql >/dev/null 2>&1 && systemctl stop postgresql || true
	mv "$PGDATA/pg_wal"/* "$WAL_TARGET" 2>/dev/null || true
	rm -rf "$PGDATA/pg_wal"
	ln -s "$WAL_TARGET" "$PGDATA/pg_wal"
	chown -h postgres:postgres "$PGDATA/pg_wal"
	chown -R postgres:postgres "$WAL_TARGET"
	systemctl start postgresql 2>/dev/null || true
	log "Relocated pg_wal to $WAL_TARGET and created symlink"
	touch "$BOOTSTRAP_DIR/wal_relocate.done"
}

if [[ ! -f "$BOOTSTRAP_DIR/wal_relocate.done" ]]; then
	relocate_wal || true
fi

#############################################
# Module 4: Package & Repo Bootstrap
#############################################
# Goal: Install PostgreSQL 17, pg_auto_failover, pgbouncer with idempotent APT setup.

install_packages() {
	[[ -f "$BOOTSTRAP_DIR/packages.done" ]] && { log "Packages already installed"; return 0; }
  local apt_log="$LOG_DIR/apt-last.log"
  : > "$apt_log"

  apt_retry() { # apt_retry <cmd...>
    local attempt rc
    for attempt in 1 2 3; do
      "$@" >>"$apt_log" 2>&1 && return 0
      rc=$?
      log WARN "APT command failed attempt $attempt (rc=$rc): $*"
      sleep 3
      apt-get update -y >>"$apt_log" 2>&1 || true
    done
    return 1
  }

  log INFO "Running apt-get update (initial)"
  apt-get update -y >>"$apt_log" 2>&1 || log WARN "Initial apt update returned non-zero (continuing)"
  apt_retry apt-get install -y ca-certificates curl gnupg lsb-release || {
    log ERROR "Failed installing base packages. See $apt_log (tail below)"
    tail -n 40 "$apt_log" | while read -r l; do log ERROR "APT: $l"; done
    die "Base package install failed"
  }

	# PGDG repo
	if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
		curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg
		echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
	fi

  # Citus / pg_auto_failover repo (map noble->jammy until upstream supports noble)
  if [[ ! -f /etc/apt/sources.list.d/citusdata.list ]]; then
    local codename
    codename=$(lsb_release -cs)
    local citus_codename="$codename"
    if [[ "$codename" == "noble" ]]; then
      citus_codename="jammy"
      log WARN "Mapping Ubuntu codename noble -> jammy for citus repository (temporary workaround)"
    fi
    curl -fsSL https://repos.citusdata.com/community/gpgkey | gpg --dearmor -o /usr/share/keyrings/citus.gpg
    echo "deb [signed-by=/usr/share/keyrings/citus.gpg] https://repos.citusdata.com/community/ubuntu $citus_codename main" > /etc/apt/sources.list.d/citusdata.list
  fi

  log INFO "Refreshing APT metadata after repo additions"
  if ! apt-get update -y >>"$apt_log" 2>&1; then
    log WARN "apt-get update returned non-zero; continuing to attempt install"
  fi
  # Detect citus 404 and fallback remove if necessary
  if grep -q "citusdata.com.*404" "$apt_log"; then
    log ERROR "Citus repository returned 404. Removing citus repo and proceeding without pg_auto_failover package (will retry build alternative later)."
    rm -f /etc/apt/sources.list.d/citusdata.list
    apt-get update -y >>"$apt_log" 2>&1 || true
  fi

	# Package list
	PKGS=(postgresql-${PG_VERSION} postgresql-client-${PG_VERSION} postgresql-${PG_VERSION}-pg-auto-failover pg-auto-failover-cli pgbouncer jq xfsprogs lvm2)
	to_install=()
	for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || to_install+=("$p"); done
  if (( ${#to_install[@]} > 0 )); then
    log INFO "Installing packages: ${to_install[*]}"
    if ! apt_retry apt-get install -y "${to_install[@]}"; then
      local rc=$?
      log ERROR "Package install failed (rc=$rc) — tailing last log"
      tail -n 80 "$apt_log" | while read -r l; do log ERROR "APT: $l"; done
      # If pg-auto-failover packages missing due to repo removal, note next step
      if ! dpkg -s pg-auto-failover-cli >/dev/null 2>&1; then
        log WARN "pg_auto_failover not installed; will require alternate install method (binary or source) in later module."
      fi
      die "Package installation failed"
    fi
  else
    log INFO "All required packages already present"
  fi

	# Enable and stop services for later controlled initialization
	systemctl disable postgresql 2>/dev/null || true
	systemctl stop postgresql 2>/dev/null || true
	systemctl disable pgbouncer 2>/dev/null || true
	systemctl stop pgbouncer 2>/dev/null || true

	touch "$BOOTSTRAP_DIR/packages.done"
  log INFO "Package bootstrap complete"
}

install_packages

log "Module 4 package bootstrap segment finished"

#############################################
# Module 4 Completion: Version Verification
#############################################
record_versions() {
	[[ -f "$BOOTSTRAP_DIR/package_versions.env" ]] && return 0
	local pv cv av bv
	pv=$(psql --version 2>/dev/null | awk '{print $3}' || echo unknown)
	cv=$(pg_autoctl --version 2>/dev/null | awk '{print $2}' || echo unknown)
	av=$(pg_autoctl show version 2>/dev/null | awk '{print $1}' || echo unknown)
	bv=$(pgbouncer -V 2>/dev/null | awk '{print $2}' || echo unknown)
	cat > "$BOOTSTRAP_DIR/package_versions.env" <<EOF
POSTGRESQL_VERSION=$pv
PG_AUTO_FAILOVER_VERSION=$cv
PG_AUTO_FAILOVER_MONITOR_VERSION=$av
PGBOUNCER_VERSION=$bv
EOF
	log "Recorded package versions: PG=$pv auto_failover=$cv pgbouncer=$bv"
}
record_versions || true

#############################################
# Module 5: Secrets & TLS Retrieval Layer
#############################################
# Retrieves secrets from Secret Manager only if hash differs.
# Expected secret names (adjust if naming differs):
#  pg_superuser, pg_repl, pg_monitor, pgbouncer, tls_ca, tls_ca_cert, tls_key

SECRETS_DIR="/etc/postgresql/secrets"
TLS_DIR="/etc/postgresql/tls"
mkdir -p "$SECRETS_DIR" "$TLS_DIR"
chmod 700 "$SECRETS_DIR" "$TLS_DIR"

hash_file() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || true; }
fetch_secret() { # name dest
	local name="$1" dest="$2" tmp
	tmp=$(mktemp)
	if gcloud secrets versions access latest --secret="$name" > "$tmp" 2>/dev/null; then
		if [[ -f "$dest" ]] && [[ "$(hash_file "$dest")" == "$(hash_file "$tmp")" ]]; then
			rm -f "$tmp"; return 0
		fi
		mv "$tmp" "$dest"
		chmod 600 "$dest"
		log "Updated secret $name"
	else
		rm -f "$tmp"; log "Secret $name not accessible"; return 1
	fi
}

secrets_setup() {
	[[ -f "$BOOTSTRAP_DIR/secrets.done" ]] && return 0
	command -v gcloud >/dev/null 2>&1 || { log "gcloud not installed; delaying secrets retrieval"; return 0; }

	fetch_secret pg_superuser "$SECRETS_DIR/pg_superuser.pass" || true
	fetch_secret pg_repl "$SECRETS_DIR/pg_repl.pass" || true
	fetch_secret pg_monitor "$SECRETS_DIR/pg_monitor.pass" || true
	fetch_secret pgbouncer "$SECRETS_DIR/pgbouncer.pass" || true

	fetch_secret tls_ca "$TLS_DIR/ca.key" || true
	fetch_secret tls_ca_cert "$TLS_DIR/ca.crt" || true
	fetch_secret tls_key "$TLS_DIR/server.key" || true

	# If server certificate delivered via Certificate Manager elsewhere, placeholder for integration.
	# Future: fetch chain + deploy to $TLS_DIR/server.crt

	# Build combined server certificate file if available
	if [[ -f "$TLS_DIR/server.key" && -f "$TLS_DIR/ca.crt" ]]; then
		cat "$TLS_DIR/ca.crt" > "$TLS_DIR/server.crt" 2>/dev/null || true
		chmod 600 "$TLS_DIR/server.key" "$TLS_DIR/server.crt"
	fi

	chown -R postgres:postgres "$SECRETS_DIR" "$TLS_DIR"
	touch "$BOOTSTRAP_DIR/secrets.done"
}

secrets_setup || true

log "Module 5 secrets & TLS segment initialized"

#############################################
# Module 5 Completion: Mandatory Secret Validation & TLS Fallback
#############################################
validate_secrets() {
	[[ -f "$BOOTSTRAP_DIR/secrets_validation.done" ]] && return 0
	if [[ "$ROLE" =~ ^(primary|standby)$ ]]; then
		local missing=()
		for req in pg_superuser.pass pg_repl.pass; do
			[[ -s "/etc/postgresql/secrets/$req" ]] || missing+=("$req")
		done
		if (( ${#missing[@]} > 0 )); then
			log "Required secrets missing for data node: ${missing[*]} (will retry on next run)"; return 0
		fi
	fi
	# TLS fallback: create ephemeral self-signed if server.crt missing
	if [[ ! -f /etc/postgresql/tls/server.crt || ! -f /etc/postgresql/tls/server.key ]]; then
		log "TLS server certificate missing; generating ephemeral self-signed cert (NOT FOR PRODUCTION LONG TERM)"
		openssl req -new -newkey rsa:4096 -days 3 -nodes -x509 \
			-subj "/CN=ephemeral-pg" \
			-keyout /etc/postgresql/tls/server.key \
			-out /etc/postgresql/tls/server.crt >/dev/null 2>&1 || true
		chmod 600 /etc/postgresql/tls/server.key /etc/postgresql/tls/server.crt
		chown postgres:postgres /etc/postgresql/tls/server.key /etc/postgresql/tls/server.crt
		touch /etc/postgresql/tls/EPHEMERAL_CERT
	fi
	touch "$BOOTSTRAP_DIR/secrets_validation.done"
	log "Secrets validation complete"
}

validate_secrets || true

#############################################
# Module 6: PostgreSQL Configuration Generator (Pre-Init)
#############################################
PG_VERSION="17"
PGDATA_BASE="/var/lib/postgresql/${PG_VERSION}"
PGDATA="${PGDATA_BASE}/main"
CONF_DIR="$PGDATA"
HBA_FILE="$CONF_DIR/pg_hba.conf"
CONF_FILE="$CONF_DIR/postgresql.conf"

generate_config() {
	[[ "$ROLE" =~ ^(primary|standby)$ ]] || { log "Role $ROLE not a data node; skipping PG config"; return 0; }
	[[ -f "$BOOTSTRAP_DIR/pg_config.done" ]] && return 0

	mkdir -p "$CONF_DIR"
	chown -R postgres:postgres "$PGDATA_BASE"

	# Dynamic memory sizing
	mem_kb=$(grep -i MemTotal /proc/meminfo | awk '{print $2}')
	mem_mb=$((mem_kb/1024))
	shared_mb=$((mem_mb/4))           # ~25%
	effective_cache_mb=$(( (mem_mb*70)/100 ))
	maintenance_mb=$((mem_mb/16))
	wal_buffers_mb=$((shared_mb/32)); (( wal_buffers_mb < 16 )) && wal_buffers_mb=16

	tmp_conf=$(mktemp)
	cat > "$tmp_conf" <<EOF
# Auto-generated by ha_postgresql_setup.sh (Module 6)
data_directory = '$CONF_DIR'
listen_addresses = '*'
port = 5432
unix_socket_directories = '/var/run/postgresql'
ssl = on
ssl_cert_file = '/etc/postgresql/tls/server.crt'
ssl_key_file  = '/etc/postgresql/tls/server.key'
ssl_ca_file   = '/etc/postgresql/tls/ca.crt'

max_connections = 800
shared_buffers = ${shared_mb}MB
effective_cache_size = ${effective_cache_mb}MB
maintenance_work_mem = ${maintenance_mb}MB
work_mem = 8MB
wal_buffers = ${wal_buffers_mb}MB
huge_pages = try
random_page_cost = 1.1
effective_io_concurrency = 300
max_parallel_workers_per_gather = 4
max_worker_processes = 16
max_parallel_workers = 16
max_parallel_maintenance_workers = 4

# WAL / Replication
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f'
max_wal_senders = 20
max_replication_slots = 20
hot_standby = on
synchronous_commit = remote_apply
synchronous_standby_names = '*'
wal_compression = on
wal_keep_size = '4GB'
max_wal_size = '16GB'
min_wal_size = '2GB'
checkpoint_timeout = '15min'
checkpoint_completion_target = 0.9

# Logging
log_destination = 'csvlog'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%a.log'
log_rotation_age = '1d'
log_rotation_size = '0'
log_min_duration_statement = 2000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_line_prefix = '%m [%p] %u@%d %r %a '

# Monitoring
track_io_timing = on
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 10000
pg_stat_statements.track = all

# Autovacuum tuning
autovacuum = on
autovacuum_vacuum_cost_limit = 3000
autovacuum_vacuum_cost_delay = 2ms

# Failover safety
recovery_target_timeline = 'latest'
EOF

	if [[ -f "$CONF_FILE" ]] && cmp -s "$tmp_conf" "$CONF_FILE"; then
		log "postgresql.conf unchanged"
		rm -f "$tmp_conf"
	else
		mv "$tmp_conf" "$CONF_FILE"
		chown postgres:postgres "$CONF_FILE"
		chmod 600 "$CONF_FILE"
		log "postgresql.conf written"
	fi

	# pg_hba.conf
	tmp_hba=$(mktemp)
	cat > "$tmp_hba" <<'EOF'
# Auto-generated pg_hba.conf (Module 6)
local   all             postgres                                peer
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# Replication & intra-cluster
host    replication     all             0.0.0.0/0               scram-sha-256
host    all             all             0.0.0.0/0               scram-sha-256
EOF
	if [[ -f "$HBA_FILE" ]] && cmp -s "$tmp_hba" "$HBA_FILE"; then
		log "pg_hba.conf unchanged"
		rm -f "$tmp_hba"
	else
		mv "$tmp_hba" "$HBA_FILE"
		chown postgres:postgres "$HBA_FILE"
		chmod 600 "$HBA_FILE"
		log "pg_hba.conf written"
	fi

	touch "$BOOTSTRAP_DIR/pg_config.done"
	log "PostgreSQL base configuration generated"
}

generate_config || true

log "Module 6 configuration segment finished"

#############################################
# Module 6 Completion: Cluster Init & Roles
#############################################
init_cluster_and_roles() {
  [[ "$ROLE" =~ ^(primary|standby)$ ]] || return 0
  # Marker for cluster init
  if [[ ! -f "$BOOTSTRAP_DIR/cluster_init.done" ]]; then
    # If PGDATA missing or empty, run initdb (Debian may auto-init; handle both)
    if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
      log "Initializing PostgreSQL cluster in $PGDATA"
      install -d -o postgres -g postgres "$PGDATA"
      sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/initdb -D "$PGDATA" --data-checksums >/dev/null 2>&1 || die "initdb failed"
    else
      log "Existing cluster detected; skipping initdb"
    fi

    # Ensure wal_archive dir exists
    install -d -o postgres -g postgres -m 700 "$MNT_WAL/wal_archive" || true
    [[ -d "$PGDATA/wal_archive" ]] || ln -s "$MNT_WAL/wal_archive" "$PGDATA/wal_archive" || true
    chown -h postgres:postgres "$PGDATA/wal_archive" || true

    touch "$BOOTSTRAP_DIR/cluster_init.done"
    log "Cluster initialization step complete"
  fi

  # Start server temporarily (not managed by pg_autoctl yet) to create roles if needed
  if [[ ! -f "$BOOTSTRAP_DIR/roles_configured.done" ]]; then
    systemctl stop postgresql 2>/dev/null || true
    # Launch standalone
    sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D "$PGDATA" -w start >/dev/null 2>&1 || die "temporary start failed"

    SUPER_PASS=$(cat /etc/postgresql/secrets/pg_superuser.pass 2>/dev/null || true)
    REPL_PASS=$(cat /etc/postgresql/secrets/pg_repl.pass 2>/dev/null || true)
    MON_PASS=$(cat /etc/postgresql/secrets/pg_monitor.pass 2>/dev/null || true)
    PGBOUNCER_PASS=$(cat /etc/postgresql/secrets/pgbouncer.pass 2>/dev/null || true)

    psql_cmd=(sudo -u postgres psql -v ON_ERROR_STOP=1 -q)

    # Set postgres password (if secret available)
    if [[ -n "$SUPER_PASS" ]]; then
      "${psql_cmd[@]}" -c "ALTER ROLE postgres WITH ENCRYPTED PASSWORD '$SUPER_PASS';" || die "Failed to set superuser password"
    fi

    # Idempotent role creation block
    "${psql_cmd[@]}" <<'SQL'
DO $$
DECLARE
BEGIN
  -- Replication role
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN;
  END IF;
  -- Monitor role
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgmonitor') THEN
    CREATE ROLE pgmonitor WITH LOGIN;
  END IF;
  -- PgBouncer auth role
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer') THEN
    CREATE ROLE pgbouncer WITH LOGIN;
  END IF;
END;$$;
SQL

    # Apply passwords if secrets present
    [[ -n "$REPL_PASS" ]] && "${psql_cmd[@]}" -c "ALTER ROLE replicator WITH ENCRYPTED PASSWORD '$REPL_PASS';" || true
    [[ -n "$MON_PASS" ]] && "${psql_cmd[@]}" -c "ALTER ROLE pgmonitor  WITH ENCRYPTED PASSWORD '$MON_PASS';" || true
    [[ -n "$PGBOUNCER_PASS" ]] && "${psql_cmd[@]}" -c "ALTER ROLE pgbouncer WITH ENCRYPTED PASSWORD '$PGBOUNCER_PASS';" || true

    # Grant minimal monitoring privs
    "${psql_cmd[@]}" <<'SQL'
GRANT pg_monitor TO pgmonitor; -- if extension role exists
SQL
    # Stop temporary server
    sudo -u postgres /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true

    touch "$BOOTSTRAP_DIR/roles_configured.done"
    log "Roles/password configuration complete"
  fi

  # Attempt WAL relocation after init
  if [[ ! -f "$BOOTSTRAP_DIR/wal_relocate.done" ]]; then
    relocate_wal || true
  fi
}

init_cluster_and_roles || true

#############################################
# Module 7: pg_auto_failover Monitor + Nodes Init (Initial Steps)
#############################################
CANDIDATE_PRIORITY="${CANDIDATE_PRIORITY:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/candidate_priority || echo 50)}"
REPLICATION_QUORUM="${REPLICATION_QUORUM:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/replication_quorum || echo true)}"
MONITOR_URI_META="${MONITOR_URI_META:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_monitor_uri || true)}"
MONITOR_PGDATA="/var/lib/postgresql/monitor"

create_monitor() {
  [[ "$ROLE" == "monitor" ]] || return 0
  [[ -f "$BOOTSTRAP_DIR/monitor_init.done" ]] && { log "Monitor already initialized"; return 0; }
  install -d -o postgres -g postgres "$MONITOR_PGDATA"
  if [[ ! -s "$MONITOR_PGDATA/PG_VERSION" ]]; then
    log "Creating pg_auto_failover monitor"
    sudo -u postgres pg_autoctl create monitor \
      --pgdata "$MONITOR_PGDATA" \
      --auth scram \
      --ssl-self-signed >/dev/null 2>&1 || die "Monitor creation failed"
  else
    log "Existing monitor cluster detected"
  fi
  # Record monitor URI
  sudo -u postgres pg_autoctl show uri --pgdata "$MONITOR_PGDATA" --monitor > "$BOOTSTRAP_DIR/monitor_uri.txt" 2>/dev/null || true
  touch "$BOOTSTRAP_DIR/monitor_init.done"
  log "Monitor initialization complete"
}

register_data_node() {
  [[ "$ROLE" =~ ^(primary|standby)$ ]] || return 0
  [[ -f "$BOOTSTRAP_DIR/node_registered.done" ]] && { log "Data node already registered"; return 0; }

  local monitor_uri=""
  if [[ -n "$MONITOR_URI_META" ]]; then
    monitor_uri="$MONITOR_URI_META"
  fi
  if [[ -z "$monitor_uri" ]]; then
    log "Monitor URI not provided via metadata; delaying node registration"; return 0
  fi

  # pg_autoctl will init PGDATA itself if empty; we already did but that's okay.
  log "Registering data node with monitor $monitor_uri"
  sudo -u postgres pg_autoctl create postgres \
    --pgdata "$PGDATA" \
    --monitor "$monitor_uri" \
    --hostname "$(hostname -f)" \
    --auth scram \
    --dbname postgres >/dev/null 2>&1 || {
      log "pg_autoctl create postgres failed (may already exist); continuing"; }

  # Set candidate priority & replication quorum
  sudo -u postgres pg_autoctl set node candidate-priority "$CANDIDATE_PRIORITY" --pgdata "$PGDATA" >/dev/null 2>&1 || true
  if [[ "$REPLICATION_QUORUM" =~ ^(false|0|no)$ ]]; then
    sudo -u postgres pg_autoctl set node replication-quorum false --pgdata "$PGDATA" >/dev/null 2>&1 || true
  else
    sudo -u postgres pg_autoctl set node replication-quorum true --pgdata "$PGDATA" >/dev/null 2>&1 || true
  fi

  touch "$BOOTSTRAP_DIR/node_registered.done"
  log "Data node registration complete"
}

create_monitor || true
register_data_node || true

log "Module 7 initial cluster formation steps executed (may be partial pending metadata)."

# (Future Module 7 Completion Tasks)
# - Enforce synchronous replication formation configuration
# - Add systemd units for pg_autoctl run processes
# - Health check & promotion timing tuning
# - Capture initial formation state metrics

#############################################
# Module 7 Completion: Supervision & Health
#############################################
setup_pg_autoctl_systemd() {
  # Monitor service
  if [[ "$ROLE" == "monitor" && ! -f "$BOOTSTRAP_DIR/monitor_unit.done" ]]; then
    cat > /etc/systemd/system/pg_autoctl-monitor.service <<'UNIT'
[Unit]
Description=pg_auto_failover monitor
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=postgres
ExecStart=/usr/bin/pg_autoctl run --pgdata /var/lib/postgresql/monitor
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable pg_autoctl-monitor.service || true
    systemctl start pg_autoctl-monitor.service || true
    touch "$BOOTSTRAP_DIR/monitor_unit.done"
    log "Monitor systemd unit installed"
  fi

  # Data node service
  if [[ "$ROLE" =~ ^(primary|standby)$ && ! -f "$BOOTSTRAP_DIR/node_unit.done" ]]; then
    cat > /etc/systemd/system/pg_autoctl-node.service <<UNIT
[Unit]
Description=pg_auto_failover data node
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=postgres
Environment=PGDATA=$PGDATA
ExecStart=/usr/bin/pg_autoctl run --pgdata $PGDATA
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable pg_autoctl-node.service || true
    systemctl start pg_autoctl-node.service || true
    touch "$BOOTSTRAP_DIR/node_unit.done"
    log "Data node systemd unit installed"
  fi
}

verify_sync_replication() {
  [[ "$ROLE" == "primary" ]] || return 0
  [[ -f "$BOOTSTRAP_DIR/sync_verified.done" ]] && return 0
  # Give some time for standby to appear
  for i in {1..30}; do
    if sudo -u postgres psql -Atqc "SELECT state FROM pg_stat_replication LIMIT 1" 2>/dev/null | grep -qi streaming; then
      # Check synchronous standby names resolution
      sudo -u postgres psql -Atqc "SHOW synchronous_standby_names;" | grep -q '*' && {
        touch "$BOOTSTRAP_DIR/sync_verified.done"; log "Synchronous replication verified"; return 0; }
    fi
    sleep 2
  done
  log "Synchronous replication verification deferred (standby not ready)"
}

install_healthcheck() {
  [[ -f /usr/local/bin/pg_healthcheck ]] && return 0
  cat > /usr/local/bin/pg_healthcheck <<'HC'
#!/bin/bash
# Simple health check: returns 0 if primary writable or standby hot + in sync
ROLE_FILE="/var/lib/pg-bootstrap/node_registered.done"
PGDATA="/var/lib/postgresql/17/main"
if [[ ! -d "$PGDATA" ]]; then exit 1; fi
# Determine current node role via pg_autoctl state if available
if command -v pg_autoctl >/dev/null 2>&1; then
  STATE=$(sudo -u postgres pg_autoctl show state --pgdata "$PGDATA" 2>/dev/null | awk 'NR>2 {print $3" "$4" "$5}' | head -1)
  # STATE includes node name and state columns; we just check for primary/secondary keywords
  if echo "$STATE" | grep -qi primary; then
    sudo -u postgres psql -Atqc "SELECT 1" >/dev/null 2>&1 && exit 0 || exit 1
  fi
  if echo "$STATE" | grep -Eqi 'secondary|wait_standby'; then
    # Check replication delay minimal
    LAG=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(EPOCH FROM now()-pg_last_xact_replay_timestamp())::int" 2>/dev/null || echo 9999)
    [[ "$LAG" =~ ^[0-9]+$ ]] || LAG=9999
    (( LAG < 10 )) && exit 0 || exit 1
  fi
fi
# Fallback: basic connectivity
sudo -u postgres psql -Atqc "SELECT 1" >/dev/null 2>&1 && exit 0 || exit 1
HC
  chmod +x /usr/local/bin/pg_healthcheck
  log "Health check script installed"
}

apply_timeout_tuning() {
  [[ "$ROLE" =~ ^(primary|standby|monitor)$ ]] || return 0
  [[ -f "$BOOTSTRAP_DIR/timeouts_tuned.done" ]] && return 0
  # Use pg_autoctl config set for monitor and node; ignore errors if unsupported
  if [[ "$ROLE" == "monitor" ]]; then
    sudo -u postgres pg_autoctl config set --pgdata $MONITOR_PGDATA monitor.default_group_name 'formation' >/dev/null 2>&1 || true
  fi
  if [[ "$ROLE" =~ ^(primary|standby)$ ]]; then
    sudo -u postgres pg_autoctl config set --pgdata $PGDATA postgresql.shared_buffers "$(grep '^shared_buffers' $CONF_FILE | awk '{print $3}')" >/dev/null 2>&1 || true
  fi
  touch "$BOOTSTRAP_DIR/timeouts_tuned.done"
  log "Timeout/config tuning marker set (placeholder)"
}

setup_pg_autoctl_systemd || true
install_healthcheck || true
apply_timeout_tuning || true
verify_sync_replication || true

# Final Module 7 marker
if [[ ! -f "$BOOTSTRAP_DIR/module7.complete" ]]; then
  # Mark complete when core artifacts exist
  if [[ -f "$BOOTSTRAP_DIR/node_registered.done" || "$ROLE" == "monitor" ]]; then
    touch "$BOOTSTRAP_DIR/module7.complete"
    log "Module 7 completion marker set"
  fi
fi

#############################################
# Module 8: Failback Controller Integration
#############################################
setup_failback_controller() {
  [[ "$ROLE" =~ ^(primary|standby)$ ]] || return 0
  [[ -f "$BOOTSTRAP_DIR/failback_controller.done" ]] && return 0
  if [[ ! -x /usr/bin/pg_autoctl || ! -x /usr/lib/postgresql/${PG_VERSION}/bin/postgres ]]; then
    log "Dependencies for failback controller not ready"; return 0
  fi
  if [[ ! -f /usr/local/sbin/failback-controller ]]; then
    install -m 755 /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/06-HA_Auto-Failfover_Failback-setup/HA_PG_setup_v6/scripts/failback-controller.sh /usr/local/sbin/failback-controller || return 0
  fi
  cat > /etc/systemd/system/failback-controller.service <<'UNIT'
[Unit]
Description=PostgreSQL Failback Controller
After=pg_autoctl-node.service network.target
Requires=pg_autoctl-node.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/sbin/failback-controller
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/failback-controller.timer <<'TIMER'
[Unit]
Description=Run failback controller periodically (safety loop)

[Timer]
OnBootSec=2m
OnUnitActiveSec=1m
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
TIMER
  systemctl daemon-reload || true
  systemctl enable failback-controller.service failback-controller.timer || true
  systemctl start failback-controller.timer || true
  touch "$BOOTSTRAP_DIR/failback_controller.done"
  log "Failback controller systemd integration complete"
}

#############################################
# Module 9: PgBouncer Deployment (Initial)
#############################################
setup_pgbouncer() {
  [[ "$ROLE" =~ ^(primary|standby)$ ]] || { log "PgBouncer only on data nodes (current role $ROLE)"; return 0; }
  local cfg_dir='/etc/pgbouncer'
  local cfg_file="$cfg_dir/pgbouncer.ini"
  local userlist="$cfg_dir/userlist.txt"
  [[ -d $cfg_dir ]] || mkdir -p "$cfg_dir"
  chmod 750 "$cfg_dir"

  # Require at least superuser secret
  local super_pass pgb_pass
  super_pass=$(cat /etc/postgresql/secrets/pg_superuser.pass 2>/dev/null || true)
  pgb_pass=$(cat /etc/postgresql/secrets/pgbouncer.pass 2>/dev/null || true)
  if [[ -z "$super_pass" ]]; then
    log "Superuser secret missing; deferring PgBouncer configuration"; return 0
  fi
  if [[ -z "$pgb_pass" ]]; then
    # fallback: reuse super user password for pgbouncer role if its secret absent (not ideal)
    pgb_pass="$super_pass"
  fi

  # Build userlist with md5 hashes (auth_type=md5)
  # md5 format: md5<md5 of password+username>
  build_hash() { local pw="$1" user="$2"; printf "md5%s" "$(echo -n "${pw}${user}" | md5sum | awk '{print $1}')"; }
  local postgres_hash pgbouncer_hash tmp_userlist
  postgres_hash=$(build_hash "$super_pass" postgres)
  pgbouncer_hash=$(build_hash "$pgb_pass" pgbouncer)
  tmp_userlist=$(mktemp)
  cat > "$tmp_userlist" <<EOF
"postgres" "$postgres_hash"
"pgbouncer" "$pgbouncer_hash"
EOF
  if [[ ! -f "$userlist" || ! cmp -s "$tmp_userlist" "$userlist" ]]; then
    mv "$tmp_userlist" "$userlist"
    chmod 640 "$userlist"
    chown postgres:postgres "$userlist"
    log "PgBouncer userlist.txt updated"
  else
    rm -f "$tmp_userlist"
  fi

  # Generate config
  local tmp_cfg
  tmp_cfg=$(mktemp)
  cat > "$tmp_cfg" <<'EOF'
[databases]
# Wildcard mapping: all DBs local host
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres,pgbouncer
stats_users = postgres
pool_mode = transaction
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits
max_client_conn = 2000
default_pool_size = 100
reserve_pool_size = 20
reserve_pool_timeout = 5
server_idle_timeout = 300
query_timeout = 600000
client_idle_timeout = 600
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
pidfile = /var/run/postgresql/pgbouncer.pid
unix_socket_dir = /var/run/postgresql
# TLS (optional server side) - disabled by default, can be enabled later
;; server_tls_sslmode = prefer
;; server_tls_ca_file = /etc/postgresql/tls/ca.crt
;; server_tls_key_file = /etc/postgresql/tls/server.key
;; server_tls_cert_file = /etc/postgresql/tls/server.crt
EOF
  if [[ ! -f "$cfg_file" || ! cmp -s "$tmp_cfg" "$cfg_file" ]]; then
    mv "$tmp_cfg" "$cfg_file"
    chown postgres:postgres "$cfg_file"
    chmod 640 "$cfg_file"
    log "PgBouncer configuration updated"
  else
    rm -f "$tmp_cfg"
  fi

  # Systemd service adjustments (ensure enabled/running)
  if ! systemctl is-enabled pgbouncer >/dev/null 2>&1; then
    systemctl enable pgbouncer >/dev/null 2>&1 || true
  fi
  systemctl restart pgbouncer >/dev/null 2>&1 || systemctl start pgbouncer >/dev/null 2>&1 || true

  # Healthcheck for PgBouncer
  if [[ ! -f /usr/local/bin/pgbouncer_healthcheck ]]; then
    cat > /usr/local/bin/pgbouncer_healthcheck <<'HC'
#!/bin/bash
# Returns 0 if PgBouncer is accepting connections and (if primary) DB is writable.
PGBOUNCER_PORT=6432
PGBOUNCER_HOST=127.0.0.1
psql -h "$PGBOUNCER_HOST" -p $PGBOUNCER_PORT -U postgres -d postgres -Atqc 'SHOW VERSION;' >/dev/null 2>&1 || exit 1
# Optional: check pools not in error
err=$(psql -h "$PGBOUNCER_HOST" -p $PGBOUNCER_PORT -U postgres -d pgbouncer -Atqc "SHOW POOLS;" 2>/dev/null | awk '$8=="failed"{c++} END{print c+0}')
[[ "$err" == "0" ]] || exit 1
exit 0
HC
    chmod +x /usr/local/bin/pgbouncer_healthcheck
  fi

  touch "$BOOTSTRAP_DIR/pgbouncer_config.done"
}

#############################################
# Module 9 Completion Enhancements
#############################################
finalize_pgbouncer() {
  [[ "$ROLE" =~ ^(primary|standby)$ ]] || return 0
  [[ -f "$BOOTSTRAP_DIR/pgbouncer_final.done" ]] && return 0

  local cfg_dir='/etc/pgbouncer'
  local cfg_file="$cfg_dir/pgbouncer.ini"
  local enable_tls_meta
  enable_tls_meta=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pgbouncer_tls_enabled || echo false)

  # Inject TLS lines if enabled and not already present
  if [[ "$enable_tls_meta" =~ ^(true|1|yes)$ && -f /etc/postgresql/tls/server.crt ]]; then
    if ! grep -q '^server_tls_sslmode' "$cfg_file"; then
      cat >> "$cfg_file" <<'TLS'
server_tls_sslmode = prefer
server_tls_ca_file = /etc/postgresql/tls/ca.crt
server_tls_key_file = /etc/postgresql/tls/server.key
server_tls_cert_file = /etc/postgresql/tls/server.crt
TLS
      log "PgBouncer TLS parameters appended"
    fi
  fi

  # Pause/Resume helper scripts (used during switchover events in future modules)
  if [[ ! -f /usr/local/bin/pgbouncer_pause ]]; then
    cat > /usr/local/bin/pgbouncer_pause <<'PZ'
#!/bin/bash
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -Atqc "PAUSE;" >/dev/null 2>&1
PZ
    chmod +x /usr/local/bin/pgbouncer_pause
  fi
  if [[ ! -f /usr/local/bin/pgbouncer_resume ]]; then
    cat > /usr/local/bin/pgbouncer_resume <<'RS'
#!/bin/bash
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -Atqc "RESUME;" >/dev/null 2>&1
RS
    chmod +x /usr/local/bin/pgbouncer_resume
  fi

  # Metric exporter (textfile) for PgBouncer stats
  local metrics_dir="/var/lib/node_exporter/textfile_collector"
  mkdir -p "$metrics_dir"
  if [[ ! -f /usr/local/bin/pgbouncer_metrics ]]; then
    cat > /usr/local/bin/pgbouncer_metrics <<'MT'
#!/bin/bash
OUT="/var/lib/node_exporter/textfile_collector/pgbouncer.prom"
TMP=$(mktemp)
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -Atqc "SHOW STATS;" 2>/dev/null | \
awk 'BEGIN{print "# HELP pgbouncer_active_connections Active server connections";print "# TYPE pgbouncer_active_connections gauge"} {print "pgbouncer_active_connections{db=\""$1"\"}"" "$3}' >> "$TMP"
# Basic pools (pool mode aggregated)
psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -Atqc "SHOW POOLS;" 2>/dev/null | awk 'NR>0{print "pgbouncer_pool_client_connections{db=\""$1"\"}"" "$3}' >> "$TMP"
mv "$TMP" "$OUT" 2>/dev/null || true
MT
    chmod +x /usr/local/bin/pgbouncer_metrics
  fi

  # Install a simple systemd timer for metrics collection if not present
  if [[ ! -f /etc/systemd/system/pgbouncer-metrics.timer ]]; then
    cat > /etc/systemd/system/pgbouncer-metrics.service <<'UNIT'
[Unit]
Description=PgBouncer metrics exporter

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/pgbouncer_metrics
UNIT
    cat > /etc/systemd/system/pgbouncer-metrics.timer <<'TMR'
[Unit]
Description=Run PgBouncer metrics exporter every minute

[Timer]
OnBootSec=1m
OnUnitActiveSec=1m
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
TMR
    systemctl daemon-reload || true
    systemctl enable pgbouncer-metrics.timer >/dev/null 2>&1 || true
    systemctl start pgbouncer-metrics.timer >/dev/null 2>&1 || true
  fi

  touch "$BOOTSTRAP_DIR/pgbouncer_final.done"
  log "PgBouncer finalization complete"
}

setup_pgbouncer || true
finalize_pgbouncer || true

#############################################
# Module 10: ILB Role Gating for PgBouncer
#############################################
setup_pgbouncer_ilb_gating() {
  [[ "$ROLE" =~ ^(primary|standby)$ ]] || return 0
  [[ -f "$BOOTSTRAP_DIR/pgbouncer_role_gate.done" ]] && return 0

  cat > /usr/local/bin/pgbouncer_role_gate <<'RG'
#!/bin/bash
STATE_FILE="/var/lib/postgresql/pgbouncer_role_state"
CURRENT_ROLE="unknown"

# Determine if local Postgres is primary (not in recovery)
is_recovery=$(psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -Atqc 'SELECT pg_is_in_recovery();' 2>/dev/null)
if [[ "$is_recovery" == "f" ]]; then
  CURRENT_ROLE="primary"
else
  CURRENT_ROLE="standby"
fi

prev_state=""
[[ -f "$STATE_FILE" ]] && prev_state=$(cat "$STATE_FILE" 2>/dev/null || true)

if [[ "$CURRENT_ROLE" == "primary" ]]; then
  # Ensure PgBouncer active
  if ! systemctl is-active --quiet pgbouncer; then
    systemctl start pgbouncer >/dev/null 2>&1 || true
  fi
else
  # Standby: stop PgBouncer so ILB health fails
  if systemctl is-active --quiet pgbouncer; then
    systemctl stop pgbouncer >/dev/null 2>&1 || true
  fi
fi

if [[ "$prev_state" != "$CURRENT_ROLE" ]]; then
  echo "$CURRENT_ROLE" > "$STATE_FILE"
  ts=$(date -u +%s)
  echo "{\"timestamp\":$ts,\"event\":\"pgbouncer_role_gate\",\"new_role\":\"$CURRENT_ROLE\"}" >> /var/log/pg_failback_events.json 2>/dev/null || true
fi
RG
  chmod +x /usr/local/bin/pgbouncer_role_gate

  # systemd service + timer
  if [[ ! -f /etc/systemd/system/pgbouncer-role-gate.service ]]; then
    cat > /etc/systemd/system/pgbouncer-role-gate.service <<'UNIT'
[Unit]
Description=PgBouncer ILB role gating evaluator
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/pgbouncer_role_gate
UNIT
    cat > /etc/systemd/system/pgbouncer-role-gate.timer <<'TMR'
[Unit]
Description=Run PgBouncer ILB gating every 5s

[Timer]
OnBootSec=15s
OnUnitActiveSec=5s
AccuracySec=2s
Unit=pgbouncer-role-gate.service
Persistent=true

[Install]
WantedBy=timers.target
TMR
    systemctl daemon-reload || true
    systemctl enable pgbouncer-role-gate.timer >/dev/null 2>&1 || true
    systemctl start pgbouncer-role-gate.timer >/dev/null 2>&1 || true
  fi

  touch "$BOOTSTRAP_DIR/pgbouncer_role_gate.done"
  log "PgBouncer ILB role gating installed"
}

setup_pgbouncer_ilb_gating || true

log "Bootstrap process completed"
