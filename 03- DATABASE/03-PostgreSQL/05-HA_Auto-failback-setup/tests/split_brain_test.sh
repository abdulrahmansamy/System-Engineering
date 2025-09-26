#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "$DIR/bin/helpers.sh"

OUT_DIR=${OUT_DIR:-$DIR/out}
mkdir -p "$OUT_DIR"

log "Starting split-brain test"

# Ensure test table exists via primary
ssh_node "$PRIMARY_IP" "sudo -u postgres psql -v ON_ERROR_STOP=1 -c 'CREATE TABLE IF NOT EXISTS ha_rpo(k bigserial primary key, t timestamptz default now(), v text)';"

# Partition nodes from monitor to force role instability
log "Partition data nodes from monitor"
for ip in "$PRIMARY_IP" "$STANDBY_IP"; do
  ssh_node "$ip" "sudo iptables -I OUTPUT -d ${MONITOR_IP} -j DROP; sudo iptables -I INPUT -s ${MONITOR_IP} -j DROP"
done

sleep 5

log "Check write acceptance via VIP"
WRITE_OK=0
if echo "insert into ha_rpo(v) values ('sb_test')" | eval ${PSQL} >/dev/null 2>&1; then WRITE_OK=1; fi

log "Restore connectivity"
for ip in "$PRIMARY_IP" "$STANDBY_IP"; do
  ssh_node "$ip" "sudo iptables -D OUTPUT -d ${MONITOR_IP} -j DROP 2>/dev/null || true; sudo iptables -D INPUT -s ${MONITOR_IP} -j DROP 2>/dev/null || true"
done

if [[ "$WRITE_OK" -ne 1 ]]; then
  log "Split-brain prevention OK: VIP denied writes during partition"
  echo '{"split_brain_prevented":true}' | tee "$OUT_DIR/split_brain.json"
else
  log "Split-brain risk: VIP allowed writes during partition"
  echo '{"split_brain_prevented":false}' | tee "$OUT_DIR/split_brain.json"
  exit 1
fi
