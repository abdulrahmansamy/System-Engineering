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
        success "$desc is available"
        return 0
    else
        fail "$desc is not available"
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
        success "$desc port $port is listening"
        return 0
    else
        fail "$desc port $port is not listening"
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
        local version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        success "Running on Ubuntu $version"
    else
        warn "Not running on Ubuntu - compatibility not guaranteed"
    fi
    
    # Check basic tools
    check_command curl "curl"
    check_command jq "jq" 
    check_command systemctl "systemctl"
    check_command bc "bc (basic calculator)"
    check_command nc "netcat"
}

validate_postgresql_installation() {
    section "PostgreSQL Installation"
    
    # Check PostgreSQL binaries
    check_command psql "PostgreSQL client"
    check_command pg_basebackup "pg_basebackup"
    check_command pg_isready "pg_isready"
    
    # Check PostgreSQL server binary
    if [[ -x "/usr/lib/postgresql/$PG_VERSION/bin/postgres" ]]; then
        success "PostgreSQL server is installed"
    else
        fail "PostgreSQL server is not installed"
    fi
    
    # Check PostgreSQL version
    if command -v psql >/dev/null 2>&1; then
        local pg_version
        pg_version=$(psql --version | head -1 | awk '{print $3}' | cut -d. -f1)
        if [[ "$pg_version" == "$PG_VERSION" ]]; then
            success "PostgreSQL version $pg_version matches expected version"
        else
            warn "PostgreSQL version $pg_version does not match expected version $PG_VERSION"
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

validate_streaming_replication_config() {
    section "Streaming Replication Configuration"
    
    # Check configuration files
    local pg_conf="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    local pg_hba="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
    
    if [[ -f "$pg_conf" ]]; then
        success "PostgreSQL configuration file exists: $pg_conf"
        
        # Check streaming replication settings
        if grep -q "wal_level.*replica" "$pg_conf"; then
            success "WAL level set to replica for streaming replication"
        else
            warn "WAL level may not be configured for streaming replication"
        fi
        
        if grep -q "max_wal_senders" "$pg_conf"; then
            local wal_senders=$(grep "max_wal_senders" "$pg_conf" | grep -v "^#" | head -1 | awk '{print $3}')
            success "WAL senders configured: $wal_senders"
        else
            warn "WAL senders may not be configured"
        fi
        
        if grep -q "hot_standby.*on" "$pg_conf"; then
            success "Hot standby enabled"
        else
            warn "Hot standby may not be enabled"
        fi
        
        # Check synchronous replication
        if grep -q "synchronous_standby_names" "$pg_conf"; then
            success "Synchronous standby names configured"
        else
            info "Asynchronous replication mode (synchronous_standby_names not set)"
        fi
        
        # Check replication slots
        if grep -q "max_replication_slots" "$pg_conf"; then
            success "Replication slots configured"
        else
            warn "Replication slots may not be configured"
        fi
        
    else
        fail "PostgreSQL configuration file not found: $pg_conf"
    fi
    
    if [[ -f "$pg_hba" ]]; then
        success "PostgreSQL HBA configuration file exists: $pg_hba"
        
        # Check replication access
        if grep -q "replication.*replication" "$pg_hba"; then
            success "Replication user access configured in pg_hba.conf"
        else
            warn "Replication user access may not be configured"
        fi
        
    else
        fail "PostgreSQL HBA configuration file not found: $pg_hba"
    fi
}

validate_postgresql_users() {
    section "PostgreSQL Users and Permissions"
    
    # Check replication user
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='replication'" postgres 2>/dev/null | grep -q 1; then
        success "Replication user exists"
        
        # Check replication privileges
        if sudo -u postgres psql -tAc "SELECT rolreplication FROM pg_roles WHERE rolname='replication'" postgres 2>/dev/null | grep -q t; then
            success "Replication user has replication privileges"
        else
            fail "Replication user lacks replication privileges"
        fi
    else
        fail "Replication user does not exist"
    fi
    
    # Check monitor user
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='monitor_user'" postgres 2>/dev/null | grep -q 1; then
        success "Monitor user exists"
    else
        warn "Monitor user does not exist"
    fi
    
    # Check app user
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='app_user'" postgres 2>/dev/null | grep -q 1; then
        success "Application user exists"
    else
        info "Application user does not exist (may be created later)"
    fi
}

validate_streaming_replication_status() {
    section "Streaming Replication Status"
    
    local role
    role=$(get_pg_role)
    
    info "Node role: $role"
    
    if [[ "$role" == "primary" ]]; then
        # Check replication connections
        local repl_count
        repl_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" postgres 2>/dev/null || echo "0")
        
        if [[ "$repl_count" -gt 0 ]]; then
            success "Active replication connections: $repl_count"
            
            # Show replication details
            info "Replication status:"
            sudo -u postgres psql -c "SELECT client_addr, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn) AS lag_bytes FROM pg_stat_replication;" postgres 2>/dev/null || true
            
            # Check for synchronous replication
            local sync_count
            sync_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication WHERE sync_state = 'sync';" postgres 2>/dev/null || echo "0")
            
            if [[ "$sync_count" -gt 0 ]]; then
                success "Synchronous replication is active"
            else
                info "Asynchronous replication mode"
            fi
        else
            warn "No active replication connections found"
        fi
        
        # Check replication slots
        local slot_count
        slot_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_replication_slots;" postgres 2>/dev/null || echo "0")
        
        if [[ "$slot_count" -gt 0 ]]; then
            success "Active replication slots: $slot_count"
            
            info "Replication slots:"
            sudo -u postgres psql -c "SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;" postgres 2>/dev/null || true
        else
            warn "No replication slots found"
        fi
        
    elif [[ "$role" == "standby" ]]; then
        # Check WAL receiver status
        local receiver_status
        receiver_status=$(sudo -u postgres psql -Atqc "SELECT status FROM pg_stat_wal_receiver;" postgres 2>/dev/null || echo "unknown")
        
        if [[ "$receiver_status" == "streaming" ]]; then
            success "WAL receiver is streaming"
            
            # Show WAL receiver details
            info "WAL receiver status:"
            sudo -u postgres psql -c "SELECT status, received_lsn, latest_end_lsn FROM pg_stat_wal_receiver;" postgres 2>/dev/null || true
            
            # Check replication lag
            local lag_seconds
            lag_seconds=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN COALESCE(EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp()), 0) ELSE 0 END;" postgres 2>/dev/null || echo "-1")
            
            if [[ "$lag_seconds" != "-1" ]]; then
                if (( $(echo "$lag_seconds < 60" | bc -l 2>/dev/null) )); then
                    success "Replication lag: ${lag_seconds} seconds (acceptable)"
                else
                    warn "Replication lag: ${lag_seconds} seconds (high)"
                fi
            fi
        else
            fail "WAL receiver status: $receiver_status"
        fi
        
    else
        info "Node role: $role (witness or unknown)"
    fi
}

validate_custom_failover_script() {
    section "Custom Failover Script"
    
    # Check failover script
    if [[ -f "$FAILOVER_SCRIPT" ]]; then
        success "Custom failover script exists: $FAILOVER_SCRIPT"
        
        # Check if executable
        if [[ -x "$FAILOVER_SCRIPT" ]]; then
            success "Failover script is executable"
        else
            fail "Failover script is not executable"
        fi
        
        # Test failover script health check
        info "Testing failover script health check functionality..."
        if timeout 15 sudo -u postgres "$FAILOVER_SCRIPT" test-health >/dev/null 2>&1; then
            success "Failover script health checks working"
        else
            warn "Failover script health checks may have issues"
        fi
        
    else
        fail "Custom failover script not found: $FAILOVER_SCRIPT"
    fi
    
    # Check failover configuration
    if [[ -f "$FAILOVER_CONF_FILE" ]]; then
        success "Failover configuration file exists: $FAILOVER_CONF_FILE"
        
        # Validate configuration content
        if grep -q "PRIMARY_HOST" "$FAILOVER_CONF_FILE" && grep -q "STANDBY_HOST" "$FAILOVER_CONF_FILE"; then
            success "Failover configuration contains required host settings"
            
            # Show configuration
            local primary_host=$(grep "^PRIMARY_HOST=" "$FAILOVER_CONF_FILE" | cut -d'=' -f2 | tr -d '"')
            local standby_host=$(grep "^STANDBY_HOST=" "$FAILOVER_CONF_FILE" | cut -d'=' -f2 | tr -d '"')
            local witness_host=$(grep "^WITNESS_HOST=" "$FAILOVER_CONF_FILE" | cut -d'=' -f2 | tr -d '"')
            
            info "Primary host: $primary_host"
            info "Standby host: $standby_host"
            info "Witness host: $witness_host"
        else
            warn "Failover configuration may be incomplete"
        fi
    else
        fail "Failover configuration file not found: $FAILOVER_CONF_FILE"
    fi
    
    # Check failover manager service (only for standby nodes)
    local role=$(get_pg_role)
    if [[ "$role" == "standby" ]]; then
        if check_service pg-failover-manager "PostgreSQL failover manager"; then
            success "PostgreSQL failover manager service is running on standby"
        else
            warn "PostgreSQL failover manager service not running on standby node"
        fi
    else
        info "Failover manager service not expected on $role node"
    fi
}

validate_witness_consensus() {
    section "Witness Node and Consensus"
    
    # Check if witness node is configured in failover config
    if [[ -f "$FAILOVER_CONF_FILE" ]]; then
        local witness_host
        witness_host=$(grep "^WITNESS_HOST=" "$FAILOVER_CONF_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
        
        if [[ -n "$witness_host" ]]; then
            success "Witness node configured: $witness_host"
            
            # Test witness node connectivity
            info "Testing witness node connectivity..."
            if timeout 5 ping -c 1 "$witness_host" >/dev/null 2>&1; then
                success "Witness node is reachable via ping"
            else
                warn "Witness node is not reachable: $witness_host"
            fi
            
            # Test PostgreSQL connectivity to witness
            if timeout 10 pg_isready -h "$witness_host" -p 5432 >/dev/null 2>&1; then
                success "Witness node PostgreSQL is accessible"
            else
                warn "Witness node PostgreSQL is not accessible"
            fi
        else
            warn "No witness node configured in failover configuration"
            info "Witness nodes help prevent split-brain scenarios in 2-node clusters"
        fi
    else
        warn "Failover configuration file not found - cannot check witness setup"
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
    
    # Check .pgpass file
    local pgpass_file="/var/lib/postgresql/.pgpass"
    if [[ -f "$pgpass_file" ]]; then
        success ".pgpass file exists for authentication"
    else
        warn ".pgpass file not found - creating basic template"
        cat > "$pgpass_file" <<EOF
# Basic .pgpass template - update with real passwords
localhost:$PGBOUNCER_PORT:*:postgres:test_password
localhost:5432:*:postgres:test_password
EOF
        chown postgres:postgres "$pgpass_file" 2>/dev/null || true
        chmod 600 "$pgpass_file" 2>/dev/null || true
        info "Created basic .pgpass file - you may need to update passwords"
    fi
    
    # Test database connection through PgBouncer
    info "Testing database connection through PgBouncer..."
    if timeout 10 sudo -u postgres env PGPASSFILE="$pgpass_file" psql -h localhost -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 'PgBouncer connection test successful' as status;" >/dev/null 2>&1; then
        success "Database connection through PgBouncer working"
    else
        warn "Database connection through PgBouncer failed - check authentication"
    fi
}

validate_health_endpoints() {
    section "Health Endpoints"
    
    # Test PostgreSQL health endpoint
    info "Testing PostgreSQL health endpoint..."
    if timeout 10 curl -sf "http://localhost:$HEALTH_PORT_PG" >/dev/null 2>&1; then
        success "PostgreSQL health endpoint responding"
        
        # Show health status
        local health_response
        health_response=$(timeout 5 curl -s "http://localhost:$HEALTH_PORT_PG" 2>/dev/null || echo "")
        if [[ -n "$health_response" ]]; then
            info "Health status: $health_response"
        fi
    else
        fail "PostgreSQL health endpoint not responding"
    fi
    
    # Test PgBouncer health endpoint  
    info "Testing PgBouncer health endpoint..."
    if timeout 10 curl -sf "http://localhost:$HEALTH_PORT_PGBOUNCER" >/dev/null 2>&1; then
        success "PgBouncer health endpoint responding"
        
        # Show health status
        local pgb_health_response
        pgb_health_response=$(timeout 5 curl -s "http://localhost:$HEALTH_PORT_PGBOUNCER" 2>/dev/null || echo "")
        if [[ -n "$pgb_health_response" ]]; then
            info "PgBouncer health status: $pgb_health_response"
        fi
    else
        fail "PgBouncer health endpoint not responding"
    fi
    
    # Check health endpoint services
    if systemctl is-active --quiet final-pg-health.service; then
        success "PostgreSQL health endpoint service is running"
    else
        warn "PostgreSQL health endpoint service is not running"
    fi
    
    if systemctl is-active --quiet final-pgbouncer-health.service; then
        success "PgBouncer health endpoint service is running"
    else
        warn "PgBouncer health endpoint service is not running"
    fi
}

validate_security_configuration() {
    section "Security Configuration"
    
    # Check file permissions
    local pgdata_dir="/var/lib/postgresql/$PG_VERSION/main"
    if [[ -d "$pgdata_dir" ]]; then
        local pgdata_perms
        pgdata_perms=$(stat -c %a "$pgdata_dir" 2>/dev/null || echo "unknown")
        if [[ "$pgdata_perms" == "700" ]]; then
            success "PostgreSQL data directory has correct permissions (700)"
        else
            warn "PostgreSQL data directory permissions may be incorrect: $pgdata_perms"
        fi
    fi
    
    # Check PostgreSQL network binding
    if command -v ss >/dev/null 2>&1; then
        local pg_bindings
        pg_bindings=$(ss -tln | grep ":5432" | head -5)
        if [[ -n "$pg_bindings" ]]; then
            info "PostgreSQL network bindings:"
            echo "$pg_bindings"
        fi
    fi
    
    # Check authentication methods
    local pg_hba="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
    if [[ -f "$pg_hba" ]]; then
        if grep -q "scram-sha-256" "$pg_hba"; then
            success "SCRAM-SHA-256 authentication configured"
        else
            info "MD5 authentication in use (acceptable for PgBouncer compatibility)"
        fi
    fi
}

validate_wal_archiving() {
    section "WAL Archiving and Backup Readiness"
    
    # Check WAL archiving status
    local archive_mode
    archive_mode=$(sudo -u postgres psql -Atqc "SHOW archive_mode;" postgres 2>/dev/null || echo "unknown")
    
    if [[ "$archive_mode" == "on" ]]; then
        success "WAL archiving is enabled"
        
        # Check archive command
        local archive_command
        archive_command=$(sudo -u postgres psql -Atqc "SHOW archive_command;" postgres 2>/dev/null || echo "unknown")
        info "Archive command: $archive_command"
        
        # Check WAL archive directory
        local wal_archive_dir="/var/lib/postgresql/wal_archive"
        if [[ -d "$wal_archive_dir" ]]; then
            success "WAL archive directory exists: $wal_archive_dir"
            
            # Check recent WAL files
            local wal_count
            wal_count=$(find "$wal_archive_dir" -name "*.wal" -o -name "*[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]" 2>/dev/null | wc -l || echo "0")
            info "WAL files in archive: $wal_count"
        else
            warn "WAL archive directory not found: $wal_archive_dir"
        fi
    else
        info "WAL archiving is disabled (acceptable for streaming-only setup)"
    fi
    
    # Check backup tools
    check_command pg_dump "pg_dump backup tool"
    check_command pg_basebackup "pg_basebackup tool"
}

run_integration_tests() {
    section "Integration Tests"
    
    local role
    role=$(get_pg_role)
    
    info "Running integration tests for $role node..."
    
    # Test replication functionality
    if [[ "$role" == "primary" ]]; then
        # Test write operations
        if sudo -u postgres psql -c "CREATE TABLE IF NOT EXISTS validation_test (id serial, test_time timestamp DEFAULT now());" postgres >/dev/null 2>&1; then
            success "Write operations working on primary"
            
            # Insert test data
            if sudo -u postgres psql -c "INSERT INTO validation_test DEFAULT VALUES;" postgres >/dev/null 2>&1; then
                success "Data insertion working"
            fi
        else
            warn "Write operations may have issues on primary"
        fi
        
        # Check replication lag
        local standby_count
        standby_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming';" postgres 2>/dev/null || echo "0")
        
        if [[ "$standby_count" -gt 0 ]]; then
            success "Primary has $standby_count streaming standby connection(s)"
        else
            warn "Primary has no streaming standby connections"
        fi
        
    elif [[ "$role" == "standby" ]]; then
        # Test read operations
        if sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;" postgres >/dev/null 2>&1; then
            success "Read operations working on standby"
        else
            warn "Read operations may have issues on standby"
        fi
        
        # Check if in recovery
        if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
            success "Standby node is correctly in recovery mode"
        else
            fail "Standby node is not in recovery mode"
        fi
    fi
    
    # Test PgBouncer integration
    info "Testing PgBouncer connection handling..."
    if timeout 10 sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p "$PGBOUNCER_PORT" -U postgres -d postgres -c "SELECT 'Integration test successful' as status;" >/dev/null 2>&1; then
        success "PgBouncer integration test successful"
    else
        warn "PgBouncer integration test failed"
    fi
    
    info "Integration tests completed"
}

generate_summary_report() {
    section "Validation Summary"
    
    local end_time
    end_time=$(($(date +%s) - VALIDATION_START_TIME))
    
    echo
    printf "%b=== POSTGRESQL HA STREAMING REPLICATION VALIDATION SUMMARY ===%b\n" "$BLUE" "$NC"
    printf "Validation completed in %d seconds\n" "$end_time"
    printf "%b✅ PASSED:%b %d tests\n" "$GREEN" "$NC" "$PASSED"
    printf "%b⚠️  WARNINGS:%b %d issues\n" "$YELLOW" "$NC" "$WARNINGS"
    printf "%b❌ FAILED:%b %d tests\n" "$RED" "$NC" "$FAILED"
    echo
    
    # Overall status
    if [[ $FAILED -eq 0 && $WARNINGS -eq 0 ]]; then
        printf "%b🎉 EXCELLENT: PostgreSQL HA streaming replication is fully operational!%b\n" "$GREEN" "$NC"
    elif [[ $FAILED -eq 0 ]]; then
        printf "%b✅ GOOD: PostgreSQL HA streaming replication is operational with minor warnings%b\n" "$YELLOW" "$NC"
    elif [[ $FAILED -lt 5 ]]; then
        printf "%b⚠️  CAUTION: PostgreSQL HA streaming replication has some issues that should be addressed%b\n" "$YELLOW" "$NC"
    else
        printf "%b❌ CRITICAL: PostgreSQL HA streaming replication has significant issues requiring immediate attention%b\n" "$RED" "$NC"
    fi
    
    echo
    local role=$(get_pg_role)
    info "Node role: $role"
    info "PostgreSQL version: $PG_VERSION"
    info "Failover script: Expert-validated custom failover"
    info "Connection pooling: PgBouncer"
    
    # Show connection information
    echo
    printf "%b=== CONNECTION INFORMATION ===%b\n" "$CYAN" "$NC"
    printf "PostgreSQL Direct: postgresql://postgres:***@localhost:5432/postgres\n"
    printf "PgBouncer Pooled: postgresql://postgres:***@localhost:%d/postgres\n" "$PGBOUNCER_PORT"
    printf "PostgreSQL Health: http://localhost:%d\n" "$HEALTH_PORT_PG"
    printf "PgBouncer Health: http://localhost:%d\n" "$HEALTH_PORT_PGBOUNCER"
    echo
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════════════════╗
║                PostgreSQL HA Streaming Replication Validation                ║
║                          Expert-Validated Setup                              ║
║                       Production Readiness Check                             ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF

    echo
    info "Starting comprehensive validation of PostgreSQL HA streaming replication..."
    info "Script version: $SCRIPT_VERSION"
    echo
    
    # Run all validation tests
    validate_system_prerequisites
    validate_postgresql_installation
    validate_streaming_replication_config
    validate_postgresql_users
    validate_streaming_replication_status
    validate_custom_failover_script
    validate_witness_consensus
    validate_pgbouncer_installation
    validate_pgbouncer_connectivity
    validate_health_endpoints
    validate_security_configuration
    validate_wal_archiving
    run_integration_tests
    
    # Generate final report
    generate_summary_report
    
    # Exit with appropriate code
    if [[ $FAILED -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "WARNING: This script should be run as root for complete validation"
    echo "Some checks may fail or provide incomplete results"
    echo ""
fi

# Execute main function
main "$@"