#!/bin/bash
# Simple PgBouncer Health Endpoint Manual Fix
# Bypasses systemd issues by running the health endpoint directly
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "%b[INFO]%b %s\n" "$BLUE" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }

# Configuration
PGBOUNCER_HEALTH_PORT=8002

main() {
    info "🔧 Simple PgBouncer Health Endpoint Fix"
    info "======================================"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Step 1: Stop the problematic systemd service completely
    info "Step 1: Disabling problematic systemd service..."
    systemctl stop final-pgbouncer-health.service 2>/dev/null || true
    systemctl disable final-pgbouncer-health.service 2>/dev/null || true
    
    # Kill any existing processes
    pkill -f "final-pgbouncer-health" 2>/dev/null || true
    pkill -f ":8002" 2>/dev/null || true
    
    # Kill by port if lsof is available
    if command -v lsof >/dev/null 2>&1; then
        lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    fi
    
    sleep 2
    success "✓ Cleaned up systemd service and processes"
    
    # Step 2: Create a simple Python script that works
    info "Step 2: Creating simplified health script..."
    
    cat > /usr/local/bin/pgbouncer-health-simple.py <<'HEALTH_SCRIPT_EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import socket
import sys
from datetime import datetime

def check_pgbouncer():
    try:
        # Check service
        result = subprocess.run(['systemctl', 'is-active', '--quiet', 'pgbouncer'], 
                              capture_output=True, timeout=2)
        if result.returncode != 0:
            return {"status": "unhealthy", "service": "pgbouncer", "reason": "service_down"}
        
        # Check port
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        result = sock.connect_ex(('127.0.0.1', 6432))
        sock.close()
        
        if result == 0:
            return {"status": "healthy", "service": "pgbouncer"}
        else:
            return {"status": "unhealthy", "service": "pgbouncer", "reason": "port_closed"}
    except Exception as e:
        return {"status": "unhealthy", "service": "pgbouncer", "reason": str(e)[:50]}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = check_pgbouncer()
        data["timestamp"] = datetime.now().isoformat()
        
        status_code = 200 if data["status"] == "healthy" else 503
        response = json.dumps(data)
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8002
    with socketserver.TCPServer(("", port), Handler) as httpd:
        httpd.allow_reuse_address = True
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
HEALTH_SCRIPT_EOF
    
    chmod +x /usr/local/bin/pgbouncer-health-simple.py
    success "✓ Created simplified health script"
    
    # Step 3: Test the script manually
    info "Step 3: Testing the script..."
    if timeout 3 sudo -u postgres python3 /usr/local/bin/pgbouncer-health-simple.py $PGBOUNCER_HEALTH_PORT &>/dev/null &
    then
        local test_pid=$!
        sleep 1
        
        if timeout 2 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
            success "✓ Script test successful"
            kill $test_pid 2>/dev/null || true
        else
            warn "⚠️ Script test failed"
            kill $test_pid 2>/dev/null || true
        fi
    fi
    
    # Step 4: Start it permanently in the background
    info "Step 4: Starting health endpoint permanently..."
    
    # Create a simple startup script that runs at boot
    cat > /etc/init.d/pgbouncer-health-simple <<'INIT_SCRIPT_EOF'
#!/bin/bash
# Simple PgBouncer Health Endpoint
# chkconfig: 35 80 20
# description: PgBouncer Health Endpoint

. /lib/lsb/init-functions

USER="postgres"
DAEMON="pgbouncer-health-simple"
ROOT_DIR="/var/lib/postgresql"

DAEMON_PATH="/usr/local/bin/pgbouncer-health-simple.py"
DAEMON_ARGS="8002"
PIDFILE="/var/run/pgbouncer-health.pid"

case "$1" in
    start)
        echo -n "Starting daemon: "$DAEMON
        start-stop-daemon --start --quiet --user "$USER" --pidfile "$PIDFILE" --make-pidfile --background --exec /usr/bin/python3 -- "$DAEMON_PATH" $DAEMON_ARGS
        echo "."
        ;;
    stop)
        echo -n "Shutting down daemon: "$DAEMON
        start-stop-daemon --stop --quiet --oknodo --pidfile "$PIDFILE"
        rm -f "$PIDFILE"
        echo "."
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
esac

exit 0
INIT_SCRIPT_EOF
    
    chmod +x /etc/init.d/pgbouncer-health-simple
    
    # Start the service
    /etc/init.d/pgbouncer-health-simple start
    sleep 2
    
    # Test if it's working
    if timeout 5 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
        local response
        response=$(curl -s "http://localhost:$PGBOUNCER_HEALTH_PORT" 2>/dev/null || echo '{"status":"unknown"}')
        success "✅ PgBouncer health endpoint is working!"
        info "Response: $response"
        
        # Make it start at boot
        update-rc.d pgbouncer-health-simple defaults 2>/dev/null || true
        
        success "✅ Health endpoint configured to start at boot"
        
    else
        error "✗ Health endpoint still not working"
        
        # Final fallback - direct nohup
        info "Trying direct nohup approach..."
        sudo -u postgres nohup python3 /usr/local/bin/pgbouncer-health-simple.py $PGBOUNCER_HEALTH_PORT >/dev/null 2>&1 &
        sleep 2
        
        if timeout 5 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
            success "✅ Direct approach working!"
            
            # Create a cron job to ensure it stays running
            cat > /etc/cron.d/pgbouncer-health <<'CRON_EOF'
# Keep PgBouncer health endpoint running
*/2 * * * * postgres /bin/bash -c "if ! curl -sf http://localhost:8002 >/dev/null 2>&1; then nohup python3 /usr/local/bin/pgbouncer-health-simple.py 8002 >/dev/null 2>&1 & fi"
CRON_EOF
            
            success "✅ Cron job created to maintain health endpoint"
        else
            error "✗ All approaches failed"
            return 1
        fi
    fi
    
    info ""
    success "🎉 Simple PgBouncer Health Fix Complete!"
    info "======================================"
    info "✅ Health endpoint: http://localhost:$PGBOUNCER_HEALTH_PORT"
    info "✅ Method: Simple background process"
    info "✅ Maintenance: Automatic via cron/init script"
    
    return 0
}

# Run main function
main "$@"