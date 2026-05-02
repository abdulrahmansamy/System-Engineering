#!/usr/bin/env bash
set -euo pipefail

########################################
# PostgreSQL HA Configuration Audit Script
########################################
#
# PURPOSE:
#   This script performs a comprehensive READ-ONLY audit of PostgreSQL High Availability
#   configurations including replication, failover tools (Patroni/repmgr), and PgBouncer.
#   It collects configuration files, runtime settings, and system state WITHOUT making
#   any modifications to the running system.
#
# SAFETY:
#   - This script is 100% READ-ONLY and will NOT modify any configuration files
#   - No PostgreSQL parameters are changed
#   - No services are started, stopped, or restarted
#   - Only queries database for runtime information (SELECT/SHOW commands only)
#   - All output is written to a timestamped directory in the current working directory
#
# WHAT IT COLLECTS:
#   - PostgreSQL configuration files (postgresql.conf, pg_hba.conf, pg_ident.conf)
#   - Include directories and all included configuration files
#   - Streaming replication settings and status
#   - Replication slots information
#   - PgBouncer configuration (if present)
#   - Patroni configuration (if present)
#   - repmgr configuration (if present)
#   - systemd service units and overrides
#   - File permissions and ownership
#   - Process command lines
#
# OUTPUT:
#   Creates a timestamped directory containing:
#   - audit.log: Detailed execution log with timestamps
#   - report.txt: Human-readable audit report
#
# REQUIREMENTS:
#   - psql must be available and able to connect to the local PostgreSQL instance
#   - pg_config should be available (for baseline path detection)
#   - Read access to PostgreSQL configuration files and data directory
#   - Optional: sudo access for fallback psql execution (if current user cannot connect)
#
# USAGE:
#   ./pgsql_ha_config_audit_v2.0.sh
#
# EXIT CODES:
#   0 - Success
#   1 - Fatal error (e.g., psql not found)
#
########################################

########################################
# Output and logging
########################################

# Create timestamped output directory for all audit artifacts
OUTPUT_DIR="./pgsql_ha_audit_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

LOG_FILE="$OUTPUT_DIR/audit.log"
REPORT_FILE="$OUTPUT_DIR/report.txt"

#
# Function: ts
# Purpose: Generate ISO-8601 UTC timestamp for log entries
# Returns: Timestamp string in format YYYY-MM-DDTHH:MM:SSZ
#
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

#
# Function: log
# Purpose: Write structured log messages to audit.log with timestamp and severity level
# Arguments:
#   $1 - Log level (INFO|WARN|ERROR|DEBUG|SUCCESS) - optional, defaults to INFO
#   $@ - Log message
# Output: Writes to LOG_FILE only (not displayed on console)
# Note: This is for internal logging; user-facing output goes through tee_report
#
log() {
  case "${1:-}" in
    INFO|WARN|ERROR|DEBUG|SUCCESS) lvl="$1"; shift; msg="$*" ;;
    *) lvl=INFO; msg="$*" ;;
  esac
  local line
  line="$(ts) [$lvl] $msg"
  echo "$line" >> "$LOG_FILE"
}

#
# Function: tee_report
# Purpose: Pipe function to write data to both report file and stdout
# Input: Reads from stdin
# Output: Writes to REPORT_FILE and stdout (for user visibility)
# Usage: command | tee_report
#
tee_report() {
  # Read stdin, append to report, and also print to stdout
  tee -a "$REPORT_FILE"
}

########################################
# Helpers
########################################

#
# Function: have_cmd
# Purpose: Check if a command exists in PATH
# Arguments: $1 - Command name to check
# Returns: 0 if command exists, 1 otherwise
# Note: READ-ONLY check, no execution
#
have_cmd() { command -v "$1" >/dev/null 2>&1; }

#
# Function: safe_stat
# Purpose: Safely get file/directory metadata without failing on missing paths
# Arguments: $1 - Path to file or directory
# Output: stat output or error message
# Note: READ-ONLY operation
#
safe_stat() {
  local path="$1"
  if [[ -e "$path" ]]; then
    stat "$path"
  else
    echo "stat: cannot stat '$path': No such file or directory"
  fi
}

#
# Function: dump_file
# Purpose: Read and display contents of a configuration file with metadata
# Arguments: $1 - Path to file
# Output: File metadata (via stat) and contents, written to report
# Note: READ-ONLY operation - only reads file contents, never writes
#
dump_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    log INFO "Dumping file: $file"
    {
      echo "----- FILE: $file -----"
      safe_stat "$file"
      echo
      sed 's/^/    /' "$file"  # Indent file contents for readability
      echo
    } | tee_report
  else
    log WARN "File not found or not a regular file: $file"
  fi
}

#
# Function: dump_dir
# Purpose: Recursively scan a directory and dump all configuration files found
# Arguments: $1 - Directory path to scan
# Output: Contents of all files found (max depth 2), written to report
# Note: READ-ONLY operation - only reads files, never modifies
#
dump_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    log INFO "Scanning directory: $dir"
    {
      echo "----- DIRECTORY: $dir -----"
      find "$dir" -maxdepth 2 -type f 2>/dev/null | sort | while read -r f; do
        echo "----- FILE: $f -----"
        safe_stat "$f"
        echo
        sed 's/^/    /' "$f" 2>/dev/null || true
        echo
      done
    } | tee_report
  else
    log DEBUG "Directory not present: $dir"
  fi
}

#
# Function: append_section
# Purpose: Add a formatted section header to the audit report
# Arguments: $1 - Section title
# Output: Formatted section header written to report
#
append_section() {
  local title="$1"
  log INFO "$title"
  {
    echo
    echo "=== $title ==="
  } | tee_report
}

#
# Function: psqlq
# Purpose: Execute a PostgreSQL query in a safe, read-only manner
# Arguments: $1 - SQL query to execute (should be SELECT/SHOW only)
# Returns: Query results or error
# Note: READ-ONLY - only executes SELECT/SHOW queries, never modifies data
#       Tries current user first, falls back to sudo -u postgres if needed
# Safety: Caller is responsible for ensuring only read-only queries are passed
#
psqlq() {
  # Prefer running as current user; if that fails, try via sudo -u postgres when available.
  local sql="$1"
  if psql -Atqc "$sql" >/dev/null 2>&1; then
    psql -Atqc "$sql"
    return 0
  fi

  if have_cmd sudo; then
    if sudo -n -u postgres psql -Atqc "$sql" >/dev/null 2>&1; then
      log WARN "psql required sudo -u postgres for query execution"
      sudo -n -u postgres psql -Atqc "$sql"
      return 0
    fi
  fi

  log ERROR "Unable to execute psql query (insufficient privileges or no local access)"
  return 1
}

########################################
# Header
########################################

# Initialize empty log and report files (overwrites any existing files with same timestamp)
: > "$LOG_FILE"
: > "$REPORT_FILE"

log INFO "Starting PostgreSQL HA configuration audit"
{
  echo "=== PostgreSQL HA Configuration Audit ==="
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Hostname: $(hostname)"
  echo "User: $(id -un) (uid=$(id -u))"
  echo "Kernel: $(uname -srmo 2>/dev/null || uname -a)"
  echo
  echo "NOTE: This audit is completely READ-ONLY and will NOT modify any configuration."
} | tee_report

########################################
# Requirements
########################################

# Check for required and optional commands
append_section "Command availability"

{
  echo "psql:      $(command -v psql 2>/dev/null || echo 'NOT FOUND')"
  echo "pg_config: $(command -v pg_config 2>/dev/null || echo 'NOT FOUND')"
  echo "systemctl: $(command -v systemctl 2>/dev/null || echo 'NOT FOUND')"
  echo "sudo:      $(command -v sudo 2>/dev/null || echo 'NOT FOUND')"
} | tee_report

# Abort if psql is not available (critical requirement)
if ! have_cmd psql; then
  log ERROR "psql not found; cannot discover runtime config paths"
  exit 1
fi

########################################
# Derive default baselines
########################################

# Establish baseline paths based on PostgreSQL installation defaults
# These are used later to detect non-standard configurations
append_section "Default location baselines"

DEFAULT_PG_CONF_DIR="$(pg_config --sysconfdir 2>/dev/null || true)"
DEFAULT_PGDATA_PARENT="$(pg_config --localstatedir 2>/dev/null || true)"
DEFAULT_PGDATA="${DEFAULT_PGDATA_PARENT}/lib/pgsql/data"

DEFAULT_PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"
DEFAULT_PGBOUNCER_USERS="/etc/pgbouncer/userlist.txt"

{
  echo "DEFAULT_PG_CONF_DIR: ${DEFAULT_PG_CONF_DIR:-'(unknown)'}"
  echo "DEFAULT_PGDATA:      ${DEFAULT_PGDATA:-'(unknown)'}"
  echo "DEFAULT_PGBOUNCER_CONF: $DEFAULT_PGBOUNCER_CONF"
  echo "DEFAULT_PGBOUNCER_USERS: $DEFAULT_PGBOUNCER_USERS"
} | tee_report

########################################
# PostgreSQL runtime discovery
########################################

# Query the running PostgreSQL instance to discover actual configuration paths
# This is more reliable than assuming default locations
append_section "PostgreSQL runtime discovery"

PGDATA="$(psqlq "SHOW data_directory;")"
PGCONF="$(psqlq "SHOW config_file;")"
HBA="$(psqlq "SHOW hba_file;")"
IDENT="$(psqlq "SHOW ident_file;")"

AUTO_CONF="${PGDATA%/}/postgresql.auto.conf"

{
  echo "PGDATA:        $PGDATA"
  echo "config_file:   $PGCONF"
  echo "hba_file:      $HBA"
  echo "ident_file:    $IDENT"
  echo "auto_conf:     $AUTO_CONF"
} | tee_report

log INFO "PGDATA resolved to $PGDATA"
log INFO "postgresql.conf resolved to $PGCONF"
log INFO "pg_hba.conf resolved to $HBA"
log INFO "pg_ident.conf resolved to $IDENT"

# Compare actual paths against expected defaults to flag non-standard configurations
# Deviation checks (best-effort; defaults vary by distro)
if [[ -n "${DEFAULT_PG_CONF_DIR:-}" ]]; then
  if [[ "$PGCONF" != "$DEFAULT_PG_CONF_DIR/postgresql.conf" ]]; then
    log WARN "postgresql.conf is NOT in default location (expected $DEFAULT_PG_CONF_DIR/postgresql.conf)"
  else
    log SUCCESS "postgresql.conf matches default location"
  fi
else
  log WARN "DEFAULT_PG_CONF_DIR unknown; cannot assert default postgresql.conf location"
fi

if [[ -n "${DEFAULT_PGDATA:-}" ]]; then
  [[ "$PGDATA" != "$DEFAULT_PGDATA" ]] && log WARN "PGDATA directory is NOT default (expected $DEFAULT_PGDATA)" || log SUCCESS "PGDATA matches default location"
else
  log WARN "DEFAULT_PGDATA unknown; cannot assert default PGDATA location"
fi

[[ "$HBA" != "${PGDATA%/}/pg_hba.conf" ]] && log WARN "pg_hba.conf is NOT in PGDATA (expected ${PGDATA%/}/pg_hba.conf)"
[[ "$IDENT" != "${PGDATA%/}/pg_ident.conf" ]] && log WARN "pg_ident.conf is NOT in PGDATA (expected ${PGDATA%/}/pg_ident.conf)"

########################################
# Dump core PostgreSQL config files
########################################

# Read and archive the main PostgreSQL configuration files
append_section "PostgreSQL core configuration files"

dump_file "$PGCONF"
dump_file "$HBA"
dump_file "$IDENT"
dump_file "$AUTO_CONF"

########################################
# Include directory and included files discovery
########################################

# PostgreSQL supports include directives to load additional config files
# Parse these directives and recursively collect all included configurations
append_section "Included configuration directives and discovered include files"

#
# Function: extract_includes
# Purpose: Parse a PostgreSQL config file for include/include_dir directives
# Arguments: $1 - Path to config file
# Output: Lines containing include directives (comments stripped)
# Note: READ-ONLY operation
#
extract_includes() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # capture include / include_if_exists / include_dir, stripping comments
  sed -E 's/[[:space:]]*#.*$//' "$f" \
    | grep -E '^[[:space:]]*(include|include_if_exists|include_dir)[[:space:]]*=' \
    || true
}

INCLUDE_LINES="$( (extract_includes "$PGCONF"; extract_includes "$AUTO_CONF") 2>/dev/null || true )"

if [[ -z "$INCLUDE_LINES" ]]; then
  log INFO "No include/include_dir directives found (or files unreadable)"
  echo "    (none found)" | tee_report
else
  echo "$INCLUDE_LINES" | sed 's/^/    /' | tee_report
  log INFO "Found include directives; attempting to resolve included paths"

  # Resolve include_dir values (relative to dirname(PGCONF) if relative)
  CONF_DIR="$(dirname "$PGCONF")"

  # Process each include directive and collect the referenced files
  while IFS= read -r line; do
    # Split key and value
    key="$(echo "$line" | awk -F= '{gsub(/[[:space:]]/,"",$1); print $1}')"
    val="$(echo "$line" | awk -F= '{sub(/^[^=]*=/,""); print $0}')"
    # Trim spaces and quotes
    val="$(echo "$val" | sed -E "s/^[[:space:]]*//; s/[[:space:]]*$//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/")"

    case "$key" in
      include_dir)
        dir="$val"
        [[ "$dir" != /* ]] && dir="$CONF_DIR/$dir"
        log INFO "Resolving include_dir: $dir"
        dump_dir "$dir"
        ;;
      include|include_if_exists)
        fpath="$val"
        [[ "$fpath" != /* ]] && fpath="$CONF_DIR/$fpath"
        log INFO "Resolving $key: $fpath"
        dump_file "$fpath"
        ;;
    esac
  done <<< "$INCLUDE_LINES"
fi

########################################
# Streaming replication and HA-relevant settings
########################################

# Query PostgreSQL for settings that affect replication and high availability
# These parameters control streaming replication, archiving, and synchronization
append_section "Streaming replication and HA-relevant settings"

psqlq "
SELECT name || ' = ' || setting
FROM pg_settings
WHERE name IN (
  'cluster_name',
  'listen_addresses',
  'port',
  'wal_level',
  'max_wal_senders',
  'max_replication_slots',
  'wal_keep_size',
  'hot_standby',
  'primary_conninfo',
  'primary_slot_name',
  'restore_command',
  'archive_mode',
  'archive_command',
  'synchronous_commit',
  'synchronous_standby_names'
)
ORDER BY name;
" | sed 's/^/    /' | tee_report

PRIMARY_CONNINFO="$(psqlq "SHOW primary_conninfo;" || true)"
RESTORE_CMD="$(psqlq "SHOW restore_command;" || true)"

[[ -n "${PRIMARY_CONNINFO:-}" ]] && log INFO "primary_conninfo is configured"
[[ -n "${RESTORE_CMD:-}" ]] && log INFO "restore_command is configured"

########################################
# Replication status (best effort)
########################################

# Query runtime replication status from both primary and replica perspectives
# This shows active replication connections and their lag/status
append_section "Replication status snapshots"

# Primary-side view
{
  echo "-- pg_stat_replication (primary-side; may be empty on replicas) --"
  psqlq "SELECT application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;" 2>/dev/null \
    | sed 's/^/    /' || true
  echo
  echo "-- pg_stat_wal_receiver (replica-side; may be empty on primary) --"
  psqlq "SELECT status, receive_start_lsn, received_lsn, latest_end_lsn, last_msg_send_time, last_msg_receipt_time FROM pg_stat_wal_receiver;" 2>/dev/null \
    | sed 's/^/    /' || true
} | tee_report

########################################
# Replication slots
########################################

# List all replication slots (used for guaranteed WAL retention)
# Important for monitoring slot lag and preventing disk space issues
append_section "Replication slots"

psqlq "SELECT slot_name, slot_type, active, restart_lsn, wal_status FROM pg_replication_slots;" \
  | sed 's/^/    /' | tee_report

########################################
# Standby signal / recovery hints
########################################

# Check for files that indicate replica status or recovery mode
# standby.signal marks a replica, recovery.conf is legacy (pre-PG12)
append_section "Standby/replica indicator files"

STANDBY_SIGNAL="${PGDATA%/}/standby.signal"
RECOVERY_SIGNAL="${PGDATA%/}/recovery.signal"
RECOVERY_CONF="${PGDATA%/}/recovery.conf"  # legacy

for f in "$STANDBY_SIGNAL" "$RECOVERY_SIGNAL" "$RECOVERY_CONF"; do
  if [[ -e "$f" ]]; then
    log INFO "Found indicator: $f"
    {
      echo "----- INDICATOR: $f -----"
      safe_stat "$f"
      echo
    } | tee_report
  else
    log DEBUG "Not present: $f"
  fi
done

########################################
# PgBouncer detection and config dump
########################################

# PgBouncer is a connection pooler often used in HA setups
# Locate and collect its configuration files
append_section "PgBouncer configuration"

FOUND_PGBOUNCER_CONFS=()

if [[ -f "$DEFAULT_PGBOUNCER_CONF" ]]; then
  log SUCCESS "PgBouncer config found at default location: $DEFAULT_PGBOUNCER_CONF"
  FOUND_PGBOUNCER_CONFS+=("$DEFAULT_PGBOUNCER_CONF")
else
  log WARN "PgBouncer default config not found at $DEFAULT_PGBOUNCER_CONF"
  # Best-effort discovery
  while IFS= read -r f; do
    [[ -n "$f" ]] && FOUND_PGBOUNCER_CONFS+=("$f")
  done < <(find /etc -maxdepth 4 -type f -name 'pgbouncer.ini' 2>/dev/null | sort || true)

  if [[ "${#FOUND_PGBOUNCER_CONFS[@]}" -gt 0 ]]; then
    log WARN "PgBouncer config found at NON-default locations: ${FOUND_PGBOUNCER_CONFS[*]}"
  else
    log WARN "PgBouncer config not found under /etc"
  fi
fi

for f in "${FOUND_PGBOUNCER_CONFS[@]:-}"; do
  dump_file "$f"
done

if [[ -f "$DEFAULT_PGBOUNCER_USERS" ]]; then
  dump_file "$DEFAULT_PGBOUNCER_USERS"
else
  # find userlist if exists
  FOUND_USERS="$(find /etc -maxdepth 4 -type f -name 'userlist.txt' 2>/dev/null | grep -i pgbouncer | head -n 5 || true)"
  if [[ -n "$FOUND_USERS" ]]; then
    log WARN "PgBouncer userlist.txt not in default location; candidates:"
    echo "$FOUND_USERS" | sed 's/^/    /' | tee_report
    while IFS= read -r uf; do
      [[ -n "$uf" ]] && dump_file "$uf"
    done <<< "$FOUND_USERS"
  else
    log WARN "PgBouncer userlist.txt not found"
  fi
fi

########################################
# HA tooling: Patroni / repmgr
########################################

# Patroni and repmgr are popular HA/failover management tools
# Collect their configurations if present

append_section "Patroni configuration"

dump_dir /etc/patroni
dump_dir /var/lib/patroni

append_section "repmgr configuration"

# Default-ish locations (vary by distro)
dump_file /etc/repmgr.conf
dump_dir /etc/repmgr

# Non-default discovery (best-effort)
FOUND_REPMGR="$(find /etc -maxdepth 6 -type f -name 'repmgr.conf' 2>/dev/null | grep -v '^/etc/repmgr\.conf$' || true)"
if [[ -n "$FOUND_REPMGR" ]]; then
  log WARN "repmgr.conf found at NON-default location(s):"
  echo "$FOUND_REPMGR" | sed 's/^/    /' | tee_report
  while IFS= read -r rf; do
    [[ -n "$rf" ]] && dump_file "$rf"
  done <<< "$FOUND_REPMGR"
fi

########################################
# systemd units and overrides
########################################

# Collect systemd service configurations and overrides
# Important for understanding how services are started and managed
append_section "systemd unit overrides and detected services"

dump_dir /etc/systemd/system/postgresql.service.d
# glob might not expand; handle safely
for d in /etc/systemd/system/postgresql@*.service.d; do
  [[ -d "$d" ]] && dump_dir "$d"
done

if have_cmd systemctl; then
  {
    echo "-- systemctl list-units (filtered) --"
    systemctl list-units --type=service --all 2>/dev/null \
      | egrep -i 'postgres|postgresql|patroni|repmgr|pgbouncer' \
      | sed 's/^/    /' || true
  } | tee_report
else
  log DEBUG "systemctl not available; skipping service enumeration"
fi

########################################
# Non-default config-file detection via process args (best effort)
########################################

# Inspect running process command lines to detect non-default config paths
# Useful when PostgreSQL is started with custom -D or -c options
append_section "Process argument inspection for non-default config paths"

# This is useful when postgresql.conf is passed via -c config_file=... or -D ...
if have_cmd ps; then
  {
    echo "-- postgres/postgresql processes (command lines) --"
    ps -eo pid,user,cmd 2>/dev/null | egrep -i 'postgres|postmaster|pgbouncer|patroni|repmgr' | sed 's/^/    /' || true
  } | tee_report

  POSTGRES_CMDLINES="$(ps -eo cmd 2>/dev/null | egrep -i 'postgres|postmaster' || true)"
  if echo "$POSTGRES_CMDLINES" | grep -qE -- '-c[[:space:]]+config_file=|config_file='; then
    log WARN "Detected postgres process using explicit config_file override in command line"
  fi
  if echo "$POSTGRES_CMDLINES" | grep -qE -- ' -D[[:space:]]+'; then
    log INFO "Detected postgres process specifying -D (data directory) on command line"
  fi
else
  log DEBUG "ps not available; skipping process inspection"
fi

########################################
# Permissions summary
########################################

# Collect file ownership and permissions for security audit
# Important for ensuring proper access controls
append_section "Permissions and ownership summary"

log INFO "Collecting permission and ownership metadata for key paths"

# Build a candidate list; only include existing roots
CANDIDATE_ROOTS=()
[[ -d "$PGDATA" ]] && CANDIDATE_ROOTS+=("$PGDATA")
[[ -f "$PGCONF" ]] && CANDIDATE_ROOTS+=("$PGCONF")
[[ -f "$HBA" ]] && CANDIDATE_ROOTS+=("$HBA")
[[ -f "$IDENT" ]] && CANDIDATE_ROOTS+=("$IDENT")
[[ -d /etc/pgbouncer ]] && CANDIDATE_ROOTS+=("/etc/pgbouncer")
[[ -d /etc/patroni ]] && CANDIDATE_ROOTS+=("/etc/patroni")
[[ -d /etc/repmgr ]] && CANDIDATE_ROOTS+=("/etc/repmgr")

if [[ "${#CANDIDATE_ROOTS[@]}" -eq 0 ]]; then
  log WARN "No candidate roots found for permission scan"
  echo "    (no roots found)" | tee_report
else
  {
    printf "Roots scanned:\n"
    for r in "${CANDIDATE_ROOTS[@]}"; do
      echo "    $r"
    done
    echo
    echo "-- stat (mode owner:group path) --"
  } | tee_report

  # stat format differs on macOS; assume Linux here (HA pgsql usually)
  find "${CANDIDATE_ROOTS[@]}" -maxdepth 4 -type f 2>/dev/null \
    -exec stat --format '%A %U:%G %n' {} \; \
    | sort | tee_report

  # Also append to structured log for machine parsing
  find "${CANDIDATE_ROOTS[@]}" -maxdepth 4 -type f 2>/dev/null \
    -exec stat --format '%A %U:%G %n' {} \; \
    | sort >> "$LOG_FILE" || true
fi

########################################
# Finish
########################################

append_section "Audit complete"

log SUCCESS "Audit complete; output directory: $OUTPUT_DIR"
{
  echo
  echo "====================================================================="
  echo "AUDIT COMPLETED SUCCESSFULLY"
  echo "====================================================================="
  echo
  echo "Output directory: $OUTPUT_DIR"
  echo "Report file:      $REPORT_FILE"
  echo "Log file:         $LOG_FILE"
  echo
  echo "This audit was READ-ONLY and made no changes to your system."
  echo "You can safely review the collected configuration files in the"
  echo "output directory without any risk to your running setup."
  echo
} | tee_report
