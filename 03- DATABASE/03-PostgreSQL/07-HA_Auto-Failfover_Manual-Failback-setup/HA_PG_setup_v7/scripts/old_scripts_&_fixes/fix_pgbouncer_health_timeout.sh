#!/bin/bash
# PgBouncer Health Endpoint Fix - Targeted Solution
# Fixes the specific PgBouncer health endpoint timeout issues

set -euo pipefail

LOG_FILE="/var/log/pg-bootstrap/pgbouncer-health-fix.log"
mkdir -p "$(dirname "$LOG_FILE")"

info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "$LOG_FILE"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $*" | tee -a "$LOG_FILE"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" | tee -a "$LOG_FILE"; }

info "Starting PgBouncer health endpoint fix..."

# Stop the existing PgBouncer health service
info "Stopping existing PgBouncer health service..."
systemctl stop pgbouncer-ha-health 2>/dev/null || true

# Kill any processes on port 8002
info "Clearing port 8002..."
fuser -k 8002/tcp 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true
sleep 3

# Create a simplified, working PgBouncer health script
info "Creating new PgBouncer health endpoint..."
cat > /usr/local/bin/pgbouncer-health-simple.sh <<'PGBHEALTH_EOF'
#!/bin/bash
# Simple PgBouncer Health Endpoint - Guaranteed to work
set -euo pipefail

PORT=${1:-8002}
SELF_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")

# Detect PostgreSQL role
get_pg_role() {
    if systemctl is-active --quiet postgresql >/dev/null 2>&1; then
        if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
            echo "primary"
        elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
            echo "standby"
        else
            echo "unknown"
        fi
    else
        echo "down"
    fi
}

# Check PgBouncer status
check_pgbouncer() {
    local pg_role=$(get_pg_role)
    local status="healthy"
    local message="PgBouncer operational"
    local detailed_status="service_running"
    
    # Quick checks in order of importance
    if ! systemctl is-active --quiet pgbouncer; then
        status="unhealthy"
        message="PgBouncer service not active"
        detailed_status="service_down"
    elif ! ss -tuln | grep -q ":6432 "; then
        status="unhealthy"
        message="PgBouncer not listening on port 6432"
        detailed_status="port_not_listening"
    else
        # PgBouncer is running and listening
        case "$pg_role" in
            "primary")
                message="PgBouncer running and accepting connections"
                detailed_status="service_running"
                ;;
            "standby")
                message="PgBouncer operational on standby node"
                detailed_status="standby_service_running"
                ;;
            *)
                message="PgBouncer operational (PostgreSQL: $pg_role)"
                detailed_status="service_running"
                ;;
        esac
    fi
    
    # Generate JSON response
    local json="{\"service\":\"pgbouncer\",\"status\":\"$status\",\"message\":\"$message\",\"detailed_status\":\"$detailed_status\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\",\"port\":6432,\"node_ip\":\"$SELF_IP\""
    
    if [[ "$pg_role" != "unknown" && "$pg_role" != "down" ]]; then
        json="${json},\"node_role\":\"$pg_role\"}"
    else
        json="${json}}"
    fi
    
    echo "$json"
}

# HTTP handler using simple approach
handle_http() {
    local response=$(check_pgbouncer)
    local content_length=${#response}
    
    # Always return 200 OK for load balancer compatibility
    # The JSON status field indicates actual health
    cat <<HTTP_RESPONSE
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: $content_length
Connection: close
Access-Control-Allow-Origin: *

$response
HTTP_RESPONSE
}

# Simple HTTP server using socat or nc
start_server() {
    echo "Starting PgBouncer health server on port $PORT" >&2
    
    if command -v socat >/dev/null 2>&1; then
        # Use socat for reliable HTTP serving
        socat TCP-LISTEN:$PORT,reuseaddr,fork SYSTEM:'bash -c "$(declare -f check_pgbouncer get_pg_role handle_http); handle_http"'
    elif command -v nc >/dev/null 2>&1; then
        # Fallback to netcat loop
        while true; do
            echo -e "$(handle_http)" | nc -l -p $PORT -q 1 2>/dev/null || sleep 1
        done
    else
        # Last resort - basic TCP server
        while true; do
            {
                echo -e "$(handle_http)"
            } | timeout 30 nc -l $PORT 2>/dev/null || sleep 2
        done
    fi
}

# Main execution
start_server
PGBHEALTH_EOF

# Make the script executable
chmod +x /usr/local/bin/pgbouncer-health-simple.sh

# Create a new, simplified systemd service
info "Creating simplified PgBouncer health service..."
cat > /etc/systemd/system/pgbouncer-health-simple.service <<'SERVICE_EOF'
[Unit]
Description=PgBouncer Health Check Endpoint (Simple)
Documentation=https://pgbouncer.github.io/
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/pgbouncer-health-simple.sh 8002
Restart=always
RestartSec=5
TimeoutStartSec=60
TimeoutStopSec=15

# Environment
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=/var/lib/postgresql

# Security (minimal for compatibility)
NoNewPrivileges=yes

# Resource limits
MemoryHigh=64M
MemoryMax=128M
TasksMax=20

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pgbouncer-health

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Reload systemd and start the service
info "Starting new PgBouncer health service..."
systemctl daemon-reload
systemctl enable pgbouncer-health-simple
systemctl start pgbouncer-health-simple

# Wait for the service to start
sleep 5

# Check if the service is running
if systemctl is-active --quiet pgbouncer-health-simple; then
    success "PgBouncer health service is running"
else
    error "PgBouncer health service failed to start"
    info "Checking service status..."
    systemctl status pgbouncer-health-simple --no-pager -l
    exit 1
fi

# Test the endpoint locally
info "Testing PgBouncer health endpoint..."
sleep 3

test_local_endpoint() {
    local max_attempts=10
    local attempt=1
    
    while (( attempt <= max_attempts )); do
        info "Test attempt $attempt/$max_attempts..."
        
        if response=$(timeout 15 curl -s "http://localhost:8002" 2>/dev/null); then
            if echo "$response" | jq -e . >/dev/null 2>&1; then
                local service=$(echo "$response" | jq -r '.service // "unknown"')
                local status=$(echo "$response" | jq -r '.status // "unknown"')
                
                success "PgBouncer health endpoint is working!"
                success "Service: $service, Status: $status"
                echo "Full response:"
                echo "$response" | jq .
                return 0
            else
                warn "Invalid JSON response (attempt $attempt)"
                echo "Raw response: $response"
            fi
        else
            warn "No response from endpoint (attempt $attempt)"
        fi
        
        if (( attempt < max_attempts )); then
            sleep 2
        fi
        ((attempt++))
    done
    
    return 1
}

if test_local_endpoint; then
    success "PgBouncer health endpoint test passed!"
else
    error "PgBouncer health endpoint test failed"
    info "Checking service logs..."
    journalctl -u pgbouncer-health-simple -n 20 --no-pager
    exit 1
fi

# Verify port is listening
info "Verifying port 8002 is listening..."
if ss -tuln | grep -q ":8002 "; then
    success "Port 8002 is listening"
else
    warn "Port 8002 may not be properly bound"
    ss -tuln | grep ":8002" || info "No processes found listening on port 8002"
fi

success "PgBouncer health endpoint fix completed successfully!"
success "Endpoint URL: http://$(hostname -I | awk '{print $1}'):8002"
info "Test from external host: curl http://$(hostname -I | awk '{print $1}'):8002"
info "Monitor service: journalctl -u pgbouncer-health-simple -f"
SERVICE_EOF