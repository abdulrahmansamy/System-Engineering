#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "$DIR/bin/helpers.sh"

OUT_DIR=${OUT_DIR:-$DIR/out}
mkdir -p "$OUT_DIR"

log "Starting performance/lag test"

# Ensure pgbench installed on primary, init db, then run for short time
ssh_node "$PRIMARY_IP" "sudo apt-get update -y && sudo apt-get install -y postgresql-client-common postgresql-client && command -v pgbench >/dev/null || sudo apt-get install -y postgresql-contrib"

log "Initialize pgbench schema"
echo "create extension if not exists pg_stat_statements;" | eval ${PSQL} >/dev/null 2>&1 || true
ssh_node "$PRIMARY_IP" "pgbench -i -s 5 -h ${VIP_IP} -p ${PGBOUNCER_PORT} -U ${DB_USER} ${DB_NAME} >/dev/null 2>&1 || true"

log "Run pgbench load for 60s via VIP"
ssh_node "$PRIMARY_IP" "pgbench -T 60 -c 10 -j 4 -h ${VIP_IP} -p ${PGBOUNCER_PORT} -U ${DB_USER} ${DB_NAME} > /tmp/pgbench.out 2>&1 & echo $! > /tmp/pgbench.pid"

SAMPLES=0
TOTAL_LAG=0
MAX_LAG=0
while kill -0 $(ssh_node "$PRIMARY_IP" "cat /tmp/pgbench.pid") 2>/dev/null; do
  lag_ms=$(get_replication_delay_ms)
  TOTAL_LAG=$((TOTAL_LAG + lag_ms))
  (( lag_ms > MAX_LAG )) && MAX_LAG=$lag_ms || true
  ((SAMPLES++))
  sleep 1
done

AVG_LAG=$(( SAMPLES > 0 ? TOTAL_LAG / SAMPLES : 0 ))

echo "{\n  \"avg_lag_ms\": ${AVG_LAG},\n  \"max_lag_ms\": ${MAX_LAG},\n  \"samples\": ${SAMPLES}\n}" | tee "$OUT_DIR/perf_lag.json"
log "Perf/lag result: $(cat "$OUT_DIR/perf_lag.json")"

log "Performance/lag test complete"
