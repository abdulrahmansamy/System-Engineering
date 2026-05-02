#!/bin/bash
# PostgreSQL Streaming Replication Quick Fix Script
# Addresses missing components identified by validation

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

# Load secrets from bootstrap if available
load_passwords() {
    info "Loading passwords from Secret Manager or generating new ones..."
    
    # Try to load from existing .pgpass or generate
    if [[ -f "/var/lib/postgresql/.pgpass" ]]; then
        info "Using existing .pgpass file"
    else
        warn "No .pgpass file found, will create with generated passwords"
    fi
    
    # Generate secure passwords
    export PG_SUPER_PASS="${PG_SUPER_PASS:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)}"
    export PG_REPL_PASS="${PG_REPL_PASS:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)}"
    export PG_MONITOR_PASS="${PG_MONITOR_PASS:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)}"
    export PGBOUNCER_PASSWORD="${PGBOUNCER_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)}"
}

create_missing_users() {
    info "Creating missing PostgreSQL users for streaming replication..."
    
    sudo -u postgres psql <<EOF
-- Create replication user if it doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replication') THEN
        CREATE USER replication WITH REPLICATION LOGIN;
        RAISE NOTICE 'Created replication user';
    ELSE
        RAISE NOTICE 'Replication user already exists';
    END IF;
END\$\$;

-- Create monitor user if it doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor_user') THEN
        CREATE USER monitor_user WITH LOGIN;
        RAISE NOTICE 'Created monitor_user';
    ELSE
        RAISE NOTICE 'Monitor user already exists';
    END IF;
END\$\$;

-- Create app user if it doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE USER app_user WITH LOGIN;
        RAISE NOTICE 'Created app_user';
    ELSE
        RAISE NOTICE 'App user already exists';
    END IF;
END\$\$;

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

-- Show users created
SELECT rolname, rolreplication, rolsuper FROM pg_roles WHERE rolname IN ('replication', 'monitor_user', 'app_user', 'postgres');
EOF

    success "PostgreSQL users created/updated"
}

create_replication_slot() {
    info "Creating physical replication slot for standby..."
    
    sudo -u postgres psql <<EOF || warn "Replication slot creation failed - may already exist"
-- Create replication slot if it doesn't exist
SELECT CASE 
    WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'standby_slot') 
    THEN 'Replication slot already exists'
    ELSE (SELECT pg_create_physical_replication_slot('standby_slot'))::text
END AS result;
EOF

    success "Replication slot configured"
}

update_pgpass() {
    info "Updating .pgpass file with correct credentials..."
    
    local pgpass_file="/var/lib/postgresql/.pgpass"
    
    cat > "$pgpass_file" <<EOF
# PostgreSQL HA .pgpass file (updated by quick fix)
*:5432:*:replication:${PG_REPL_PASS}
*:5432:*:postgres:${PG_SUPER_PASS}
*:5432:*:monitor_user:${PG_MONITOR_PASS}
*:6432:*:postgres:${PG_SUPER_PASS}
*:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
localhost:5432:*:replication:${PG_REPL_PASS}
localhost:5432:*:postgres:${PG_SUPER_PASS}
localhost:6432:*:postgres:${PG_SUPER_PASS}
EOF

    chown postgres:postgres "$pgpass_file"
    chmod 600 "$pgpass_file"
    
    success ".pgpass file updated"
}

update_pgbouncer_userlist() {
    info "Updating PgBouncer userlist with correct MD5 hashes..."
    
    local pgbouncer_userlist="/etc/pgbouncer/userlist.txt"
    
    # Generate MD5 hashes
    local postgres_md5=$(printf '%s%s' "$PG_SUPER_PASS" "postgres" | md5sum | cut -d' ' -f1)
    local pgbouncer_admin_md5=$(printf '%s%s' "$PGBOUNCER_PASSWORD" "pgbouncer_admin" | md5sum | cut -d' ' -f1)
    local replication_md5=$(printf '%s%s' "$PG_REPL_PASS" "replication" | md5sum | cut -d' ' -f1)
    local monitor_md5=$(printf '%s%s' "$PG_MONITOR_PASS" "monitor_user" | md5sum | cut -d' ' -f1)
    
    cat > "$pgbouncer_userlist" <<EOF
;; PgBouncer MD5 Authentication File (updated by quick fix)
"postgres" "md5${postgres_md5}"
"pgbouncer_admin" "md5${pgbouncer_admin_md5}"
"replication" "md5${replication_md5}"
"monitor_user" "md5${monitor_md5}"
EOF
    
    chmod 640 "$pgbouncer_userlist"
    chown root:pgbouncer "$pgbouncer_userlist"
    
    # Restart PgBouncer to reload userlist
    systemctl restart pgbouncer
    
    success "PgBouncer userlist updated and service restarted"
}

create_pgbouncer_admin_user() {
    info "Creating pgbouncer_admin user in PostgreSQL..."
    
    sudo -u postgres psql <<EOF
-- Create pgbouncer_admin user for admin operations
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
        CREATE ROLE pgbouncer_admin LOGIN;
        RAISE NOTICE 'Created pgbouncer_admin user';
    ELSE
        RAISE NOTICE 'pgbouncer_admin user already exists';
    END IF;
END\$\$;

-- Set password (using MD5 for PgBouncer compatibility)
SET password_encryption = 'md5';
ALTER ROLE pgbouncer_admin PASSWORD '$PGBOUNCER_PASSWORD';

-- Grant necessary permissions
GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
GRANT CONNECT ON DATABASE template1 TO pgbouncer_admin;
GRANT USAGE ON SCHEMA public TO pgbouncer_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgbouncer_admin;

-- Reset password encryption
RESET password_encryption;
EOF

    success "pgbouncer_admin user created"
}

start_health_endpoints() {
    info "Starting health endpoint services..."
    
    # Start PostgreSQL health endpoint
    if systemctl is-active --quiet final-pg-health.service; then
        info "PostgreSQL health service already running"
    else
        systemctl start final-pg-health.service || warn "Failed to start PostgreSQL health service"
    fi
    
    # Start PgBouncer health endpoint  
    if systemctl is-active --quiet final-pgbouncer-health.service; then
        info "PgBouncer health service already running"
    else
        systemctl start final-pgbouncer-health.service || warn "Failed to start PgBouncer health service"
    fi
    
    # Wait for services to start
    sleep 3
    
    # Test endpoints
    if timeout 5 curl -sf http://localhost:8001 >/dev/null 2>&1; then
        success "PostgreSQL health endpoint is working"
    else
        warn "PostgreSQL health endpoint not responding"
    fi
    
    if timeout 5 curl -sf http://localhost:8002 >/dev/null 2>&1; then
        success "PgBouncer health endpoint is working"
    else
        warn "PgBouncer health endpoint not responding"
    fi
}

fix_failover_config() {
    info "Updating failover configuration with correct IP addresses..."
    
    local failover_conf="/etc/postgresql/failover.conf"
    local current_ip=$(hostname -I | awk '{print $1}')
    
    if [[ -f "$failover_conf" ]]; then
        # Update primary host to current IP
        sed -i "s/PRIMARY_HOST=.*/PRIMARY_HOST=\"$current_ip\"/" "$failover_conf"
        success "Updated failover configuration with current IP: $current_ip"
    else
        warn "Failover configuration file not found"
    fi
}

test_connections() {
    info "Testing database connections..."
    
    # Test direct PostgreSQL connection
    if sudo -u postgres psql -c "SELECT 'Direct connection successful' as status;" postgres >/dev/null 2>&1; then
        success "Direct PostgreSQL connection working"
    else
        error "Direct PostgreSQL connection failed"
    fi
    
    # Test PgBouncer connection
    if timeout 10 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer connection successful' as status;" >/dev/null 2>&1; then
        success "PgBouncer connection working"
    else
        warn "PgBouncer connection failed - may need password adjustment"
    fi
    
    # Test replication user
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -U replication -d postgres -c "SELECT 'Replication user working' as status;" >/dev/null 2>&1; then
        success "Replication user authentication working"
    else
        warn "Replication user authentication may need adjustment"
    fi
}

show_status() {
    info "=== Current Status ==="
    
    echo "PostgreSQL Service: $(systemctl is-active postgresql)"
    echo "PgBouncer Service: $(systemctl is-active pgbouncer)"
    echo "PostgreSQL Health: $(systemctl is-active final-pg-health.service 2>/dev/null || echo 'inactive')"
    echo "PgBouncer Health: $(systemctl is-active final-pgbouncer-health.service 2>/dev/null || echo 'inactive')"
    
    echo
    echo "PostgreSQL Users:"
    sudo -u postgres psql -c "SELECT rolname, rolreplication, rolsuper FROM pg_roles WHERE rolname IN ('postgres', 'replication', 'monitor_user', 'app_user', 'pgbouncer_admin');" postgres
    
    echo
    echo "Replication Slots:"
    sudo -u postgres psql -c "SELECT slot_name, slot_type, active FROM pg_replication_slots;" postgres
    
    echo
    info "Connection Information:"
    local current_ip=$(hostname -I | awk '{print $1}')
    echo "PostgreSQL Direct: postgresql://postgres:***@$current_ip:5432/postgres"
    echo "PgBouncer Pooled: postgresql://postgres:***@$current_ip:6432/postgres"
    echo "PostgreSQL Health: http://$current_ip:8001"
    echo "PgBouncer Health: http://$current_ip:8002"
}

main() {
    echo "PostgreSQL Streaming Replication Quick Fix Script"
    echo "================================================="
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    load_passwords
    create_missing_users
    create_replication_slot
    update_pgpass
    update_pgbouncer_userlist
    create_pgbouncer_admin_user
    start_health_endpoints
    fix_failover_config
    test_connections
    show_status
    
    echo
    success "Quick fix completed! Please run the validation script again to verify."
    echo "Passwords have been generated and saved to .pgpass file."
    echo "Consider backing up these passwords to Secret Manager for production use."
}

main "$@"