#!/usr/bin/env bash
set -euo pipefail

# Config via env vars with sensible defaults
: "${SSH_USER:=ubuntu}"
: "${SSH_OPTS:=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"
: "${PRIMARY_IP:=192.168.24.21}"
: "${STANDBY_IP:=192.168.24.22}"
: "${MONITOR_IP:=192.168.24.23}"
: "${VIP_IP:=192.168.24.24}"
: "${PG_PORT:=5432}"
: "${PGBOUNCER_PORT:=6432}"
: "${DB_NAME:=postgres}"
: "${DB_USER:=postgres}"
: "${DB_PASSWORD:=}"
: "${SSL_MODE:=require}"

export PSQL="psql 'sslmode=${SSL_MODE} host=${VIP_IP} port=${PGBOUNCER_PORT} dbname=${DB_NAME} user=${DB_USER}' -Atqc"

# Pass password to psql if provided
if [[ -n "${DB_PASSWORD}" ]]; then export PGPASSWORD="${DB_PASSWORD}"; fi

# Portable millisecond timestamp and logger for macOS/BSD
ts(){ python3 - <<'PY'
import time; print(int(time.time()*1000))
PY
}
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S%z')] $*"; }

get_vip_backend_ip(){
  echo "select inet_server_addr();" | eval ${PSQL} 2>/dev/null | tr -d '\r' | head -n1 || true
}

ssh_node(){
  local host="$1"; shift
  ssh ${SSH_OPTS} ${SSH_USER}@${host} "$@"
}

scp_node(){
  local src="$1" dst_host="$2" dst_path="$3"
  scp ${SSH_OPTS} "$src" ${SSH_USER}@${dst_host}:"$dst_path"
}

wait_for_vip_rw(){
  local timeout_ms=${1:-30000}
  local start=$(ts)
  while true; do
    if echo "select 1;" | eval ${PSQL} >/dev/null 2>&1; then
      # Try a write via small temp table
      if echo "create table if not exists ha_test_probe(id int); insert into ha_test_probe values (1) on conflict do nothing;" | eval ${PSQL} >/dev/null 2>&1; then
        return 0
      fi
    fi
    if (( $(ts) - start > timeout_ms )); then return 1; fi
    sleep 0.2
  done
}

get_role(){
  local node_ip="$1"
  ssh_node "$node_ip" "pg_autoctl show state --json 2>/dev/null | jq -r '.nodes[] | select(.name==\"default\" or .name).reportedState' | head -n1" 2>/dev/null || true
}

get_replication_delay_ms(){
  # Query primary for replication delay in ms (uses pg_stat_replication write_lag)
  ssh_node "$PRIMARY_IP" "sudo -u postgres psql -Atqc \"select coalesce(extract(epoch from write_lag)*1000,0) from pg_stat_replication limit 1;\"" 2>/dev/null || echo 0
}
