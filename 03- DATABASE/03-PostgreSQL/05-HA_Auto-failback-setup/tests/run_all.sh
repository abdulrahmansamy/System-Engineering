#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
OUT_DIR=${OUT_DIR:-$DIR/out}
mkdir -p "$OUT_DIR"

export OUT_DIR

tests=(
  "rto_rpo_test.sh"
  "split_brain_test.sh"
  "failback_test.sh"
  "perf_lag_test.sh"
)

status_ok=true

for t in "${tests[@]}"; do
  echo "==> Running $t"
  if ! bash "$DIR/$t"; then
    echo "Test $t FAILED"
    status_ok=false
  fi
done

# Aggregate
rto_rpo_json=$(cat "$OUT_DIR/rto_rpo.json" 2>/dev/null || echo '{}')
split_json=$(cat "$OUT_DIR/split_brain.json" 2>/dev/null || echo '{}')
perf_json=$(cat "$OUT_DIR/perf_lag.json" 2>/dev/null || echo '{}')
failback_json=$(cat "$OUT_DIR/failback.json" 2>/dev/null || echo '{}')

echo "{\n  \"rto_rpo\": ${rto_rpo_json},\n  \"split_brain\": ${split_json},\n  \"failback\": ${failback_json},\n  \"perf_lag\": ${perf_json}\n}" > "$OUT_DIR/summary.json"

# Lightweight markdown summary
RTO=$(jq -r '.rto_rpo.rto_ms // "n/a"' "$OUT_DIR/summary.json" 2>/dev/null || echo n/a)
RPO=$(jq -r '.rto_rpo.rpo_zero // "n/a"' "$OUT_DIR/summary.json" 2>/dev/null || echo n/a)
SB=$(jq -r '.split_brain.split_brain_prevented // "n/a"' "$OUT_DIR/summary.json" 2>/dev/null || echo n/a)
AFB=$(jq -r '.failback.auto_failback // "n/a"' "$OUT_DIR/summary.json" 2>/dev/null || echo n/a)
AVG_LAG=$(jq -r '.perf_lag.avg_lag_ms // "n/a"' "$OUT_DIR/summary.json" 2>/dev/null || echo n/a)
MAX_LAG=$(jq -r '.perf_lag.max_lag_ms // "n/a"' "$OUT_DIR/summary.json" 2>/dev/null || echo n/a)

cat > "$OUT_DIR/summary.md" <<MD
# HA Test Summary

- RTO (ms): ${RTO}
- RPO=0: ${RPO}
- Split-brain prevented: ${SB}
- Auto-failback to original primary: ${AFB}
- Avg replication lag (ms): ${AVG_LAG}
- Max replication lag (ms): ${MAX_LAG}
MD

echo "Summary written to $OUT_DIR"

if [[ "$status_ok" != "true" ]]; then
  exit 1
fi
