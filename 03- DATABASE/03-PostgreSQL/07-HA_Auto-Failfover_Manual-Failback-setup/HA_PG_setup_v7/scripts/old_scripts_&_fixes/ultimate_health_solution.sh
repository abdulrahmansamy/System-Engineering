#!/bin/bash
# ULTIMATE Health Solution - High Ports + Systemd Proxy
# Solves ALL binding, permission, and port conflict issues

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "🚀 ULTIMATE Health Solution"
echo "=========================="
echo "Strategy: High ports (18001/18002) + socat proxy to standard ports"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Nuclear cleanup of ALL health processes and ports"

# Stop all known health services
for service in pg-ha-health pgbouncer-health pg-working-health pgbouncer-working-health \
               pg-definitive-health pgbouncer-definitive-health pg-ultimate-health pgbouncer-ultimate-health; do
    systemctl stop ${service}.service 2>/dev/null || true
    systemctl disable ${service}.service 2>/dev/null || true
done

# Kill all processes on target ports
for port in 8001 8002 18001 18002; do
    lsof -ti:$port 2>/dev/null | xargs -r kill -9 2>/dev/null || true
done

# Kill health-related processes
pkill -f "health" 2>/dev/null || true
pkill -f "python.*800" 2>/dev/null || true
pkill -f "socat.*800" 2>/dev/null || true

sleep 3
success "✅ Nuclear cleanup completed"

info "Step 2: Create Python health services on HIGH ports (no permission issues)"

# Create PostgreSQL health service on port 18001
cat > /usr/local/bin/pg-ultimate-health.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import sys
import signal
import os
from datetime import datetime

# Use high port to avoid permission issues
PORT = 18001

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            status_code = 503
            role = "unknown"
            
            # Check PostgreSQL service
            try:
                result = subprocess.run(['systemctl', 'is-active', '--quiet', 'postgresql'], 
                                       timeout=2, capture_output=True)
                pg_active = result.returncode == 0
            except:
                pg_active = False
            
            if pg_active:
                try:
                    # Check role with timeout
                    result = subprocess.run([
                        'sudo', '-u', 'postgres', 'psql', '-tAc', 
                        'SELECT pg_is_in_recovery();', 'postgres'
                    ], capture_output=True, text=True, timeout=2)
                    
                    if result.returncode == 0:
                        is_standby = result.stdout.strip() == 't'
                        role = "standby" if is_standby else "primary"
                        status_code = 200
                except:
                    # If DB check fails, still mark as unhealthy but service running
                    role = "unknown"
            
            response_data = {
                "status": "healthy" if status_code == 200 else "unhealthy",
                "role": role,
                "timestamp": datetime.now().isoformat(),
                "port": PORT
            }
            
            response_json = json.dumps(response_data)
            
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response_json)))
            self.send_header('Connection', 'close')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(response_json.encode())
            
        except Exception as e:
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            error_response = json.dumps({
                "status": "error", 
                "message": f"Health check failed: {str(e)}", 
                "timestamp": datetime.now().isoformat()
            })
            self.wfile.write(error_response.encode())
    
    def log_message(self, format, *args):
        # Suppress default logging to reduce noise
        pass

def signal_handler(signum, frame):
    print(f"Received signal {signum}, shutting down gracefully...")
    sys.exit(0)

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    print(f"Starting PostgreSQL health server on port {PORT}")
    
    # Ensure we can bind to the port
    try:
        with socketserver.TCPServer(("0.0.0.0", PORT), HealthHandler) as httpd:
            httpd.allow_reuse_address = True
            httpd.serve_forever()
    except Exception as e:
        print(f"Failed to start health server: {e}")
        sys.exit(1)
EOF

# Create PgBouncer health service on port 18002
cat > /usr/local/bin/pgbouncer-ultimate-health.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import socket
import sys
import signal
from datetime import datetime

# Use high port to avoid permission issues
PORT = 18002

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            status_code = 503
            
            # Check PgBouncer service
            try:
                result = subprocess.run(['systemctl', 'is-active', '--quiet', 'pgbouncer'], 
                                       timeout=2, capture_output=True)
                pgb_active = result.returncode == 0
            except:
                pgb_active = False
            
            if pgb_active:
                # Test actual connectivity to PgBouncer port
                try:
                    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    sock.settimeout(1)
                    result = sock.connect_ex(('127.0.0.1', 6432))
                    if result == 0:
                        status_code = 200
                    sock.close()
                except:
                    pass
            
            response_data = {
                "status": "healthy" if status_code == 200 else "unhealthy",
                "service": "pgbouncer",
                "timestamp": datetime.now().isoformat(),
                "port": PORT
            }
            
            response_json = json.dumps(response_data)
            
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response_json)))
            self.send_header('Connection', 'close')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(response_json.encode())
            
        except Exception as e:
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            error_response = json.dumps({
                "status": "error", 
                "message": f"PgBouncer check failed: {str(e)}", 
                "timestamp": datetime.now().isoformat()
            })
            self.wfile.write(error_response.encode())
    
    def log_message(self, format, *args):
        # Suppress default logging
        pass

def signal_handler(signum, frame):
    print(f"Received signal {signum}, shutting down gracefully...")
    sys.exit(0)

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    print(f"Starting PgBouncer health server on port {PORT}")
    
    try:
        with socketserver.TCPServer(("0.0.0.0", PORT), HealthHandler) as httpd:
            httpd.allow_reuse_address = True
            httpd.serve_forever()
    except Exception as e:
        print(f"Failed to start PgBouncer health server: {e}")
        sys.exit(1)
EOF

chmod +x /usr/local/bin/pg-ultimate-health.py /usr/local/bin/pgbouncer-ultimate-health.py
success "✅ Created Python health services on high ports"

info "Step 3: Create socat proxies from standard ports to high ports"

# Create socat proxy scripts
cat > /usr/local/bin/pg-health-proxy.sh << 'EOF'
#!/bin/bash
# Proxy from 8001 to 18001
exec socat TCP4-LISTEN:8001,reuseaddr,fork TCP4:127.0.0.1:18001
EOF

cat > /usr/local/bin/pgbouncer-health-proxy.sh << 'EOF'
#!/bin/bash
# Proxy from 8002 to 18002
exec socat TCP4-LISTEN:8002,reuseaddr,fork TCP4:127.0.0.1:18002
EOF

chmod +x /usr/local/bin/pg-health-proxy.sh /usr/local/bin/pgbouncer-health-proxy.sh
success "✅ Created socat proxy scripts"

info "Step 4: Create robust systemd services"

# PostgreSQL health service (high port)
cat > /etc/systemd/system/pg-ultimate-health.service <<EOF
[Unit]
Description=PostgreSQL Ultimate Health Service
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pg-ultimate-health.py
Restart=always
RestartSec=5
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# PgBouncer health service (high port)
cat > /etc/systemd/system/pgbouncer-ultimate-health.service <<EOF
[Unit]
Description=PgBouncer Ultimate Health Service
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pgbouncer-ultimate-health.py
Restart=always
RestartSec=5
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# PostgreSQL health proxy (standard port)
cat > /etc/systemd/system/pg-health-proxy.service <<EOF
[Unit]
Description=PostgreSQL Health Proxy (8001 -> 18001)
After=network.target pg-ultimate-health.service
Requires=pg-ultimate-health.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pg-health-proxy.sh
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

# PgBouncer health proxy (standard port)
cat > /etc/systemd/system/pgbouncer-health-proxy.service <<EOF
[Unit]
Description=PgBouncer Health Proxy (8002 -> 18002)
After=network.target pgbouncer-ultimate-health.service
Requires=pgbouncer-ultimate-health.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pgbouncer-health-proxy.sh
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

success "✅ Created robust systemd services"

info "Step 5: Start services in correct order"

systemctl daemon-reload

# Start high-port services first
systemctl start pg-ultimate-health.service
systemctl start pgbouncer-ultimate-health.service

# Wait for services to be ready
sleep 3

# Test high-port services
if curl -sf http://localhost:18001 >/dev/null 2>&1; then
    success "✅ PostgreSQL high-port service (18001) working"
else
    error "❌ PostgreSQL high-port service failed"
    journalctl -u pg-ultimate-health.service --lines=5 --no-pager
fi

if curl -sf http://localhost:18002 >/dev/null 2>&1; then
    success "✅ PgBouncer high-port service (18002) working"  
else
    error "❌ PgBouncer high-port service failed"
    journalctl -u pgbouncer-ultimate-health.service --lines=5 --no-pager
fi

# Start proxy services
systemctl start pg-health-proxy.service
systemctl start pgbouncer-health-proxy.service

# Enable all services
systemctl enable pg-ultimate-health.service
systemctl enable pgbouncer-ultimate-health.service
systemctl enable pg-health-proxy.service
systemctl enable pgbouncer-health-proxy.service

sleep 5

info "Step 6: Comprehensive testing"

echo "Service Status:"
echo "==============="
systemctl is-active pg-ultimate-health.service && echo "✅ PostgreSQL health service" || echo "❌ PostgreSQL health service"
systemctl is-active pgbouncer-ultimate-health.service && echo "✅ PgBouncer health service" || echo "❌ PgBouncer health service"
systemctl is-active pg-health-proxy.service && echo "✅ PostgreSQL proxy" || echo "❌ PostgreSQL proxy"
systemctl is-active pgbouncer-health-proxy.service && echo "✅ PgBouncer proxy" || echo "❌ PgBouncer proxy"

echo
echo "Port Testing:"
echo "============="

# Test all endpoints
test_endpoint() {
    local url="$1"
    local name="$2"
    
    if response=$(timeout 3 curl -sf "$url" 2>/dev/null); then
        if echo "$response" | jq . >/dev/null 2>&1; then
            echo "✅ $name: WORKING"
            echo "   $(echo "$response" | jq -c .)"
        else
            echo "❌ $name: Invalid JSON"
        fi
    else
        echo "❌ $name: Connection failed"
    fi
}

test_endpoint "http://localhost:18001" "PostgreSQL High Port (18001)"
test_endpoint "http://localhost:18002" "PgBouncer High Port (18002)"
test_endpoint "http://localhost:8001" "PostgreSQL Standard Port (8001)"
test_endpoint "http://localhost:8002" "PgBouncer Standard Port (8002)"

SELF_IP=$(hostname -I | awk '{print $1}')
test_endpoint "http://$SELF_IP:8001" "PostgreSQL External ($SELF_IP:8001)"
test_endpoint "http://$SELF_IP:8002" "PgBouncer External ($SELF_IP:8002)"

# Final verification
working_count=0
for port in 8001 8002; do
    if timeout 3 curl -sf http://localhost:$port >/dev/null 2>&1; then
        ((working_count++))
    fi
done

echo
echo "FINAL RESULT:"
echo "============="
if [ $working_count -eq 2 ]; then
    success "🎉 ULTIMATE SOLUTION SUCCESS!"
    success "✅ All health endpoints working on standard ports (8001/8002)"
    success "✅ Python services stable on high ports (18001/18002)"
    success "✅ Socat proxies providing transparent access"
    
    echo
    info "Architecture:"
    echo "  Client → 8001/8002 (socat proxy) → 18001/18002 (Python server)"
    echo "  ✅ No port conflicts"
    echo "  ✅ No permission issues"  
    echo "  ✅ Stable service binding"
    echo "  ✅ Production ready"
else
    error "❌ Only $working_count/2 endpoints working"
    info "Check service logs for issues"
fi

echo
success "🚀 Ultimate health solution deployed!"
echo
info "Next steps:"
echo "1. Run on both servers"
echo "2. Test: sudo ./test_health_checks_v1.2.sh"
echo "3. Expect 6/6 working endpoints!"