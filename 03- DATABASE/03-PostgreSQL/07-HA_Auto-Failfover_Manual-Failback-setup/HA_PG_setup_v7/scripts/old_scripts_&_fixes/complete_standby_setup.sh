#!/bin/bash
# Fix standby pg_hba.conf and complete registration
set -euo pipefail

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

# Get metadata and IPs
REPMGR_PRIMARY_HOST="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_primary_host || echo 192.168.14.21)"
REPMGR_USER="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_user || echo repmgr)"
REPMGR_DB="$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/repmgr_db || echo repmgr)"

self_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}' || true)

info "Primary host: $REPMGR_PRIMARY_HOST"
info "Self IP: $self_ip"

# Find PostgreSQL configuration files
PG_VERSION="17"
PG_CLUSTER_NAME="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}"
PG_HBA="${PG_DATA_DIR}/pg_hba.conf"
PG_CONF="${PG_DATA_DIR}/postgresql.conf"

if [[ -f "/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/pg_hba.conf" ]]; then
  PG_HBA="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/pg_hba.conf"
fi
if [[ -f "/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/postgresql.conf" ]]; then
  PG_CONF="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER_NAME}/postgresql.conf"
fi

info "Using pg_hba.conf: $PG_HBA"

# Detect auth method
auth_method="scram-sha-256"
if sudo -u postgres psql -Atqc "show password_encryption" 2>/dev/null | grep -q "md5"; then
  auth_method="md5"
fi

info "Using auth method: $auth_method"

# Add comprehensive pg_hba.conf entries for standby
if ! grep -q '# STANDBY-HA-HBA' "$PG_HBA" 2>/dev/null; then
  info "Adding standby pg_hba.conf entries..."
  cat >> "$PG_HBA" <<EOF
# STANDBY-HA-HBA (comprehensive access for standby)
local   all             all                                     peer
host    all             all             127.0.0.1/32            ${auth_method}
host    all             all             ::1/128                 ${auth_method}
host    replication     replication     192.168.0.0/16          ${auth_method}
host    ${REPMGR_DB}    ${REPMGR_USER}  192.168.0.0/16          ${auth_method}
host    all             ${REPMGR_USER}  192.168.0.0/16          ${auth_method}
host    replication     ${REPMGR_USER}  192.168.0.0/16          ${auth_method}
# Specific IP entries
host    ${REPMGR_DB}    ${REPMGR_USER}  ${self_ip}/32           ${auth_method}
host    replication     replication     ${self_ip}/32           ${auth_method}
host    replication     ${REPMGR_USER}  ${self_ip}/32           ${auth_method}
host    ${REPMGR_DB}    ${REPMGR_USER}  ${REPMGR_PRIMARY_HOST}/32  ${auth_method}
host    replication     replication     ${REPMGR_PRIMARY_HOST}/32  ${auth_method}
host    replication     ${REPMGR_USER}  ${REPMGR_PRIMARY_HOST}/32  ${auth_method}
EOF
  info "Added standby pg_hba.conf entries"
else
  info "pg_hba.conf already has standby entries"
fi

# Reload PostgreSQL to apply pg_hba.conf changes
info "Reloading PostgreSQL to apply pg_hba.conf changes..."
systemctl reload postgresql || true
sleep 2

# Test local connection
pgpass="/var/lib/postgresql/.pgpass"
info "Testing local connection after pg_hba fix..."
if sudo -u postgres env PGPASSFILE="$pgpass" psql -h "$self_ip" -U "$REPMGR_USER" -d "$REPMGR_DB" -Atqc 'select 1' 2>/dev/null; then
  info "SUCCESS: Can connect locally to repmgr database"
else
  warn "Still cannot connect locally, trying without explicit host..."
  if sudo -u postgres env PGPASSFILE="$pgpass" psql -U "$REPMGR_USER" -d "$REPMGR_DB" -Atqc 'select 1' 2>/dev/null; then
    info "SUCCESS: Can connect locally via socket"
  else
    error "Still cannot connect locally"
  fi
fi

# Try registering standby again
REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"
info "Attempting standby registration..."

if sudo -u postgres env PGPASSFILE="$pgpass" repmgr -f "$REPMGR_CONF_FILE" standby register --force; then
  info "SUCCESS: Standby registered successfully"
else
  warn "Registration failed, trying with force flag and primary connection..."
  if sudo -u postgres env PGPASSFILE="$pgpass" repmgr -f "$REPMGR_CONF_FILE" -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$REPMGR_DB" standby register --force; then
    info "SUCCESS: Standby registered with primary connection"
  else
    warn "Registration still failed"
  fi
fi

# Test cluster status
info "Checking cluster status..."
if sudo -u postgres env PGPASSFILE="$pgpass" repmgr -f "$REPMGR_CONF_FILE" cluster show; then
  info "Cluster status retrieved successfully"
else
  warn "Could not retrieve cluster status"
fi

# Start repmgrd service
info "Starting repmgrd service..."
systemctl enable repmgrd || true
systemctl restart repmgrd || true

# Deploy remaining components
info "Deploying health endpoint and event hooks..."

# Deploy event hooks
mkdir -p "/etc/repmgr/events"
cat > "/etc/repmgr/events/exec.sh" <<'EOF'
#!/bin/bash
EVT="$1"; shift || true
ROLE_STATE="unknown"; REC="unknown"
if psql -U postgres -d postgres -Atqc 'select 1' >/dev/null 2>&1; then
  REC=$(psql -Atqc 'select pg_is_in_recovery()' 2>/dev/null || echo unknown)
  [[ "$REC" == "f" ]] && ROLE_STATE=primary || ROLE_STATE=standby
fi
PAYLOAD=$(jq -n --arg evt "$EVT" --arg role "$ROLE_STATE" --arg rec "$REC" --arg ts "$(date -u +%FT%TZ)" '{timestamp:$ts,event:$evt,role:$role,is_in_recovery:$rec}')
echo "$PAYLOAD" >> /var/log/repmgr/events.log
exit 0
EOF
chmod +x "/etc/repmgr/events/exec.sh"

# Deploy health endpoint
HEALTH_BIN="/usr/local/bin/pg-ha-health.sh"
HEALTH_SERVICE="pg-ha-health.service"
HEALTH_PORT="8001"

cat > "$HEALTH_BIN" <<'EOS_HEALTH'
#!/bin/bash
### PG HA Health Endpoint
set -euo pipefail
PORT=__PORT__
NC_BIN="/usr/bin/nc"
while true; do
  role="unknown"; rec="unknown"
  if psql -U postgres -d postgres -Atqc 'select 1' >/dev/null 2>&1; then
    rec=$(psql -U postgres -d postgres -Atqc 'select pg_is_in_recovery()' 2>/dev/null || echo unknown)
    [[ "$rec" == "f" ]] && role=primary || role=standby
  fi
  body="{\"role\":\"$role\",\"ts\":\"$(date -u +%FT%TZ)\",\"is_in_recovery\":\"$rec\"}"
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: %s\r\n\r\n%s' "${#body}" "$body" | "$NC_BIN" -l -p "$PORT" -q 1 >/dev/null 2>&1 || sleep 1
done
EOS_HEALTH

sed -i "s/__PORT__/${HEALTH_PORT}/" "$HEALTH_BIN"
chmod +x "$HEALTH_BIN"

cat > /etc/systemd/system/${HEALTH_SERVICE} <<EOF
[Unit]
Description=PG HA Role Health Endpoint
After=network.target postgresql.service
[Service]
ExecStart=${HEALTH_BIN}
Restart=always
RestartSec=2
User=postgres
Group=postgres
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload || true
systemctl enable ${HEALTH_SERVICE} || true
systemctl restart ${HEALTH_SERVICE} || true

info "Standby setup and registration completed!"
info "Run validate_phase4.sh to check final status."