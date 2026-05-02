#!/bin/bash
# MINIMAL BULLETPROOF Health Solution
# Zero cleanup - just create working endpoints on unique ports

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "⚡ MINIMAL BULLETPROOF Health Solution"
echo "====================================="
echo "Strategy: Use unique ports to avoid ALL conflicts"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Creating Python health servers on unique ports (no cleanup needed)"

# Use completely unique ports to avoid any conflicts
PG_PORT=28001
PGB_PORT=28002

# Create minimal PostgreSQL health server
cat > /usr/local/bin/minimal-pg-health.py << EOF
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
from datetime import datetime

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status_code = 503
        role = "unknown"
        
        try:
            # Quick PostgreSQL check
            pg_result = subprocess.run(['systemctl', 'is-active', '--quiet', 'postgresql'], 
                                     timeout=1, capture_output=True)
            if pg_result.returncode == 0:
                try:
                    role_result = subprocess.run([
                        'sudo', '-u', 'postgres', 'psql', '-tAc', 
                        'SELECT pg_is_in_recovery();', 'postgres'
                    ], capture_output=True, text=True, timeout=1)
                    
                    if role_result.returncode == 0:
                        role = "standby" if role_result.stdout.strip() == 't' else "primary"
                        status_code = 200
                except:
                    pass
        except:
            pass
        
        response = json.dumps({
            "status": "healthy" if status_code == 200 else "unhealthy",
            "role": role,
            "timestamp": datetime.now().isoformat()
        })
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, *args): pass

if __name__ == '__main__':
    with socketserver.TCPServer(("", ${PG_PORT}), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        httpd.serve_forever()
EOF

# Create minimal PgBouncer health server  
cat > /usr/local/bin/minimal-pgbouncer-health.py << EOF
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import socket
from datetime import datetime

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status_code = 503
        
        try:
            # Check PgBouncer service and port
            pgb_result = subprocess.run(['systemctl', 'is-active', '--quiet', 'pgbouncer'], 
                                      timeout=1, capture_output=True)
            if pgb_result.returncode == 0:
                try:
                    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    sock.settimeout(0.5)
                    if sock.connect_ex(('127.0.0.1', 6432)) == 0:
                        status_code = 200
                    sock.close()
                except:
                    pass
        except:
            pass
        
        response = json.dumps({
            "status": "healthy" if status_code == 200 else "unhealthy",
            "service": "pgbouncer",
            "timestamp": datetime.now().isoformat()
        })
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, *args): pass

if __name__ == '__main__':
    with socketserver.TCPServer(("", ${PGB_PORT}), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        httpd.serve_forever()
EOF

chmod +x /usr/local/bin/minimal-pg-health.py /usr/local/bin/minimal-pgbouncer-health.py

# Create socat forwarding scripts
cat > /usr/local/bin/forward-pg-health.sh << EOF
#!/bin/bash
exec socat TCP4-LISTEN:8001,reuseaddr,fork TCP4:127.0.0.1:${PG_PORT}
EOF

cat > /usr/local/bin/forward-pgbouncer-health.sh << EOF
#!/bin/bash
exec socat TCP4-LISTEN:8002,reuseaddr,fork TCP4:127.0.0.1:${PGB_PORT}
EOF

chmod +x /usr/local/bin/forward-pg-health.sh /usr/local/bin/forward-pgbouncer-health.sh

success "✅ Created minimal health scripts"

info "Creating simple systemd services"

# Minimal systemd services
cat > /etc/systemd/system/minimal-pg-health.service <<EOF
[Unit]
Description=Minimal PostgreSQL Health
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/minimal-pg-health.py
Restart=always
RestartSec=3
User=postgres

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/minimal-pgbouncer-health.service <<EOF
[Unit]
Description=Minimal PgBouncer Health
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/minimal-pgbouncer-health.py
Restart=always
RestartSec=3
User=postgres

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/forward-pg-health.service <<EOF
[Unit]
Description=Forward PostgreSQL Health
After=minimal-pg-health.service
Requires=minimal-pg-health.service

[Service]
Type=simple
ExecStart=/usr/local/bin/forward-pg-health.sh
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/forward-pgbouncer-health.service <<EOF
[Unit]
Description=Forward PgBouncer Health
After=minimal-pgbouncer-health.service
Requires=minimal-pgbouncer-health.service

[Service]
Type=simple
ExecStart=/usr/local/bin/forward-pgbouncer-health.sh
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

success "✅ Created systemd services"

info "Starting services"
systemctl daemon-reload

# Start minimal services on unique ports
systemctl start minimal-pg-health.service
systemctl start minimal-pgbouncer-health.service
sleep 2

# Start forwarding services
systemctl start forward-pg-health.service  
systemctl start forward-pgbouncer-health.service

# Enable services
systemctl enable minimal-pg-health.service
systemctl enable minimal-pgbouncer-health.service
systemctl enable forward-pg-health.service
systemctl enable forward-pgbouncer-health.service

sleep 3

info "Testing endpoints"

echo "Testing unique ports:"
echo -n "PostgreSQL (${PG_PORT}): "
timeout 2 curl -sf http://localhost:${PG_PORT} >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "PgBouncer (${PGB_PORT}): "
timeout 2 curl -sf http://localhost:${PGB_PORT} >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo
echo "Testing standard ports:"
echo -n "PostgreSQL (8001): "
timeout 2 curl -sf http://localhost:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "PgBouncer (8002): "
timeout 2 curl -sf http://localhost:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

SELF_IP=$(hostname -I | awk '{print $1}')
echo -n "External PostgreSQL ($SELF_IP:8001): "
timeout 2 curl -sf http://$SELF_IP:8001 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

echo -n "External PgBouncer ($SELF_IP:8002): "
timeout 2 curl -sf http://$SELF_IP:8002 >/dev/null 2>&1 && echo "✅ WORKING" || echo "❌ FAILED"

# Final check
working=0
timeout 2 curl -sf http://localhost:8001 >/dev/null 2>&1 && working=$((working+1)) || true
timeout 2 curl -sf http://localhost:8002 >/dev/null 2>&1 && working=$((working+1)) || true

echo
if [ $working -eq 2 ]; then
    success "🎉 MINIMAL SOLUTION SUCCESS!"
    success "✅ Both endpoints working on standard ports"
    echo
    info "Architecture:"
    echo "  Client:8001 → socat → Python:${PG_PORT}"
    echo "  Client:8002 → socat → Python:${PG_PORT}"
else
    echo "❌ Only $working/2 endpoints working"
    echo "Service status:"
    systemctl is-active minimal-pg-health.service || echo "PG service inactive"
    systemctl is-active minimal-pgbouncer-health.service || echo "PGB service inactive"  
    systemctl is-active forward-pg-health.service || echo "PG forward inactive"
    systemctl is-active forward-pgbouncer-health.service || echo "PGB forward inactive"
fi

echo
success "⚡ Minimal bulletproof solution complete!"
echo
info "Next: Test cross-node with: sudo ./test_health_checks_v1.2.sh"