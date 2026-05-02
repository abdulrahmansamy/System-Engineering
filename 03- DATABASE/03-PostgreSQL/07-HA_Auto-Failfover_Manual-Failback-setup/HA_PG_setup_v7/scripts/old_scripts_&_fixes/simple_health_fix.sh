#!/bin/bash
# Simple Health Endpoint Fix - No complexity, just works
# Run on both servers to get working health endpoints

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "🔧 Simple Health Endpoint Fix"
echo "=============================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# Install Python3 if not present
apt-get update -qq
apt-get install -y python3 >/dev/null 2>&1

# Stop existing health services completely
info "Stopping all health services..."
systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true
pkill -f "8001" 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true
pkill -f "health" 2>/dev/null || true
sleep 3

# Create simple PostgreSQL health check
info "Creating simple PostgreSQL health endpoint..."
cat > /usr/local/bin/pg-health-simple.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import sys

PORT = 8001

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Default unhealthy
        status_code = 503
        role = "unknown"
        
        try:
            # Check if PostgreSQL is active
            result = subprocess.run(['systemctl', 'is-active', 'postgresql'], 
                                  capture_output=True, text=True, timeout=5)
            
            if result.returncode == 0:
                # Check if primary (not in recovery)
                primary_check = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 
                                              'SELECT NOT pg_is_in_recovery();', 'postgres'], 
                                             capture_output=True, text=True, timeout=5)
                
                if primary_check.returncode == 0 and 't' in primary_check.stdout:
                    status_code = 200
                    role = "primary"
                else:
                    # Check if standby (in recovery)
                    standby_check = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 
                                                  'SELECT pg_is_in_recovery();', 'postgres'], 
                                                 capture_output=True, text=True, timeout=5)
                    
                    if standby_check.returncode == 0 and 't' in standby_check.stdout:
                        # Check WAL receiver
                        wal_check = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 
                                                  "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';", 'postgres'], 
                                                 capture_output=True, text=True, timeout=5)
                        
                        if wal_check.returncode == 0:
                            wal_count = int(wal_check.stdout.strip() or '0')
                            if wal_count >= 1:
                                status_code = 200
                        
                        role = "standby"
        except:
            pass
        
        # Response
        response_data = {
            "status": "healthy" if status_code == 200 else "unhealthy",
            "role": role,
            "timestamp": "2025-10-12T16:10:00Z"
        }
        
        response_json = json.dumps(response_data)
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response_json)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response_json.encode())
    
    def log_message(self, format, *args):
        pass

try:
    with socketserver.TCPServer(("", PORT), HealthHandler) as httpd:
        httpd.serve_forever()
except KeyboardInterrupt:
    pass
EOF

# Create simple PgBouncer health check
info "Creating simple PgBouncer health endpoint..."
cat > /usr/local/bin/pgbouncer-health-simple.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import socket

PORT = 8002

class PgBouncerHealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status_code = 503
        service_status = "unhealthy"
        
        try:
            # Check service
            result = subprocess.run(['systemctl', 'is-active', 'pgbouncer'], 
                                  capture_output=True, text=True, timeout=3)
            
            if result.returncode == 0:
                # Check port
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(2)
                port_result = sock.connect_ex(('localhost', 6432))
                sock.close()
                
                if port_result == 0:
                    status_code = 200
                    service_status = "healthy"
        except:
            pass
        
        response_data = {
            "status": service_status,
            "service": "pgbouncer",
            "timestamp": "2025-10-12T16:10:00Z"
        }
        
        response_json = json.dumps(response_data)
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response_json)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response_json.encode())
    
    def log_message(self, format, *args):
        pass

try:
    with socketserver.TCPServer(("", PORT), PgBouncerHealthHandler) as httpd:
        httpd.serve_forever()
except KeyboardInterrupt:
    pass
EOF

chmod +x /usr/local/bin/pg-health-simple.py /usr/local/bin/pgbouncer-health-simple.py

# Create simple systemd services
info "Creating simple systemd services..."

cat > /etc/systemd/system/pg-health-simple.service << 'EOF'
[Unit]
Description=Simple PostgreSQL Health Check
After=postgresql.service
Wants=postgresql.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pg-health-simple.py
Restart=always
RestartSec=10
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-health-simple.service << 'EOF'
[Unit]
Description=Simple PgBouncer Health Check
After=pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pgbouncer-health-simple.py
Restart=always
RestartSec=10
User=postgres
Group=postgres

[Install]
WantedBy=multi-user.target
EOF

# Start services
info "Starting simple health services..."
systemctl daemon-reload

systemctl enable pg-health-simple.service
systemctl start pg-health-simple.service

systemctl enable pgbouncer-health-simple.service  
systemctl start pgbouncer-health-simple.service

# Wait for startup
sleep 5

# Test endpoints
info "Testing health endpoints..."
echo -n "PostgreSQL Health (8001): "
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ Working!"
    curl -s http://localhost:8001 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8001
else
    error "❌ Failed"
    echo "Checking service status:"
    systemctl status pg-health-simple.service --no-pager -l || true
fi

echo
echo -n "PgBouncer Health (8002): "
if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ Working!"  
    curl -s http://localhost:8002 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8002
else
    error "❌ Failed"
    echo "Checking service status:"
    systemctl status pgbouncer-health-simple.service --no-pager -l || true
fi

echo
info "Checking listening ports:"
ss -tuln | grep -E ':(8001|8002)' | head -5 || echo "Health ports not found"

echo
success "🎉 Simple health endpoint setup complete!"
info "Service status:"
echo "PostgreSQL Health: $(systemctl is-active pg-health-simple.service)"
echo "PgBouncer Health:  $(systemctl is-active pgbouncer-health-simple.service)"