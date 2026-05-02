#!/bin/bash
# Nuclear port cleanup - completely clear ports 8001/8002

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

echo "☢️ Nuclear Port Cleanup - Ports 8001/8002"
echo "=========================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Step 1: Stop ALL systemd services"
systemctl stop final-pg-health.service final-pgbouncer-health.service 2>/dev/null || true
systemctl disable final-pg-health.service final-pgbouncer-health.service 2>/dev/null || true

# Stop any other health services
for service in pg-ha-health pgbouncer-health pg-working-health pgbouncer-working-health; do
    systemctl stop ${service}.service 2>/dev/null || true
    systemctl disable ${service}.service 2>/dev/null || true
done

info "Step 2: Nuclear process kill"
# Kill by port
fuser -k 8001/tcp 2>/dev/null || true
fuser -k 8002/tcp 2>/dev/null || true

# Kill by process name
pkill -f "python.*8001" 2>/dev/null || true
pkill -f "python.*8002" 2>/dev/null || true
pkill -f "final-pg-health" 2>/dev/null || true
pkill -f "final-pgbouncer-health" 2>/dev/null || true

# Kill by lsof
lsof -ti:8001 2>/dev/null | xargs -r kill -9 2>/dev/null || true
lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true

sleep 3

info "Step 3: Force socket cleanup"
# Clean up any lingering sockets
netstat -tuln | grep ":8001 " | awk '{print $1}' | xargs -r -I {} ss -K dst {}:8001 2>/dev/null || true
netstat -tuln | grep ":8002 " | awk '{print $1}' | xargs -r -I {} ss -K dst {}:8002 2>/dev/null || true

sleep 2

info "Step 4: Final verification"
if ss -tuln | grep -q ":8001 "; then
    error "❌ Port 8001 STILL in use after nuclear cleanup"
    ss -tuln | grep ":8001 "
    lsof -i:8001 2>/dev/null || true
else
    success "✅ Port 8001 is now FREE"
fi

if ss -tuln | grep -q ":8002 "; then
    error "❌ Port 8002 STILL in use after nuclear cleanup"  
    ss -tuln | grep ":8002 "
    lsof -i:8002 2>/dev/null || true
else
    success "✅ Port 8002 is now FREE"
fi

info "Step 5: Start fresh health services (background)"
# Start with explicit exclusive binding
nohup python3 -c "
import http.server
import socketserver
import json
import subprocess
from datetime import datetime

PORT = 8001
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            role_result = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 'SELECT pg_is_in_recovery();', 'postgres'], 
                                       capture_output=True, text=True, timeout=1)
            role = 'standby' if role_result.returncode == 0 and role_result.stdout.strip() == 't' else 'primary'
            response = json.dumps({'status': 'healthy', 'role': role, 'timestamp': datetime.now().isoformat()})
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response)))
            self.end_headers()
            self.wfile.write(response.encode())
        except: pass
    def log_message(self, *args): pass

with socketserver.TCPServer(('0.0.0.0', PORT), Handler) as httpd:
    httpd.allow_reuse_address = True
    httpd.serve_forever()
" > /var/log/pg-health-manual.log 2>&1 &
PG_PID=$!

nohup python3 -c "
import http.server
import socketserver
import json
import socket
from datetime import datetime

PORT = 8002
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(0.5)
            status = 'healthy' if sock.connect_ex(('127.0.0.1', 6432)) == 0 else 'unhealthy'
            sock.close()
            response = json.dumps({'status': status, 'service': 'pgbouncer', 'timestamp': datetime.now().isoformat()})
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response)))
            self.end_headers()
            self.wfile.write(response.encode())
        except: pass
    def log_message(self, *args): pass

with socketserver.TCPServer(('0.0.0.0', PORT), Handler) as httpd:
    httpd.allow_reuse_address = True
    httpd.serve_forever()
" > /var/log/pgbouncer-health-manual.log 2>&1 &
PGB_PID=$!

sleep 3

info "Step 6: Test new services"
if kill -0 $PG_PID 2>/dev/null; then
    success "✅ New PostgreSQL health service running (PID: $PG_PID)"
else
    error "❌ New PostgreSQL health service failed"
fi

if kill -0 $PGB_PID 2>/dev/null; then
    success "✅ New PgBouncer health service running (PID: $PGB_PID)"
else
    error "❌ New PgBouncer health service failed"
fi

# Save PIDs
echo $PG_PID > /tmp/manual-pg-health.pid
echo $PGB_PID > /tmp/manual-pgbouncer-health.pid

info "Step 7: Final endpoint test"
sleep 2
curl -s http://localhost:8001 | jq . 2>/dev/null && success "✅ Port 8001 responding" || error "❌ Port 8001 not responding"
curl -s http://localhost:8002 | jq . 2>/dev/null && success "✅ Port 8002 responding" || error "❌ Port 8002 not responding"

success "☢️ Nuclear cleanup complete!"
info "Manual health services running with PIDs saved to /tmp/"
info "To stop: kill \$(cat /tmp/manual-pg-health.pid) \$(cat /tmp/manual-pgbouncer-health.pid)"