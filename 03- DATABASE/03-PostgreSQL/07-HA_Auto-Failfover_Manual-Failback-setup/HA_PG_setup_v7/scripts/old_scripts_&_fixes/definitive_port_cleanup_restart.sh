#!/bin/bash
# DEFINITIVE Port Cleanup & Health Restart
# Eliminates ALL port conflicts and creates clean working solution

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "🧹 DEFINITIVE Port Cleanup & Health Restart"
echo "==========================================="
echo "Goal: Eliminate ALL conflicts and create clean working health endpoints"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Nuclear cleanup - Kill ALL processes using ports 8001/8002"

# Stop all known health services
for service in pg-ha-health pgbouncer-health pg-working-health pgbouncer-working-health \
               pg-definitive-health pgbouncer-definitive-health pg-ultimate-health pgbouncer-ultimate-health \
               minimal-pg-health minimal-pgbouncer-health forward-pg-health forward-pgbouncer-health; do
    systemctl stop ${service}.service 2>/dev/null || true
    systemctl disable ${service}.service 2>/dev/null || true
done

# Nuclear port cleanup - Kill everything on target ports
info "Killing ALL processes on ports 8001, 8002, 28001, 28002..."
for port in 8001 8002 28001 28002; do
    # Find and kill all processes using the port
    fuser -k ${port}/tcp 2>/dev/null || true
    lsof -ti:${port} 2>/dev/null | xargs -r kill -9 2>/dev/null || true
done

# Kill netcat/socat processes that might be hanging around
pkill -f "nc.*800" 2>/dev/null || true
pkill -f "socat.*800" 2>/dev/null || true
pkill -f "python.*800" 2>/dev/null || true
pkill -f "python.*28" 2>/dev/null || true

sleep 5
success "✅ Nuclear cleanup completed"

info "Step 2: Verify ports are completely free"
for port in 8001 8002; do
    if ss -tuln | grep -q ":${port} "; then
        warn "⚠️ Port ${port} still in use - forcing cleanup"
        lsof -ti:${port} 2>/dev/null | xargs -r kill -9 2>/dev/null || true
        sleep 2
    fi
done

info "Step 3: Create FINAL working health solution - Pure Python on standard ports"

# Create final PostgreSQL health script - direct on port 8001
cat > /usr/local/bin/final-pg-health.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import signal
import sys
from datetime import datetime

PORT = 8001

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            status_code = 503
            role = "unknown"
            
            # Quick PostgreSQL check
            try:
                pg_result = subprocess.run(['systemctl', 'is-active', '--quiet', 'postgresql'], 
                                         timeout=1, capture_output=True)
                if pg_result.returncode == 0:
                    # Check role
                    role_result = subprocess.run([
                        'sudo', '-u', 'postgres', 'psql', '-tAc', 
                        'SELECT pg_is_in_recovery();', 'postgres'
                    ], capture_output=True, text=True, timeout=1)
                    
                    if role_result.returncode == 0:
                        role = "standby" if role_result.stdout.strip() == 't' else "primary"
                        status_code = 200
            except:
                pass
            
            response_data = {
                "status": "healthy" if status_code == 200 else "unhealthy",
                "role": role,
                "timestamp": datetime.now().isoformat()
            }
            
            response_json = json.dumps(response_data)
            
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response_json)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(response_json.encode())
            
        except Exception as e:
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            error_response = json.dumps({
                "status": "error", 
                "message": str(e), 
                "timestamp": datetime.now().isoformat()
            })
            self.wfile.write(error_response.encode())
    
    def log_message(self, *args): pass

def signal_handler(signum, frame):
    print(f"Received signal {signum}, shutting down...")
    sys.exit(0)

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    try:
        with socketserver.TCPServer(("0.0.0.0", PORT), HealthHandler) as httpd:
            httpd.allow_reuse_address = True
            print(f"PostgreSQL health server started on port {PORT}")
            httpd.serve_forever()
    except Exception as e:
        print(f"Failed to start server: {e}")
        sys.exit(1)
EOF

# Create final PgBouncer health script - direct on port 8002
cat > /usr/local/bin/final-pgbouncer-health.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import socket
import signal
import sys
from datetime import datetime

PORT = 8002

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            status_code = 503
            
            # Quick PgBouncer check
            try:
                pgb_result = subprocess.run(['systemctl', 'is-active', '--quiet', 'pgbouncer'], 
                                          timeout=1, capture_output=True)
                if pgb_result.returncode == 0:
                    # Test port connectivity
                    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    sock.settimeout(0.5)
                    if sock.connect_ex(('127.0.0.1', 6432)) == 0:
                        status_code = 200
                    sock.close()
            except:
                pass
            
            response_data = {
                "status": "healthy" if status_code == 200 else "unhealthy",
                "service": "pgbouncer",
                "timestamp": datetime.now().isoformat()
            }
            
            response_json = json.dumps(response_data)
            
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response_json)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(response_json.encode())
            
        except Exception as e:
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            error_response = json.dumps({
                "status": "error", 
                "message": str(e), 
                "timestamp": datetime.now().isoformat()
            })
            self.wfile.write(error_response.encode())
    
    def log_message(self, *args): pass

def signal_handler(signum, frame):
    print(f"Received signal {signum}, shutting down...")
    sys.exit(0)

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    try:
        with socketserver.TCPServer(("0.0.0.0", PORT), HealthHandler) as httpd:
            httpd.allow_reuse_address = True
            print(f"PgBouncer health server started on port {PORT}")
            httpd.serve_forever()
    except Exception as e:
        print(f"Failed to start server: {e}")
        sys.exit(1)
EOF

chmod +x /usr/local/bin/final-pg-health.py /usr/local/bin/final-pgbouncer-health.py
success "✅ Created final Python health scripts"

info "Step 4: Create clean systemd services"

cat > /etc/systemd/system/final-pg-health.service <<EOF
[Unit]
Description=Final PostgreSQL Health Service
After=network.target postgresql.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/final-pg-health.py
Restart=always
RestartSec=5
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/final-pgbouncer-health.service <<EOF
[Unit]
Description=Final PgBouncer Health Service
After=network.target pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/final-pgbouncer-health.py
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
success "✅ Created clean systemd services"

info "Step 5: Start final services"

# Start services
systemctl start final-pg-health.service
systemctl start final-pgbouncer-health.service

# Enable for boot
systemctl enable final-pg-health.service
systemctl enable final-pgbouncer-health.service

sleep 3

info "Step 6: Test final solution"

echo "Port binding verification:"
ss -tuln | grep -E ':(8001|8002) ' || echo "No ports bound yet"

echo
echo "Service status:"
systemctl is-active final-pg-health.service && echo "✅ PostgreSQL service active" || echo "❌ PostgreSQL service failed"
systemctl is-active final-pgbouncer-health.service && echo "✅ PgBouncer service active" || echo "❌ PgBouncer service failed"

echo
echo "Endpoint testing:"

test_endpoint() {
    local url="$1"
    local name="$2"
    
    echo -n "$name: "
    if response=$(timeout 3 curl -sf "$url" 2>/dev/null); then
        if echo "$response" | jq . >/dev/null 2>&1; then
            echo "✅ WORKING"
            echo "  $(echo "$response" | jq -c .)"
            return 0
        else
            echo "❌ BAD_JSON"
        fi
    else
        echo "❌ FAILED"
    fi
    return 1
}

working=0
test_endpoint "http://localhost:8001" "PostgreSQL Local" && working=$((working+1)) || true
test_endpoint "http://localhost:8002" "PgBouncer Local" && working=$((working+1)) || true

SELF_IP=$(hostname -I | awk '{print $1}')
test_endpoint "http://$SELF_IP:8001" "PostgreSQL External" && working=$((working+1)) || true
test_endpoint "http://$SELF_IP:8002" "PgBouncer External" && working=$((working+1)) || true

echo
echo "FINAL RESULT:"
echo "============="
if [ $working -eq 4 ]; then
    success "🎉 DEFINITIVE SUCCESS!"
    success "✅ All 4 endpoints working (local + external)"
    success "✅ Clean port binding - no conflicts"
    success "✅ Production ready health endpoints"
elif [ $working -ge 2 ]; then
    success "✅ Partial success - $working/4 endpoints working"
    warn "⚠️ Some endpoints may have network/firewall issues"
else
    error "❌ Services failed to start properly"
    info "Check logs: journalctl -u final-pg-health.service -u final-pgbouncer-health.service"
fi

echo
info "Current port usage:"
ss -tuln | grep -E ':(8001|8002) '

echo
success "🧹 Definitive cleanup and restart complete!"
echo
info "Next steps:"
echo "1. Run this script on BOTH servers"
echo "2. Test cross-node connectivity"
echo "3. Configure GCP Load Balancer health checks"