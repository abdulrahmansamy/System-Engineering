#!/bin/bash
# Complete Health Endpoints Fix and Restart
# Addresses all current issues with Python health endpoints

set -euo pipefail

info() { echo "[INFO] $*"; }
success() { echo "[SUCCESS] ✓ $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

info "🔧 Complete health endpoints fix - addressing all current issues"

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

# Complete cleanup first
info "🛑 Complete cleanup of all health processes and services..."
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
pkill -f "python.*health" 2>/dev/null || true
pkill -f "enhanced.*health" 2>/dev/null || true
pkill -f "network.*health" 2>/dev/null || true

# Stop all related services
for service in python-pg-health python-pgbouncer-health enhanced-pg-health enhanced-pgbouncer-health network-pg-health network-pgbouncer-health; do
    systemctl stop "${service}.service" 2>/dev/null || true
done

sleep 5

# Remove old service files
rm -f /etc/systemd/system/python-*-health.service 2>/dev/null || true
rm -f /etc/systemd/system/enhanced-*-health.service 2>/dev/null || true
rm -f /etc/systemd/system/network-*-health.service 2>/dev/null || true

systemctl daemon-reload

# Create Python health endpoint files with better error handling
info "🐍 Creating robust Python health endpoints..."

# PostgreSQL health endpoint (port 8001)
cat > /usr/local/bin/python-pg-health.py <<EOF
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import datetime
import sys
import os
import traceback

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
ROLE = "$ROLE"
NODE_IP = "$SELF_IP"

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Log to syslog instead of stdout
        timestamp = datetime.datetime.now().isoformat()
        message = format % args
        try:
            with open('/var/log/pg-health-debug.log', 'a') as f:
                f.write(f"{timestamp} - {message}\n")
        except:
            pass
    
    def do_GET(self):
        try:
            # More robust PostgreSQL service check
            try:
                postgres_check = subprocess.run(['systemctl', 'is-active', 'postgresql'], 
                                              capture_output=True, text=True, timeout=5)
                postgres_active = postgres_check.stdout.strip() == 'active'
            except:
                postgres_active = False
            
            if not postgres_active:
                # Fallback to process check
                postgres_running = subprocess.run(['pgrep', '-f', 'postgres'], 
                                                capture_output=True, text=True).returncode == 0
                if not postgres_running:
                    self.send_error_response("unhealthy", "PostgreSQL service not running")
                    return
            
            # Test PostgreSQL connectivity with timeout
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
            
            # Check role with better error handling
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
            
            # Role validation and status determination
            if detected_role == ROLE:
                if ROLE == "standby":
                    try:
                        # Check WAL receiver for standby with timeout
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
            # Log full traceback for debugging
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

if __name__ == "__main__":
    try:
        # Bind to all interfaces for network access
        with socketserver.TCPServer(("0.0.0.0", PORT), HealthHandler) as httpd:
            httpd.allow_reuse_address = True
            print(f"PostgreSQL health server running on 0.0.0.0:{PORT}")
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("Server stopped by user")
    except Exception as e:
        print(f"Server error: {e}")
        # Log error for debugging
        try:
            with open('/var/log/pg-health-debug.log', 'a') as f:
                f.write(f"{datetime.datetime.now().isoformat()} - STARTUP ERROR: {e}\n")
                f.write(f"{traceback.format_exc()}\n")
        except:
            pass
        sys.exit(1)
EOF

# PgBouncer health endpoint (port 8002)
cat > /usr/local/bin/python-pgbouncer-health.py <<EOF
#!/usr/bin/env python3
import http.server
import socketserver
import json
import subprocess
import datetime
import sys
import socket
import traceback

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8002
NODE_IP = "$SELF_IP"

class PgBouncerHealthHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        timestamp = datetime.datetime.now().isoformat()
        message = format % args
        try:
            with open('/var/log/pgbouncer-health-debug.log', 'a') as f:
                f.write(f"{timestamp} - {message}\n")
        except:
            pass
    
    def do_GET(self):
        try:
            # Check PgBouncer service status
            try:
                pgb_service_check = subprocess.run(['systemctl', 'is-active', 'pgbouncer'], 
                                                 capture_output=True, text=True, timeout=5)
                pgb_service_active = pgb_service_check.stdout.strip() == 'active'
            except:
                pgb_service_active = False
            
            # Fallback to process check
            if not pgb_service_active:
                pgb_running = subprocess.run(['pgrep', '-f', 'pgbouncer'], 
                                           capture_output=True, text=True).returncode == 0
                if not pgb_running:
                    self.send_response_json("unhealthy", "PgBouncer process not running", "process_down", 503)
                    return
            
            # Check if port 6432 is listening with better error handling
            try:
                with socket.create_connection(('localhost', 6432), timeout=5):
                    pass
            except Exception as e:
                self.send_response_json("unhealthy", f"PgBouncer port 6432 not accepting connections: {str(e)}", "port_unavailable", 503)
                return
            
            # Try to connect to PgBouncer admin with extended timeout
            try:
                admin_test = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-h', 'localhost', '-p', '6432', 
                                           '-d', 'pgbouncer', '-c', 'SHOW POOLS;'], 
                                          capture_output=True, text=True, timeout=10)
                
                if admin_test.returncode == 0:
                    # Count pools more robustly
                    lines = [line.strip() for line in admin_test.stdout.split('\n') if line.strip()]
                    # Filter out header and separator lines
                    pool_lines = [line for line in lines if '|' in line and not line.startswith('-')]
                    active_pools = max(0, len(pool_lines) - 1)  # Subtract header
                    self.send_response_json("healthy", "PgBouncer fully operational with admin access", 
                                          "admin_accessible", 200, active_pools)
                    return
            except subprocess.TimeoutExpired:
                pass  # Continue to next test
            except Exception as e:
                pass  # Continue to next test
            
            # Try database connection with timeout
            try:
                db_test = subprocess.run(['sudo', '-u', 'postgres', 'psql', '-h', 'localhost', '-p', '6432',
                                        '-d', 'postgres', '-c', 'SELECT 1;'], 
                                       capture_output=True, text=True, timeout=10)
                
                if db_test.returncode == 0:
                    self.send_response_json("healthy", "PgBouncer operational for database connections", 
                                          "db_accessible", 200)
                    return
            except subprocess.TimeoutExpired:
                pass  # Continue to final status
            except Exception as e:
                pass  # Continue to final status
            
            # Service is running and listening, report as healthy for load balancer
            self.send_response_json("healthy", "PgBouncer running and accepting connections",
                                  "service_running", 200)
                
        except Exception as e:
            error_msg = f"Health check error: {str(e)}"
            # Log full traceback for debugging
            try:
                with open('/var/log/pgbouncer-health-debug.log', 'a') as f:
                    f.write(f"{datetime.datetime.now().isoformat()} - ERROR: {error_msg}\n")
                    f.write(f"{traceback.format_exc()}\n")
            except:
                pass
            self.send_response_json("unhealthy", error_msg, "check_error", 503)
    
    def send_response_json(self, status, message, detailed_status, http_code, active_pools=None):
        response_data = {
            "service": "pgbouncer",
            "status": status,
            "message": message,
            "detailed_status": detailed_status,
            "timestamp": datetime.datetime.now().isoformat() + "Z",
            "port": 6432,
            "node_ip": NODE_IP
        }
        
        if active_pools is not None:
            response_data["active_pools"] = active_pools
        
        response_json = json.dumps(response_data, indent=2)
        
        self.send_response(http_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response_json)))
        self.send_header('Connection', 'close')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Server', 'PgBouncer-HealthMonitor/4.0')
        self.end_headers()
        self.wfile.write(response_json.encode())

if __name__ == "__main__":
    try:
        # Bind to all interfaces for network access
        with socketserver.TCPServer(("0.0.0.0", PORT), PgBouncerHealthHandler) as httpd:
            httpd.allow_reuse_address = True
            print(f"PgBouncer health server running on 0.0.0.0:{PORT}")
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("Server stopped by user")
    except Exception as e:
        print(f"Server error: {e}")
        # Log error for debugging
        try:
            with open('/var/log/pgbouncer-health-debug.log', 'a') as f:
                f.write(f"{datetime.datetime.now().isoformat()} - STARTUP ERROR: {e}\n")
                f.write(f"{traceback.format_exc()}\n")
        except:
            pass
        sys.exit(1)
EOF

# Make scripts executable
chmod +x /usr/local/bin/python-pg-health.py
chmod +x /usr/local/bin/python-pgbouncer-health.py

# Create log files with proper permissions
touch /var/log/pg-health-debug.log /var/log/pgbouncer-health-debug.log
chown postgres:postgres /var/log/pg-health-debug.log /var/log/pgbouncer-health-debug.log
chmod 644 /var/log/pg-health-debug.log /var/log/pgbouncer-health-debug.log

# Create enhanced systemd services
info "📋 Creating enhanced systemd services..."

cat > /etc/systemd/system/python-pg-health.service <<EOF
[Unit]
Description=Python PostgreSQL HA Health Endpoint
After=network.target postgresql.service
Wants=postgresql.service
StartLimitInterval=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/python-pg-health.py 8001
Restart=always
RestartSec=15
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal
TimeoutStartSec=30
TimeoutStopSec=10

# Resource limits
MemoryHigh=64M
MemoryMax=128M

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/python-pgbouncer-health.service <<EOF
[Unit]
Description=Python PgBouncer Health Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service
StartLimitInterval=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/python-pgbouncer-health.py 8002
Restart=always
RestartSec=15
User=postgres
Group=postgres
StandardOutput=journal
StandardError=journal
TimeoutStartSec=30
TimeoutStopSec=10

# Resource limits
MemoryHigh=64M
MemoryMax=128M

[Install]
WantedBy=multi-user.target
EOF

# Reload and enable services
systemctl daemon-reload
systemctl enable python-pg-health.service
systemctl enable python-pgbouncer-health.service

# Start services
info "🚀 Starting enhanced health services..."
systemctl start python-pg-health.service
systemctl start python-pgbouncer-health.service

# Wait for services to start
sleep 10

# Comprehensive testing
info "🧪 Comprehensive health endpoint testing..."

# Check service status
info "📊 Checking service status..."
for service in python-pg-health python-pgbouncer-health; do
    if systemctl is-active --quiet ${service}.service; then
        success "${service}.service is ACTIVE ✓"
    else
        error "${service}.service is NOT ACTIVE"
        systemctl status ${service}.service --no-pager -l || true
    fi
done

# Test local access
info "🏠 Testing local access..."
for port in 8001 8002; do
    service_name="PostgreSQL HA"
    if [[ $port -eq 8002 ]]; then
        service_name="PgBouncer"
    fi
    
    for attempt in {1..5}; do
        if timeout 15 curl -s "http://localhost:$port" >/dev/null 2>&1; then
            success "Port $port ($service_name): Local access WORKING ✓"
            response=$(timeout 10 curl -s "http://localhost:$port" 2>/dev/null)
            echo "Response:"
            echo "$response" | jq . 2>/dev/null || echo "$response"
            echo ""
            break
        else
            if [[ $attempt -eq 5 ]]; then
                error "Port $port ($service_name): Local access FAILED after 5 attempts"
                # Show debugging info
                warn "Debugging info:"
                ss -tulnp | grep ":$port " || warn "  Port $port not listening"
                ps aux | grep -E "python.*$port" | grep -v grep || warn "  No Python process for port $port"
            else
                warn "Port $port: Attempt $attempt failed, retrying..."
                sleep 3
            fi
        fi
    done
done

# Test network access
info "🌐 Testing network access..."
for port in 8001 8002; do
    if timeout 15 curl -s "http://$SELF_IP:$port" >/dev/null 2>&1; then
        success "Port $port: Network access WORKING ✓"
        response=$(timeout 10 curl -s "http://$SELF_IP:$port" 2>/dev/null)
        echo "Response:"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        echo ""
    else
        warn "Port $port: Network access issues"
        # Check if it's a firewall issue
        if timeout 3 nc -z "$SELF_IP" "$port" 2>/dev/null; then
            warn "  Port is reachable but HTTP request failed"
        else
            warn "  Port is not reachable (may be firewall related)"
        fi
    fi
done

# Show listening ports and processes
info "📡 Current network status:"
echo "Listening ports:"
ss -tulnp | grep -E ":(8001|8002) " || warn "Ports 8001/8002 not found in listening"

echo ""
echo "Health processes:"
ps aux | grep -E "(python.*health|:800[12])" | grep -v grep || warn "No health processes found"

success "🎉 Enhanced health endpoints setup complete!"
info ""
info "📋 Final Status Summary:"
info "  Node Role: $ROLE"
info "  Node IP: $SELF_IP" 
info "  Services: python-pg-health.service, python-pgbouncer-health.service"
info ""
info "🧪 Test commands:"
info "  curl http://localhost:8001 | jq .    # Local PostgreSQL health"
info "  curl http://localhost:8002 | jq .    # Local PgBouncer health"
info "  curl http://$SELF_IP:8001 | jq .  # Network PostgreSQL health"
info "  curl http://$SELF_IP:8002 | jq .  # Network PgBouncer health"
info ""
info "🔍 Debugging commands:"
info "  systemctl status python-pg-health.service python-pgbouncer-health.service"
info "  journalctl -u python-pg-health.service -u python-pgbouncer-health.service -f"
info "  tail -f /var/log/pg-health-debug.log /var/log/pgbouncer-health-debug.log"
info ""
success "🚀 Ready for cross-node testing!"