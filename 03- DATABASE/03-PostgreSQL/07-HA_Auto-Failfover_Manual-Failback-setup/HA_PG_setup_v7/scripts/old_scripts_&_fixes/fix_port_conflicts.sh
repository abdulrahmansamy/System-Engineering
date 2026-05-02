#!/bin/bash
# Port Cleanup and Health Service Restart
# Fixes "Address already in use" issues on ports 8001 and 8002

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Cleaning up port conflicts and restarting health services"

# Detect node info
get_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q '^f'; then
        echo "primary"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q '^t'; then
        echo "standby"
    else
        echo "unknown"
    fi
}

ROLE=$(get_role)
SELF_IP=$(hostname -I | awk '{print $1}')
info "Node: $ROLE (IP: $SELF_IP)"

# Step 1: Complete port cleanup
info "🛑 Complete port and process cleanup..."

# Stop systemd services first
systemctl stop python-pg-health.service 2>/dev/null || true
systemctl stop python-pgbouncer-health.service 2>/dev/null || true

# Kill all processes using ports 8001 and 8002
for port in 8001 8002; do
    info "Cleaning up processes on port $port..."
    
    # Find and kill processes using the port
    lsof -ti:$port 2>/dev/null | while read pid; do
        if [[ -n "$pid" ]]; then
            info "  Killing process $pid using port $port"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    
    # Alternative method using fuser
    fuser -k $port/tcp 2>/dev/null || true
    
    # Kill specific processes by name
    pkill -f ":$port" 2>/dev/null || true
    pkill -f "port.*$port" 2>/dev/null || true
done

# Kill all health-related processes
pkill -f "python.*health" 2>/dev/null || true
pkill -f "nc.*800" 2>/dev/null || true

sleep 5

# Step 2: Verify ports are free
info "🔍 Verifying ports are free..."
for port in 8001 8002; do
    if ss -tulnp | grep -q ":$port "; then
        error "Port $port is still in use:"
        ss -tulnp | grep ":$port " || true
        
        # Force kill anything still using the port
        lsof -ti:$port 2>/dev/null | while read pid; do
            warn "  Force killing remaining process $pid"
            kill -9 "$pid" 2>/dev/null || true
        done
        
        sleep 2
        
        # Check again
        if ss -tulnp | grep -q ":$port "; then
            error "Port $port cleanup failed - manual intervention needed"
            ss -tulnp | grep ":$port " || true
        else
            success "Port $port is now free"
        fi
    else
        success "Port $port is free ✓"
    fi
done

# Step 3: Fix the Python script to handle port binding better
info "🐍 Updating Python script with better port handling..."

cat > /usr/local/bin/python-pg-health-fixed.py <<EOF
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import datetime
import sys
import os
import traceback
import socket
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
ROLE = "$ROLE"
NODE_IP = "$SELF_IP"

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Log to file instead of stdout
        timestamp = datetime.datetime.now().isoformat()
        message = format % args
        try:
            with open('/var/log/pg-health-debug.log', 'a') as f:
                f.write(f"{timestamp} - {message}\n")
        except:
            pass
    
    def do_GET(self):
        try:
            # Check PostgreSQL service with timeout
            try:
                postgres_check = subprocess.run(['systemctl', 'is-active', 'postgresql'], 
                                              capture_output=True, text=True, timeout=5)
                postgres_active = postgres_check.stdout.strip() == 'active'
            except:
                postgres_active = False
            
            if not postgres_active:
                postgres_running = subprocess.run(['pgrep', '-f', 'postgres'], 
                                                capture_output=True, text=True).returncode == 0
                if not postgres_running:
                    self.send_error_response("unhealthy", "PostgreSQL service not running")
                    return
            
            # Test PostgreSQL connectivity
            try:
                pg_test = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-c', 'SELECT 1'], 
                                       capture_output=True, text=True, timeout=10)
                if pg_test.returncode != 0:
                    self.send_error_response("unhealthy", f"PostgreSQL not accessible: {pg_test.stderr}")
                    return
            except subprocess.TimeoutExpired:
                self.send_error_response("unhealthy", "PostgreSQL connection timeout")
                return
            except Exception as e:
                self.send_error_response("unhealthy", f"PostgreSQL connection error: {str(e)}")
                return
            
            # Check role
            try:
                role_check = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-Atqc', 
                                           'SELECT CASE WHEN pg_is_in_recovery() THEN \'standby\' ELSE \'primary\' END;'],
                                          capture_output=True, text=True, timeout=10)
                
                if role_check.returncode != 0:
                    self.send_error_response("unhealthy", f"Cannot determine PostgreSQL role: {role_check.stderr}")
                    return
                
                detected_role = role_check.stdout.strip()
            except Exception as e:
                self.send_error_response("unhealthy", f"Role detection error: {str(e)}")
                return
            
            # Role validation and response
            if detected_role == ROLE:
                if ROLE == "standby":
                    try:
                        wal_check = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-Atqc',
                                                  'SELECT count(*) FROM pg_stat_wal_receiver;'],
                                                 capture_output=True, text=True, timeout=10)
                        wal_count = int(wal_check.stdout.strip()) if wal_check.returncode == 0 else 0
                        
                        if wal_count > 0:
                            message = f"PostgreSQL {detected_role} operational with active replication"
                        else:
                            message = f"PostgreSQL {detected_role} operational"
                    except:
                        message = f"PostgreSQL {detected_role} operational"
                else:
                    message = f"PostgreSQL {detected_role} operational"
                
                self.send_success_response("healthy", message)
            else:
                self.send_error_response("unhealthy", f"Role mismatch (expected {ROLE}, got {detected_role})")
                
        except Exception as e:
            error_msg = f"Health check error: {str(e)}"
            try:
                with open('/var/log/pg-health-debug.log', 'a') as f:
                    f.write(f"{datetime.datetime.now().isoformat()} - ERROR: {error_msg}\n")
                    f.write(f"{traceback.format_exc()}\n")
            except:
                pass
            self.send_error_response("unhealthy", error_msg)
    
    def send_success_response(self, status, message):
        response_data = {
            "status": status,
            "service": "postgresql-ha",
            "role": ROLE,
            "message": message,
            "timestamp": datetime.datetime.now().isoformat() + "Z",
            "node_ip": NODE_IP
        }
        
        response_json = json.dumps(response_data, indent=2)
        
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response_json)))
        self.send_header('Connection', 'close')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(response_json.encode())
    
    def send_error_response(self, status, message):
        response_data = {
            "status": status,
            "service": "postgresql-ha",
            "role": ROLE,
            "message": message,
            "timestamp": datetime.datetime.now().isoformat() + "Z",
            "node_ip": NODE_IP
        }
        
        response_json = json.dumps(response_data, indent=2)
        
        self.send_response(503)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response_json)))
        self.send_header('Connection', 'close')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(response_json.encode())

# Custom TCPServer with better socket handling
class ReuseAddrTCPServer(socketserver.TCPServer):
    def __init__(self, server_address, RequestHandlerClass, bind_and_activate=True):
        self.allow_reuse_address = True
        super().__init__(server_address, RequestHandlerClass, bind_and_activate)
    
    def server_bind(self):
        # Set SO_REUSEADDR and SO_REUSEPORT if available
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except AttributeError:
            pass  # SO_REUSEPORT not available on all systems
        super().server_bind()

if __name__ == "__main__":
    try:
        # Wait a moment to ensure port is fully released
        time.sleep(2)
        
        with ReuseAddrTCPServer(("0.0.0.0", PORT), HealthHandler) as httpd:
            print(f"PostgreSQL health server running on 0.0.0.0:{PORT}")
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("Server stopped by user")
    except Exception as e:
        print(f"Server error: {e}")
        try:
            with open('/var/log/pg-health-debug.log', 'a') as f:
                f.write(f"{datetime.datetime.now().isoformat()} - STARTUP ERROR: {e}\n")
                f.write(f"{traceback.format_exc()}\n")
        except:
            pass
        sys.exit(1)
EOF

chmod +x /usr/local/bin/python-pg-health-fixed.py

# Step 4: Update systemd service to use the fixed script
info "📋 Updating systemd service configuration..."

cat > /etc/systemd/system/python-pg-health.service <<EOF
[Unit]
Description=Python PostgreSQL HA Health Endpoint (Fixed)
After=network.target postgresql.service
Wants=postgresql.service
StartLimitInterval=0

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/python3 /usr/local/bin/python-pg-health-fixed.py 8001
Restart=on-failure
RestartSec=20
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal
TimeoutStartSec=60
TimeoutStopSec=15

# Resource limits
MemoryHigh=64M
MemoryMax=128M

[Install]
WantedBy=multi-user.target
EOF

# Step 5: Reload and restart services
info "🚀 Reloading and restarting services..."

systemctl daemon-reload
systemctl enable python-pg-health.service

# Start PostgreSQL health service
info "Starting PostgreSQL health service..."
if systemctl start python-pg-health.service; then
    sleep 5
    if systemctl is-active --quiet python-pg-health.service; then
        success "PostgreSQL health service started successfully ✓"
    else
        error "PostgreSQL health service failed to start"
        systemctl status python-pg-health.service --no-pager -l || true
    fi
else
    error "Failed to start PostgreSQL health service"
fi

# Start PgBouncer health service
info "Starting PgBouncer health service..."
if systemctl start python-pgbouncer-health.service; then
    sleep 3
    if systemctl is-active --quiet python-pgbouncer-health.service; then
        success "PgBouncer health service started successfully ✓"
    else
        warn "PgBouncer health service may have issues"
        systemctl status python-pgbouncer-health.service --no-pager -l || true
    fi
else
    warn "Failed to start PgBouncer health service"
fi

# Step 6: Final verification
sleep 10

info "🧪 Final verification of health endpoints..."

# Check service status
for service in python-pg-health python-pgbouncer-health; do
    if systemctl is-active --quiet ${service}.service; then
        success "${service}.service is ACTIVE ✓"
    else
        error "${service}.service is NOT ACTIVE"
    fi
done

# Test endpoints
for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    info "Testing $service_name (port $port)..."
    
    if timeout 15 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        success "Port $port ($service_name): LOCAL access WORKING ✓"
        response=$(timeout 10 curl -s "http://localhost:$port" 2>/dev/null)
        echo "Response:"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        echo ""
    else
        error "Port $port ($service_name): LOCAL access FAILED"
    fi
    
    if timeout 15 curl -s "http://$SELF_IP:$port" >/dev/null 2>&1; then
        success "Port $port ($service_name): NETWORK access WORKING ✓"
    else
        warn "Port $port ($service_name): NETWORK access issues"
    fi
done

# Show final status
info "📊 Final Status Summary:"
echo "Listening ports:"
ss -tulnp | grep -E ":(8001|8002) " || warn "Health ports not found"
echo ""
echo "Health processes:"
ps aux | grep -E "python.*health" | grep -v grep || warn "No Python health processes"

success "🎉 Port cleanup and service restart complete!"
info ""
info "🧪 Quick test commands:"
info "  curl http://localhost:8001 | jq .    # PostgreSQL HA health"
info "  curl http://localhost:8002 | jq .    # PgBouncer health"
info ""
info "🔍 If still having issues:"
info "  systemctl status python-pg-health.service python-pgbouncer-health.service"
info "  journalctl -u python-pg-health.service -f"
info "  tail -f /var/log/pg-health-debug.log"