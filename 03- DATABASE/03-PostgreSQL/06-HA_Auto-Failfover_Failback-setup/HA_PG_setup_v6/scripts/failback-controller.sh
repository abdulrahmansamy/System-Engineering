#!/bin/bash
# Failback Controller (Module 8)
# Purpose: Automatically restore the original preferred primary (highest candidate_priority)
# when safety predicates are satisfied, avoiding flapping.
# Idempotent: Safe to run periodically (systemd timer or service with Restart=always).

set -euo pipefail

BOOTSTRAP_DIR="/var/lib/pg-bootstrap"
LOG_TAG="failback-controller"
STATE_DIR="/var/lib/pg-failback"
mkdir -p "$STATE_DIR"

log(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$LOG_TAG] $*" | systemd-cat -t $LOG_TAG || echo "$*" >&2; }

ROLE="${ROLE:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_role || echo unknown)}"
COOLDOWN_SEC="${COOLDOWN_SEC:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_controller_cooldown || echo 600)}"
PREFERRED_FLAG_FILE="$STATE_DIR/preferred_primary"   # Present only on the originally designated primary
LAST_ACTION="$STATE_DIR/last_action.ts"
FAILBACK_EVENTS="$STATE_DIR/failback_events.log"
PGDATA="/var/lib/postgresql/17/main"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
JSON_EVENTS="$STATE_DIR/failback_events.jsonl"
mkdir -p "$METRICS_DIR"

# Determine if this node is the original preferred primary by metadata candidate_priority >= 100
CANDIDATE_PRIORITY="${CANDIDATE_PRIORITY:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/candidate_priority || echo 50)}"
if (( CANDIDATE_PRIORITY >= 100 )); then
  touch "$PREFERRED_FLAG_FILE" || true
fi

[[ -f "$PREFERRED_FLAG_FILE" ]] || { log "Not preferred primary node; exiting"; exit 0; }
[[ "$ROLE" =~ ^(primary|standby)$ ]] || { log "Role $ROLE not a data node; exiting"; exit 0; }

command -v pg_autoctl >/dev/null 2>&1 || { log "pg_autoctl not installed yet"; exit 0; }
command -v psql >/dev/null 2>&1 || { log "psql not installed yet"; exit 0; }

# Helper: seconds since epoch
now_ts(){ date +%s; }

cooldown_ok() {
  [[ -f "$LAST_ACTION" ]] || return 0
  local last; last=$(cat "$LAST_ACTION" 2>/dev/null || echo 0)
  local diff=$(( $(now_ts) - last ))
  (( diff >= COOLDOWN_SEC ))
}

# Gather cluster state from pg_autoctl
get_state_table() {
  sudo -u postgres pg_autoctl show state --pgdata "$PGDATA" 2>/dev/null | awk 'NR>2' || true
}

current_primary_hostname() {
  get_state_table | awk '$3 ~ /primary/i {print $2; exit}'
}

this_hostname() { hostname -f; }

replication_lag_ok() {
  local lag
  lag=$(sudo -u postgres psql -Atqc "SELECT COALESCE(EXTRACT(EPOCH FROM now()-pg_last_xact_replay_timestamp())::int,0)" 2>/dev/null || echo 9999)
  [[ "$lag" =~ ^[0-9]+$ ]] || lag=9999
  echo "$lag" > "$STATE_DIR/current_lag.sec" 2>/dev/null || true
  (( lag == 0 )) || (( lag < 2 ))  # Accept tiny (<2s) lag threshold
}

node_min_uptime_ok() {
  local boot
  boot=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
  (( boot > 180 ))  # Require 3 minutes uptime before attempting failback
}

formation_stable() {
  # Ensure no recent failover events recorded inside cooldown window besides allowable steady state
  cooldown_ok
}

safe_window_ok() {
  # Ensure node has been registered and sync established (markers from Module 7)
  [[ -f "$BOOTSTRAP_DIR/node_registered.done" ]] || return 1
  [[ -f "$BOOTSTRAP_DIR/sync_verified.done" ]] || return 1
  return 0
}

perform_failback() {
  local ts iso
  ts=$(date +%s)
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log "Initiating controlled failback switchover to $(this_hostname)"
  if sudo -u postgres pg_autoctl perform switchover --pgdata "$PGDATA" --candidate "$(this_hostname)" >/dev/null 2>&1; then
    date +%s > "$LAST_ACTION"
    echo "$iso failback_to=$(this_hostname)" >> "$FAILBACK_EVENTS"
    printf '{"ts":"%s","action":"failback","candidate":"%s","result":"success"}\n' "$iso" "$(this_hostname)" >> "$JSON_EVENTS" 2>/dev/null || true
    log "Failback switchover command issued successfully"
  else
    printf '{"ts":"%s","action":"failback","candidate":"%s","result":"error"}\n' "$iso" "$(this_hostname)" >> "$JSON_EVENTS" 2>/dev/null || true
    log "Failback switchover command failed (will retry later)"
  fi
}

emit_metrics() {
  local mfile="$METRICS_DIR/failback_controller.prom"
  local last_ts=0 now lag=0
  now=$(date +%s)
  [[ -f "$LAST_ACTION" ]] && last_ts=$(cat "$LAST_ACTION" 2>/dev/null || echo 0)
  [[ -f "$STATE_DIR/current_lag.sec" ]] && lag=$(cat "$STATE_DIR/current_lag.sec" 2>/dev/null || echo 0)
  cat > "$mfile" <<EOF
# HELP pg_failback_seconds_since_last Seconds since last failback action
# TYPE pg_failback_seconds_since_last gauge
pg_failback_seconds_since_last $(( now - last_ts ))
# HELP pg_failback_replication_lag_seconds Current measured replication lag seconds
# TYPE pg_failback_replication_lag_seconds gauge
pg_failback_replication_lag_seconds $lag
EOF
}

main() {
  local primary
  primary=$(current_primary_hostname)
  emit_metrics || true
  if [[ -z "$primary" ]]; then
    log "No primary detected in cluster state; skipping"; return 0; fi
  if [[ "$primary" == "$(this_hostname)" ]]; then
    log "This node already primary; nothing to do"; return 0; fi

  cooldown_ok || { log "Cooldown not satisfied"; return 0; }
  node_min_uptime_ok || { log "Node uptime predicate failed"; return 0; }
  replication_lag_ok || { log "Replication lag predicate failed"; return 0; }
  formation_stable || { log "Formation stability predicate failed"; return 0; }
  safe_window_ok || { log "Safety window predicate failed (markers missing)"; return 0; }

  perform_failback
}

main

# Module 8 completion marker (idempotent)
[[ -f "$STATE_DIR/module8.complete" ]] || touch "$STATE_DIR/module8.complete"
