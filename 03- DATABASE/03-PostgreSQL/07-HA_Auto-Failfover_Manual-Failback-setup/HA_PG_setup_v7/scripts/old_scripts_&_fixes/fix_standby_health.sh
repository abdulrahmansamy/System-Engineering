#!/bin/bash
# Fix Health Endpoints for Standby Nodes
# Updates health check logic to properly report healthy standby status

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🔧 Fixing Health Endpoints for Standby Nodes"
echo "============================================"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root"
    exit 1
fi

PG_HEALTH_BIN="/usr/local/bin/pg-ha-health.sh"

info "Updating PostgreSQL health endpoint to properly handle standby nodes..."

# Create the improved health endpoint
cat > "$PG_HEALTH_BIN" <<'PG_HEALTH_EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8001}

handle_request() {
  local status_code="503"
  local role="unknown"
  local response_body=""
  
  if systemctl is-active --quiet postgresql; then
    if sudo -u postgres psql -tAc "SELECT NOT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
      status_code="200"
      role="primary"
    else
      # For standby nodes, check if replication is working properly
      if sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        # Check if WAL receiver is active (indicates healthy replication)
        if sudo -u postgres psql -tAc "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';" postgres 2>/dev/null | grep -q '^1'; then
          status_code="200"  # Healthy standby with active replication
        else
          status_code="503"  # Standby but replication issues
        fi
      else
        status_code="503"  # Neither primary nor proper standby
      fi
      role="standby"
    fi
  fi
  
  response_body="{\"status\": \"$([ "$status_code" = "200" ] && echo healthy || echo unhealthy)\", \"role\": \"$role\", \"timestamp\": \"$(date -Iseconds)\"}"
  content_length=${#response_body}
  
  if [[ "$status_code" = "200" ]]; then
    cat <<RESP_EOF
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: $content_length

$response_body
RESP_EOF
  else
    cat <<RESP_EOF
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
Content-Length: $content_length

$response_body
RESP_EOF
  fi
}

if command -v socat >&/dev/null; then
  while true; do
    handle_request | socat -T 3 - TCP-LISTEN:$PORT,reuseaddr,fork
  done
else
  while true; do
    nc -l -p $PORT -c 'handle_request'
  done
fi
PG_HEALTH_EOF

chmod +x "$PG_HEALTH_BIN"
success "Updated PostgreSQL health endpoint script"

info "Restarting health endpoint services..."

# Restart the health services
systemctl restart pg-ha-health.service
systemctl restart pgbouncer-health.service

sleep 3

info "Testing health endpoints..."

# Test PostgreSQL health endpoint
if curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ PostgreSQL health endpoint is responding"
    info "Response:"
    curl -s http://localhost:8001 | jq . 2>/dev/null || curl -s http://localhost:8001
else
    echo -e "${RED}[ERROR]${NC} PostgreSQL health endpoint not responding"
fi

echo

# Test PgBouncer health endpoint  
if curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ PgBouncer health endpoint is responding"
    info "Response:"
    curl -s http://localhost:8002 | jq . 2>/dev/null || curl -s http://localhost:8002
else
    echo -e "${RED}[ERROR]${NC} PgBouncer health endpoint not responding"
fi

echo
success "🎉 Health endpoint fix complete!"

info "Current WAL receiver status:"
sudo -u postgres psql -c "SELECT pid, status FROM pg_stat_wal_receiver;" || true