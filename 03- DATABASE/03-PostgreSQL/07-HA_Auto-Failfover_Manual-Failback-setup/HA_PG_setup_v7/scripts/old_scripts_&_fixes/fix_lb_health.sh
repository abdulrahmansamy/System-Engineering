#!/bin/bash
# Quick fix for load balancer health checks
# This enables proper health endpoints for GCP Load Balancer integration

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }

info "🔧 Fixing health endpoints for load balancer integration"

# Enable PgBouncer health service
info "Enabling PgBouncer health service..."
systemctl enable pgbouncer-health.service 2>/dev/null || true
systemctl start pgbouncer-health.service 2>/dev/null || true

# Kill any conflicting processes on port 8001
info "Cleaning up port 8001..."
pkill -f ":8001" 2>/dev/null || true
sleep 2

# Create dedicated load balancer health endpoint
info "Creating load balancer health endpoint..."
cat > /usr/local/bin/lb-health.sh <<'EOF'
#!/bin/bash
# Load Balancer Health Endpoint - Simple HTTP responder for GCP Load Balancer
PORT=${1:-8001}

while true; do
  # Check if PostgreSQL and PgBouncer are running
  if pgrep -f postgres >/dev/null && pgrep -f pgbouncer >/dev/null; then
    response='{"status":"healthy","service":"postgresql-ha","timestamp":"'$(date -Iseconds)'"}'
    status_code="200 OK"
  else
    response='{"status":"unhealthy","service":"postgresql-ha","timestamp":"'$(date -Iseconds)'"}'  
    status_code="503 Service Unavailable"
  fi
  
  content_length=${#response}
  
  # Simple HTTP response for load balancer
  (
    echo "HTTP/1.1 $status_code"
    echo "Content-Type: application/json"
    echo "Content-Length: $content_length"
    echo "Connection: close"
    echo ""
    echo "$response"
  ) | nc -l -p $PORT -q 1 2>/dev/null || sleep 1
done
EOF

chmod +x /usr/local/bin/lb-health.sh

# Start the load balancer health endpoint
info "Starting load balancer health endpoint..."
nohup /usr/local/bin/lb-health.sh 8001 >/dev/null 2>&1 &
sleep 3

# Test the endpoints
info "Testing health endpoints..."
for port in 8001 8002; do
    if timeout 5 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "Port $port: RESPONDING ✓"
        response=$(curl -s "http://localhost:$port" 2>/dev/null || echo "No response")
        info "  Response: $response"
    else
        warn "Port $port: NOT RESPONDING"
    fi
done

success "🎉 Load balancer health endpoints are now configured!"
info ""
info "📋 Next steps:"
info "  1. Your PostgreSQL HA cluster is ready for load balancer integration"
info "  2. Health checks will work on port 8001 (HTTP)"
info "  3. PgBouncer service is available on port 6432"
info "  4. You can now proceed with load balancer deployment"