#!/bin/bash
# HA PostgreSQL Failover / Failback Validation Helper
# Uses pg_auto_failover + PgBouncer ILB endpoint.
# Run from a bastion or any host with psql + gcloud auth that can reach the ILB IP.
#
# Requirements:
#  - psql available and PGPASSWORD exported for postgres role (or .pgpass)
#  - ILB_IP environment variable (or pass --ilb-ip)
#  - Optionally ILB_FQDN for logging clarity
#
# Functions Provided:
#   1. baseline_state            : Capture current cluster + replication status
#   2. rpo_zero_test             : Insert a TX, immediate failover, verify row exists (RPO=0)
#   3. measure_failover_rto      : Force failover and measure client outage window (RTO)
#   4. show_gating_status        : Show PgBouncer gating role events
#   5. list_backend_health       : GCP backend health (requires gcloud + region/backend name)
#   6. manual_failback_sequence  : Guidance output for initiating failback (if controller not yet auto-switched)
#
# NOTE: This script does NOT itself perform destructive operations unless you invoke
#       measure_failover_rto (which stops the primary pg_autoctl-node service) or
#       rpo_zero_test (which also triggers a failover). Review before use.
#
set -euo pipefail

ILB_IP="${ILB_IP:-}"        # e.g. 192.168.14.24
ILB_FQDN="${ILB_FQDN:-}"    # e.g. pg-ha.ha.internal.
PGPORT="${PGPORT:-6432}"
DBNAME="${DBNAME:-postgres}"
PGUSER="${PGUSER:-postgres}"
REGION="${REGION:-me-central2}"
BACKEND_SERVICE="${BACKEND_SERVICE:-ipa-nprd-ilb-pgbouncer-01-bs}"  # name must match TF
PRIMARY_HOST_HINT="${PRIMARY_HOST_HINT:-}"   # optional DNS / hostname of expected primary

usage(){ cat <<EOF
Usage: $0 <command>
Commands:
  baseline_state
  rpo_zero_test
  measure_failover_rto
  show_gating_status
  list_backend_health
  manual_failback_sequence
Environment vars:
  ILB_IP (required)  ILB_FQDN  PGPORT  PGUSER  DBNAME  REGION  BACKEND_SERVICE
Examples:
  ILB_IP=192.168.14.24 $0 baseline_state
  PGPASSWORD=secret ILB_IP=192.168.14.24 $0 measure_failover_rto
EOF
}

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 2; }; }
psql_wrap(){ psql -h "$ILB_IP" -p "$PGPORT" -U "$PGUSER" -d "$DBNAME" -Atqc "$1"; }

check_env(){ [[ -n "$ILB_IP" ]] || { echo "ILB_IP required" >&2; exit 1; }; }

baseline_state(){
  check_env
  echo "== Cluster Role Resolution via ILB ($ILB_IP:$PGPORT) =="
  need psql
  echo "Server version: $(psql_wrap 'SELECT version();')"
  echo "Transaction test: $(psql_wrap 'SELECT 1;')"
  echo "In recovery?: $(psql_wrap 'SELECT pg_is_in_recovery();')" 2>/dev/null || true
  echo "Current timeline: $(psql_wrap 'SELECT timeline_id FROM pg_control_checkpoint();' 2>/dev/null || true)"
  echo "Replication slots (count): $(psql_wrap 'SELECT count(*) FROM pg_replication_slots;' 2>/dev/null || true)"
  echo "Streaming replicas: $(psql_wrap "SELECT count(*) FROM pg_stat_replication WHERE state='streaming';" 2>/dev/null || true)"
  echo "Synchronous commit: $(psql_wrap 'SHOW synchronous_commit;' 2>/dev/null || true)"
  echo "Synchronous standby names: $(psql_wrap 'SHOW synchronous_standby_names;' 2>/dev/null || true)"
  echo "Replay lag (if standby): $(psql_wrap "SELECT CASE WHEN pg_is_in_recovery() THEN now()-pg_last_xact_replay_timestamp() END;" 2>/dev/null || true)"
}

rpo_zero_test(){
  check_env; need psql
  ts=$(date -u +%s)
  echo "== RPO=0 test inserting marker ts=$ts =="
  psql_wrap "CREATE TABLE IF NOT EXISTS ha_rpo_test(id bigint primary key, created_at timestamptz default now());" >/dev/null || true
  psql_wrap "INSERT INTO ha_rpo_test(id) VALUES ($ts);" >/dev/null
  echo "Row inserted. Forcing failover via pg_autoctl (requires access to primary host)." 
  echo "You must run on primary host: sudo systemctl stop pg_autoctl-node.service"
  echo "Then observe automatic promotion. Once new primary ready, script will verify row." 
  echo "Press Enter after initiating failover..."; read -r
  echo "Waiting for ILB to return connections with inserted row present..."
  for i in {1..180}; do
    if psql_wrap "SELECT 1 FROM ha_rpo_test WHERE id=$ts;" 2>/dev/null | grep -q 1; then
      echo "SUCCESS: Row visible post-failover (RPO=0) after $i seconds"; return 0
    fi
    sleep 1
  done
  echo "FAIL: Row not visible after 180s"; return 1
}

measure_failover_rto(){
  check_env; need psql
  echo "== Measuring failover RTO =="
  echo "This requires you manually trigger failure of current primary (stop service or power off)."
  echo "Baseline connectivity check..."; psql_wrap 'SELECT 1;' >/dev/null || { echo "Cannot reach ILB"; exit 1; }
  echo "Start continuous probe (1s interval). Trigger failover NOW." 
  start=$(date -u +%s)
  outage_started=0; outage_ended=0; last_ok=1
  for i in {1..600}; do
    if psql_wrap 'SELECT 1;' >/dev/null 2>&1; then
      if (( last_ok == 0 )); then
        outage_ended=$(date -u +%s); break
      fi
      last_ok=1
    else
      if (( last_ok == 1 )); then
        outage_started=$(date -u +%s)
        last_ok=0
      fi
    fi
    sleep 1
  done
  if (( outage_started > 0 && outage_ended > 0 )); then
    rto=$(( outage_ended - outage_started ))
    total=$(( outage_ended - start ))
    echo "Failover RTO window (connectivity loss): ${rto}s (total time until recovery ${total}s)."
  else
    echo "Unable to bound outage window (did failover occur?)."
  fi
}

show_gating_status(){
  file="/var/log/pg_failback_events.json"
  echo "== PgBouncer role gate events (requires tail on data node hosts) =="
  echo "Run on each data node: sudo grep pgbouncer_role_gate $file | tail -20" 
}

list_backend_health(){
  need gcloud; check_env
  echo "== GCP Backend Health =="
  gcloud compute backend-services get-health "$BACKEND_SERVICE" --region "$REGION" --format=json 2>/dev/null || echo "(Ensure permissions & correct backend service name)"
}

manual_failback_sequence(){
  cat <<'STEPS'
== Manual Failback Guidance ==
1. Ensure original primary is back online, fully caught up as secondary:
   psql -h <old-primary-host> -U postgres -d postgres -Atqc "SELECT pg_is_in_recovery();"  # should be t
2. Confirm replication lag < 2s on new primary for old primary node.
3. (Optional) Raise candidate priority of original primary (if failback controller not auto-handling):
   sudo -u postgres pg_autoctl set node candidate-priority 90 --pgdata /var/lib/postgresql/17/main
4. Trigger controlled switchover:
   sudo -u postgres pg_autoctl perform switchover --pgdata /var/lib/postgresql/17/main --time 60
5. Monitor state:
   sudo -u postgres pg_autoctl show state --watch --pgdata /var/lib/postgresql/17/main
6. Verify ILB now routes to reverted primary (INSERT test, check current timeline etc.).
7. Reset candidate_priority if needed for symmetry (e.g., 50 on both) post-validation.
STEPS
}

cmd="${1:-}"; [[ -z "$cmd" ]] && { usage; exit 1; }
shift || true
case "$cmd" in
  baseline_state) baseline_state;;
  rpo_zero_test) rpo_zero_test;;
  measure_failover_rto) measure_failover_rto;;
  show_gating_status) show_gating_status;;
  list_backend_health) list_backend_health;;
  manual_failback_sequence) manual_failback_sequence;;
  *) usage; exit 1;;
esac
