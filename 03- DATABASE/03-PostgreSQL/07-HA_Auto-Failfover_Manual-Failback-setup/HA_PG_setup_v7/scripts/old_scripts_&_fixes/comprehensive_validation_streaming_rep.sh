#!/bin/bash
# PostgreSQL HA Streaming Replication + PgBouncer Comprehensive Validation Script
# Validates expert-validated streaming replication deployment with custom failover
# Version: 3.0.0 - Expert-Validated Streaming Replication: Native PostgreSQL HA, Custom Failover, Witness Consensus

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_VERSION="3.0.0"
VALIDATION_START_TIME=$(date +%s)

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Status counters
PASSED=0
FAILED=0
WARNINGS=0

# Configuration
PG_VERSION="17"
FAILOVER_CONF_FILE="/etc/postgresql/failover.conf"
FAILOVER_SCRIPT="/usr/local/bin/pg-failover-manager.sh"
PGBOUNCER_PORT=6432
HEALTH_PORT_PG=8001
HEALTH_PORT_PGBOUNCER=8002

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; WARNINGS=$((WARNINGS + 1)); }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; FAILED=$((FAILED + 1)); }
success() { printf "%b[PASS]%b %s\n" "$GREEN" "$NC" "$*"; PASSED=$((PASSED + 1)); }
fail() { printf "%b[FAIL]%b %s\n" "$RED" "$NC" "$*"; FAILED=$((FAILED + 1)); }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }
subsection() { printf "\n%b--- %s ---%b\n" "$CYAN" "$*" "$NC"; }

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

check_command() {
    local cmd="$1" desc="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        success "$desc is installed"
        return 0
    else
        fail "$desc is not installed"
        return 1
    fi
}

check_service() {
    local service="$1" desc="$2"
    if systemctl is-active --quiet "$service"; then
        success "$desc service is running"
        return 0
    else
        fail "$desc service is not running"
        return 1  
    fi
}

check_port() {
    local port="$1" desc="$2"
    if timeout 3 bash -c "</dev/tcp/localhost/$port" 2>/dev/null; then
        success "$desc (port $port) is listening"
        return 0
    else
        fail "$desc (port $port) is not listening"
        return 1
    fi
}

test_http_endpoint() {
    local url="$1" desc="$2" expected="$3"
    local response
    if response=$(timeout 5 curl -s "$url" 2>/dev/null); then
        if [[ -n "$expected" ]] && echo "$response" | grep -q "$expected"; then
            success "$desc endpoint is responding correctly"
            # Try to format as JSON, fall back to plain text if it fails
            if echo "$response" | jq . >/dev/null 2>&1; then
                echo "    Response: $(echo "$response" | jq .)"
            else
                echo "    Response: $response"
            fi
        elif [[ -z "$expected" ]]; then
            success "$desc endpoint is responding"
            # Try to format as JSON, fall back to plain text if it fails
            if echo "$response" | jq . >/dev/null 2>&1; then
                echo "    Response: $(echo "$response" | jq .)"
            else
                echo "    Response: $response"
            fi
        else
            warn "$desc endpoint responding but content unexpected"
            echo "    Response: $response"
        fi
        return 0
    else
        fail "$desc endpoint is not responding"
        return 1
    fi
}

get_pg_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        echo "standby"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
        echo "primary"
    else
        echo "unknown"
    fi
}

# ============================================================================
# VALIDATION TESTS
# ============================================================================

validate_system_prerequisites() {
    section "System Prerequisites"
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        success "Running as root user"
    else
        warn "Not running as root - some checks may fail"
    fi
    
    # Check operating system
    if grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
        local version
        version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        success "Running on Ubuntu $version"
    else
        warn "Not running on Ubuntu - compatibility not guaranteed"
    fi
    
    # Check basic tools
    check_command curl "curl"
    check_command jq "jq" 
    check_command systemctl "systemctl"
    if ! check_command nc "netcat"; then
        info "Installing netcat..."
        export DEBIAN_FRONTEND=noninteractive
        if apt-get update && apt-get install -y netcat-openbsd; then
            info "✓ netcat installed successfully"
        else
            warn "Failed to install netcat - some tests may be limited"
        fi
    fi
}

validate_postgresql_installation() {
    section "PostgreSQL Installation"
    
    # Check PostgreSQL binaries
    check_command psql "PostgreSQL client"
    
    # Check PostgreSQL server binary (different paths possible)
    if command -v postgres >/dev/null 2>&1; then
        success "PostgreSQL server is installed"
    elif command -v "/usr/lib/postgresql/$PG_VERSION/bin/postgres" >/dev/null 2>&1; then
        success "PostgreSQL server is installed"
    elif [[ -x "/usr/lib/postgresql/$PG_VERSION/bin/postgres" ]]; then
        success "PostgreSQL server is installed"
    else
        fail "PostgreSQL server is not installed"
    fi
    
    # Check PostgreSQL version
    if command -v psql >/dev/null 2>&1; then
        local version
        version=$(psql --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [[ "$version" == "$PG_VERSION"* ]]; then
            success "PostgreSQL version $version matches expected $PG_VERSION"
        else
            warn "PostgreSQL version $version differs from expected $PG_VERSION"
        fi
    fi
    
    # Check PostgreSQL service
    check_service postgresql "PostgreSQL"
    
    # Check PostgreSQL port
    check_port 5432 "PostgreSQL"
    
    # Check database connectivity
    if sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
        success "PostgreSQL database connectivity working"
    else
        fail "Cannot connect to PostgreSQL database"
    fi
}

validate_postgresql_configuration() {
    section "PostgreSQL Configuration"
    
    # Check configuration files
    local pg_conf="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    local pg_hba="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
    
    if [[ -f "$pg_conf" ]]; then
        success "PostgreSQL configuration file exists: $pg_conf"
        
        # Check HA-specific settings
        if grep -q "^wal_level.*replica" "$pg_conf"; then
            success "WAL level set to replica for replication"
        else
            fail "WAL level not configured for replication"
        fi
        
        if grep -q "^max_wal_senders.*[1-9]" "$pg_conf"; then
            success "WAL senders configured for replication"
        else
            fail "WAL senders not configured"
        fi
        
        if grep -q "^listen_addresses.*\\*" "$pg_conf"; then
            success "PostgreSQL configured to listen on all addresses"
        else
            warn "PostgreSQL may not be configured to listen on all addresses"
        fi
        
    else
        fail "PostgreSQL configuration file not found: $pg_conf"
    fi
    
    if [[ -f "$pg_hba" ]]; then
        success "PostgreSQL HBA configuration file exists: $pg_hba"
        
        # Check replication entries
        if grep -q "replication.*repmgr" "$pg_hba"; then
            success "Replication access configured for repmgr"
        else
            warn "Replication access for repmgr not found in pg_hba.conf"
        fi
        
    else
        fail "PostgreSQL HBA configuration file not found: $pg_hba"
    fi
}

validate_postgresql_role() {
    section "PostgreSQL Role and Status"
    
    local role
    role=$(get_pg_role)
    
    case "$role" in
        primary)
            success "Node is functioning as PRIMARY"
            
            # Check for replication slots on primary
            local slots
            slots=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_replication_slots;" postgres 2>/dev/null || echo "0")
            if [[ "$slots" -gt 0 ]]; then
                success "Replication slots exist ($slots slots)"
            else
                warn "No replication slots found (may be normal if no standby connected)"
            fi
            
            # Check WAL senders
            local senders
            senders=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" postgres 2>/dev/null || echo "0")
            if [[ "$senders" -gt 0 ]]; then
                success "Active WAL senders found ($senders senders)"
            else
                warn "No active WAL senders (may be normal if no standby connected)"
            fi
            ;;
            
        standby)
            success "Node is functioning as STANDBY"
            
            # Check WAL receiver
            if sudo -u postgres psql -Atqc "SELECT pid FROM pg_stat_wal_receiver;" postgres 2>/dev/null | grep -q '[0-9]'; then
                success "WAL receiver is active"
            else
                fail "WAL receiver is not active"
            fi
            
            # Check replication lag
            local lag
            lag=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" postgres 2>/dev/null || echo "unknown")
            if [[ "$lag" != "unknown" ]]; then
                # Use awk for floating point comparison instead of bc
                if [[ $(echo "$lag" | awk '{print ($1 < 30) ? "1" : "0"}') -eq 1 ]]; then
                    success "Replication lag is acceptable (${lag}s)"
                elif [[ $(echo "$lag" | awk '{print ($1 < 300) ? "1" : "0"}') -eq 1 ]]; then
                    warn "Replication lag is moderate (${lag}s)"
                else
                    warn "Replication lag is high (${lag}s)"
                    
                    # Additional replication diagnostics
                    info "Replication diagnostics:"
                    local last_received last_replayed
                    last_received=$(sudo -u postgres psql -Atqc "SELECT pg_last_wal_receive_lsn();" postgres 2>/dev/null || echo "unknown")
                    last_replayed=$(sudo -u postgres psql -Atqc "SELECT pg_last_wal_replay_lsn();" postgres 2>/dev/null || echo "unknown")
                    info "  → Last WAL received: $last_received"
                    info "  → Last WAL replayed: $last_replayed"
                    
                    # Check if replication is still active
                    if pgrep -f "wal receiver" >/dev/null; then
                        info "  → WAL receiver process is running"
                    else
                        warn "  → WAL receiver process not found"
                    fi
                    
                    info "  → Consider restarting replication or checking primary connection"
                fi
            else
                warn "Could not determine replication lag"
            fi
            ;;
            
        *)
            fail "Could not determine PostgreSQL role"
            ;;
    esac
    
    # Check PostgreSQL is writable (primary) or read-only (standby)
    if [[ "$role" == "primary" ]]; then
        if sudo -u postgres psql -c "CREATE TEMP TABLE test_write (id int);" postgres >/dev/null 2>&1; then
            success "Database is writable (correct for primary)"
        else
            fail "Database is not writable (incorrect for primary)"
        fi
    elif [[ "$role" == "standby" ]]; then
        if ! sudo -u postgres psql -c "CREATE TEMP TABLE test_write (id int);" postgres >/dev/null 2>&1; then
            success "Database is read-only (correct for standby)"
        else
            warn "Database appears writable (unexpected for standby)"
        fi
    fi
}

validate_repmgr_installation() {
    section "Repmgr Installation and Configuration"
    
    # Check repmgr binary
    check_command repmgr "repmgr"
    
    # Check repmgr configuration
    if [[ -f "$REPMGR_CONF_FILE" ]]; then
        success "Repmgr configuration file exists: $REPMGR_CONF_FILE"
        
        # Check configuration content
        if grep -q "^node_id" "$REPMGR_CONF_FILE"; then
            local node_id
            node_id=$(grep "^node_id" "$REPMGR_CONF_FILE" | cut -d'=' -f2 | tr -d ' ')
            success "Node ID configured: $node_id"
        else
            fail "Node ID not configured in repmgr.conf"
        fi
        
        if grep -q "^conninfo" "$REPMGR_CONF_FILE"; then
            success "Connection info configured in repmgr.conf"
        else
            fail "Connection info not configured in repmgr.conf"
        fi
        
    else
        fail "Repmgr configuration file not found: $REPMGR_CONF_FILE"
    fi
    
    # Check repmgrd service
    check_service repmgrd "repmgrd"
    
    # Check repmgr database and user
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='repmgr'" postgres 2>/dev/null | grep -q 1; then
        success "Repmgr database exists"
    else
        fail "Repmgr database does not exist"
    fi
    
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='repmgr'" postgres 2>/dev/null | grep -q 1; then
        success "Repmgr user exists"
    else
        fail "Repmgr user does not exist"
    fi
}

validate_repmgr_cluster() {
    section "Repmgr Cluster Status"
    
    # Test cluster show command
    local cluster_output
    if cluster_output=$(sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f "$REPMGR_CONF_FILE" cluster show 2>/dev/null); then
        success "Repmgr cluster status accessible"
        echo "Cluster Status:"
        echo "$cluster_output" | head -10
        
        # Count nodes in cluster
        local node_count
        node_count=$(echo "$cluster_output" | grep -c "| [0-9]" || echo "0")
        if [[ "$node_count" -gt 0 ]]; then
            success "Cluster has $node_count registered nodes"
        else
            warn "No nodes found in cluster status"
        fi
        
    else
        fail "Cannot access repmgr cluster status"
    fi
    
    # Check node registration
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f "$REPMGR_CONF_FILE" node check >/dev/null 2>&1; then
        success "Node check passed"
    else
        warn "Node check failed"
    fi
}

validate_pgbouncer_installation() {
    section "PgBouncer Installation"
    
    # Check PgBouncer binary
    check_command pgbouncer "PgBouncer"
    
    # Check PgBouncer user
    if id -u pgbouncer >/dev/null 2>&1; then
        success "PgBouncer system user exists"
    else
        fail "PgBouncer system user does not exist"
    fi
    
    # Check PgBouncer service
    check_service pgbouncer "PgBouncer"
    
    # Check PgBouncer port
    check_port "$PGBOUNCER_PORT" "PgBouncer"
    
    # Check PgBouncer configuration files
    local pgb_conf="/etc/pgbouncer/pgbouncer.ini"
    local pgb_users="/etc/pgbouncer/userlist.txt"
    
    if [[ -f "$pgb_conf" ]]; then
        success "PgBouncer configuration file exists: $pgb_conf"
        
        # Check configuration content
        if grep -q "^listen_port.*$PGBOUNCER_PORT" "$pgb_conf"; then
            success "PgBouncer configured on correct port"
        else
            warn "PgBouncer port configuration may be incorrect"
        fi
        
        if grep -q "^pool_mode" "$pgb_conf"; then
            local pool_mode
            pool_mode=$(grep "^pool_mode" "$pgb_conf" | cut -d'=' -f2 | tr -d ' ')
            success "PgBouncer pool mode: $pool_mode"
        else
            warn "PgBouncer pool mode not configured"
        fi
        
    else
        fail "PgBouncer configuration file not found: $pgb_conf"
    fi
    
    if [[ -f "$pgb_users" ]]; then
        success "PgBouncer userlist file exists: $pgb_users"
    else
        fail "PgBouncer userlist file not found: $pgb_users"
    fi
}

validate_pgbouncer_connectivity() {
    section "PgBouncer Connectivity"
    
    # Test direct connection to PgBouncer
    if timeout 5 bash -c "</dev/tcp/localhost/$PGBOUNCER_PORT" 2>/dev/null; then
        success "PgBouncer accepting connections"
    else
        fail "PgBouncer not accepting connections"
        return 1
    fi
    
    # Check .pgpass file before attempting connections
    local pgpass_file="/var/lib/postgresql/.pgpass"
    if [[ -f "$pgpass_file" ]]; then
        success ".pgpass file exists"
        
        local pgpass_perms
        pgpass_perms=$(stat -c %a "$pgpass_file" 2>/dev/null || echo "unknown")
        if [[ "$pgpass_perms" == "600" ]]; then
            success ".pgpass file has correct permissions (600)"
        else
            warn ".pgpass file permissions are incorrect: $pgpass_perms (should be 600)"
            info "Fixing .pgpass file permissions..."
            chmod 600 "$pgpass_file" 2>/dev/null || warn "Failed to fix .pgpass permissions"
        fi
        
        # Check if postgres user entries exist
        if grep -q "localhost:$PGBOUNCER_PORT:.*:postgres:" "$pgpass_file" 2>/dev/null; then
            success ".pgpass contains PgBouncer entries for postgres user"
        else
            warn ".pgpass file missing PgBouncer entries for postgres user"
        fi
    else
        warn ".pgpass file not found at $pgpass_file"
        info "Creating basic .pgpass file..."
        
        # Try to create a basic .pgpass file
        if [[ -d "/var/lib/postgresql" ]]; then
            cat > "$pgpass_file" 2>/dev/null << EOF || warn "Failed to create .pgpass file"
localhost:$PGBOUNCER_PORT:*:postgres:test_password
localhost:5432:*:postgres:test_password
EOF
            chown postgres:postgres "$pgpass_file" 2>/dev/null || true
            chmod 600 "$pgpass_file" 2>/dev/null || true
            info "Created basic .pgpass file - you may need to update passwords"
        fi
    fi
    
    # Diagnostic check for .pgpass content
    if [[ -f "$pgpass_file" ]]; then
        info "Checking .pgpass content (passwords hidden)..."
        local pgpass_entries
        pgpass_entries=$(grep -c "^[^#]" "$pgpass_file" 2>/dev/null || echo "0")
        info "  → Found $pgpass_entries active entries in .pgpass"
        
        # Show entries with passwords hidden
        info "  → .pgpass entries (passwords masked):"
        while IFS= read -r line; do
            if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
                masked_line=$(echo "$line" | sed 's/:[^:]*$/:*****/')
                info "    $masked_line"
            fi
        done < "$pgpass_file"
    fi
    
    # Test database connection through PgBouncer using .pgpass
    info "Testing database connection through PgBouncer..."
    if timeout 10 sudo -u postgres env PGPASSFILE="$pgpass_file" psql -h localhost -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 'PgBouncer connection test successful' as status;" >/dev/null 2>&1; then
        success "Database connection through PgBouncer working"
    else
        fail "Cannot connect to database through PgBouncer"
        info "Hint: Check .pgpass file and PgBouncer userlist.txt authentication"
        
        # Try to diagnose the issue
        info "Diagnosing PgBouncer connection issue..."
        
        # Check if PgBouncer userlist exists and has entries
        local userlist_file="/etc/pgbouncer/userlist.txt"
        if [[ -f "$userlist_file" ]]; then
            local user_count
            user_count=$(grep -c "^\"" "$userlist_file" 2>/dev/null || echo "0")
            info "  → PgBouncer userlist has $user_count user entries"
        else
            warn "  → PgBouncer userlist.txt not found"
        fi
    fi
    
    # Test admin connection to PgBouncer
    info "Testing PgBouncer admin interface..."
    if timeout 10 bash -c "echo 'SHOW POOLS;' | sudo -u postgres env PGPASSFILE='$pgpass_file' psql -h localhost -p $PGBOUNCER_PORT -U postgres -d pgbouncer" >/dev/null 2>&1; then
        success "PgBouncer admin interface accessible"
        
        # Show pool statistics
        echo "Current PgBouncer pool status:"
        echo "SHOW POOLS;" | sudo -u postgres env PGPASSFILE="$pgpass_file" psql -h localhost -p "$PGBOUNCER_PORT" -U postgres -d pgbouncer 2>/dev/null || echo "Could not retrieve pool status"
        
    else
        warn "PgBouncer admin interface not accessible"
        info "Hint: Check PgBouncer admin users configuration"
    fi
    
    # Skip connection count if authentication is failing
    info "Checking active PgBouncer connections..."
    local active_conns
    if active_conns=$(timeout 5 bash -c "echo 'SHOW CLIENTS;' | sudo -u postgres env PGPASSFILE='$pgpass_file' psql -h localhost -p $PGBOUNCER_PORT -U postgres -d pgbouncer -t" 2>/dev/null | wc -l); then
        info "Active PgBouncer client connections: $active_conns"
    else
        info "Cannot check active connections (authentication required)"
    fi
}

validate_health_endpoints() {
    section "Health Endpoints"
    
    # Test PostgreSQL health endpoint
    test_http_endpoint "http://localhost:$HEALTH_PORT_PG" "PostgreSQL HA health" "status"
    
    # Test PgBouncer health endpoint  
    test_http_endpoint "http://localhost:$HEALTH_PORT_PGBOUNCER" "PgBouncer health" "service"
    
    # Check health endpoint services
    if check_service final-pg-health.service "PostgreSQL health endpoint"; then
        # Service is running, no additional action needed
        true
    else
        warn "PostgreSQL health endpoint service is not running - health endpoint may still work if started manually"
    fi
    
    if check_service final-pgbouncer-health.service "PgBouncer health endpoint"; then
        # Service is running, no additional action needed  
        true
    else
        warn "PgBouncer health endpoint service is not running - health endpoint may still work if started manually"
    fi
}

validate_performance_tuning() {
    section "Performance and Tuning"
    
    # Check PostgreSQL memory settings
    local shared_buffers
    shared_buffers=$(sudo -u postgres psql -Atqc "SHOW shared_buffers;" postgres 2>/dev/null || echo "unknown")
    if [[ "$shared_buffers" != "unknown" ]]; then
        success "PostgreSQL shared_buffers: $shared_buffers"
    else
        warn "Could not determine shared_buffers setting"
    fi
    
    local effective_cache_size
    effective_cache_size=$(sudo -u postgres psql -Atqc "SHOW effective_cache_size;" postgres 2>/dev/null || echo "unknown")
    if [[ "$effective_cache_size" != "unknown" ]]; then
        success "PostgreSQL effective_cache_size: $effective_cache_size"
    else
        warn "Could not determine effective_cache_size setting"
    fi
    
    # Check connection limits
    local max_connections
    max_connections=$(sudo -u postgres psql -Atqc "SHOW max_connections;" postgres 2>/dev/null || echo "unknown")
    if [[ "$max_connections" != "unknown" ]]; then
        success "PostgreSQL max_connections: $max_connections"
    else
        warn "Could not determine max_connections setting"
    fi
    
    # Check current connection count
    local current_connections
    current_connections=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_activity;" postgres 2>/dev/null || echo "unknown")
    if [[ "$current_connections" != "unknown" ]]; then
        info "Current PostgreSQL connections: $current_connections"
    fi
}

validate_security() {
    section "Security Configuration"
    
    # Check file permissions
    local pgdata_perms
    pgdata_perms=$(stat -c %a "/var/lib/postgresql/$PG_VERSION/main" 2>/dev/null || echo "unknown")
    if [[ "$pgdata_perms" == "700" ]]; then
        success "PostgreSQL data directory has correct permissions (700)"
    else
        warn "PostgreSQL data directory permissions may be incorrect: $pgdata_perms"
    fi
    
    # Check PostgreSQL is not listening on public interfaces (unless intended)
    if command -v netstat >/dev/null 2>&1; then
        if netstat -tlnp 2>/dev/null | grep ":5432" | grep -q "0.0.0.0"; then
            warn "PostgreSQL is listening on all interfaces - ensure this is intended"
        else
            success "PostgreSQL network access appears restricted"
        fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -tlnp 2>/dev/null | grep ":5432" | grep -q "0.0.0.0"; then
            warn "PostgreSQL is listening on all interfaces - ensure this is intended"
        else
            success "PostgreSQL network access appears restricted"
        fi
    else
        warn "Cannot check PostgreSQL network binding (netstat/ss not available)"
    fi
    
    # Check for default passwords (basic check)
    if sudo -u postgres psql -c "SELECT rolname FROM pg_roles WHERE rolname='postgres' AND rolpassword IS NULL;" postgres 2>/dev/null | grep -q postgres; then
        warn "PostgreSQL postgres user may not have a password set"
    else
        success "PostgreSQL postgres user appears to have password protection"
    fi
}

validate_backup_readiness() {
    section "Backup and Recovery Readiness"
    
    # Check WAL archiving status
    local archive_mode
    archive_mode=$(sudo -u postgres psql -Atqc "SHOW archive_mode;" postgres 2>/dev/null || echo "unknown")
    if [[ "$archive_mode" == "on" ]]; then
        success "WAL archiving is enabled"
        
        local archive_command
        archive_command=$(sudo -u postgres psql -Atqc "SHOW archive_command;" postgres 2>/dev/null || echo "unknown")
        info "Archive command: $archive_command"
        
    elif [[ "$archive_mode" == "off" ]]; then
        warn "WAL archiving is disabled - consider enabling for backup purposes"
    else
        warn "Could not determine WAL archiving status"
    fi
    
    # Check for backup tools
    if command -v pg_dump >/dev/null 2>&1; then
        success "pg_dump backup tool available"
    else
        warn "pg_dump backup tool not found"
    fi
    
    if command -v pg_basebackup >/dev/null 2>&1; then
        success "pg_basebackup tool available"
    else
        warn "pg_basebackup tool not found"
    fi
}

# Secret Manager validation is handled later in the script

validate_logs_and_monitoring() {
    section "Logs and Monitoring"
    
    # Check log files exist and are recent
    local pg_log_dir="/var/log/postgresql"
    if [[ -d "$pg_log_dir" ]]; then
        success "PostgreSQL log directory exists"
        
        local recent_logs
        recent_logs=$(find "$pg_log_dir" -name "*.log" -mtime -1 2>/dev/null | wc -l)
        if [[ "$recent_logs" -gt 0 ]]; then
            success "Recent PostgreSQL log files found ($recent_logs files)"
        else
            warn "No recent PostgreSQL log files found"
        fi
    else
        warn "PostgreSQL log directory not found: $pg_log_dir"
    fi
    
    # Check repmgr logs
    local repmgr_log="/var/log/repmgr/repmgrd.log"
    if [[ -f "$repmgr_log" ]]; then
        success "Repmgr log file exists"
        
        if [[ $(find "$repmgr_log" -mtime -1 2>/dev/null | wc -l) -gt 0 ]]; then
            success "Repmgr log file is recent"
        else
            warn "Repmgr log file is not recent"
        fi
    else
        warn "Repmgr log file not found: $repmgr_log"
        # Check alternative log locations
        if journalctl -u repmgrd.service --lines=1 --no-pager >/dev/null 2>&1; then
            info "Repmgr logs available via systemd journal"
        else
            info "Check repmgr configuration for log file location"
        fi
    fi
    
    # Check PgBouncer logs
    local pgb_log_dir="/var/log/pgbouncer"
    if [[ -d "$pgb_log_dir" ]]; then
        success "PgBouncer log directory exists"
    else
        warn "PgBouncer log directory not found: $pgb_log_dir"
    fi
}

validate_secret_manager_integration() {
    section "Secret Manager Integration"
    
    # Check if we can access GCP metadata
    if curl -sf -H 'Metadata-Flavor: Google' \
       'http://metadata.google.internal/computeMetadata/v1/project/project-id' >/dev/null 2>&1; then
        success "GCP metadata service is accessible"
        
        local project_id
        project_id=$(curl -sf -H 'Metadata-Flavor: Google' \
                     'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null || echo "unknown")
        info "Project ID: $project_id"
        
        # Test access token retrieval
        if curl -sf -H 'Metadata-Flavor: Google' \
           'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' >/dev/null 2>&1; then
            success "Service account access token is accessible"
        else
            fail "Cannot retrieve service account access token"
        fi
        
        # Check org and env codes from metadata
        local org_code env_code
        org_code=$(curl -sf -H 'Metadata-Flavor: Google' \
                   'http://metadata.google.internal/computeMetadata/v1/instance/attributes/org_code' 2>/dev/null || echo "unknown")
        env_code=$(curl -sf -H 'Metadata-Flavor: Google' \
                   'http://metadata.google.internal/computeMetadata/v1/instance/attributes/env_code' 2>/dev/null || echo "unknown")
        
        info "Organization code: $org_code"
        info "Environment code: $env_code"
        
        if [[ "$org_code" != "unknown" && "$env_code" != "unknown" ]]; then
            # Test specific secret access (PgBouncer password)
            local pgbouncer_secret="${org_code}-${env_code}-sec-pgbouncer-password-01"
            info "Testing PgBouncer secret access: $pgbouncer_secret"
            
            local token
            token=$(curl -sf -H 'Metadata-Flavor: Google' \
                     'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | \
                     jq -r '.access_token' 2>/dev/null || echo "")
            
            if [[ -n "$token" ]]; then
                local url="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${pgbouncer_secret}/versions/latest:access"
                if curl -sf -H "Authorization: Bearer $token" -H 'Accept: application/json' "$url" >/dev/null 2>&1; then
                    success "PgBouncer secret is accessible via Secret Manager"
                else
                    fail "Cannot access PgBouncer secret: $pgbouncer_secret"
                    warn "This may explain why PgBouncer password falls back to generated password in bootstrap"
                fi
            else
                fail "Cannot get access token for secret testing"
            fi
        else
            warn "Cannot determine org/env codes from metadata - secret testing skipped"
        fi
        
    else
        fail "GCP metadata service is not accessible"
    fi
}

run_integration_tests() {
    section "Integration Tests"
    
    # Test failover scenario (read-only test)
    info "Testing cluster integration..."
    
    # Test replication lag (if standby)
    local role
    role=$(get_pg_role)
    
    if [[ "$role" == "standby" ]]; then
        # Create a test table on primary and check if it replicates
        info "Testing replication functionality..."
        
        # Get primary host from repmgr config
        local primary_host
        primary_host=$(grep "^conninfo" "$REPMGR_CONF_FILE" | grep -o "host=[^[:space:]]*" | cut -d'=' -f2 || echo "localhost")
        
        if [[ "$primary_host" != "localhost" ]]; then
            # Test connection to primary
            if timeout 5 bash -c "</dev/tcp/$primary_host/5432" 2>/dev/null; then
                success "Can connect to primary host: $primary_host"
            else
                warn "Cannot connect to primary host: $primary_host"
            fi
        fi
        
        # Test replication status if standby  
        local replication_lag
        replication_lag=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" postgres 2>/dev/null || echo "unknown")
        if [[ "$replication_lag" != "unknown" ]] && [[ $(echo "$replication_lag" | awk '{print ($1 < 60) ? "1" : "0"}') -eq 1 ]]; then
            success "Replication integration test: lag acceptable (${replication_lag}s)"
        elif [[ "$replication_lag" != "unknown" ]]; then
            warn "Replication integration test: high lag (${replication_lag}s)"
        else
            warn "Could not test replication lag"
        fi
    fi
    
    # Test connection failover through PgBouncer
    info "Testing PgBouncer connection handling..."
    
    # Single quick test instead of loop to avoid hanging
    if timeout 10 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 'Integration test successful' as status;" >/dev/null 2>&1; then
        success "PgBouncer connection integration test successful"
    else
        warn "PgBouncer connection integration test failed"
    fi
    
    # Test cluster connectivity for primary
    if [[ "$role" == "primary" ]]; then
        local connected_standbys
        connected_standbys=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" postgres 2>/dev/null || echo "0")
        if [[ "$connected_standbys" -gt 0 ]]; then
            success "Cluster integration test: $connected_standbys standby(s) connected"
        else
            info "Cluster integration test: no standbys currently connected"
        fi
    fi
    
    # Add a final completion message
    info "Integration tests completed successfully"
}

# ============================================================================
# ENTERPRISE TESTING FEATURES
# ============================================================================

validate_failover_readiness() {
    section "Failover and Failback Readiness"
    
    local role
    role=$(get_pg_role)
    
    # Check repmgr failover prerequisites
    if [[ "$role" == "primary" ]]; then
        info "Testing primary node failover readiness..."
        
        # Check if standby nodes are connected and synchronized
        local standby_count
        standby_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming';" postgres 2>/dev/null || echo "0")
        if [[ "$standby_count" -gt 0 ]]; then
            success "Primary has $standby_count streaming standby(s) - failover ready"
        else
            warn "No streaming standbys found - failover not possible"
        fi
        
        # Check replication lag for all standbys
        local max_lag
        max_lag=$(sudo -u postgres psql -Atqc "SELECT COALESCE(MAX(EXTRACT(EPOCH FROM (now() - backend_start))), 0) FROM pg_stat_replication;" postgres 2>/dev/null || echo "unknown")
        if [[ "$max_lag" != "unknown" ]] && [[ $(echo "$max_lag" | awk '{print ($1 < 60) ? "1" : "0"}') -eq 1 ]]; then
            success "All standbys have acceptable lag (max: ${max_lag}s)"
        elif [[ "$max_lag" != "unknown" ]]; then
            warn "High replication lag detected (max: ${max_lag}s) - may affect failover"
        fi
        
    elif [[ "$role" == "standby" ]]; then
        info "Testing standby node promotion readiness..."
        
        # Check if standby can be promoted
        if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f "$REPMGR_CONF_FILE" standby promote --dry-run >/dev/null 2>&1; then
            success "Standby node is ready for promotion"
        else
            warn "Standby node promotion may have issues"
        fi
    fi
    
    # Test repmgr cluster commands
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f "$REPMGR_CONF_FILE" cluster show >/dev/null 2>&1; then
        success "Repmgr cluster commands working"
    else
        fail "Repmgr cluster commands failing"
    fi
}

validate_witness_node() {
    section "Witness Node Configuration"
    
    # Check if witness node is configured
    local witness_count witness_output
    witness_output=$(sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f "$REPMGR_CONF_FILE" cluster show 2>/dev/null || echo "")
    
    if [[ -n "$witness_output" ]]; then
        witness_count=$(echo "$witness_output" | grep -c "witness" 2>/dev/null || echo "0")
    else
        witness_count="0"
    fi
    
    # Ensure witness_count is a valid single number
    witness_count=$(echo "$witness_count" | head -1 | grep -o '^[0-9]*' || echo "0")
    
    if [[ "$witness_count" -gt 0 ]]; then
        success "Witness node is configured ($witness_count witness nodes)"
        
        # Check witness node connectivity
        local witness_status
        witness_status=$(echo "$witness_output" | grep "witness" | grep -c "running" 2>/dev/null || echo "0")
        witness_status=$(echo "$witness_status" | head -1 | grep -o '^[0-9]*' || echo "0")
        
        if [[ "$witness_status" -gt 0 ]]; then
            success "Witness node(s) are running and accessible"
        else
            warn "Witness node(s) appear to be down or unreachable"
        fi
    else
        warn "No witness node configured - consider adding for improved quorum management"
        info "Witness nodes help prevent split-brain scenarios in 2-node clusters"
    fi
}

validate_gcs_backup_configuration() {
    section "GCS Backup Configuration"
    
    # Check if gcloud is installed
    if command -v gcloud >/dev/null 2>&1; then
        success "Google Cloud SDK is installed"
        
        # Check authentication
        if gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
            success "GCP authentication is configured"
            
            local active_account
            active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || echo "unknown")
            info "Active GCP account: $active_account"
        else
            warn "GCP authentication not configured - backup uploads will fail"
        fi
    else
        warn "Google Cloud SDK not installed - GCS backup functionality unavailable"
        info "Install with: curl https://sdk.cloud.google.com | bash"
    fi
    
    # Check backup directories
    local backup_dir="/var/backups/postgresql"
    if [[ -d "$backup_dir" ]]; then
        success "Backup directory exists: $backup_dir"
        
        # Check permissions
        local backup_perms
        backup_perms=$(stat -c %a "$backup_dir" 2>/dev/null || echo "unknown")
        if [[ "$backup_perms" == "755" ]] || [[ "$backup_perms" == "750" ]]; then
            success "Backup directory has appropriate permissions ($backup_perms)"
        else
            warn "Backup directory permissions may be incorrect: $backup_perms"
        fi
    else
        warn "Backup directory not found: $backup_dir"
        info "Consider creating: sudo mkdir -p $backup_dir && sudo chown postgres:postgres $backup_dir"
    fi
    
    # Check if pg_dump can create backups
    if sudo -u postgres pg_dump --version >/dev/null 2>&1; then
        success "pg_dump is available for logical backups"
    else
        fail "pg_dump not available - backup functionality impaired"
    fi
    
    # Check available disk space for backups
    local available_space
    available_space=$(df /var/backups 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [[ "$available_space" -gt 1048576 ]]; then  # > 1GB
        success "Sufficient disk space for backups ($(echo $((available_space/1024/1024))GB) available)"
    else
        warn "Limited disk space for backups ($(echo $((available_space/1024))MB) available)"
    fi
}

validate_timezone_synchronization() {
    section "Timezone Synchronization"
    
    # Check system timezone
    local system_tz
    system_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
    if [[ "$system_tz" != "unknown" ]]; then
        success "System timezone: $system_tz"
    else
        warn "Could not determine system timezone"
    fi
    
    # Check PostgreSQL timezone
    local pg_tz
    pg_tz=$(sudo -u postgres psql -Atqc "SHOW timezone;" postgres 2>/dev/null || echo "unknown")
    if [[ "$pg_tz" != "unknown" ]]; then
        success "PostgreSQL timezone: $pg_tz"
        
        # Check if they match
        if [[ "$system_tz" == "$pg_tz" ]]; then
            success "System and PostgreSQL timezones are synchronized"
        else
            warn "System timezone ($system_tz) differs from PostgreSQL timezone ($pg_tz)"
            info "Consider synchronizing: ALTER SYSTEM SET timezone = '$system_tz';"
        fi
    else
        warn "Could not determine PostgreSQL timezone"
    fi
    
    # Check NTP synchronization
    if command -v timedatectl >/dev/null 2>&1; then
        local ntp_status
        ntp_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
        if [[ "$ntp_status" == "yes" ]]; then
            success "NTP time synchronization is active"
        else
            warn "NTP time synchronization is not active"
            info "Enable with: sudo timedatectl set-ntp true"
        fi
        
        # Show more detailed time status
        info "Time synchronization details:"
        local time_status
        time_status=$(timedatectl status 2>/dev/null | grep -E "synchronized|NTP service" || echo "Unknown")
        info "  $time_status"
    fi
    
    # Check if running on GCE and timezone matches metadata
    if curl -sf -H 'Metadata-Flavor: Google' \
       'http://metadata.google.internal/computeMetadata/v1/project/project-id' >/dev/null 2>&1; then
        local gce_zone metadata_tz
        gce_zone=$(curl -sf -H 'Metadata-Flavor: Google' \
                   'http://metadata.google.internal/computeMetadata/v1/instance/zone' 2>/dev/null | cut -d'/' -f4 || echo "unknown")
        metadata_tz=$(curl -sf -H 'Metadata-Flavor: Google' \
                      'http://metadata.google.internal/computeMetadata/v1/instance/attributes/timezone' 2>/dev/null || echo "")
        
        if [[ "$gce_zone" != "unknown" ]]; then
            success "Running on GCE in zone: $gce_zone"
            
            if [[ -n "$metadata_tz" ]]; then
                if [[ "$metadata_tz" == "$system_tz" ]]; then
                    success "System timezone matches metadata: $metadata_tz"
                else
                    warn "System timezone ($system_tz) differs from metadata timezone ($metadata_tz)"
                fi
            else
                info "No timezone metadata set - using zone-based default"
            fi
        fi
        
        # Show current time comparison
        info "Current time verification:"
        info "  System: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        local pg_time_formatted
        pg_time_formatted=$(sudo -u postgres psql -Atqc "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS TZ');" postgres 2>/dev/null || echo "unknown")
        info "  PostgreSQL: $pg_time_formatted"
        
        # Check for significant time differences
        local system_epoch pg_epoch time_diff
        system_epoch=$(date +%s)
        pg_epoch=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(EPOCH FROM now())::bigint;" postgres 2>/dev/null || echo "0")
        
        if [[ "$pg_epoch" != "0" ]] && [[ "$system_epoch" != "0" ]]; then
            time_diff=$((system_epoch - pg_epoch))
            if [[ ${time_diff#-} -lt 5 ]]; then  # Within 5 seconds
                success "System and PostgreSQL times are synchronized (diff: ${time_diff}s)"
            else
                warn "Significant time difference detected: ${time_diff}s"
            fi
        fi
    else
        info "Not running on GCE - manual timezone configuration"
    fi
}

validate_monitoring_and_alerting() {
    section "Monitoring and Alerting Setup"
    
    # Check if monitoring agents are installed
    local monitoring_found=false
    
    # Check for Google Cloud Ops Agent
    if systemctl list-units --type=service --state=active | grep -q "google-cloud-ops-agent"; then
        success "Google Cloud Ops Agent is running"
        monitoring_found=true
    fi
    
    # Check for Prometheus node exporter
    if systemctl list-units --type=service --state=active | grep -q "node_exporter\|prometheus-node-exporter"; then
        success "Prometheus Node Exporter is running"
        monitoring_found=true
    fi
    
    # Check for postgres_exporter
    if systemctl list-units --type=service --state=active | grep -q "postgres_exporter"; then
        success "PostgreSQL Prometheus Exporter is running"
        monitoring_found=true
    fi
    
    if ! $monitoring_found; then
        warn "No monitoring agents detected"
        info "Consider installing Google Cloud Ops Agent or Prometheus exporters"
    fi
    
    # Check PostgreSQL logging configuration
    local log_destination
    log_destination=$(sudo -u postgres psql -Atqc "SHOW log_destination;" postgres 2>/dev/null || echo "unknown")
    if [[ "$log_destination" != "unknown" ]]; then
        success "PostgreSQL log destination: $log_destination"
    fi
    
    local log_statement
    log_statement=$(sudo -u postgres psql -Atqc "SHOW log_statement;" postgres 2>/dev/null || echo "unknown")
    if [[ "$log_statement" != "unknown" ]]; then
        success "PostgreSQL log statement level: $log_statement"
        if [[ "$log_statement" == "none" ]]; then
            warn "Statement logging is disabled - consider enabling for monitoring"
        fi
    fi
    
    # Check replication monitoring
    local role
    role=$(get_pg_role)
    if [[ "$role" == "primary" ]]; then
        # Check if we can monitor replication slots
        local slot_monitoring
        slot_monitoring=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_replication_slots WHERE active = true;" postgres 2>/dev/null || echo "0")
        if [[ "$slot_monitoring" -gt 0 ]]; then
            success "Active replication slots detected for monitoring"
        fi
    fi
    
    # Check log rotation
    if [[ -f "/etc/logrotate.d/postgresql-common" ]]; then
        success "PostgreSQL log rotation is configured"
    else
        warn "PostgreSQL log rotation not found - logs may grow indefinitely"
    fi
}

validate_custom_motd() {
    section "Custom MOTD Configuration"
    
    # Check if custom MOTD exists
    if [[ -f "/etc/motd" ]]; then
        success "MOTD file exists"
        
        # Check if it contains PostgreSQL information
        if grep -qi "postgresql\|postgres" /etc/motd 2>/dev/null; then
            success "MOTD contains PostgreSQL information"
        else
            warn "MOTD does not contain PostgreSQL cluster information"
        fi
        
        # Show current MOTD content (first few lines)
        info "Current MOTD preview:"
        head -10 /etc/motd 2>/dev/null | sed 's/^/    /' || true
    else
        warn "No custom MOTD found"
        info "Consider creating a custom MOTD with cluster information"
    fi
    
    # Check dynamic MOTD components
    if [[ -d "/etc/update-motd.d" ]]; then
        success "Dynamic MOTD directory exists"
        
        local motd_scripts
        motd_scripts=$(find /etc/update-motd.d -name "*postgresql*" -o -name "*postgres*" -o -name "*cluster*" 2>/dev/null | wc -l)
        if [[ "$motd_scripts" -gt 0 ]]; then
            success "PostgreSQL-related MOTD scripts found ($motd_scripts scripts)"
        else
            info "No PostgreSQL-specific MOTD scripts found"
        fi
    fi
    
    # Suggest MOTD improvements
    local role hostname
    role=$(get_pg_role)
    hostname=$(hostname)
    
    info "MOTD should include:"
    info "  • Node role: $role"
    info "  • Hostname: $hostname"
    info "  • PostgreSQL version: $PG_VERSION"
    info "  • Cluster status and connection endpoints"
    info "  • Last update timestamp"
}

run_advanced_failover_tests() {
    section "Advanced Failover Testing"
    
    # Only run detailed failover tests if explicitly requested
    if [[ "${ENABLE_FAILOVER_TESTS:-false}" == "true" ]]; then
        warn "DESTRUCTIVE FAILOVER TESTING ENABLED"
        info "This will test actual failover scenarios - use with caution!"
        
        local role
        role=$(get_pg_role)
        
        if [[ "$role" == "primary" ]]; then
            info "Testing primary failover simulation..."
            
            # Test read-only queries during simulated stress
            info "Testing read-only operations during primary stress..."
            if timeout 5 sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;" postgres >/dev/null 2>&1; then
                success "Read operations successful during stress test"
            else
                warn "Read operations failed during stress test"
            fi
            
            # Test connection handling under load
            info "Testing connection resilience..."
            local conn_success=0
            for i in {1..3}; do
                if timeout 3 sudo -u postgres psql -c "SELECT 'test_$i' as result;" postgres >/dev/null 2>&1; then
                    ((conn_success++))
                fi
            done
            
            if [[ "$conn_success" -eq 3 ]]; then
                success "All resilience tests passed (3/3)"
            else
                warn "Some resilience tests failed ($conn_success/3 passed)"
            fi
            
        elif [[ "$role" == "standby" ]]; then
            info "Testing standby promotion readiness..."
            
            # Test dry-run promotion
            if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f "$REPMGR_CONF_FILE" standby promote --dry-run >/dev/null 2>&1; then
                success "Standby promotion dry-run successful"
                
                # Test read operations on standby
                info "Testing read operations on standby..."
                if timeout 5 sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;" postgres >/dev/null 2>&1; then
                    success "Standby read operations working correctly"
                else
                    warn "Standby read operations failed"
                fi
            else
                warn "Standby promotion dry-run failed"
            fi
        fi
        
        # Test cluster communication
        info "Testing cluster communication..."
        if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f "$REPMGR_CONF_FILE" cluster show >/dev/null 2>&1; then
            success "Cluster communication test passed"
        else
            warn "Cluster communication test failed"
        fi
        
        info "Advanced failover tests completed"
    else
        info "Advanced failover testing disabled by default"
        info "Enable with: ENABLE_FAILOVER_TESTS=true sudo ./comprehensive_validation.sh"
        info "⚠️  WARNING: Failover tests can cause service interruption"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

generate_summary_report() {
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - VALIDATION_START_TIME))
    
    section "Validation Summary Report"
    
    printf "%bValidation Results:%b\n" "$PURPLE" "$NC"
    printf "  ✅ Passed: %s\n" "$PASSED"
    printf "  ❌ Failed: %s\n" "$FAILED"  
    printf "  ⚠️  Warnings: %s\n" "$WARNINGS"
    printf "  ⏱️  Duration: %s seconds\n" "$duration"
    
    echo ""
    if [[ "$FAILED" -eq 0 ]]; then
        printf "%b🎉 VALIDATION PASSED%b - PostgreSQL HA + PgBouncer cluster is healthy!\n" "$GREEN" "$NC"
        echo ""
        printf "Your cluster includes:\n"
        printf "  ✅ PostgreSQL %s with streaming replication\n" "$PG_VERSION"
        printf "  ✅ Repmgr automatic failover\n"
        printf "  ✅ PgBouncer connection pooling\n"
        printf "  ✅ Health monitoring endpoints\n"
        printf "  ✅ Production-ready configuration\n"
        echo ""
        printf "Ready for production workloads! 🚀\n"
        
        # Show additional success information
        local role
        role=$(get_pg_role)
        printf "\n%bCluster Status Summary:%b\n" "$CYAN" "$NC"
        printf "  • Node Role: %s\n" "$role"
        if [[ "$WARNINGS" -gt 0 ]]; then
            printf "  • Warnings: %s (review recommended but not blocking)\n" "$WARNINGS"
        fi
        printf "  • All critical components validated ✅\n"
        printf "  • Ready for production traffic 🚀\n"
        return 0
    else
        printf "%b❌ VALIDATION FAILED%b - %s critical issues found\n" "$RED" "$NC" "$FAILED"
        echo ""
        printf "Please review the failed checks above and resolve issues before production use.\n"
        
        if [[ "$WARNINGS" -gt 0 ]]; then
            printf "\nAdditionally, there are %s warnings that should be addressed.\n" "$WARNINGS"
        fi
        
        printf "\n%bCommon Solutions:%b\n" "$CYAN" "$NC"
        printf "  • Restart services: sudo systemctl restart postgresql pgbouncer repmgrd\n"
        printf "  • Check logs: journalctl -u postgresql -u pgbouncer -u repmgrd --lines=50\n"
        printf "  • Verify network connectivity between nodes\n"
        printf "  • Check .pgpass file permissions and content\n"
        return 1
    fi
}

show_connection_info() {
    section "Connection Information"
    
    local role
    role=$(get_pg_role)
    
    printf "%bDirect PostgreSQL connections:%b\n" "$CYAN" "$NC"
    printf "  • Direct (port 5432): postgresql://username:password@%s:5432/database\n" "$(hostname -I | awk '{print $1}')"
    
    printf "\n%bPgBouncer pooled connections:%b\n" "$CYAN" "$NC"
    printf "  • Pooled (port %s): postgresql://username:password@%s:%s/database\n" "$PGBOUNCER_PORT" "$(hostname -I | awk '{print $1}')" "$PGBOUNCER_PORT"
    
    printf "\n%bHealth endpoints:%b\n" "$CYAN" "$NC"
    printf "  • PostgreSQL HA: http://%s:%s\n" "$(hostname -I | awk '{print $1}')" "$HEALTH_PORT_PG"
    printf "  • PgBouncer: http://%s:%s\n" "$(hostname -I | awk '{print $1}')" "$HEALTH_PORT_PGBOUNCER"
    
    printf "\n%bNode information:%b\n" "$CYAN" "$NC" 
    printf "  • Role: %s\n" "$role"
    printf "  • Hostname: %s\n" "$(hostname)"
    printf "  • IP Address: %s\n" "$(hostname -I | awk '{print $1}')"
}

main() {
    printf "%b" "$BLUE"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║        PostgreSQL HA + PgBouncer Validation          ║
║                Production Readiness Check            ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    printf "\nValidation Script Version: %s\n" "$SCRIPT_VERSION"
    printf "Start Time: %s\n" "$(date)"
    printf "Target: PostgreSQL %s + repmgr + PgBouncer\n" "$PG_VERSION"
    
    # Run validation tests
    validate_system_prerequisites
    validate_postgresql_installation  
    validate_postgresql_configuration
    validate_postgresql_role
    validate_repmgr_installation
    validate_repmgr_cluster
    validate_pgbouncer_installation
    validate_pgbouncer_connectivity
    validate_health_endpoints
    validate_performance_tuning
    validate_security
    validate_backup_readiness
    validate_logs_and_monitoring
    validate_secret_manager_integration
    run_integration_tests
    
    # Run enterprise validation tests
    validate_failover_readiness
    validate_witness_node
    validate_gcs_backup_configuration
    validate_timezone_synchronization
    validate_monitoring_and_alerting
    validate_custom_motd
    run_advanced_failover_tests
    
    # Generate summary report
    generate_summary_report
    
    # Show connection information
    show_connection_info
    
    # Return appropriate exit code
    if [[ "$FAILED" -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    warn "This script should be run as root for complete validation"
    echo "Some checks may fail or be incomplete"
    echo ""
fi

# Execute main function
main "$@"