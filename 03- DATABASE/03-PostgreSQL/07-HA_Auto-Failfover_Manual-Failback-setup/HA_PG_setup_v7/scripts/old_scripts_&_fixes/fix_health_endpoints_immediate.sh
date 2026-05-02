#!/bin/bash
# Health Endpoint Fix Script - Immediate Deployment
# This script fixes the health endpoint issues identified in the validation tests

set -euo pipefail

info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $*"; }

info "Starting health endpoint fix..."

# Install socat if missing
if ! command -v socat >/dev/null 2>&1; then
    info "Installing socat for reliable HTTP endpoints..."
    apt-get update -qq && apt-get install -y socat
fi

# Stop existing health services
systemctl stop postgresql-ha-health 2>/dev/null || true
systemctl stop pgbouncer-ha-health 2>/dev/null || true

# Create robust PostgreSQL health endpoint
cat > /usr/local/bin/clean-pg-health.sh <<'EOF'
#!/bin/bash
# PostgreSQL HA Health Endpoint - Production Ready
set -euo pipefail

PORT=${1:-8001}
ROLE=""
SELF_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")

# Detect role dynamically
detect_role() {
  if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
    ROLE="primary"
  elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
    ROLE="standby"
  else
    ROLE="unknown"
  fi
}

# Check PostgreSQL health
check_postgresql_health() {
  detect_role
  local status="healthy"
  local message=""
  
  if ! systemctl is-active --quiet postgresql; then
    status="unhealthy"
    message="PostgreSQL service not running"
  elif ! sudo -u postgres psql -c "SELECT 1;" >/dev/null 2>&1; then
    status="unhealthy"
    message="PostgreSQL not accepting connections"
  else
    case "$ROLE" in
      "primary") message="PostgreSQL primary operational" ;;
      "standby") message="PostgreSQL standby operational" ;;
      *) message="PostgreSQL role unknown" ;;
    esac
  fi
  
  echo "{\"status\":\"$status\",\"service\":\"postgresql-ha\",\"role\":\"$ROLE\",\"message\":\"$message\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\",\"node_ip\":\"$SELF_IP\"}"
}

# HTTP server using socat
serve_http() {
  local response
  response=$(check_postgresql_health)
  local content_length=${#response}
  
  if echo "$response" | grep -q '"status":"healthy"'; then
    cat << HTTP_200
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: $content_length
Connection: close

$response
HTTP_200
  else
    cat << HTTP_503
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
Content-Length: $content_length
Connection: close

$response
HTTP_503
  fi
}

# Main server loop
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting PostgreSQL HA health endpoint on port $PORT" >&2

if command -v socat >/dev/null 2>&1; then
  while true; do
    socat TCP-LISTEN:$PORT,reuseaddr,fork SYSTEM:'bash -c "$(declare -f serve_http check_postgresql_health detect_role); serve_http"' 2>/dev/null || sleep 1
  done
else
  # Fallback using netcat
  while true; do
    echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n$(check_postgresql_health)" | nc -l -p $PORT -q 1 2>/dev/null || sleep 1
  done
fi
EOF

# Create robust PgBouncer health endpoint
cat > /usr/local/bin/clean-pgbouncer-health.sh <<'EOF'
#!/bin/bash
# PgBouncer Health Endpoint - Production Ready
set -euo pipefail

PORT=${1:-8002}
SELF_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")

# Detect PostgreSQL role for context
detect_role() {
  if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
    echo "primary"
  elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
    echo "standby"
  else
    echo "unknown"
  fi
}

# Check PgBouncer health
check_pgbouncer_health() {
  local status="healthy"
  local message=""
  local detailed_status=""
  local role=$(detect_role)
  
  if ! systemctl is-active --quiet pgbouncer; then
    status="unhealthy"
    message="PgBouncer service not running"
    detailed_status="service_down"
  elif ! nc -z localhost 6432 2>/dev/null; then
    status="unhealthy"  
    message="PgBouncer port not accessible"
    detailed_status="port_unreachable"
  elif ! sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    status="unhealthy"
    message="PgBouncer not accepting connections"
    detailed_status="connection_failed"
  else
    case "$role" in
      "primary") 
        message="PgBouncer running and accepting connections"
        detailed_status="service_running"
        ;;
      "standby") 
        message="PgBouncer operational on standby node"
        detailed_status="standby_service_running"
        ;;
      *) 
        message="PgBouncer running (role unknown)"
        detailed_status="service_running"
        ;;
    esac
  fi
  
  local json="{\"service\":\"pgbouncer\",\"status\":\"$status\",\"message\":\"$message\",\"detailed_status\":\"$detailed_status\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\",\"port\":6432,\"node_ip\":\"$SELF_IP\""
  
  if [[ "$role" != "unknown" ]]; then
    json="${json},\"node_role\":\"$role\"}"
  else
    json="${json}}"
  fi
  
  echo "$json"
}

# HTTP server using socat
serve_http() {
  local response
  response=$(check_pgbouncer_health)
  local content_length=${#response}
  
  if echo "$response" | grep -q '"status":"healthy"'; then
    cat << HTTP_200
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: $content_length
Connection: close

$response
HTTP_200
  else
    cat << HTTP_503
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
Content-Length: $content_length
Connection: close

$response
HTTP_503
  fi
}

# Main server loop
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting PgBouncer health endpoint on port $PORT" >&2

if command -v socat >/dev/null 2>&1; then
  while true; do
    socat TCP-LISTEN:$PORT,reuseaddr,fork SYSTEM:'bash -c "$(declare -f serve_http check_pgbouncer_health detect_role); serve_http"' 2>/dev/null || sleep 1
  done
else
  # Fallback using netcat
  while true; do
    echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n$(check_pgbouncer_health)" | nc -l -p $PORT -q 1 2>/dev/null || sleep 1
  done
fi
EOF

# Make scripts executable
chmod +x /usr/local/bin/clean-pg-health.sh
chmod +x /usr/local/bin/clean-pgbouncer-health.sh

# Create improved systemd service files
cat > /etc/systemd/system/postgresql-ha-health.service <<EOF
[Unit]
Description=PostgreSQL HA Health Check Endpoint
After=network.target postgresql.service
Wants=postgresql.service
PartOf=postgresql.service

[Service]
Type=simple
ExecStart=/usr/local/bin/clean-pg-health.sh 8001
Restart=always
RestartSec=5
User=postgres
Group=postgres
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

# Resource limits
MemoryHigh=64M
MemoryMax=128M
TasksMax=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-ha-health.service <<EOF
[Unit]
Description=PgBouncer HA Health Check Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service
PartOf=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/clean-pgbouncer-health.sh 8002
Restart=always
RestartSec=5
User=postgres
Group=postgres
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

# Resource limits
MemoryHigh=64M
MemoryMax=128M
TasksMax=10

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start services
systemctl daemon-reload

# Start services
systemctl enable postgresql-ha-health
systemctl start postgresql-ha-health

systemctl enable pgbouncer-ha-health
systemctl start pgbouncer-ha-health

# Wait for services to start
sleep 5

# Verify services are running
if systemctl is-active --quiet postgresql-ha-health; then
    success "PostgreSQL health service is running"
else
    error "PostgreSQL health service failed to start"
    systemctl status postgresql-ha-health --no-pager -l
fi

if systemctl is-active --quiet pgbouncer-ha-health; then
    success "PgBouncer health service is running"
else
    error "PgBouncer health service failed to start"  
    systemctl status pgbouncer-ha-health --no-pager -l
fi

# Test health endpoints
info "Testing health endpoints..."

for port in 8001 8002; do
    if timeout 10 curl -s "http://localhost:$port" | jq -r .status >/dev/null 2>&1; then
        success "Health endpoint on port $port is responding correctly"
    else
        error "Health endpoint on port $port is not responding"
    fi
done

success "Health endpoint fix completed!"
info "You can test with: curl http://localhost:8001 && curl http://localhost:8002"