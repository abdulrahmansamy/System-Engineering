#!/bin/bash
# PgBouncer Health Endpoint Fix Script
# Fixes the persistent PgBouncer health endpoint (port 8002) issue
# Version: 1.0.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "%b[INFO]%b %s\n" "$BLUE" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }

# Configuration
PGBOUNCER_HEALTH_BIN="/usr/local/bin/final-pgbouncer-health.py"
PGBOUNCER_HEALTH_PORT=8002

main() {
    info "🔧 Fixing PgBouncer Health Endpoint Issue"
    info "========================================="
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Step 1: Stop and clean up existing processes
    info "Step 1: Cleaning up existing processes..."
    systemctl stop final-pgbouncer-health.service 2>/dev/null || true
    pkill -f "final-pgbouncer-health" 2>/dev/null || true
    pkill -f ":8002" 2>/dev/null || true
    
    # Kill any processes using port 8002
    if command -v lsof >/dev/null 2>&1; then
        lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    else
        # Install lsof if not available
        info "Installing lsof package..."
        apt-get update -qq && apt-get install -y lsof
        lsof -ti:8002 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    fi
    
    sleep 2
    success "✓ Cleaned up existing processes"
    
    # Step 2: Verify the health script exists and is executable
    info "Step 2: Verifying health script..."
    if [[ ! -f "$PGBOUNCER_HEALTH_BIN" ]]; then
        error "PgBouncer health script not found: $PGBOUNCER_HEALTH_BIN"
        info "Creating the health script..."
        
        cat > "$PGBOUNCER_HEALTH_BIN" <<'PGBOUNCER_HEALTH_EOF'
#!/usr/bin/env python3
"""
Production-ready PgBouncer Health Endpoint
Provides HTTP health checks for GCP Internal Load Balancer
"""

import http.server
import socketserver
import json
import subprocess
import socket
import sys
from datetime import datetime

def check_pgbouncer_health():
    """Check PgBouncer status and connectivity"""
    try:
        # Check if PgBouncer service is active
        service_check = subprocess.run(
            ['systemctl', 'is-active', '--quiet', 'pgbouncer'],
            capture_output=True, timeout=2
        )
        
        if service_check.returncode != 0:
            return {"status": "unhealthy", "service": "pgbouncer", "reason": "service_down"}
        
        # Test actual connectivity to PgBouncer port
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        result = sock.connect_ex(('127.0.0.1', 6432))
        sock.close()
        
        if result == 0:
            return {"status": "healthy", "service": "pgbouncer"}
        else:
            return {"status": "unhealthy", "service": "pgbouncer", "reason": "port_closed"}
            
    except socket.timeout:
        return {"status": "unhealthy", "service": "pgbouncer", "reason": "timeout"}
    except Exception as e:
        return {"status": "unhealthy", "service": "pgbouncer", "reason": str(e)[:50]}

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        health_data = check_pgbouncer_health()
        health_data["timestamp"] = datetime.now().isoformat()
        
        # Set HTTP status based on health
        status_code = 200 if health_data["status"] == "healthy" else 503
        
        response = json.dumps(health_data)
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        # Suppress default logging to reduce noise
        pass

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8002
    
    with socketserver.TCPServer(("", port), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        print(f"PgBouncer health endpoint serving on port {port}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("Shutting down health endpoint")

if __name__ == "__main__":
    main()
PGBOUNCER_HEALTH_EOF
        
        chmod +x "$PGBOUNCER_HEALTH_BIN"
        success "✓ Created PgBouncer health script"
    else
        chmod +x "$PGBOUNCER_HEALTH_BIN"
        success "✓ PgBouncer health script exists and is executable"
    fi
    
    # Step 3: Create/update the systemd service
    info "Step 3: Creating optimized systemd service..."
    cat > /etc/systemd/system/final-pgbouncer-health.service <<EOF
[Unit]
Description=PgBouncer Health Endpoint Service
After=network-online.target pgbouncer.service
Wants=pgbouncer.service network-online.target

[Service]
Type=simple
# Clean startup
ExecStartPre=/bin/bash -c "pkill -f 'final-pgbouncer-health' 2>/dev/null || true; sleep 1"
ExecStart=/usr/bin/python3 ${PGBOUNCER_HEALTH_BIN} ${PGBOUNCER_HEALTH_PORT}
Restart=always
RestartSec=3
User=postgres
Group=postgres
Environment=HOME=/var/lib/postgresql
Environment=USER=postgres
Environment=PATH=/usr/bin:/bin
StandardOutput=journal
StandardError=journal
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=5
TimeoutStartSec=15

[Install]
WantedBy=multi-user.target
EOF
    
    success "✓ Created systemd service file"
    
    # Step 4: Reload systemd and enable service
    info "Step 4: Reloading systemd and enabling service..."
    systemctl daemon-reload
    systemctl enable final-pgbouncer-health.service
    success "✓ Service enabled"
    
    # Step 5: Test the script manually first
    info "Step 5: Testing PgBouncer health script manually..."
    if timeout 5 sudo -u postgres python3 "$PGBOUNCER_HEALTH_BIN" "$PGBOUNCER_HEALTH_PORT" &>/dev/null &
    then
        local test_pid=$!
        sleep 2
        
        # Test if it responds
        if timeout 3 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
            success "✓ Manual test successful"
            kill $test_pid 2>/dev/null || true
        else
            warn "⚠️ Manual test failed, but continuing with service start"
            kill $test_pid 2>/dev/null || true
        fi
    else
        warn "⚠️ Could not start manual test, but continuing"
    fi
    
    sleep 1
    
    # Step 6: Start the service
    info "Step 6: Starting PgBouncer health service..."
    if systemctl start final-pgbouncer-health.service; then
        sleep 3
        
        # Verify it's running
        if systemctl is-active --quiet final-pgbouncer-health.service; then
            success "✓ Service started successfully"
            
            # Test the endpoint
            if timeout 5 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
                local response
                response=$(curl -s "http://localhost:$PGBOUNCER_HEALTH_PORT" | jq -r '.status' 2>/dev/null || echo "unknown")
                success "✓ Health endpoint is responding: $response"
            else
                warn "⚠️ Service is running but endpoint not responding yet - may need a moment"
            fi
        else
            error "✗ Service failed to stay running"
            info "Checking service logs..."
            journalctl -u final-pgbouncer-health.service --lines=10 --no-pager
            return 1
        fi
    else
        error "✗ Failed to start service"
        info "Checking service logs..."
        journalctl -u final-pgbouncer-health.service --lines=10 --no-pager
        return 1
    fi
    
    # Step 7: Final verification
    info "Step 7: Final verification..."
    sleep 2
    
    if timeout 10 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
        local response
        response=$(curl -s "http://localhost:$PGBOUNCER_HEALTH_PORT" 2>/dev/null || echo '{"status":"unknown"}')
        success "✅ PgBouncer health endpoint is working!"
        info "Response: $response"
        
        # Show service status
        info "Service status:"
        systemctl status final-pgbouncer-health.service --no-pager --lines=3 || true
        
    else
        error "✗ Health endpoint still not responding after all fixes"
        warn "Trying one more manual fallback..."
        
        # Final fallback - start manually in background
        sudo -u postgres nohup python3 "$PGBOUNCER_HEALTH_BIN" "$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1 &
        sleep 2
        
        if timeout 5 curl -sf "http://localhost:$PGBOUNCER_HEALTH_PORT" >/dev/null 2>&1; then
            success "✅ Manual fallback successful - endpoint is working!"
            warn "⚠️ Note: Running manually, not as systemd service"
        else
            error "✗ All attempts failed - manual investigation needed"
            return 1
        fi
    fi
    
    info ""
    success "🎉 PgBouncer Health Endpoint Fix Complete!"
    info "========================================"
    info "✅ Health endpoint should now be accessible at: http://localhost:$PGBOUNCER_HEALTH_PORT"
    info "✅ Service: final-pgbouncer-health.service"
    info "✅ Status: $(systemctl is-active final-pgbouncer-health.service 2>/dev/null || echo 'manual')"
    
    return 0
}

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# Run main function
main "$@"