#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "$DIR/bin/helpers.sh"

OUT_DIR=${OUT_DIR:-$DIR/out}
mkdir -p "$OUT_DIR"

log "Starting failback test"

# Record original VIP backend
orig_backend=$(get_vip_backend_ip)
log "Original VIP backend: ${orig_backend}"

log "Stop Postgres on primary to force failover"
ssh_node "$PRIMARY_IP" "sudo systemctl stop postgresql || sudo pkill -9 -f postgres || true"

if ! wait_for_vip_rw 30000; then
  log "Failover did not complete within 30s"
  echo '{"failover_completed":false,"auto_failback":false}' | tee "$OUT_DIR/failback.json"
  exit 1
fi

new_backend=$(get_vip_backend_ip)
log "New VIP backend after failover: ${new_backend}"

log "Start Postgres on original primary and wait for rejoin"
ssh_node "$PRIMARY_IP" "sudo systemctl start postgresql"

# Wait up to 2 minutes for auto-failback
end=$(( $(ts) + 120000 ))
auto=false
while (( $(ts) < end )); do
  curr=$(get_vip_backend_ip)
  if [[ "$curr" == "$PRIMARY_IP" ]]; then auto=true; break; fi
  sleep 2
done

echo "{\n  \"failover_completed\": true,\n  \"auto_failback\": ${auto}\n}" | tee "$OUT_DIR/failback.json"
log "Failback test result: $(cat "$OUT_DIR/failback.json")"
