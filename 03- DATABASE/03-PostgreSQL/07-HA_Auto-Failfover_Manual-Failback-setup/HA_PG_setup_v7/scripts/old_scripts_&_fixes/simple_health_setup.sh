#!/bin/bash
# Simple Working Health Endpoints
# Basic but reliable solution for PostgreSQL HA health monitoring

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🚀 Setting up simple working health endpoints"

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

# Clean up everything
info "🛑 Complete cleanup..."
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "python.*health" 2>/dev/null || true
pkill -f "nc.*800" 2>/dev/null || true

# Stop services
systemctl stop python-pg-health.service 2>/dev/null || true
systemctl stop python-pgbouncer-health.service 2>/dev/null || true

# Force kill processes using ports
for port in 8001 8002; do
    lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    fuser -k $port/tcp 2>/dev/null || true
done

sleep 5

# Create simple working scripts
info "📝 Creating simple health scripts..."

# PostgreSQL health script
cat > /usr/local/bin/simple-pg-health.sh <<EOF
#!/bin/bash
PORT=\${1:-8001}
ROLE="$ROLE"
SELF_IP="$SELF_IP"

while true; do
    # Check PostgreSQL
    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
        pg_role=\$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null)
        
        if [[ "\$pg_role" == "\$ROLE" ]]; then
            if [[ "\$ROLE" == "standby" ]]; then
                wal_count=\$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_wal_receiver;" 2>/dev/null || echo "0")
                if [[ "\$wal_count" -gt 0 ]]; then
                    message="PostgreSQL \$pg_role operational with active replication"
                else
                    message="PostgreSQL \$pg_role operational"
                fi
            else
                message="PostgreSQL \$pg_role operational"
            fi
            
            response='{"status":"healthy","service":"postgresql-ha","role":"'\$ROLE'","message":"'\$message'","timestamp":"'"\$(date -Iseconds)"'","node_ip":"'\$SELF_IP'"}'
            http_status="200 OK"
        else
            response='{"status":"unhealthy","service":"postgresql-ha","role":"'\$ROLE'","message":"Role mismatch (expected '\$ROLE', got '\$pg_role')","timestamp":"'"\$(date -Iseconds)"'","node_ip":"'\$SELF_IP'"}'
            http_status="503 Service Unavailable"
        fi
    else
        response='{"status":"unhealthy","service":"postgresql-ha","role":"'\$ROLE'","message":"PostgreSQL not accessible","timestamp":"'"\$(date -Iseconds)"'","node_ip":"'\$SELF_IP'"}'
        http_status="503 Service Unavailable"
    fi
    
    # Send HTTP response
    {
        echo "HTTP/1.1 \$http_status"
        echo "Content-Type: application/json"
        echo "Content-Length: \${#response}"
        echo "Connection: close"
        echo "Access-Control-Allow-Origin: *"
        echo ""
        echo "\$response"
    } | nc -l -s 0.0.0.0 -p \$PORT -q 1 2>/dev/null || sleep 1
done
EOF

# PgBouncer health script
cat > /usr/local/bin/simple-pgbouncer-health.sh <<EOF
#!/bin/bash
PORT=\${1:-8002}
SELF_IP="$SELF_IP"

while true; do
    # Check PgBouncer
    if pgrep -f pgbouncer >/dev/null 2>&1; then
        if timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
            # Try admin connection
            if timeout 5 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -c "SHOW POOLS;" >/dev/null 2>&1; then
                pool_count=\$(timeout 3 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -Atqc "SHOW POOLS;" 2>/dev/null | wc -l || echo "0")
                active_pools=\$((pool_count > 1 ? pool_count - 1 : 0))
                response='{"service":"pgbouncer","status":"healthy","message":"PgBouncer fully operational with admin access","detailed_status":"admin_accessible","timestamp":"'"\$(date -Iseconds)"'","port":6432,"node_ip":"'\$SELF_IP'","active_pools":'\$active_pools'}'
            elif timeout 5 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
                response='{"service":"pgbouncer","status":"healthy","message":"PgBouncer operational for database connections","detailed_status":"db_accessible","timestamp":"'"\$(date -Iseconds)"'","port":6432,"node_ip":"'\$SELF_IP'"}'
            else
                response='{"service":"pgbouncer","status":"healthy","message":"PgBouncer running and accepting connections","detailed_status":"service_running","timestamp":"'"\$(date -Iseconds)"'","port":6432,"node_ip":"'\$SELF_IP'"}'
            fi
            http_status="200 OK"
        else
            response='{"service":"pgbouncer","status":"unhealthy","message":"PgBouncer port 6432 not accepting connections","detailed_status":"port_unavailable","timestamp":"'"\$(date -Iseconds)"'","port":6432,"node_ip":"'\$SELF_IP'"}'
            http_status="503 Service Unavailable"
        fi
    else
        response='{"service":"pgbouncer","status":"unhealthy","message":"PgBouncer process not running","detailed_status":"process_down","timestamp":"'"\$(date -Iseconds)"'","port":6432,"node_ip":"'\$SELF_IP'"}'
        http_status="503 Service Unavailable"
    fi
    
    # Send HTTP response
    {
        echo "HTTP/1.1 \$http_status"
        echo "Content-Type: application/json"
        echo "Content-Length: \${#response}"
        echo "Connection: close"
        echo "Access-Control-Allow-Origin: *"
        echo "Server: PgBouncer-HealthMonitor/Simple"
        echo ""
        echo "\$response"
    } | nc -l -s 0.0.0.0 -p \$PORT -q 1 2>/dev/null || sleep 1
done
EOF

chmod +x /usr/local/bin/simple-pg-health.sh
chmod +x /usr/local/bin/simple-pgbouncer-health.sh

# Create simple systemd services
info "📋 Creating simple systemd services..."

cat > /etc/systemd/system/simple-pg-health.service <<EOF
[Unit]
Description=Simple PostgreSQL HA Health Endpoint
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
ExecStart=/usr/local/bin/simple-pg-health.sh 8001
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/simple-pgbouncer-health.service <<EOF
[Unit]
Description=Simple PgBouncer Health Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/simple-pgbouncer-health.sh 8002
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
info "🚀 Starting simple health services..."

systemctl daemon-reload
systemctl enable simple-pg-health.service simple-pgbouncer-health.service
systemctl start simple-pg-health.service simple-pgbouncer-health.service

sleep 10

# Test the endpoints
info "🧪 Testing simple health endpoints..."

for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    # Test local access
    if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "Port $port ($service_name): Local access WORKING ✓"
        response=$(timeout 5 curl -s "http://localhost:$port" 2>/dev/null)
        echo "Response: $(echo "$response" | jq -c . 2>/dev/null || echo "$response" | head -c 100)"
    else
        error "Port $port ($service_name): Local access FAILED"
    fi
    
    # Test network access
    if timeout 10 curl -s "http://$SELF_IP:$port" >/dev/null 2>&1; then
        success "Port $port ($service_name): Network access WORKING ✓"
    else
        warn "Port $port ($service_name): Network access issues"
    fi
done

# Show service status
info "📊 Service Status:"
for service in simple-pg-health simple-pgbouncer-health; do
    if systemctl is-active --quiet ${service}.service; then
        success "${service}.service is ACTIVE ✓"
    else
        error "${service}.service is NOT ACTIVE"
        systemctl status ${service}.service --no-pager -l || true
    fi
done

# Show listening ports
info "📡 Listening ports:"
ss -tulnp | grep -E ":(8001|8002) " || warn "Health ports not found"

success "🎉 Simple health endpoints setup complete!"
info ""
info "🧪 Test commands:"
info "  curl http://localhost:8001 | jq .    # PostgreSQL HA health"
info "  curl http://localhost:8002 | jq .    # PgBouncer health"
info "  curl http://$SELF_IP:8001 | jq .  # Network PostgreSQL health"
info "  curl http://$SELF_IP:8002 | jq .  # Network PgBouncer health"
info ""
info "📊 Monitor services:"
info "  systemctl status simple-pg-health.service simple-pgbouncer-health.service"
info "  journalctl -u simple-pg-health.service -u simple-pgbouncer-health.service -f"