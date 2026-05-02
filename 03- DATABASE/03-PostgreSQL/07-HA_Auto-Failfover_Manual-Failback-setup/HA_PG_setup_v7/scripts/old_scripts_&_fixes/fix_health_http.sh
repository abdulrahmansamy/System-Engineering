#!/bin/bash
# Fix Health Endpoints HTTP Response Issue
# Fixes the "Empty reply from server" issue with health endpoints

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🔧 Fixing Health Endpoints HTTP Response"
echo "========================================"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root"
    exit 1
fi

info "Stopping health services..."
systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true
pkill -f "health.sh" 2>/dev/null || true
sleep 2

info "Recreating health endpoint scripts with proper HTTP handling..."

# Fix PostgreSQL health endpoint
cat > /usr/local/bin/pg-ha-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8001}

handle_request() {
  local status_code="503"
  local role="unknown"
  local response_body=""
  
  # Read the HTTP request (important for proper connection handling)
  read -r request_line
  while IFS= read -r header; do
    [[ $header == $'\r' ]] && break
  done
  
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
    printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$content_length" "$response_body"
  else
    printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$content_length" "$response_body"
  fi
}

while true; do
  handle_request | socat -T 3 - TCP-LISTEN:$PORT,reuseaddr,fork
done
EOF

# Fix PgBouncer health endpoint  
cat > /usr/local/bin/pgbouncer-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PORT=${1:-8002}

check_pgbouncer() {
  if systemctl is-active --quiet pgbouncer && nc -zv localhost 6432 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

handle_request() {
  local status_code="503"
  local service_status="unhealthy"
  local response_body=""
  
  # Read the HTTP request (important for proper connection handling)
  read -r request_line
  while IFS= read -r header; do
    [[ $header == $'\r' ]] && break
  done
  
  if check_pgbouncer; then
    status_code="200"
    service_status="healthy"
  fi
  
  response_body="{\"status\": \"$service_status\", \"service\": \"pgbouncer\", \"timestamp\": \"$(date -Iseconds)\"}"
  content_length=${#response_body}
  
  if [[ "$status_code" = "200" ]]; then
    printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$content_length" "$response_body"
  else
    printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$content_length" "$response_body"
  fi
}

while true; do
  handle_request | socat -T 3 - TCP-LISTEN:$PORT,reuseaddr,fork
done
EOF

chmod +x /usr/local/bin/pg-ha-health.sh /usr/local/bin/pgbouncer-health.sh

info "Starting health services..."
systemctl daemon-reload
systemctl start pg-ha-health.service pgbouncer-health.service

sleep 3

info "Testing fixed endpoints..."
echo
echo "PostgreSQL Health (port 8001):"
if timeout 5 curl -s http://localhost:8001; then
    success "✅ PostgreSQL health endpoint working!"
else
    echo "❌ Still not working"
fi

echo
echo "PgBouncer Health (port 8002):"  
if timeout 5 curl -s http://localhost:8002; then
    success "✅ PgBouncer health endpoint working!"
else
    echo "❌ Still not working"
fi

echo
success "🎉 Health endpoint fix complete!"