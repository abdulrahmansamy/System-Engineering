#!/bin/bash
# Immediate Health Endpoint Deployment - WORKS INSTANTLY
# Deploy this after PostgreSQL and PgBouncer are installed

set -euo pipefail

info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: ✓ $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"; }

echo "=============================================="
echo "Immediate Health Endpoint Deployment"  
echo "=============================================="

# Check if we're root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

SELF_IP=$(hostname -I | awk '{print $1}')
HOSTNAME=$(hostname)

info "Deploying health endpoints on $HOSTNAME ($SELF_IP)"

# Auto-detect role
if [[ "$HOSTNAME" == *"primary"* ]]; then
    ROLE="primary"
elif [[ "$HOSTNAME" == *"standby"* ]]; then
    ROLE="standby"
else
    warn "Could not auto-detect role, assuming primary"
    ROLE="primary"
fi

info "Detected role: $ROLE"

# Install required packages
info "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl jq netcat-openbsd socat 2>/dev/null || true

# Kill any existing health processes
info "Cleaning up existing health processes..."
fuser -k 8001/tcp 2>/dev/null || true
fuser -k 8002/tcp 2>/dev/null || true
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "health" 2>/dev/null || true

sleep 3

# Create immediate PostgreSQL health endpoint
info "Creating PostgreSQL health endpoint (port 8001)..."
cat > /usr/local/bin/pg-health-immediate.sh <<'PGHEALTH_EOF'
#!/bin/bash
# PostgreSQL Immediate Health Endpoint
PORT=${1:-8001}
SELF_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")

while true; do
    # Detect current role
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
            role="primary"
            status="healthy"
            message="PostgreSQL primary operational"
        elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
            role="standby"
            status="healthy"
            message="PostgreSQL standby operational"
        else
            role="unknown"
            status="healthy"
            message="PostgreSQL operational"
        fi
    else
        role="down"
        status="unhealthy"
        message="PostgreSQL service not running"
    fi
    
    # Generate JSON
    json="{\"status\":\"$status\",\"service\":\"postgresql-ha\",\"role\":\"$role\",\"message\":\"$message\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\",\"node_ip\":\"$SELF_IP\"}"
    length=${#json}
    
    # HTTP response
    if [[ "$status" == "healthy" ]]; then
        printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$length" "$json" | nc -l -p $PORT -q 1 2>/dev/null
    else
        printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$length" "$json" | nc -l -p $PORT -q 1 2>/dev/null
    fi
done 2>/dev/null || sleep 1
PGHEALTH_EOF

chmod +x /usr/local/bin/pg-health-immediate.sh

# Create immediate PgBouncer health endpoint
info "Creating PgBouncer health endpoint (port 8002)..."
cat > /usr/local/bin/pgbouncer-health-immediate.sh <<'PGBHEALTH_EOF'
#!/bin/bash
# PgBouncer Immediate Health Endpoint
PORT=${1:-8002}
SELF_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")

while true; do
    # Check PgBouncer
    if systemctl is-active --quiet pgbouncer 2>/dev/null && nc -z localhost 6432 2>/dev/null; then
        status="healthy"
        message="PgBouncer operational"
        detailed_status="service_running"
    else
        status="unhealthy"
        message="PgBouncer not accessible"
        detailed_status="service_down"
    fi
    
    # Generate JSON
    json="{\"service\":\"pgbouncer\",\"status\":\"$status\",\"message\":\"$message\",\"detailed_status\":\"$detailed_status\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\",\"port\":6432,\"node_ip\":\"$SELF_IP\"}"
    length=${#json}
    
    # HTTP response
    if [[ "$status" == "healthy" ]]; then
        printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$length" "$json" | nc -l -p $PORT -q 1 2>/dev/null
    else
        printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$length" "$json" | nc -l -p $PORT -q 1 2>/dev/null
    fi
done 2>/dev/null || sleep 1
PGBHEALTH_EOF

chmod +x /usr/local/bin/pgbouncer-health-immediate.sh

# Start health endpoints as background processes
info "Starting health endpoints..."

nohup /usr/local/bin/pg-health-immediate.sh 8001 >/dev/null 2>&1 &
PG_PID=$!
sleep 2

nohup /usr/local/bin/pgbouncer-health-immediate.sh 8002 >/dev/null 2>&1 &
PGB_PID=$!
sleep 3

# Test endpoints
info "Testing health endpoints..."

pg_working=false
pgb_working=false

# Test PostgreSQL endpoint
for attempt in {1..5}; do
    if timeout 10 curl -s "http://localhost:8001" >/dev/null 2>&1; then
        pg_working=true
        break
    fi
    sleep 1
done

# Test PgBouncer endpoint
for attempt in {1..5}; do
    if timeout 10 curl -s "http://localhost:8002" >/dev/null 2>&1; then
        pgb_working=true
        break
    fi
    sleep 1
done

# Report results
echo ""
echo "=============================================="
echo "Health Endpoint Status"
echo "=============================================="

if $pg_working; then
    success "PostgreSQL health endpoint (8001): WORKING"
    if command -v jq >/dev/null 2>&1; then
        response=$(timeout 5 curl -s "http://localhost:8001" 2>/dev/null | jq -r '.message' 2>/dev/null || echo "OK")
        info "  → $response"
    fi
else
    error "PostgreSQL health endpoint (8001): FAILED"
fi

if $pgb_working; then
    success "PgBouncer health endpoint (8002): WORKING"
    if command -v jq >/dev/null 2>&1; then
        response=$(timeout 5 curl -s "http://localhost:8002" 2>/dev/null | jq -r '.message' 2>/dev/null || echo "OK")
        info "  → $response"
    fi
else
    error "PgBouncer health endpoint (8002): FAILED"
fi

# Create systemd services for persistence
info "Creating systemd services for persistence..."

cat > /etc/systemd/system/pg-health-immediate.service <<EOF
[Unit]
Description=PostgreSQL Immediate Health Endpoint
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pg-health-immediate.sh 8001
Restart=always
RestartSec=5
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-health-immediate.service <<EOF
[Unit]
Description=PgBouncer Immediate Health Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pgbouncer-health-immediate.sh 8002
Restart=always
RestartSec=5
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pg-health-immediate
systemctl enable pgbouncer-health-immediate

# Summary
echo ""
echo "=============================================="
echo "Deployment Complete"
echo "=============================================="

if $pg_working && $pgb_working; then
    success "ALL HEALTH ENDPOINTS ARE WORKING!"
    success "External URLs:"
    success "  PostgreSQL: http://$SELF_IP:8001"
    success "  PgBouncer: http://$SELF_IP:8002"
elif $pg_working || $pgb_working; then
    warn "PARTIAL SUCCESS - Some endpoints working"
else
    error "NO ENDPOINTS WORKING - Check service status"
fi

info "Health endpoints will restart automatically if they fail"
info "Monitor with: ps aux | grep health"
info "Test from external: curl http://$SELF_IP:8001"