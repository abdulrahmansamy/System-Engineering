#!/bin/bash
# PgBouncer Health Check Setup Script
# Configures port 8002 for PgBouncer health monitoring

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }

info "🔧 Setting up PgBouncer health check endpoint on port 8002"

# Kill any existing processes on port 8002
pkill -f ":8002" 2>/dev/null || true
pkill -f "pgbouncer-health" 2>/dev/null || true
sleep 2

# Create PgBouncer health check script
cat > /usr/local/bin/pgbouncer-health-monitor.sh <<'EOF'
#!/bin/bash
# PgBouncer Health Monitor - Production Ready
PORT=${1:-8002}
LOG_FILE="/var/log/pgbouncer/health-monitor.log"

# Ensure log directory exists
mkdir -p /var/log/pgbouncer
touch "$LOG_FILE"

log_health() {
    echo "$(date -Iseconds) - $*" >> "$LOG_FILE"
}

check_pgbouncer_health() {
    local status="unhealthy"
    local message="PgBouncer service down"
    local detailed_status=""
    
    # Check if PgBouncer process is running
    if ! pgrep -f pgbouncer >/dev/null 2>&1; then
        message="PgBouncer process not running"
        detailed_status="process_down"
        log_health "FAIL: $message"
        echo "$status|$message|$detailed_status"
        return
    fi
    
    # Check if PgBouncer port is listening
    if ! timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        message="PgBouncer port 6432 not accepting connections"
        detailed_status="port_unavailable"
        log_health "FAIL: $message"
        echo "$status|$message|$detailed_status"
        return
    fi
    
    # Advanced check: Try to connect to PgBouncer admin
    if timeout 5 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -c "SHOW POOLS;" >/dev/null 2>&1; then
        status="healthy"
        message="PgBouncer fully operational with admin access"
        detailed_status="admin_accessible"
    elif timeout 5 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        status="healthy"
        message="PgBouncer operational for database connections"
        detailed_status="db_accessible"
    else
        message="PgBouncer port open but authentication/connection failed"
        detailed_status="auth_failed"
    fi
    
    log_health "$status: $message"
    echo "$status|$message|$detailed_status"
}

# Main health check loop
while true; do
    health_info=$(check_pgbouncer_health)
    status=$(echo "$health_info" | cut -d'|' -f1)
    message=$(echo "$health_info" | cut -d'|' -f2)
    detailed_status=$(echo "$health_info" | cut -d'|' -f3)
    
    # Get additional metrics
    active_pools=""
    if [[ "$status" == "healthy" ]]; then
        # Try to get pool information
        pool_count=$(timeout 3 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -Atqc "SHOW POOLS;" 2>/dev/null | wc -l || echo "0")
        if [[ "$pool_count" -gt 0 ]]; then
            active_pools=",\"active_pools\":$pool_count"
        fi
    fi
    
    # Create JSON response
    response="{\"service\":\"pgbouncer\",\"status\":\"$status\",\"message\":\"$message\",\"detailed_status\":\"$detailed_status\",\"timestamp\":\"$(date -Iseconds)\",\"port\":6432${active_pools}}"
    content_length=${#response}
    
    # Set HTTP status code
    if [[ "$status" == "healthy" ]]; then
        status_line="HTTP/1.1 200 OK"
    else
        status_line="HTTP/1.1 503 Service Unavailable"
    fi
    
    # Send HTTP response
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nServer: PgBouncer-HealthMonitor/1.0\r\n\r\n%s" \
        "$status_line" "$content_length" "$response" | nc -l -p $PORT -q 1 2>/dev/null || sleep 1
done
EOF

chmod +x /usr/local/bin/pgbouncer-health-monitor.sh

# Create systemd service for PgBouncer health monitoring
cat > /etc/systemd/system/pgbouncer-health.service <<'EOF'
[Unit]
Description=PgBouncer Health Check Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service
PartOf=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pgbouncer-health-monitor.sh 8002
Restart=always
RestartSec=5
User=postgres
Group=postgres
NoNewPrivileges=true

# Resource limits
MemoryHigh=64M
MemoryMax=128M
TasksMax=10

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable pgbouncer-health.service

info "Starting PgBouncer health monitoring service..."
if systemctl start pgbouncer-health.service; then
    success "PgBouncer health service started"
    
    # Test the endpoint
    sleep 3
    info "Testing PgBouncer health endpoint..."
    
    for attempt in {1..5}; do
        if timeout 5 curl -s http://localhost:8002 >/dev/null 2>&1; then
            success "Port 8002: PgBouncer health check RESPONDING ✓"
            
            # Show the response
            response=$(timeout 3 curl -s http://localhost:8002 2>/dev/null || echo '{"error":"no_response"}')
            echo ""
            echo "=== PGBOUNCER HEALTH RESPONSE ==="
            echo "$response" | jq . 2>/dev/null || echo "$response"
            echo ""
            break
        else
            warn "Attempt $attempt failed, retrying..."
            sleep 2
        fi
    done
else
    warn "Failed to start PgBouncer health service"
    info "Checking service status..."
    systemctl status pgbouncer-health.service --no-pager -l
fi

# Show service status
info "PgBouncer health service status:"
systemctl is-active pgbouncer-health.service && success "Service is active" || warn "Service is not active"

success "🎉 PgBouncer health check setup complete!"
info ""
info "📋 Usage:"
info "  → Health check URL: http://YOUR_SERVER:8002"
info "  → Service management: systemctl {start|stop|restart} pgbouncer-health.service"
info "  → Logs: journalctl -u pgbouncer-health.service"
info "  → Health logs: tail -f /var/log/pgbouncer/health-monitor.log"