#!/bin/bash
set -euo pipefail

LOG="/var/log/pgbouncer-setup.log"
ts(){ date --rfc-3339=seconds; }
log(){ echo -e "[$(ts)] [INFO] $*" | tee -a "$LOG"; }
warn(){ echo -e "[$(ts)] [WARN] $*" | tee -a "$LOG"; }
err(){ echo -e "[$(ts)] [ERROR] $*" | tee -a "$LOG"; }

metadata(){ curl -fsH "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/$1"; }
meta_attr(){ metadata "instance/attributes/$1" 2>/dev/null || true; }
get_sa_token(){ metadata instance/service-accounts/default/token | jq -r .access_token; }

detect(){
  HOSTNAME_FQDN=$(hostname)
  ORG_CODE=${HOSTNAME_FQDN%%-*}
  ENV_CODE=$(echo "$HOSTNAME_FQDN" | awk -F- '{print $2}')
  PROJECT=$(metadata project/project-id)
  ZONE=$(basename "$(metadata instance/zone)")
}

sm_access(){
  local sid="$1"; local token
  token=$(get_sa_token)
  local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${sid}/versions/latest:access"
  curl -fsSL -H "Authorization: Bearer $token" "$url" | jq -r '.payload.data' | base64 -d
}

derive_secret_ids(){
  PGBOUNCER_SID="${ORG_CODE}-${ENV_CODE}-sec-pgbouncer-auth-01"
  TLS_CA_SID="${ORG_CODE}-${ENV_CODE}-sec-tls-ca-01"
  TLS_CRT_SID="${ORG_CODE}-${ENV_CODE}-sec-tls-server-crt-01"
  TLS_KEY_SID="${ORG_CODE}-${ENV_CODE}-sec-tls-server-key-01"
}

install_deps(){
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y pgbouncer jq ca-certificates
}

install_tls(){
  install -d -m 0755 /etc/pgbouncer
  printf "%s" "$(sm_access "$TLS_CA_SID")" >/etc/pgbouncer/ca.crt
  printf "%s" "$(sm_access "$TLS_CRT_SID")" >/etc/pgbouncer/server.crt
  printf "%s" "$(sm_access "$TLS_KEY_SID")" >/etc/pgbouncer/server.key
  chown -R pgbouncer:pgbouncer /etc/pgbouncer || true
  chmod 644 /etc/pgbouncer/ca.crt /etc/pgbouncer/server.crt
  chmod 600 /etc/pgbouncer/server.key
}

discover_primary_ip(){
  local token project url ip
  token=$(get_sa_token)
  project="$PROJECT"
  url="https://compute.googleapis.com/compute/v1/projects/${project}/aggregated/instances?filter=labels.role%3Dprimary"
  ip=$(curl -fsSL -H "Authorization: Bearer $token" "$url" | jq -r '..|.networkInterfaces? // empty | .[0].networkIP' | head -n1)
  if [[ -z "$ip" || "$ip" == "null" ]]; then
    err "Could not discover primary IP"
    return 1
  fi
  echo "$ip"
}

write_pgbouncer_ini(){
  local primary_ip="$1"; local pw
  pw=$(sm_access "$PGBOUNCER_SID" || echo "")
  cat >/etc/pgbouncer/pgbouncer.ini <<'EOF'
[databases]
postgres = host=PRIMARY_IP_REPLACE port=5432 dbname=postgres auth_user=pgbouncer

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_user = pgbouncer
auth_query = SELECT username, passwd FROM pgbouncer.get_auth($1)
admin_users = pgbouncer
pool_mode = transaction
default_pool_size = 200
min_pool_size = 50
server_connect_timeout = 500
server_login_retry = 3
server_fast_close = 1
query_timeout = 600

server_tls_sslmode = verify-ca
server_tls_ca_file = /etc/pgbouncer/ca.crt
server_tls_key_file = /etc/pgbouncer/server.key
server_tls_cert_file = /etc/pgbouncer/server.crt

client_tls_sslmode = require
client_tls_ca_file = /etc/pgbouncer/ca.crt
client_tls_key_file = /etc/pgbouncer/server.key
EOF
  sed -i -E "s|PRIMARY_IP_REPLACE|${primary_ip}|" /etc/pgbouncer/pgbouncer.ini
  # userlist not used with auth_query, but create an admin entry for safety
  echo '"pgbouncer" "'"$pw"'"' >/etc/pgbouncer/userlist.txt || true
  chown -R pgbouncer:pgbouncer /etc/pgbouncer
  chmod 640 /etc/pgbouncer/pgbouncer.ini
}

install_refresh_unit(){
  cat >/usr/local/bin/refresh_pgbouncer_primary.sh <<'EOS'
#!/bin/bash
set -euo pipefail
LOG="/var/log/pgbouncer-refresh.log"
ts(){ date --rfc-3339=seconds; }
echo "[$(ts)] Refresh starting" | tee -a "$LOG"
get_sa_token(){ curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token; }
PROJECT=$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
token=$(get_sa_token)
url="https://compute.googleapis.com/compute/v1/projects/${PROJECT}/aggregated/instances?filter=labels.role%3Dprimary"
new_ip=$(curl -fsSL -H "Authorization: Bearer $token" "$url" | jq -r '..|.networkInterfaces? // empty | .[0].networkIP' | head -n1)
curr_ip=$(awk -F'host=' '/^postgres =/{print $2}' /etc/pgbouncer/pgbouncer.ini | awk '{print $1}' | head -n1)
if [[ -n "$new_ip" && "$new_ip" != "$curr_ip" ]]; then
  sed -i -E "s|^(postgres = host=).*( port=)|\1${new_ip}\2|" /etc/pgbouncer/pgbouncer.ini
  systemctl reload pgbouncer || systemctl restart pgbouncer
  echo "[$(ts)] Updated primary IP to ${new_ip}" | tee -a "$LOG"
else
  echo "[$(ts)] No change (${curr_ip})" | tee -a "$LOG"
fi
EOS
  chmod +x /usr/local/bin/refresh_pgbouncer_primary.sh
  cat >/etc/systemd/system/pgbouncer-refresh.service <<'EOF'
[Unit]
Description=Refresh PgBouncer primary target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/refresh_pgbouncer_primary.sh
EOF
  cat >/etc/systemd/system/pgbouncer-refresh.timer <<'EOF'
[Unit]
Description=Periodic PgBouncer primary refresh

[Timer]
OnBootSec=30
OnUnitActiveSec=30

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now pgbouncer-refresh.timer
}

install_pool_emit_unit(){
  cat >/usr/local/bin/emit_pgbouncer_pools.sh <<'EOS'
#!/bin/bash
set -euo pipefail
ts(){ date --rfc-3339=seconds; }
OUT=$(psql "host=127.0.0.1 port=6432 dbname=pgbouncer user=pgbouncer sslmode=require" -Atqc "SHOW POOLS;" 2>/dev/null || true)
if [[ -n "$OUT" ]]; then
  # Summarize waiting clients across pools
  WAIT=$(echo "$OUT" | awk -F'|' '{sum+=$8} END{print sum+0}')
  logger -t pgbouncer "PGBOUNCER_POOLS waiting=${WAIT}"
fi
EOS
  chmod +x /usr/local/bin/emit_pgbouncer_pools.sh
  cat >/etc/systemd/system/pgbouncer-pools.service <<'EOF'
[Unit]
Description=Emit PgBouncer pool stats to logs

[Service]
Type=oneshot
ExecStart=/usr/local/bin/emit_pgbouncer_pools.sh
EOF
  cat >/etc/systemd/system/pgbouncer-pools.timer <<'EOF'
[Unit]
Description=Periodic PgBouncer pools emission

[Timer]
OnBootSec=45
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now pgbouncer-pools.timer
}

main(){
  detect
  install_deps
  derive_secret_ids
  install_tls || warn "TLS install failed"
  primary_ip=$(discover_primary_ip)
  write_pgbouncer_ini "$primary_ip"
  systemctl enable --now pgbouncer
  install_refresh_unit
  install_pool_emit_unit
  # Install Ops Agent for logging/metrics on PgBouncer nodes
  if ! command -v google-cloud-ops-agent >/dev/null 2>&1; then
    curl -sSfL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh | bash || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y google-cloud-ops-agent || true
  fi
  cat >/etc/google-cloud-ops-agent/config.yaml <<'EOF'
logging:
  receivers:
    pgbouncer_log:
      type: files
      include_paths:
        - /var/log/pgbouncer/*.log
      record_log_file_path: true
  service:
    pipelines:
      default:
        receivers: [pgbouncer_log]
metrics:
  service:
    pipelines:
      default: {}
EOF
  systemctl enable --now google-cloud-ops-agent || true
  systemctl restart google-cloud-ops-agent || true
  log "PgBouncer setup complete"
}

main "$@"
