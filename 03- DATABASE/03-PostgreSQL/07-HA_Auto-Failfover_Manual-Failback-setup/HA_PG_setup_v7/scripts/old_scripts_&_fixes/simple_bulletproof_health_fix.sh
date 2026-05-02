#!/bin/bash
# Simple Bulletproof Health Fix
# Gets straight to the working solution without complex cleanup

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "⚡ SIMPLE BULLETPROOF HEALTH FIX"
echo "==============================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Quick cleanup (no complex operations)"
# Simple, fast cleanup
systemctl stop pg-ha-health.service 2>/dev/null || true >&/dev/null &
systemctl stop pgbouncer-health.service 2>/dev/null || true >&/dev/null &
wait

info "Step 2: Create WORKING health scripts"

# Create simple, working PostgreSQL health script
cat > /usr/local/bin/pg-simple-health-working.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import sys
from datetime import datetime

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8001

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            status_code = 503
            role = "unknown"
            
            # Check PostgreSQL
            pg_active = subprocess.run(['systemctl', 'is-active', '--quiet', 'postgresql'], 
                                     capture_output=True).returncode == 0
            
            if pg_active:
                try:
                    # Check role
                    result = subprocess.run([
                        'sudo', '-u', 'postgres', 'psql', '-tAc', 
                        'SELECT pg_is_in_recovery();', 'postgres'
                    ], capture_output=True, text=True, timeout=3)
                    
                    if result.returncode == 0:
                        is_standby = result.stdout.strip() == 't'
                        role = "standby" if is_standby else "primary"
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
            self.end_headers()
            error_response = json.dumps({"status": "error", "message": str(e)})
            self.wfile.write(error_response.encode())
    
    def log_message(self, format, *args):
        pass

if __name__ == '__main__':
    with socketserver.TCPServer(("", PORT), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        httpd.serve_forever()
EOF

# Create simple, working PgBouncer health script
cat > /usr/local/bin/pgbouncer-simple-health-working.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import socket
import sys
from datetime import datetime

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8002

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            status_code = 503
            
            # Check PgBouncer
            pgb_active = subprocess.run(['systemctl', 'is-active', '--quiet', 'pgbouncer'], 
                                      capture_output=True).returncode == 0
            
            if pgb_active:
                try:
                    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    sock.settimeout(2)
                    result = sock.connect_ex(('localhost', 6432))
                    if result == 0:
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
            self.end_headers()
            error_response = json.dumps({"status": "error", "message": str(e)})
            self.wfile.write(error_response.encode())
    
    def log_message(self, format, *args):
        pass

if __name__ == '__main__':
    with socketserver.TCPServer(("", PORT), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        httpd.serve_forever()
EOF

chmod +x /usr/local/bin/pg-simple-health-working.py /usr/local/bin/pgbouncer-simple-health-working.py
success "✅ Created working Python health scripts"

info "Step 3: Create simple systemd services"

cat > /etc/systemd/system/pg-working-health.service <<EOF
[Unit]
Description=PostgreSQL Working Health Check
After=network.target postgresql.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pg-simple-health-working.py 8001
Restart=always
RestartSec=3
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-working-health.service <<EOF
[Unit]
Description=PgBouncer Working Health Check
After=network.target pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pgbouncer-simple-health-working.py 8002
Restart=always
RestartSec=3
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

success "✅ Created simple systemd services"

info "Step 4: Start working services"
systemctl daemon-reload

# Start services
systemctl start pg-working-health.service
systemctl start pgbouncer-working-health.service

# Enable for boot
systemctl enable pg-working-health.service
systemctl enable pgbouncer-working-health.service

sleep 3

info "Step 5: Quick test"

echo -n "PostgreSQL (8001): "
timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "PgBouncer (8002): "
timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

SELF_IP=$(hostname -I | awk '{print $1}')
echo -n "Self PostgreSQL ($SELF_IP:8001): "
timeout 3 curl -sf http://$SELF_IP:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "Self PgBouncer ($SELF_IP:8002): "
timeout 3 curl -sf http://$SELF_IP:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo
if timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1 && timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "🎉 SIMPLE FIX SUCCESS!"
    success "✅ Health endpoints working with Python HTTP servers"
    
    echo
    info "Sample responses:"
    echo "PostgreSQL:"
    curl -s http://localhost:8001 2>/dev/null | python3 -m json.tool || echo "No response"
    echo "PgBouncer:"
    curl -s http://localhost:8002 2>/dev/null | python3 -m json.tool || echo "No response"
else
    echo "❌ Some endpoints not working - check services:"
    systemctl status pg-working-health.service --no-pager || true
    systemctl status pgbouncer-working-health.service --no-pager || true
fi

echo
success "⚡ Simple bulletproof fix complete!"
echo
info "Next: Run on both servers, then test with:"
echo "sudo ./test_health_checks_v1.2.sh"