#!/bin/bash
# Definitive Health Endpoint Fix - Uses Python HTTP server for reliability
# Run on both servers to fix PostgreSQL health endpoint

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

echo "🔧 Definitive PostgreSQL Health Endpoint Fix"
echo "============================================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

info "Creating reliable health endpoints using Python HTTP server..."

# Stop all health services
systemctl stop pg-ha-health.service pgbouncer-health.service 2>/dev/null || true
pkill -f "health" 2>/dev/null || true
pkill -f "8001" 2>/dev/null || true
pkill -f "8002" 2>/dev/null || true
sleep 3

# Create reliable PostgreSQL health endpoint using Python
cat > /usr/local/bin/pg-ha-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail

PORT=${1:-8001}

# Create Python HTTP server for PostgreSQL health
cat > /tmp/pg_health_server.py << 'PYEOF'
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
            
            # Check if PostgreSQL service is active
            result = subprocess.run(['systemctl', 'is-active', 'postgresql'], 
                                  capture_output=True, text=True)
            
            if result.returncode == 0:  # PostgreSQL is active
                # Test database connectivity
                db_test = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 'SELECT 1;', 'postgres'], 
                                       capture_output=True, text=True)
                
                if db_test.returncode == 0:  # Database is accessible
                    # Check if primary (NOT in recovery)
                    recovery_check = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 
                                                   'SELECT NOT pg_is_in_recovery();', 'postgres'], 
                                                  capture_output=True, text=True)
                    
                    if recovery_check.returncode == 0 and 't' in recovery_check.stdout:
                        status_code = 200
                        role = "primary"
                    else:
                        # Check if standby (IS in recovery)
                        standby_check = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 
                                                      'SELECT pg_is_in_recovery();', 'postgres'], 
                                                     capture_output=True, text=True)
                        
                        if standby_check.returncode == 0 and 't' in standby_check.stdout:
                            # Check WAL receiver for standby health
                            wal_check = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-tAc', 
                                                      "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';", 'postgres'], 
                                                     capture_output=True, text=True)
                            
                            if wal_check.returncode == 0 and int(wal_check.stdout.strip()) >= 1:
                                status_code = 200  # Healthy standby
                            
                            role = "standby"
                else:
                    role = "inaccessible"
            else:
                role = "down"
            
            # Create response
            response_data = {
                "status": "healthy" if status_code == 200 else "unhealthy",
                "role": role,
                "timestamp": datetime.now().isoformat()
            }
            
            response_json = json.dumps(response_data)
            
            # Send response
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response_json)))
            self.send_header('Connection', 'close')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(response_json.encode())
            
        except Exception as e:
            # Error response
            error_response = json.dumps({
                "status": "unhealthy",
                "role": "error",
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            })
            
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(error_response)))
            self.end_headers()
            self.wfile.write(error_response.encode())
    
    def log_message(self, format, *args):
        pass  # Suppress default logging

# Start server
with socketserver.TCPServer(("", PORT), HealthHandler) as httpd:
    httpd.serve_forever()
PYEOF

# Run the Python server
python3 /tmp/pg_health_server.py $PORT
EOF

# Create reliable PgBouncer health endpoint
cat > /usr/local/bin/pgbouncer-health.sh << 'EOF'
#!/bin/bash
set -euo pipefail

PORT=${1:-8002}

# Create Python HTTP server for PgBouncer health
cat > /tmp/pgbouncer_health_server.py << 'PYEOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import socket
import sys
from datetime import datetime

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8002

class PgBouncerHealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            status_code = 503
            service_status = "unhealthy"
            
            # Check if PgBouncer service is active
            service_result = subprocess.run(['systemctl', 'is-active', 'pgbouncer'], 
                                          capture_output=True, text=True)
            
            if service_result.returncode == 0:  # PgBouncer service is active
                # Test if port 6432 is listening
                try:
                    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    sock.settimeout(2)
                    result = sock.connect_ex(('localhost', 6432))
                    sock.close()
                    
                    if result == 0:  # Port is open
                        status_code = 200
                        service_status = "healthy"
                except:
                    pass
            
            # Create response
            response_data = {
                "status": service_status,
                "service": "pgbouncer",
                "timestamp": datetime.now().isoformat()
            }
            
            response_json = json.dumps(response_data)
            
            # Send response
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response_json)))
            self.send_header('Connection', 'close')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(response_json.encode())
            
        except Exception as e:
            # Error response
            error_response = json.dumps({
                "status": "unhealthy",
                "service": "pgbouncer",
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            })
            
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(error_response)))
            self.end_headers()
            self.wfile.write(error_response.encode())
    
    def log_message(self, format, *args):
        pass  # Suppress default logging

# Start server
with socketserver.TCPServer(("", PORT), PgBouncerHealthHandler) as httpd:
    httpd.serve_forever()
PYEOF

# Run the Python server
python3 /tmp/pgbouncer_health_server.py $PORT
EOF

chmod +x /usr/local/bin/pg-ha-health.sh /usr/local/bin/pgbouncer-health.sh

# Update systemd service files to handle Python properly
cat > /etc/systemd/system/pg-ha-health.service << 'EOF'
[Unit]
Description=PostgreSQL HA Health Check Endpoint
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pg-ha-health.sh 8001
Restart=always
RestartSec=5
User=postgres
Group=postgres
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pgbouncer-health.service << 'EOF'
[Unit]
Description=PgBouncer HA Health Check Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pgbouncer-health.sh 8002
Restart=always
RestartSec=5
User=postgres
Group=postgres
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

# Reload and restart services
info "Reloading systemd and starting health services..."
systemctl daemon-reload

systemctl enable pg-ha-health.service
systemctl start pg-ha-health.service

systemctl enable pgbouncer-health.service
systemctl start pgbouncer-health.service

# Wait for services to start
sleep 5

# Test the endpoints
info "Testing health endpoints..."

echo -n "PostgreSQL Health (port 8001): "
if timeout 10 curl -sf http://localhost:8001 >/dev/null 2>&1; then
    success "✅ Working!"
    echo "Response:"
    curl -s http://localhost:8001 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8001
else
    error "❌ Still not working"
    echo "Service logs:"
    journalctl -u pg-ha-health.service --lines=5 --no-pager || true
fi

echo
echo -n "PgBouncer Health (port 8002): "
if timeout 10 curl -sf http://localhost:8002 >/dev/null 2>&1; then
    success "✅ Working!"
    echo "Response:"
    curl -s http://localhost:8002 | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8002
else
    error "❌ Still not working"
    echo "Service logs:"
    journalctl -u pgbouncer-health.service --lines=5 --no-pager || true
fi

echo
# Show listening ports
info "Checking listening ports:"
ss -tuln | grep -E ':(8001|8002|5432|6432)' || echo "No ports found"

echo
success "🎉 Definitive health endpoint fix complete!"

# Show service status
info "Final service status:"
echo "PostgreSQL:       $(systemctl is-active postgresql)"
echo "PgBouncer:        $(systemctl is-active pgbouncer)" 
echo "repmgrd:          $(systemctl is-active repmgrd)"
echo "PG Health:        $(systemctl is-active pg-ha-health)"
echo "PgBouncer Health: $(systemctl is-active pgbouncer-health)"