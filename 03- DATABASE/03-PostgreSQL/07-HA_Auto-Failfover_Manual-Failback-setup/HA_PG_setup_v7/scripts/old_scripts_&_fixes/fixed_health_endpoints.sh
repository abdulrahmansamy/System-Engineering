#!/bin/bash
# Fixed Health Endpoints - No sudo issues
# Creates working health endpoints that work properly

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

echo "🔧 Fixed Health Endpoints"
echo "========================"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# Kill existing health processes
info "Stopping existing health processes..."
lsof -ti:8001 2>/dev/null | xargs -r kill -9 2>/dev/null || true
lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true
sleep 2

# Create fixed PostgreSQL health endpoint (no sudo needed)
info "Creating fixed PostgreSQL health endpoint..."
cat > /usr/local/bin/pg-health-fixed.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import os

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
                # Since we're running as postgres user, no sudo needed
                # Check if primary (not in recovery)
                primary_result = subprocess.run(['psql', '-tAc', 
                                               'SELECT NOT pg_is_in_recovery();', 'postgres'], 
                                              capture_output=True, text=True, timeout=3)
                
                if primary_result.returncode == 0 and 't' in primary_result.stdout.strip():
                    status = "healthy"
                    role = "primary"
                    code = 200
                else:
                    # Check if standby (in recovery)
                    standby_result = subprocess.run(['psql', '-tAc', 
                                                   'SELECT pg_is_in_recovery();', 'postgres'], 
                                                  capture_output=True, text=True, timeout=3)
                    
                    if standby_result.returncode == 0 and 't' in standby_result.stdout.strip():
                        # Check WAL receiver for standby health
                        wal_result = subprocess.run(['psql', '-tAc', 
                                                   "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';", 'postgres'], 
                                                  capture_output=True, text=True, timeout=3)
                        
                        if wal_result.returncode == 0:
                            try:
                                wal_count = int(wal_result.stdout.strip())
                                if wal_count >= 1:
                                    status = "healthy"
                                    code = 200
                            except:
                                pass
                        
                        role = "standby"
        except Exception as e:
            # For debugging
            role = f"error: {str(e)}"
        
        from datetime import datetime
        response = json.dumps({
            "status": status, 
            "role": role, 
            "timestamp": datetime.now().isoformat()
        })
        
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("", 8001), Handler) as httpd:
    httpd.serve_forever()
EOF

# Create PgBouncer health endpoint (already working, but let's make it consistent)
info "Creating PgBouncer health endpoint..."
cat > /usr/local/bin/pgbouncer-health-fixed.py << 'EOF'
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
            # Check service
            service_result = subprocess.run(['systemctl', 'is-active', 'pgbouncer'], 
                                          capture_output=True, text=True, timeout=3)
            
            if service_result.returncode == 0:
                # Check port connectivity
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1)
                if sock.connect_ex(('localhost', 6432)) == 0:
                    status = "healthy"
                    code = 200
                sock.close()
        except:
            pass
        
        from datetime import datetime
        response = json.dumps({
            "status": status, 
            "service": "pgbouncer", 
            "timestamp": datetime.now().isoformat()
        })
        
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("", 8002), Handler) as httpd:
    httpd.serve_forever()
EOF

chmod +x /usr/local/bin/pg-health-fixed.py /usr/local/bin/pgbouncer-health-fixed.py

# Start health endpoints as postgres user (no sudo conflicts)
info "Starting fixed health endpoints..."

# Start PostgreSQL health endpoint
nohup sudo -u postgres python3 /usr/local/bin/pg-health-fixed.py > /dev/null 2>&1 &
PG_HEALTH_PID=$!

# Start PgBouncer health endpoint
nohup sudo -u postgres python3 /usr/local/bin/pgbouncer-health-fixed.py > /dev/null 2>&1 &
PGBOUNCER_HEALTH_PID=$!

# Wait for startup
sleep 3

# Test both endpoints
info "Testing fixed health endpoints..."

echo -n "PostgreSQL Health (8001): "
if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ Working!"
    echo "Response:"
    curl -s http://localhost:8001 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8001
else
    echo "❌ Failed"
    echo "Debug: Testing manual PostgreSQL connection as postgres user..."
    sudo -u postgres psql -tAc "SELECT NOT pg_is_in_recovery();" postgres || true
fi

echo
echo -n "PgBouncer Health (8002): "
if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ Working!"
    echo "Response:"
    curl -s http://localhost:8002 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8002
else
    echo "❌ Failed"
fi

echo
info "Health endpoints running with PIDs: $PG_HEALTH_PID (PostgreSQL), $PGBOUNCER_HEALTH_PID (PgBouncer)"

echo
success "🎉 Fixed health endpoints deployed!"
echo "Test from anywhere:"
echo "curl -s http://$(hostname -I | awk '{print $1}'):8001 | jq ."
echo "curl -s http://$(hostname -I | awk '{print $1}'):8002 | jq ."

echo
info "🔍 Cross-node testing:"
echo "From primary, test standby: curl -s http://192.168.14.22:8001 | jq ."  
echo "From standby, test primary: curl -s http://192.168.14.21:8001 | jq ."