#!/bin/bash
# Simple Clean Restart - Fix Port Conflicts
# This will cleanly restart all health endpoints

set -e

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }

info "🧹 Simple Clean Restart for Health Endpoints"
info "============================================"

ROLE=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
SELF_IP=$(hostname -I | awk '{print $1}')

info "Node: $ROLE (IP: $SELF_IP)"

# Step 1: Kill ALL processes on ports 8001 and 8002
info "🛑 Killing all processes on ports 8001 and 8002..."
fuser -k 8001/tcp 2>/dev/null || true
fuser -k 8002/tcp 2>/dev/null || true
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "pg_health" 2>/dev/null || true
pkill -f "pgbouncer_health" 2>/dev/null || true
sleep 5

# Verify ports are free
info "🔍 Verifying ports are free..."
if netstat -tuln 2>/dev/null | grep -q ":8001"; then
    warn "Port 8001 still in use - force killing..."
    fuser -k -9 8001/tcp 2>/dev/null || true
    sleep 2
fi

if netstat -tuln 2>/dev/null | grep -q ":8002"; then
    warn "Port 8002 still in use - force killing..."
    fuser -k -9 8002/tcp 2>/dev/null || true
    sleep 2
fi

# Step 2: Simple firewall rules
info "🔥 Setting simple firewall rules..."
iptables -I INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 8002 -j ACCEPT 2>/dev/null || true

# Step 3: Create single, simple health scripts
info "🏥 Creating single health endpoint scripts..."

# PostgreSQL health script
cat > /tmp/clean_pg_health.sh << 'EOF'
#!/bin/bash
SELF_IP=$(hostname -I | awk '{print $1}')

while true; do
    if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
        role=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
        response="{\"status\":\"healthy\",\"service\":\"postgresql-ha\",\"role\":\"$role\",\"message\":\"PostgreSQL $role operational\",\"timestamp\":\"$(date -Iseconds)\",\"node_ip\":\"$SELF_IP\"}"
        status_line="HTTP/1.1 200 OK"
    else
        response="{\"status\":\"unhealthy\",\"service\":\"postgresql-ha\",\"role\":\"unknown\",\"message\":\"PostgreSQL not accessible\",\"timestamp\":\"$(date -Iseconds)\",\"node_ip\":\"$SELF_IP\"}"
        status_line="HTTP/1.1 503 Service Unavailable"
    fi
    
    content_length=${#response}
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s" \
        "$status_line" "$content_length" "$response" | nc -l -s 0.0.0.0 -p 8001 -q 1 2>/dev/null || sleep 1
done
EOF

# PgBouncer health script
cat > /tmp/clean_pgbouncer_health.sh << 'EOF'
#!/bin/bash
SELF_IP=$(hostname -I | awk '{print $1}')

while true; do
    if pgrep -f pgbouncer >/dev/null 2>&1 && timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        response="{\"service\":\"pgbouncer\",\"status\":\"healthy\",\"message\":\"PgBouncer operational\",\"timestamp\":\"$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"$SELF_IP\"}"
        status_line="HTTP/1.1 200 OK"
    else
        response="{\"service\":\"pgbouncer\",\"status\":\"unhealthy\",\"message\":\"PgBouncer not accessible\",\"timestamp\":\"$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"$SELF_IP\"}"
        status_line="HTTP/1.1 503 Service Unavailable"
    fi
    
    content_length=${#response}
    printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s" \
        "$status_line" "$content_length" "$response" | nc -l -s 0.0.0.0 -p 8002 -q 1 2>/dev/null || sleep 1
done
EOF

chmod +x /tmp/clean_pg_health.sh /tmp/clean_pgbouncer_health.sh

# Step 4: Start ONLY ONE instance of each endpoint
info "🚀 Starting clean health endpoints..."
nohup /tmp/clean_pg_health.sh >/dev/null 2>&1 &
PG_PID=$!
sleep 2

nohup /tmp/clean_pgbouncer_health.sh >/dev/null 2>&1 &
PGB_PID=$!
sleep 3

# Step 5: Test local endpoints
info "🧪 Testing clean endpoints..."

# Test PostgreSQL endpoint
if timeout 10 curl -s http://localhost:8001 >/dev/null 2>&1; then
    success "✅ PostgreSQL health (8001): WORKING"
    response=$(timeout 5 curl -s http://localhost:8001 2>/dev/null)
    info "Response: $(echo "$response" | jq -r '.role // .service')"
else
    warn "❌ PostgreSQL health (8001): FAILED"
fi

# Test PgBouncer endpoint
if timeout 10 curl -s http://localhost:8002 >/dev/null 2>&1; then
    success "✅ PgBouncer health (8002): WORKING"
    response=$(timeout 5 curl -s http://localhost:8002 2>/dev/null)
    info "Response: $(echo "$response" | jq -r '.service // "pgbouncer"')"
else
    warn "❌ PgBouncer health (8002): FAILED"
fi

# Step 6: Test external access
info "🌐 Testing external access..."

if timeout 10 curl -s "http://$SELF_IP:8001" >/dev/null 2>&1; then
    success "✅ External PostgreSQL health: WORKING"
else
    warn "❌ External PostgreSQL health: FAILED"
fi

if timeout 10 curl -s "http://$SELF_IP:8002" >/dev/null 2>&1; then
    success "✅ External PgBouncer health: WORKING"
else
    warn "❌ External PgBouncer health: FAILED"
fi

# Step 7: Show process status
info "📊 Process Status:"
info "  PostgreSQL health PID: $PG_PID"
info "  PgBouncer health PID: $PGB_PID"

if ps -p $PG_PID >/dev/null 2>&1; then
    info "  ✓ PostgreSQL health process running"
else
    warn "  ✗ PostgreSQL health process died"
fi

if ps -p $PGB_PID >/dev/null 2>&1; then
    info "  ✓ PgBouncer health process running"
else
    warn "  ✗ PgBouncer health process died"
fi

# Step 8: Show listening ports
info "🔍 Listening ports:"
netstat -tuln 2>/dev/null | grep ":800[12]" || info "  No health endpoints found in netstat"

success "🎯 Clean restart completed!"
info "Run this on both nodes, then test with: sudo ./test_health_checks_v1.1.sh"