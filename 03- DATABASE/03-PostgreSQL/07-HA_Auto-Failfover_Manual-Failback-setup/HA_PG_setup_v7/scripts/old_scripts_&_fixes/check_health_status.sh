#!/bin/bash
# Quick Health Endpoints Status Check and Restart
# Verifies and restarts Python health endpoints if needed

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔍 Checking health endpoints status and restarting if needed"

# Detect node info
get_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q '^f'; then
        echo "primary"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q '^t'; then
        echo "standby"
    else
        echo "unknown"
    fi
}

ROLE=$(get_role)
SELF_IP=$(hostname -I | awk '{print $1}')
info "Node: $ROLE (IP: $SELF_IP)"

# Check if Python files exist
info "🐍 Checking Python health endpoint files..."
if [[ -f /usr/local/bin/python-pg-health.py && -f /usr/local/bin/python-pgbouncer-health.py ]]; then
    success "Python health endpoint files exist"
else
    error "Python health endpoint files missing - need to run python_health_fix.sh first"
    exit 1
fi

# Check if systemd services exist
info "📋 Checking systemd services..."
if [[ -f /etc/systemd/system/python-pg-health.service && -f /etc/systemd/system/python-pgbouncer-health.service ]]; then
    success "Systemd service files exist"
else
    warn "Systemd service files missing - creating them..."
    
    # Create systemd services
    cat > /etc/systemd/system/python-pg-health.service <<EOF
[Unit]
Description=Python PostgreSQL HA Health Endpoint
After=network.target postgresql.service
Wants=postgresql.service
StartLimitInterval=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/python-pg-health.py 8001
Restart=always
RestartSec=10
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/python-pgbouncer-health.service <<EOF
[Unit]
Description=Python PgBouncer Health Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service
StartLimitInterval=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/python-pgbouncer-health.py 8002
Restart=always
RestartSec=10
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    success "Created systemd service files"
fi

# Stop any conflicting processes
info "🛑 Stopping any conflicting processes..."
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "python.*health" 2>/dev/null || true
sleep 2

# Enable and start services
info "🚀 Starting Python health services..."
systemctl enable python-pg-health.service
systemctl enable python-pgbouncer-health.service

systemctl restart python-pg-health.service
systemctl restart python-pgbouncer-health.service

sleep 5

# Check service status
info "📊 Checking service status..."
for service in python-pg-health python-pgbouncer-health; do
    if systemctl is-active --quiet ${service}.service; then
        success "${service}.service is ACTIVE ✓"
    else
        error "${service}.service is NOT ACTIVE"
        systemctl status ${service}.service --no-pager -l || true
    fi
done

# Test endpoints
info "🧪 Testing health endpoints..."

# Test local access
for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "Port $port ($service_name): Local access WORKING ✓"
        response=$(timeout 5 curl -s "http://localhost:$port" 2>/dev/null)
        echo "  Response: $(echo "$response" | jq -c . 2>/dev/null || echo "$response" | head -c 150)"
    else
        error "Port $port ($service_name): Local access FAILED"
        # Check if port is listening
        if ss -tulnp | grep -q ":$port "; then
            warn "  Port $port is listening but HTTP request failed"
        else
            error "  Port $port is not listening"
        fi
    fi
done

# Test network access
info "🌐 Testing network access..."
for port in 8001 8002; do
    if timeout 10 curl -s "http://$SELF_IP:$port" >/dev/null 2>&1; then
        success "Port $port: Network access WORKING ✓"
        response=$(timeout 5 curl -s "http://$SELF_IP:$port" 2>/dev/null)
        echo "  Response: $(echo "$response" | jq -c . 2>/dev/null || echo "$response" | head -c 150)"
    else
        warn "Port $port: Network access issues (may be firewall related)"
    fi
done

# Show listening ports
info "📡 Current listening ports:"
ss -tulnp | grep -E ":(8001|8002) " || warn "Ports 8001/8002 not found in listening ports"

# Show processes
info "🔄 Current health processes:"
ps aux | grep -E "(python.*health|:800[12])" | grep -v grep || warn "No health processes found"

success "🎉 Health endpoints status check complete!"
info ""
info "📋 Summary:"
info "  Node Role: $ROLE"
info "  Node IP: $SELF_IP"
info "  Services: python-pg-health.service, python-pgbouncer-health.service"
info ""
info "🧪 Test from other nodes:"
info "  curl http://$SELF_IP:8001 | jq .  # PostgreSQL HA health"
info "  curl http://$SELF_IP:8002 | jq .  # PgBouncer health"
info ""
info "📊 Monitor services:"
info "  systemctl status python-pg-health.service"
info "  systemctl status python-pgbouncer-health.service"
info "  journalctl -u python-pg-health.service -f"
info "  journalctl -u python-pgbouncer-health.service -f"