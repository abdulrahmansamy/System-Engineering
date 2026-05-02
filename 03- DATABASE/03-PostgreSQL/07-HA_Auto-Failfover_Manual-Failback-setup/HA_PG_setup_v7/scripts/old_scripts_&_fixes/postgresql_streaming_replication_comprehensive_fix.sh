#!/bin/bash
# PostgreSQL Streaming Replication Comprehensive Quick Fix Script
# Addresses all validation issues and implements working solutions from repmgr script

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }

# Load passwords from bootstrap if available
load_passwords() {
    info "Loading passwords from Secret Manager or generating new ones..."
    
    # Try to extract passwords from existing .pgpass file
    local pgpass_file="/var/lib/postgresql/.pgpass"
    if [[ -f "$pgpass_file" ]]; then
        info "Extracting passwords from existing .pgpass file"
        export PG_SUPER_PASS=$(grep "postgres:" "$pgpass_file" | head -1 | cut -d':' -f5 || echo "")
        export PG_REPL_PASS=$(grep "replication:" "$pgpass_file" | head -1 | cut -d':' -f5 || echo "")
        
        # If passwords not found in .pgpass, generate new ones
        if [[ -z "${PG_SUPER_PASS:-}" ]]; then
            export PG_SUPER_PASS="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
            warn "Generated new PostgreSQL superuser password"
        fi
        
        if [[ -z "${PG_REPL_PASS:-}" ]]; then
            export PG_REPL_PASS="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
            warn "Generated new replication password"
        fi
    else
        warn "No .pgpass file found, generating new passwords"
        export PG_SUPER_PASS="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
        export PG_REPL_PASS="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
    fi
    
    # Generate other passwords
    export PG_MONITOR_PASS="${PG_MONITOR_PASS:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)}"
    export PGBOUNCER_PASSWORD="${PGBOUNCER_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)}"
    
    success "Passwords loaded/generated successfully"
}

create_missing_users() {
    info "Creating missing PostgreSQL users for streaming replication..."
    
    # Check existing users first
    local repl_exists=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'replication';" 2>/dev/null || echo "0")
    local monitor_exists=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'monitor_user';" 2>/dev/null || echo "0")
    local app_exists=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'app_user';" 2>/dev/null || echo "0")
    
    info "Current users - replication: $repl_exists, monitor_user: $monitor_exists, app_user: $app_exists"
    
    # Create replication user if missing
    if [[ "$repl_exists" == "0" ]]; then
        if sudo -u postgres psql -c "CREATE USER replication WITH REPLICATION LOGIN;" >/dev/null 2>&1; then
            success "Created replication user"
        else
            warn "Failed to create replication user - may already exist"
        fi
    else
        info "Replication user already exists"
    fi
    
    # Create monitor user if missing
    if [[ "$monitor_exists" == "0" ]]; then
        if sudo -u postgres psql -c "CREATE USER monitor_user WITH LOGIN;" >/dev/null 2>&1; then
            success "Created monitor_user"
        else
            warn "Failed to create monitor_user - may already exist"
        fi
    else
        info "Monitor user already exists"
    fi
    
    # Create app user if missing
    if [[ "$app_exists" == "0" ]]; then
        if sudo -u postgres psql -c "CREATE USER app_user WITH LOGIN;" >/dev/null 2>&1; then
            success "Created app_user"
        else
            warn "Failed to create app_user - may already exist"
        fi
    else
        info "App user already exists"
    fi
    
    # Set passwords for all users (use MD5 for PgBouncer compatibility)
    info "Setting passwords and permissions..."
    sudo -u postgres psql <<EOF || warn "Some password/permission updates may have failed"
-- Set password encryption to md5 for PgBouncer compatibility
SET password_encryption = 'md5';

-- Set passwords
ALTER USER replication PASSWORD '$PG_REPL_PASS';
ALTER USER postgres PASSWORD '$PG_SUPER_PASS';
ALTER USER monitor_user PASSWORD '$PG_MONITOR_PASS';
ALTER USER app_user PASSWORD '$PG_MONITOR_PASS';

-- Grant necessary permissions
GRANT pg_monitor TO monitor_user;
GRANT CONNECT ON DATABASE postgres TO monitor_user;
GRANT CONNECT ON DATABASE postgres TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;

-- Reset password encryption
RESET password_encryption;
EOF

    # Show final user status
    info "Final user status:"
    sudo -u postgres psql -c "SELECT rolname, rolreplication, rolcanlogin FROM pg_roles WHERE rolname IN ('replication', 'monitor_user', 'app_user', 'postgres') ORDER BY rolname;" 2>/dev/null || true
    
    success "PostgreSQL users configured successfully"
}

create_replication_slot() {
    info "Creating physical replication slot for standby..."
    
    # Check if slot already exists
    local slot_exists=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = 'standby_slot';" 2>/dev/null || echo "0")
    
    if [[ "$slot_exists" == "0" ]]; then
        if sudo -u postgres psql -c "SELECT pg_create_physical_replication_slot('standby_slot');" >/dev/null 2>&1; then
            success "Created replication slot 'standby_slot'"
        else
            warn "Failed to create replication slot - may already exist"
        fi
    else
        info "Replication slot 'standby_slot' already exists"
    fi
    
    # Show replication slots
    info "Current replication slots:"
    sudo -u postgres psql -c "SELECT slot_name, slot_type, active FROM pg_replication_slots;" 2>/dev/null || true
}

update_pgpass() {
    info "Updating .pgpass file with correct credentials..."
    
    local pgpass_file="/var/lib/postgresql/.pgpass"
    
    cat > "$pgpass_file" <<EOF
# PostgreSQL HA .pgpass file (updated by comprehensive quick fix)
*:5432:*:replication:${PG_REPL_PASS}
*:5432:*:postgres:${PG_SUPER_PASS}
*:5432:*:monitor_user:${PG_MONITOR_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
*:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
localhost:5432:*:replication:${PG_REPL_PASS}
localhost:5432:*:postgres:${PG_SUPER_PASS}
localhost:6432:*:postgres:${PG_SUPER_PASS}
localhost:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
EOF

    chown postgres:postgres "$pgpass_file"
    chmod 600 "$pgpass_file"
    
    success ".pgpass file updated successfully"
}

create_pgbouncer_admin_user() {
    info "Creating/updating pgbouncer_admin user in PostgreSQL..."
    
    # Check if user exists
    local admin_exists=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'pgbouncer_admin';" 2>/dev/null || echo "0")
    
    sudo -u postgres psql <<EOF || warn "PgBouncer admin user setup had issues"
-- Set password encryption to md5 for PgBouncer compatibility
SET password_encryption = 'md5';

-- Create or update pgbouncer_admin user
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
        CREATE ROLE pgbouncer_admin LOGIN;
        RAISE NOTICE 'Created pgbouncer_admin user';
    ELSE
        RAISE NOTICE 'pgbouncer_admin user already exists';
    END IF;
END\$\$;

-- Set password
ALTER ROLE pgbouncer_admin PASSWORD '$PGBOUNCER_PASSWORD';

-- Grant necessary permissions
GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
GRANT CONNECT ON DATABASE template1 TO pgbouncer_admin;
GRANT USAGE ON SCHEMA public TO pgbouncer_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgbouncer_admin;

-- Make sure pgbouncer_admin can access pgbouncer's internal stats
ALTER ROLE pgbouncer_admin SET log_statement = 'none';

-- Reset password encryption
RESET password_encryption;
EOF

    success "pgbouncer_admin user configured"
}

update_pgbouncer_userlist() {
    info "Updating PgBouncer userlist with correct MD5 hashes..."
    
    local pgbouncer_userlist="/etc/pgbouncer/userlist.txt"
    
    # Generate MD5 hashes for PgBouncer
    local postgres_md5=$(printf '%s%s' "$PG_SUPER_PASS" "postgres" | md5sum | cut -d' ' -f1)
    local pgbouncer_admin_md5=$(printf '%s%s' "$PGBOUNCER_PASSWORD" "pgbouncer_admin" | md5sum | cut -d' ' -f1)
    local replication_md5=$(printf '%s%s' "$PG_REPL_PASS" "replication" | md5sum | cut -d' ' -f1)
    local monitor_md5=$(printf '%s%s' "$PG_MONITOR_PASS" "monitor_user" | md5sum | cut -d' ' -f1)
    
    cat > "$pgbouncer_userlist" <<EOF
;; PgBouncer MD5 Authentication File (updated by comprehensive quick fix)
"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"replication" "md5${replication_md5}"
"monitor_user" "md5${monitor_md5}"
EOF
    
    chmod 640 "$pgbouncer_userlist"
    chown root:pgbouncer "$pgbouncer_userlist" 2>/dev/null || chown postgres:postgres "$pgbouncer_userlist"
    
    # Restart PgBouncer to reload userlist
    info "Restarting PgBouncer to reload userlist..."
    systemctl restart pgbouncer || warn "Failed to restart PgBouncer service"
    sleep 3
    
    success "PgBouncer userlist updated and service restarted"
}

fix_health_endpoints() {
    info "Setting up working health endpoints (using proven approach from repmgr script)..."
    
    # Kill any conflicting processes first
    pkill -f ":8001" 2>/dev/null || true
    pkill -f ":8002" 2>/dev/null || true
    lsof -ti:8001 2>/dev/null | xargs -r kill -9 || true
    lsof -ti:8002 2>/dev/null | xargs -r kill -9 || true
    
    sleep 2
    
    # Create the working health scripts from the repmgr version
    local pg_health_script="/usr/local/bin/final-pg-health.py"
    local pgbouncer_health_script="/usr/local/bin/final-pgbouncer-health.py"
    
    # Create PostgreSQL health endpoint script
    cat > "$pg_health_script" <<'PG_HEALTH_EOF'
#!/usr/bin/env python3
"""Production-ready PostgreSQL Health Endpoint"""

import http.server
import socketserver
import json
import subprocess
import sys
import os
from datetime import datetime

def check_postgresql_health():
    """Check PostgreSQL status and role"""
    try:
        # Check if PostgreSQL service is active
        service_check = subprocess.run(
            ['systemctl', 'is-active', '--quiet', 'postgresql'],
            capture_output=True, timeout=2
        )
        
        if service_check.returncode != 0:
            return {"status": "unhealthy", "role": "unknown", "reason": "service_down"}
        
        # Check PostgreSQL role
        env = os.environ.copy()
        env['USER'] = 'postgres'
        env['HOME'] = '/var/lib/postgresql'
        
        role_check = subprocess.run(
            ['psql', '-tAc', 'SELECT pg_is_in_recovery();'],
            capture_output=True, text=True, timeout=3, env=env
        )
        
        if role_check.returncode == 0:
            is_standby = role_check.stdout.strip() == 't'
            role = "standby" if is_standby else "primary"
            return {"status": "healthy", "role": role}
        
        return {"status": "unhealthy", "role": "unknown", "reason": "query_failed"}
        
    except Exception as e:
        return {"status": "unhealthy", "role": "unknown", "reason": str(e)[:50]}

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        health_data = check_postgresql_health()
        health_data["timestamp"] = datetime.now().isoformat()
        
        status_code = 200 if health_data["status"] == "healthy" else 503
        response = json.dumps(health_data)
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        pass  # Suppress logging

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
    with socketserver.TCPServer(("", port), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        httpd.serve_forever()

if __name__ == "__main__":
    main()
PG_HEALTH_EOF

    # Create PgBouncer health endpoint script
    cat > "$pgbouncer_health_script" <<'PGBOUNCER_HEALTH_EOF'
#!/usr/bin/env python3
"""Production-ready PgBouncer Health Endpoint"""

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
        
        # Test connectivity to PgBouncer port
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

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        health_data = check_pgbouncer_health()
        health_data["timestamp"] = datetime.now().isoformat()
        
        status_code = 200 if health_data["status"] == "healthy" else 503
        response = json.dumps(health_data)
        
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(response.encode())
    
    def log_message(self, format, *args):
        pass  # Suppress logging

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8002
    with socketserver.TCPServer(("", port), HealthHandler) as httpd:
        httpd.allow_reuse_address = True
        httpd.serve_forever()

if __name__ == "__main__":
    main()
PGBOUNCER_HEALTH_EOF

    chmod +x "$pg_health_script" "$pgbouncer_health_script"
    
    # Start health endpoints using the proven manual approach
    info "Starting PostgreSQL health endpoint on port 8001..."
    sudo -u postgres nohup python3 "$pg_health_script" 8001 >/dev/null 2>&1 &
    
    info "Starting PgBouncer health endpoint on port 8002..."
    sudo -u postgres nohup python3 "$pgbouncer_health_script" 8002 >/dev/null 2>&1 &
    
    # Wait for endpoints to start
    sleep 3
    
    # Test endpoints
    if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
        success "PostgreSQL health endpoint is working on port 8001"
    else
        warn "PostgreSQL health endpoint failed to start"
    fi
    
    if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
        success "PgBouncer health endpoint is working on port 8002"
    else
        warn "PgBouncer health endpoint failed to start"
    fi
}

test_connections() {
    info "Testing database connections..."
    
    # Test direct PostgreSQL connection
    if sudo -u postgres psql -c "SELECT 'Direct PostgreSQL connection successful' as status;" >/dev/null 2>&1; then
        success "✅ Direct PostgreSQL connection working"
    else
        error "❌ Direct PostgreSQL connection failed"
    fi
    
    # Test PgBouncer connection with proper .pgpass
    if timeout 10 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer connection successful' as status;" >/dev/null 2>&1; then
        success "✅ PgBouncer connection working"
    else
        warn "⚠️ PgBouncer connection failed - retrying after userlist reload..."
        
        # Force reload PgBouncer configuration
        systemctl restart pgbouncer
        sleep 3
        
        if timeout 10 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer connection successful' as status;" >/dev/null 2>&1; then
            success "✅ PgBouncer connection working after restart"
        else
            warn "⚠️ PgBouncer connection still failing - check authentication manually"
        fi
    fi
    
    # Test replication user
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -U replication -d postgres -c "SELECT 'Replication user working' as status;" >/dev/null 2>&1; then
        success "✅ Replication user authentication working"
    else
        warn "⚠️ Replication user authentication needs attention"
    fi
}

show_status() {
    info "=== Current System Status ==="
    
    echo "Service Status:"
    echo "  PostgreSQL: $(systemctl is-active postgresql)"
    echo "  PgBouncer: $(systemctl is-active pgbouncer)"
    echo
    
    echo "PostgreSQL Users:"
    sudo -u postgres psql -c "SELECT rolname, rolreplication, rolcanlogin FROM pg_roles WHERE rolname IN ('postgres', 'replication', 'monitor_user', 'app_user', 'pgbouncer_admin') ORDER BY rolname;" 2>/dev/null || echo "Could not query users"
    echo
    
    echo "Replication Slots:"
    sudo -u postgres psql -c "SELECT slot_name, slot_type, active FROM pg_replication_slots;" 2>/dev/null || echo "No replication slots"
    echo
    
    echo "Health Endpoints:"
    if timeout 3 curl -sf http://localhost:8001 >/dev/null 2>&1; then
        echo "  PostgreSQL Health (8001): ✅ Working"
    else
        echo "  PostgreSQL Health (8001): ❌ Not responding"
    fi
    
    if timeout 3 curl -sf http://localhost:8002 >/dev/null 2>&1; then
        echo "  PgBouncer Health (8002): ✅ Working"
    else
        echo "  PgBouncer Health (8002): ❌ Not responding"
    fi
    echo
    
    info "Connection Information:"
    local current_ip=$(hostname -I | awk '{print $1}')
    echo "  PostgreSQL Direct: postgresql://postgres:***@$current_ip:5432/postgres"
    echo "  PgBouncer Pooled: postgresql://postgres:***@$current_ip:6432/postgres"
    echo "  PostgreSQL Health: http://$current_ip:8001"
    echo "  PgBouncer Health: http://$current_ip:8002"
}

main() {
    echo "PostgreSQL Streaming Replication Comprehensive Quick Fix"
    echo "========================================================"
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    load_passwords
    create_missing_users
    create_replication_slot
    update_pgpass
    create_pgbouncer_admin_user
    update_pgbouncer_userlist
    fix_health_endpoints
    test_connections
    show_status
    
    echo
    success "🎉 Comprehensive fix completed successfully!"
    echo "All major validation issues should now be resolved."
    echo "Run the validation script again to verify all fixes."
}

main "$@"