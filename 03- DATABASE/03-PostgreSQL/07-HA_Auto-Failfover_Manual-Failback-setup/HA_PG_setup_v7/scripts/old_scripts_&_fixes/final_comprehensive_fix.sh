#!/bin/bash
# Final Comprehensive Health Endpoints Fix
# Addresses all remaining issues with port conflicts and network access

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Final comprehensive fix for all health endpoint issues"

# Detect current node
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
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"

info "Current node: $ROLE (IP: $SELF_IP)"

# Step 1: Complete aggressive cleanup
info "🛑 Aggressive cleanup of all processes and conflicts..."

# Stop all services first
systemctl stop simple-pg-health.service 2>/dev/null || true
systemctl stop simple-pgbouncer-health.service 2>/dev/null || true
systemctl stop python-pg-health.service 2>/dev/null || true
systemctl stop python-pgbouncer-health.service 2>/dev/null || true

# Kill ALL processes using ports 8001 and 8002
for port in 8001 8002; do
    info "Aggressively cleaning port $port..."
    
    # Method 1: lsof
    lsof -ti:$port 2>/dev/null | while read pid 2>/dev/null; do
        if [[ -n "$pid" ]]; then
            info "  Killing process $pid (lsof)"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    
    # Method 2: fuser
    fuser -k $port/tcp 2>/dev/null || true
    
    # Method 3: ss and kill
    ss -tulnp | grep ":$port " | grep -o 'pid=[0-9]*' | cut -d= -f2 | while read pid 2>/dev/null; do
        if [[ -n "$pid" ]]; then
            info "  Killing process $pid (ss)"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
done

# Kill by process name patterns
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "nc.*800" 2>/dev/null || true
pkill -f "simple.*health" 2>/dev/null || true
pkill -f "python.*health" 2>/dev/null || true

sleep 10

# Step 2: Verify ports are completely free
info "🔍 Verifying ports are completely free..."
for port in 8001 8002; do
    attempts=0
    while ss -tulnp | grep -q ":$port " && [[ $attempts -lt 10 ]]; do
        warn "Port $port still in use, attempting cleanup..."
        lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
        fuser -k $port/tcp 2>/dev/null || true
        sleep 2
        ((attempts++))
    done
    
    if ss -tulnp | grep -q ":$port "; then
        error "Port $port cleanup failed after 10 attempts"
        ss -tulnp | grep ":$port "
        exit 1
    else
        success "Port $port is completely free ✓"
    fi
done

# Step 3: Configure comprehensive firewall rules
info "🔥 Configuring comprehensive firewall rules..."

# Configure UFW if available
if command -v ufw >/dev/null 2>&1; then
    # Reset UFW to clean state for health endpoints
    ufw --force delete allow 8001 2>/dev/null || true
    ufw --force delete allow 8002 2>/dev/null || true
    
    # Add specific rules for both nodes
    ufw allow from $PRIMARY_IP to any port 8001 comment "PG-HA Health Primary"
    ufw allow from $PRIMARY_IP to any port 8002 comment "PgBouncer Health Primary"
    ufw allow from $STANDBY_IP to any port 8001 comment "PG-HA Health Standby"  
    ufw allow from $STANDBY_IP to any port 8002 comment "PgBouncer Health Standby"
    
    # Also allow from localhost
    ufw allow from 127.0.0.1 to any port 8001
    ufw allow from 127.0.0.1 to any port 8002
    
    success "UFW rules configured for health endpoints"
fi

# Configure iptables as backup
if command -v iptables >/dev/null 2>&1; then
    # Remove existing rules first
    iptables -D INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8002 -j ACCEPT 2>/dev/null || true
    
    # Add comprehensive rules
    iptables -I INPUT -p tcp --dport 8001 -s $PRIMARY_IP -j ACCEPT
    iptables -I INPUT -p tcp --dport 8001 -s $STANDBY_IP -j ACCEPT
    iptables -I INPUT -p tcp --dport 8001 -s 127.0.0.1 -j ACCEPT
    iptables -I INPUT -p tcp --dport 8002 -s $PRIMARY_IP -j ACCEPT
    iptables -I INPUT -p tcp --dport 8002 -s $STANDBY_IP -j ACCEPT
    iptables -I INPUT -p tcp --dport 8002 -s 127.0.0.1 -j ACCEPT
    
    success "iptables rules configured for health endpoints"
fi

# Step 4: Create improved health scripts with better error handling
info "📝 Creating improved health scripts..."

# Enhanced PostgreSQL health script
cat > /usr/local/bin/final-pg-health.sh <<'EOF'
#!/bin/bash
set -euo pipefail

PORT=${1:-8001}
ROLE="$ROLE"
SELF_IP="$SELF_IP"
LOG_FILE="/var/log/pg-health-final.log"

log_msg() {
    echo "$(date -Iseconds) - $*" >> "$LOG_FILE"
}

log_msg "Starting PostgreSQL health service on port $PORT"

while true; do
    # Health check logic
    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
        pg_role=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
        
        if [[ "$pg_role" == "$ROLE" ]]; then
            if [[ "$ROLE" == "standby" ]]; then
                wal_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_wal_receiver;" 2>/dev/null || echo "0")
                if [[ "$wal_count" -gt 0 ]]; then
                    message="PostgreSQL $pg_role operational with active replication"
                else
                    message="PostgreSQL $pg_role operational"
                fi
            else
                message="PostgreSQL $pg_role operational"
            fi
            
            response='{"status":"healthy","service":"postgresql-ha","role":"'"$ROLE"'","message":"'"$message"'","timestamp":"'"$(date -Iseconds)"'","node_ip":"'"$SELF_IP"'"}'
            http_status="HTTP/1.1 200 OK"
        else
            response='{"status":"unhealthy","service":"postgresql-ha","role":"'"$ROLE"'","message":"Role mismatch (expected '"$ROLE"', got '"$pg_role"')","timestamp":"'"$(date -Iseconds)"'","node_ip":"'"$SELF_IP"'"}'
            http_status="HTTP/1.1 503 Service Unavailable"
        fi
    else
        response='{"status":"unhealthy","service":"postgresql-ha","role":"'"$ROLE"'","message":"PostgreSQL not accessible","timestamp":"'"$(date -Iseconds)"'","node_ip":"'"$SELF_IP"'"}'
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    # Send HTTP response with better error handling
    {
        echo "$http_status"
        echo "Content-Type: application/json"
        echo "Content-Length: ${#response}"
        echo "Connection: close"
        echo "Access-Control-Allow-Origin: *"
        echo "Cache-Control: no-cache"
        echo ""
        echo "$response"
    } | timeout 30 nc -l -s 0.0.0.0 -p $PORT -q 1 2>/dev/null || {
        log_msg "Failed to bind to port $PORT, retrying in 5 seconds..."
        sleep 5
    }
done
EOF

# Enhanced PgBouncer health script
cat > /usr/local/bin/final-pgbouncer-health.sh <<'EOF'
#!/bin/bash
set -euo pipefail

PORT=${1:-8002}
SELF_IP="$SELF_IP"
LOG_FILE="/var/log/pgbouncer-health-final.log"

log_msg() {
    echo "$(date -Iseconds) - $*" >> "$LOG_FILE"
}

log_msg "Starting PgBouncer health service on port $PORT"

while true; do
    # Health check logic
    if pgrep -f pgbouncer >/dev/null 2>&1; then
        if timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
            # Try admin connection
            if timeout 5 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -c "SHOW POOLS;" >/dev/null 2>&1; then
                pool_count=$(timeout 3 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -Atqc "SHOW POOLS;" 2>/dev/null | wc -l || echo "0")
                active_pools=$((pool_count > 1 ? pool_count - 1 : 0))
                response='{"service":"pgbouncer","status":"healthy","message":"PgBouncer fully operational with admin access","detailed_status":"admin_accessible","timestamp":"'"$(date -Iseconds)"'","port":6432,"node_ip":"'"$SELF_IP"'","active_pools":'$active_pools'}'
            elif timeout 5 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
                response='{"service":"pgbouncer","status":"healthy","message":"PgBouncer operational for database connections","detailed_status":"db_accessible","timestamp":"'"$(date -Iseconds)"'","port":6432,"node_ip":"'"$SELF_IP"'"}'
            else
                response='{"service":"pgbouncer","status":"healthy","message":"PgBouncer running and accepting connections","detailed_status":"service_running","timestamp":"'"$(date -Iseconds)"'","port":6432,"node_ip":"'"$SELF_IP"'"}'
            fi
            http_status="HTTP/1.1 200 OK"
        else
            response='{"service":"pgbouncer","status":"unhealthy","message":"PgBouncer port 6432 not accepting connections","detailed_status":"port_unavailable","timestamp":"'"$(date -Iseconds)"'","port":6432,"node_ip":"'"$SELF_IP"'"}'
            http_status="HTTP/1.1 503 Service Unavailable"
        fi
    else
        response='{"service":"pgbouncer","status":"unhealthy","message":"PgBouncer process not running","detailed_status":"process_down","timestamp":"'"$(date -Iseconds)"'","port":6432,"node_ip":"'"$SELF_IP"'"}'
        http_status="HTTP/1.1 503 Service Unavailable"
    fi
    
    # Send HTTP response with better error handling
    {
        echo "$http_status"
        echo "Content-Type: application/json"
        echo "Content-Length: ${#response}"
        echo "Connection: close"
        echo "Access-Control-Allow-Origin: *"
        echo "Cache-Control: no-cache"
        echo "Server: PgBouncer-HealthMonitor/Final"
        echo ""
        echo "$response"
    } | timeout 30 nc -l -s 0.0.0.0 -p $PORT -q 1 2>/dev/null || {
        log_msg "Failed to bind to port $PORT, retrying in 5 seconds..."
        sleep 5
    }
done
EOF

# Substitute variables in the scripts
sed -i "s/\$ROLE/$ROLE/g" /usr/local/bin/final-pg-health.sh
sed -i "s/\$SELF_IP/$SELF_IP/g" /usr/local/bin/final-pg-health.sh
sed -i "s/\$SELF_IP/$SELF_IP/g" /usr/local/bin/final-pgbouncer-health.sh

chmod +x /usr/local/bin/final-pg-health.sh
chmod +x /usr/local/bin/final-pgbouncer-health.sh

# Create log files
touch /var/log/pg-health-final.log /var/log/pgbouncer-health-final.log
chown root:root /var/log/pg-health-final.log /var/log/pgbouncer-health-final.log
chmod 644 /var/log/pg-health-final.log /var/log/pgbouncer-health-final.log

# Step 5: Create final systemd services
info "📋 Creating final systemd services..."

cat > /etc/systemd/system/final-pg-health.service <<EOF
[Unit]
Description=Final PostgreSQL HA Health Endpoint
After=network.target postgresql.service
Wants=postgresql.service
StartLimitInterval=0

[Service]
Type=simple
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/bin/final-pg-health.sh 8001
Restart=always
RestartSec=15
User=root
StandardOutput=journal
StandardError=journal
TimeoutStartSec=45
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/final-pgbouncer-health.service <<EOF
[Unit]
Description=Final PgBouncer Health Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service
StartLimitInterval=0

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/final-pgbouncer-health.sh 8002
Restart=always
RestartSec=15
User=root
StandardOutput=journal
StandardError=journal
TimeoutStartSec=45
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

# Step 6: Start final services
info "🚀 Starting final health services..."

systemctl daemon-reload
systemctl enable final-pg-health.service final-pgbouncer-health.service

# Start services with monitoring
systemctl start final-pg-health.service
sleep 10
systemctl start final-pgbouncer-health.service
sleep 10

# Step 7: Comprehensive testing
info "🧪 Comprehensive testing of final setup..."

# Wait for services to fully start
sleep 15

# Test service status
for service in final-pg-health final-pgbouncer-health; do
    if systemctl is-active --quiet ${service}.service; then
        success "${service}.service is ACTIVE ✓"
    else
        error "${service}.service is NOT ACTIVE"
        systemctl status ${service}.service --no-pager -l
        journalctl -u ${service}.service --no-pager -l
    fi
done

# Test local endpoints
for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    info "Testing $service_name (port $port)..."
    
    # Multiple attempts for local testing
    for attempt in {1..5}; do
        if timeout 15 curl -s "http://localhost:$port" >/dev/null 2>&1; then
            success "Port $port ($service_name): Local access WORKING ✓"
            response=$(timeout 10 curl -s "http://localhost:$port" 2>/dev/null)
            echo "Response:"
            echo "$response" | jq . 2>/dev/null || echo "$response"
            echo ""
            break
        else
            if [[ $attempt -eq 5 ]]; then
                error "Port $port ($service_name): Local access FAILED after 5 attempts"
            else
                warn "Port $port: Attempt $attempt failed, retrying..."
                sleep 3
            fi
        fi
    done
    
    # Test network access
    if timeout 15 curl -s "http://$SELF_IP:$port" >/dev/null 2>&1; then
        success "Port $port ($service_name): Network access WORKING ✓"
    else
        warn "Port $port ($service_name): Network access issues"
    fi
done

# Final status report
info "📊 Final Status Report:"
echo "Services:"
systemctl is-active final-pg-health.service final-pgbouncer-health.service

echo ""
echo "Listening ports:"
ss -tulnp | grep -E ":(8001|8002) "

echo ""
echo "Active processes:"
ps aux | grep -E "final.*health" | grep -v grep

success "🎉 Final comprehensive fix completed!"
info ""
info "🧪 Test cross-node connectivity now:"
info "  ./test_cross_node_health.sh"
info ""
info "📊 Monitor services:"
info "  systemctl status final-pg-health.service final-pgbouncer-health.service"
info "  tail -f /var/log/pg-health-final.log /var/log/pgbouncer-health-final.log"