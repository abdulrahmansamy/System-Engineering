#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "$DIR/bin/helpers.sh"

OUT_DIR=${OUT_DIR:-$DIR/out}
mkdir -p "$OUT_DIR"

log "Starting RTO/RPO test"

# Prepare a test table and start a writer loop
WRITER_START=$(ts)
ssh_node "$PRIMARY_IP" "sudo -u postgres psql -v ON_ERROR_STOP=1 -c 'CREATE TABLE IF NOT EXISTS ha_rpo(k bigserial primary key, t timestamptz default now(), v text)';"

log "Start background writer"
ssh_node "$PRIMARY_IP" "nohup bash -c 'while true; do psql -Atqc \"insert into ha_rpo(v) values (md5(random()::text))\" >/dev/null; sleep 0.01; done' >/tmp/writer.log 2>&1 & echo $! > /tmp/writer.pid"
sleep 2

BEFORE_FAIL_TS=$(ssh_node "$PRIMARY_IP" "sudo -u postgres psql -Atqc 'select coalesce(max(k),0) from ha_rpo'" | tr -d '\r')

log "Simulate primary crash"
FAIL_START=$(ts)
ssh_node "$PRIMARY_IP" "sudo systemctl stop postgresql || sudo pkill -9 -f postgres || true"

log "Wait for VIP to become writable"
if wait_for_vip_rw 30000; then
  RTO_MS=$(( $(ts) - FAIL_START ))
else
  log "RTO exceed 30s"
  RTO_MS=999999
fi

AFTER_FAIL_TS=$(echo "select coalesce(max(k),0) from ha_rpo" | eval ${PSQL} | tr -d '\r' || echo 0)

RPO_OK="false"
if [[ "$AFTER_FAIL_TS" -ge "$BEFORE_FAIL_TS" ]]; then RPO_OK="true"; fi

echo "{\n  \"rto_ms\": $RTO_MS,\n  \"rpo_zero\": $RPO_OK,\n  \"before_k\": $BEFORE_FAIL_TS,\n  \"after_k\": $AFTER_FAIL_TS\n}" > "$OUT_DIR/rto_rpo.json"
log "RTO/RPO result: $(cat "$OUT_DIR/rto_rpo.json")"

# Cleanup writer on old primary if still running
ssh_node "$PRIMARY_IP" "kill \\$(cat /tmp/writer.pid 2>/dev/null) 2>/dev/null || true"

log "RTO/RPO test complete"
