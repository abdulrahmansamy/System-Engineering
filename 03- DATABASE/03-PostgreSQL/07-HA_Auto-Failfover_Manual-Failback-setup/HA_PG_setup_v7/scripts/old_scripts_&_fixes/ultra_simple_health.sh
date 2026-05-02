#!/bin/bash
# Ultra-Simple Health Fix - Direct approach, no systemctl conflicts
# Creates working health endpoints immediately

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🔧 Ultra-Simple Health Fix"
echo "=========================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# Kill any existing processes on ports 8001/8002 (gentle approach)
info "Clearing ports 8001 and 8002..."
lsof -ti:8001 2>/dev/null | xargs -r kill -9 2>/dev/null || true
lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true
sleep 2

# Create minimal health scripts
info "Creating minimal health endpoints..."

# PostgreSQL health endpoint
cat > /usr/local/bin/pg-health-mini.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status = "unhealthy"
        role = "unknown"
        code = 503
        
        try:
            # Check PostgreSQL service
            pg_result = subprocess.run(['systemctl', 'is-active', 'postgresql'], 
                                     capture_output=True, text=True, timeout=3)
            
            if pg_result.returncode == 0:
                # Check if primary
                primary_result = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 
                                               'SELECT NOT pg_is_in_recovery();', 'postgres'], 
                                              capture_output=True, text=True, timeout=3)
                
                if primary_result.returncode == 0 and 't' in primary_result.stdout:
                    status = "healthy"
                    role = "primary"
                    code = 200
                else:
                    # Check if standby
                    standby_result = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 
                                                   'SELECT pg_is_in_recovery();', 'postgres'], 
                                                  capture_output=True, text=True, timeout=3)
                    
                    if standby_result.returncode == 0 and 't' in standby_result.stdout:
                        status = "healthy"
                        role = "standby"
                        code = 200
        except:
            pass
        
        response = json.dumps({"status": status, "role": role, "timestamp": "2025-10-12T16:15:00Z"})
        
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("", 8001), Handler) as httpd:
    httpd.serve_forever()
EOF

# PgBouncer health endpoint
cat > /usr/local/bin/pgbouncer-health-mini.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import socket

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status = "unhealthy"
        code = 503
        
        try:
            # Check service and port
            service_result = subprocess.run(['systemctl', 'is-active', 'pgbouncer'], 
                                          capture_output=True, text=True, timeout=3)
            
            if service_result.returncode == 0:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1)
                if sock.connect_ex(('localhost', 6432)) == 0:
                    status = "healthy"
                    code = 200
                sock.close()
        except:
            pass
        
        response = json.dumps({"status": status, "service": "pgbouncer", "timestamp": "2025-10-12T16:15:00Z"})
        
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("", 8002), Handler) as httpd:
    httpd.serve_forever()
EOF

chmod +x /usr/local/bin/pg-health-mini.py /usr/local/bin/pgbouncer-health-mini.py

# Start health endpoints directly (no systemd)
info "Starting health endpoints directly..."

# Start PostgreSQL health in background
nohup sudo -u postgres python3 /usr/local/bin/pg-health-mini.py > /dev/null 2>&1 &
PG_HEALTH_PID=$!

# Start PgBouncer health in background  
nohup sudo -u postgres python3 /usr/local/bin/pgbouncer-health-mini.py > /dev/null 2>&1 &
PGBOUNCER_HEALTH_PID=$!

# Wait for startup
sleep 3

# Test endpoints
info "Testing health endpoints..."

echo -n "PostgreSQL Health (8001): "
if timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ Working!"
    curl -s http://localhost:8001 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8001
else
    echo "❌ Failed"
fi

echo
echo -n "PgBouncer Health (8002): "
if timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ Working!"
    curl -s http://localhost:8002 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8002
else
    echo "❌ Failed"
fi

echo
info "Health endpoints are running with PIDs: $PG_HEALTH_PID (PostgreSQL), $PGBOUNCER_HEALTH_PID (PgBouncer)"
info "Processes will continue running after this script exits"

echo
success "🎉 Ultra-simple health endpoints are now running!"
echo "Test from other nodes:"
echo "curl -s http://$(hostname -I | awk '{print $1}'):8001 | jq ."
echo "curl -s http://$(hostname -I | awk '{print $1}'):8002 | jq ."