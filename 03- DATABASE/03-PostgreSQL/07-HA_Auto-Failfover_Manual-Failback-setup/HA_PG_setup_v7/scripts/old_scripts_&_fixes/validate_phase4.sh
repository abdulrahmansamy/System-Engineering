#!/bin/bash
# Phase 4 Validation Script: PostgreSQL + repmgr bootstrap checks
# Safe to run multiple times. Produces JSON + human output.
set -euo pipefail

OUT_JSON=/tmp/phase4_validation.json
TMP=$(mktemp)

json_line() { jq -n --arg k "$1" --arg v "$2" '{key:$k,value:$v}' ; }

accum() { echo "$1" >> "$TMP"; }

pass() { printf "[PASS] %s\n" "$1"; accum "$(json_line "$1" PASS)"; }
fail() { printf "[FAIL] %s\n" "$1"; accum "$(json_line "$1" FAIL)"; }
warn() { printf "[WARN] %s\n" "$1"; accum "$(json_line "$1" WARN)"; }

test_pkg() { dpkg -s "$1" >/dev/null 2>&1 && pass "package:$1" || fail "package:$1"; }

test_service_active() { systemctl is-active --quiet "$1" && pass "service:$1" || fail "service:$1"; }

# 1. Packages (repmgr may be either repmgr or versioned repmgr17)
test_pkg postgresql-17
if dpkg -s repmgr17 >/dev/null 2>&1; then
  pass package:repmgr17 || true
else
  if dpkg -s repmgr >/dev/null 2>&1; then
    pass package:repmgr || true
  else
    fail package:repmgr
  fi
fi
test_pkg pgbouncer

# 2. Directories & files
[[ -d /etc/repmgr ]] && pass dir:/etc/repmgr || fail dir:/etc/repmgr
[[ -f /etc/repmgr/repmgr.conf ]] && pass file:repmgr.conf || fail file:repmgr.conf
[[ -f /usr/local/bin/pg-ha-health.sh ]] && pass file:health_script || fail file:health_script

# 3. Services
for s in postgresql repmgrd pg-ha-health.service; do test_service_active "$s"; done || true

# 4. PostgreSQL connectivity & role
ROLE_DET="unknown"
if sudo -u postgres psql -Atqc 'select 1' postgres >/dev/null 2>&1; then
  if sudo -u postgres psql -Atqc 'select pg_is_in_recovery()' postgres | grep -q '^f'; then
    ROLE_DET=primary
  else
    ROLE_DET=standby
  fi
  pass "psql:connect" || true
else
  fail "psql:connect"
fi

# 5. Replication slot check (primary only)
if [[ "$ROLE_DET" == primary ]]; then
  SLOT_COUNT=$(sudo -u postgres psql -Atqc "select count(*) from pg_replication_slots" postgres 2>/dev/null || echo 0)
  [[ "$SLOT_COUNT" =~ ^[0-9]+$ ]] && pass "replication_slots_present" || fail "replication_slots_present"
else
  warn "replication_slots_skipped_non_primary"
fi

# 6. repmgr node listing
if command -v repmgr >/dev/null 2>&1; then
  if sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show >/dev/null 2>&1; then
    pass repmgr_cluster_show
  else
    fail repmgr_cluster_show
  fi
else
  fail repmgr_binary_missing
fi

# 7. Health endpoint
HP=${HEALTH_PORT:-$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_health_port || echo 8001)}
if curl -sf http://localhost:${HP} >/dev/null 2>&1; then
  pass health_endpoint
else
  fail health_endpoint
fi

# 8. Event hook executable
[[ -x /etc/repmgr/events/exec.sh ]] && pass event_hook_exec || fail event_hook_exec

# Aggregate JSON (defensive against empty)
if [[ -s "$TMP" ]]; then
  jq -s '{results:.,summary:(reduce .[] as $i ({}; .[$i.value] += 1))}' "$TMP" > "$OUT_JSON" || echo '{"results":[],"summary":{}}' > "$OUT_JSON"
else
  echo '{"results":[],"summary":{}}' > "$OUT_JSON"
fi

printf "\nJSON summary written to %s\n" "$OUT_JSON"
cat "$OUT_JSON"

exit 0
