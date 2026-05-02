#!/bin/bash
# filepath: /Users/abdulrahmansamy/git-repos/system_engineering/03- DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/complete_comperhensive_validation.sh
#
# COMPREHENSIVE POSTGRESQL HA VALIDATION SCRIPT
# Validates every configuration implemented by postgresql_ha_bootstrap_production_v5.0.3
# Tests: System config, PostgreSQL, Replication, PgBouncer, Health endpoints, Failover, Extensions

set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0

# Test result tracking
FAILED_TEST_NAMES=()

# Helper functions
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; ((PASSED_TESTS++)) || true; ((TOTAL_TESTS++)) || true; }
fail() { echo -e "${RED}[✗]${NC} $*"; ((FAILED_TESTS++)) || true; ((TOTAL_TESTS++)) || true; FAILED_TEST_NAMES+=("$*"); }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; ((WARNINGS++)) || true; }
section() { echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}$*${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"; }

# Configuration
PRIMARY_HOST="${PRIMARY_HOST:-localhost}"
STANDBY_HOST="${STANDBY_HOST:-}"
WITNESS_HOST="${WITNESS_HOST:-}"
PG_PORT=5432
PGBOUNCER_PORT=6432
PG_HEALTH_PORT=8001
PGBOUNCER_HEALTH_PORT=8002

# Detect current role
detect_role() {
    local is_recovery
    is_recovery=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "unknown")
    
    if [[ "$is_recovery" == "t" ]]; then
        echo "standby"
    elif [[ "$is_recovery" == "f" ]]; then
        echo "primary"
    else
        echo "unknown"
    fi
}

CURRENT_ROLE=$(detect_role)

# ============================================================================
# SYSTEM CONFIGURATION TESTS
# ============================================================================
section "1. SYSTEM CONFIGURATION VALIDATION"

# 1.1 Hostname validation
info "Testing hostname configuration..."
HOSTNAME=$(hostname)
if [[ "$CURRENT_ROLE" == "primary" && "$HOSTNAME" == "prd-ipa-pgdb1" ]]; then
    success "Primary hostname: $HOSTNAME"
elif [[ "$CURRENT_ROLE" == "standby" && "$HOSTNAME" == "prd-ipa-pgdb2" ]]; then
    success "Standby hostname: $HOSTNAME"
else
    warn "Hostname: $HOSTNAME (expected pattern based on role)"
fi

# 1.2 Timezone validation
info "Testing timezone configuration..."
SYSTEM_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone)
PG_TZ=$(sudo -u postgres psql -Atqc "SHOW timezone;" 2>/dev/null || echo "unknown")

if [[ "$SYSTEM_TZ" == "$PG_TZ" ]]; then
    success "Timezone synchronized: System=$SYSTEM_TZ, PostgreSQL=$PG_TZ"
else
    fail "Timezone mismatch: System=$SYSTEM_TZ, PostgreSQL=$PG_TZ"
fi

# 1.3 NTP synchronization
info "Testing NTP synchronization..."
if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
    success "NTP synchronization enabled"
else
    warn "NTP synchronization not enabled"
fi

# 1.4 /etc/hosts validation
info "Testing /etc/hosts configuration..."
if grep -q "$HOSTNAME" /etc/hosts; then
    success "/etc/hosts contains hostname entry"
else
    warn "/etc/hosts missing hostname entry"
fi

# 1.5 LVM storage validation
info "Testing LVM storage configuration..."
if mountpoint -q /var/lib/postgresql 2>/dev/null; then
    MOUNT_INFO=$(df -h /var/lib/postgresql | tail -1)
    success "PostgreSQL LVM storage mounted: $MOUNT_INFO"
    
    # Check filesystem type
    FS_TYPE=$(df -T /var/lib/postgresql | tail -1 | awk '{print $2}')
    if [[ "$FS_TYPE" == "xfs" ]]; then
        success "Filesystem type: XFS"
    else
        warn "Filesystem type: $FS_TYPE (expected: xfs)"
    fi
    
    # Check ownership
    OWNER=$(stat -c '%U:%G' /var/lib/postgresql)
    if [[ "$OWNER" == "postgres:postgres" ]]; then
        success "Storage ownership: $OWNER"
    else
        fail "Storage ownership incorrect: $OWNER (expected: postgres:postgres)"
    fi
else
    warn "LVM storage not mounted at /var/lib/postgresql"
fi

# ============================================================================
# POSTGRESQL INSTALLATION & CONFIGURATION TESTS
# ============================================================================
section "2. POSTGRESQL INSTALLATION & CONFIGURATION"

# 2.1 PostgreSQL version
info "Testing PostgreSQL version..."
PG_VERSION=$(sudo -u postgres psql -Atqc "SHOW server_version;" 2>/dev/null || echo "unknown")
if [[ "$PG_VERSION" == 17* ]]; then
    success "PostgreSQL version: $PG_VERSION"
else
    fail "PostgreSQL version: $PG_VERSION (expected: 17.x)"
fi

# 2.2 PostgreSQL service status
info "Testing PostgreSQL service..."
if systemctl is-active --quiet postgresql; then
    success "PostgreSQL service is active"
else
    fail "PostgreSQL service is not active"
fi

if systemctl is-enabled --quiet postgresql; then
    success "PostgreSQL service is enabled"
else
    fail "PostgreSQL service is not enabled"
fi

# 2.3 Configuration files
info "Testing configuration files..."
if [[ -f /etc/postgresql/17/main/postgresql.conf ]]; then
    success "postgresql.conf exists"
    
    # Check key configurations
    if grep -q "wal_level = replica" /etc/postgresql/17/main/postgresql.conf; then
        success "wal_level = replica configured"
    else
        fail "wal_level = replica not found"
    fi
    
    if grep -q "max_wal_senders = 10" /etc/postgresql/17/main/postgresql.conf; then
        success "max_wal_senders = 10 configured"
    else
        warn "max_wal_senders configuration not found"
    fi
    
    if grep -q "hot_standby = on" /etc/postgresql/17/main/postgresql.conf; then
        success "hot_standby = on configured"
    else
        warn "hot_standby configuration not found"
    fi
else
    fail "postgresql.conf not found"
fi

if [[ -f /etc/postgresql/17/main/pg_hba.conf ]]; then
    success "pg_hba.conf exists"
    
    # Check replication access
    if grep -q "repuser" /etc/postgresql/17/main/pg_hba.conf; then
        success "repuser replication access configured"
    else
        fail "repuser not found in pg_hba.conf"
    fi
else
    fail "pg_hba.conf not found"
fi

# ============================================================================
# DATABASE USERS & AUTHENTICATION TESTS
# ============================================================================
section "3. DATABASE USERS & AUTHENTICATION"

# 3.1 User existence
info "Testing database users..."
USERS=("postgres" "repuser" "monitor_user" "app_user" "pgbouncer_admin")
for user in "${USERS[@]}"; do
    USER_EXISTS=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_roles WHERE rolname = '$user';" 2>/dev/null || echo "0")
    if [[ "$USER_EXISTS" == "1" ]]; then
        success "User '$user' exists"
    else
        fail "User '$user' does not exist"
    fi
done

# 3.2 Replication user privileges
info "Testing replication user privileges..."
REPL_PRIVILEGE=$(sudo -u postgres psql -Atqc "SELECT rolreplication FROM pg_roles WHERE rolname = 'repuser';" 2>/dev/null || echo "f")
if [[ "$REPL_PRIVILEGE" == "t" ]]; then
    success "repuser has replication privilege"
else
    fail "repuser missing replication privilege"
fi

# 3.3 .pgpass file
info "Testing .pgpass file..."
if [[ -f /var/lib/postgresql/.pgpass ]]; then
    success ".pgpass file exists"
    
    PGPASS_PERMS=$(stat -c '%a' /var/lib/postgresql/.pgpass)
    if [[ "$PGPASS_PERMS" == "600" ]]; then
        success ".pgpass permissions: 600"
    else
        fail ".pgpass permissions: $PGPASS_PERMS (expected: 600)"
    fi
    
    if grep -q "repuser" /var/lib/postgresql/.pgpass; then
        success ".pgpass contains repuser entry"
    else
        fail ".pgpass missing repuser entry"
    fi
else
    fail ".pgpass file not found"
fi

# ============================================================================
# REPLICATION CONFIGURATION TESTS
# ============================================================================
section "4. STREAMING REPLICATION CONFIGURATION"

# 4.1 WAL archive directory
info "Testing WAL archive directory..."
if [[ -d /var/lib/postgresql/wal_archive ]]; then
    success "WAL archive directory exists"
    
    WAL_PERMS=$(stat -c '%a' /var/lib/postgresql/wal_archive)
    if [[ "$WAL_PERMS" == "750" ]]; then
        success "WAL archive permissions: 750"
    else
        warn "WAL archive permissions: $WAL_PERMS (expected: 750)"
    fi
else
    fail "WAL archive directory not found"
fi

# 4.2 Replication slots
info "Testing replication slots..."
SLOT_COUNT=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = 'pgstandby1';" 2>/dev/null || echo "0")
if [[ "$CURRENT_ROLE" == "primary" ]]; then
    if [[ "$SLOT_COUNT" == "1" ]]; then
        success "Replication slot 'pgstandby1' exists on primary"
        
        SLOT_ACTIVE=$(sudo -u postgres psql -Atqc "SELECT active FROM pg_replication_slots WHERE slot_name = 'pgstandby1';" 2>/dev/null || echo "f")
        if [[ "$SLOT_ACTIVE" == "t" ]]; then
            success "Replication slot 'pgstandby1' is active"
        else
            warn "Replication slot 'pgstandby1' is not active"
        fi
    else
        fail "Replication slot 'pgstandby1' not found on primary"
    fi
fi

# 4.3 Replication status
if [[ "$CURRENT_ROLE" == "primary" ]]; then
    info "Testing replication status on primary..."
    REPL_COUNT=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    if [[ "$REPL_COUNT" -gt 0 ]]; then
        success "Primary has $REPL_COUNT active replication connection(s)"
        
        # Check standby sync state
        SYNC_STATE=$(sudo -u postgres psql -Atqc "SELECT sync_state FROM pg_stat_replication WHERE application_name = 'standby_sync';" 2>/dev/null || echo "unknown")
        if [[ "$SYNC_STATE" == "sync" ]]; then
            success "Standby is in synchronous mode"
        elif [[ "$SYNC_STATE" == "async" ]]; then
            warn "Standby is in asynchronous mode"
        else
            warn "Standby sync state: $SYNC_STATE"
        fi
    else
        warn "No active replication connections"
    fi
elif [[ "$CURRENT_ROLE" == "standby" ]]; then
    info "Testing replication status on standby..."
    WAL_RECEIVER=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_stat_wal_receiver WHERE status = 'streaming';" 2>/dev/null || echo "0")
    if [[ "$WAL_RECEIVER" == "1" ]]; then
        success "WAL receiver is streaming"
        
        # Check replication lag
        REPL_LAG=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(epoch FROM now() - pg_last_xact_replay_timestamp())::int;" 2>/dev/null || echo "999")
        if [[ "$REPL_LAG" -lt 5 ]]; then
            success "Replication lag: ${REPL_LAG}s (healthy)"
        elif [[ "$REPL_LAG" -lt 30 ]]; then
            warn "Replication lag: ${REPL_LAG}s (acceptable)"
        else
            fail "Replication lag: ${REPL_LAG}s (too high)"
        fi
    else
        fail "WAL receiver not streaming"
    fi
fi

# 4.4 Synchronous replication settings
if [[ "$CURRENT_ROLE" == "primary" ]]; then
    info "Testing synchronous replication settings..."
    SYNC_STANDBY=$(sudo -u postgres psql -Atqc "SHOW synchronous_standby_names;" 2>/dev/null || echo "")
    if [[ -n "$SYNC_STANDBY" && "$SYNC_STANDBY" != "''" ]]; then
        success "Synchronous standby configured: $SYNC_STANDBY"
    else
        warn "Synchronous replication not enabled (expected after standby connects)"
    fi
    
    SYNC_COMMIT=$(sudo -u postgres psql -Atqc "SHOW synchronous_commit;" 2>/dev/null || echo "off")
    info "Synchronous commit: $SYNC_COMMIT"
fi

# ============================================================================
# PGBOUNCER CONFIGURATION TESTS
# ============================================================================
section "5. PGBOUNCER CONNECTION POOLING"

# 5.1 PgBouncer installation
info "Testing PgBouncer installation..."
if command -v pgbouncer >/dev/null 2>&1; then
    success "PgBouncer is installed"
else
    fail "PgBouncer not found"
fi

# 5.2 PgBouncer service
info "Testing PgBouncer service..."
if systemctl is-active --quiet pgbouncer; then
    success "PgBouncer service is active"
else
    fail "PgBouncer service is not active"
fi

if systemctl is-enabled --quiet pgbouncer; then
    success "PgBouncer service is enabled"
else
    warn "PgBouncer service is not enabled"
fi

# 5.3 PgBouncer configuration files
info "Testing PgBouncer configuration..."
if [[ -f /etc/pgbouncer/pgbouncer.ini ]]; then
    success "pgbouncer.ini exists"
    
    if grep -q "listen_port = 6432" /etc/pgbouncer/pgbouncer.ini; then
        success "PgBouncer listening on port 6432"
    else
        warn "PgBouncer port configuration not found"
    fi
    
    if grep -q "auth_type = md5" /etc/pgbouncer/pgbouncer.ini; then
        success "PgBouncer using MD5 authentication"
    else
        warn "PgBouncer auth_type not set to md5"
    fi
else
    fail "pgbouncer.ini not found"
fi

if [[ -f /etc/pgbouncer/userlist.txt ]]; then
    success "userlist.txt exists"
    
    USERLIST_PERMS=$(stat -c '%a' /etc/pgbouncer/userlist.txt)
    if [[ "$USERLIST_PERMS" == "640" ]]; then
        success "userlist.txt permissions: 640"
    else
        warn "userlist.txt permissions: $USERLIST_PERMS (expected: 640)"
    fi
    
    if grep -q "repuser" /etc/pgbouncer/userlist.txt; then
        success "userlist.txt contains repuser"
    else
        warn "userlist.txt missing repuser"
    fi
else
    fail "userlist.txt not found"
fi

# 5.4 PgBouncer connectivity
info "Testing PgBouncer connectivity..."
if timeout 5 sudo -u postgres psql -h localhost -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    success "PgBouncer connection successful"
else
    fail "Cannot connect to PgBouncer"
fi

# Test with actual query
PGBOUNCER_TEST=$(timeout 5 sudo -u postgres psql -h localhost -p 6432 -d postgres -Atqc "SELECT 'pgbouncer_ok';" 2>/dev/null || echo "failed")
if [[ "$PGBOUNCER_TEST" == "pgbouncer_ok" ]]; then
    success "PgBouncer query execution successful"
else
    fail "PgBouncer query failed"
fi

# 5.5 Test all database users through PgBouncer
info "Testing database user connections through PgBouncer..."

# Test postgres user
if timeout 5 sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    success "User 'postgres' can connect through PgBouncer"
else
    fail "User 'postgres' cannot connect through PgBouncer"
fi

# Test app_user
if timeout 5 sudo -u postgres psql -h localhost -p 6432 -U app_user -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    success "User 'app_user' can connect through PgBouncer"
else
    warn "User 'app_user' cannot connect through PgBouncer"
fi

# Test monitor_user
if timeout 5 sudo -u postgres psql -h localhost -p 6432 -U monitor_user -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    success "User 'monitor_user' can connect through PgBouncer"
else
    warn "User 'monitor_user' cannot connect through PgBouncer"
fi

# 5.6 Test PgBouncer statistics and admin access
info "Testing PgBouncer admin console..."
PGBOUNCER_VERSION=$(timeout 5 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -Atqc "SHOW VERSION;" 2>/dev/null || echo "failed")
if [[ "$PGBOUNCER_VERSION" != "failed" && -n "$PGBOUNCER_VERSION" ]]; then
    success "PgBouncer admin console accessible: $PGBOUNCER_VERSION"
else
    warn "Cannot access PgBouncer admin console"
fi

# Check PgBouncer pools
info "Testing PgBouncer pool statistics..."
POOL_COUNT=$(timeout 5 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -Atqc "SHOW POOLS;" 2>/dev/null | wc -l || echo "0")
if [[ "$POOL_COUNT" -gt 0 ]]; then
    success "PgBouncer pools active: $POOL_COUNT pools"
else
    warn "No active PgBouncer pools found"
fi

# Check PgBouncer clients
CLIENT_COUNT=$(timeout 5 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -Atqc "SHOW CLIENTS;" 2>/dev/null | wc -l || echo "0")
if [[ "$CLIENT_COUNT" -ge 0 ]]; then
    success "PgBouncer client connections: $CLIENT_COUNT"
else
    warn "Cannot retrieve PgBouncer client count"
fi

# Check PgBouncer databases
DB_COUNT=$(timeout 5 sudo -u postgres psql -h localhost -p 6432 -d pgbouncer -Atqc "SHOW DATABASES;" 2>/dev/null | wc -l || echo "0")
if [[ "$DB_COUNT" -gt 0 ]]; then
    success "PgBouncer configured databases: $DB_COUNT"
else
    warn "No databases configured in PgBouncer"
fi

# 5.7 Compare direct PostgreSQL vs PgBouncer connections
info "Comparing direct PostgreSQL vs PgBouncer connections..."

# Direct connection test
DIRECT_RESULT=$(timeout 5 sudo -u postgres psql -h localhost -p 5432 -d postgres -Atqc "SELECT 'direct_ok';" 2>/dev/null || echo "failed")
if [[ "$DIRECT_RESULT" == "direct_ok" ]]; then
    success "Direct PostgreSQL connection (port 5432) working"
else
    fail "Direct PostgreSQL connection (port 5432) failed"
fi

# PgBouncer connection test
BOUNCER_RESULT=$(timeout 5 sudo -u postgres psql -h localhost -p 6432 -d postgres -Atqc "SELECT 'bouncer_ok';" 2>/dev/null || echo "failed")
if [[ "$BOUNCER_RESULT" == "bouncer_ok" ]]; then
    success "PgBouncer connection (port 6432) working"
else
    fail "PgBouncer connection (port 6432) failed"
fi

# 5.8 Test PgBouncer transaction pooling
info "Testing PgBouncer transaction behavior..."
TRANSACTION_TEST=$(timeout 5 sudo -u postgres psql -h localhost -p 6432 -d postgres -Atqc "BEGIN; SELECT 1; COMMIT; SELECT 'transaction_ok';" 2>/dev/null || echo "failed")
if [[ "$TRANSACTION_TEST" == "transaction_ok" ]]; then
    success "PgBouncer transaction handling working"
else
    warn "PgBouncer transaction test inconclusive"
fi

# 5.9 Test connection limits
info "Testing PgBouncer connection limits..."
MAX_CLIENT_CONN=$(grep -E "^max_client_conn" /etc/pgbouncer/pgbouncer.ini 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ' || echo "unknown")
DEFAULT_POOL_SIZE=$(grep -E "^default_pool_size" /etc/pgbouncer/pgbouncer.ini 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ' || echo "unknown")

if [[ "$MAX_CLIENT_CONN" != "unknown" ]]; then
    success "PgBouncer max_client_conn: $MAX_CLIENT_CONN"
else
    warn "Cannot determine PgBouncer max_client_conn"
fi

if [[ "$DEFAULT_POOL_SIZE" != "unknown" ]]; then
    success "PgBouncer default_pool_size: $DEFAULT_POOL_SIZE"
else
    warn "Cannot determine PgBouncer default_pool_size"
fi

# ============================================================================
# POSTGRESQL EXTENSIONS TESTS
# ============================================================================
section "6. POSTGRESQL EXTENSIONS - INSTALLATION & CONFIGURATION"

# 6.1 Check installed extensions
info "Testing PostgreSQL extensions installation..."
EXTENSIONS=("pg_stat_statements" "pg_buffercache" "uuid-ossp" "plpgsql")
for ext in "${EXTENSIONS[@]}"; do
    EXT_EXISTS=$(sudo -u postgres psql -d postgres -Atqc "SELECT COUNT(*) FROM pg_extension WHERE extname = '$ext';" 2>/dev/null || echo "0")
    if [[ "$EXT_EXISTS" == "1" ]]; then
        success "Extension '$ext' installed"
        
        # Get extension version
        EXT_VERSION=$(sudo -u postgres psql -d postgres -Atqc "SELECT extversion FROM pg_extension WHERE extname = '$ext';" 2>/dev/null || echo "unknown")
        info "  → Version: $EXT_VERSION"
    else
        fail "Extension '$ext' not installed"
    fi
done

# 6.2 Test pg_stat_statements functionality
info "Testing pg_stat_statements functionality..."
if sudo -u postgres psql -d postgres -c "SELECT * FROM pg_stat_statements LIMIT 1;" >/dev/null 2>&1; then
    success "pg_stat_statements is functional"
    
    # Check if it's tracking queries
    TRACKED_QUERIES=$(sudo -u postgres psql -d postgres -Atqc "SELECT COUNT(*) FROM pg_stat_statements;" 2>/dev/null || echo "0")
    if [[ "$TRACKED_QUERIES" -gt 0 ]]; then
        success "pg_stat_statements tracking queries: $TRACKED_QUERIES statements"
    else
        warn "pg_stat_statements not tracking any queries yet"
    fi
    
    # Test query statistics capture
    sudo -u postgres psql -d postgres -c "SELECT 1 AS test_query;" >/dev/null 2>&1
    if sudo -u postgres psql -d postgres -Atqc "SELECT COUNT(*) FROM pg_stat_statements WHERE query LIKE '%test_query%';" 2>/dev/null | grep -q "^[1-9]"; then
        success "pg_stat_statements capturing query statistics"
    else
        info "pg_stat_statements query capture test (may not appear immediately)"
    fi
else
    fail "pg_stat_statements query failed"
fi

# 6.3 Test pg_buffercache functionality
info "Testing pg_buffercache functionality..."
if sudo -u postgres psql -d postgres -c "SELECT * FROM pg_buffercache LIMIT 1;" >/dev/null 2>&1; then
    success "pg_buffercache is functional"
    
    # Check buffer cache statistics
    BUFFER_COUNT=$(sudo -u postgres psql -d postgres -Atqc "SELECT COUNT(*) FROM pg_buffercache WHERE reldatabase IS NOT NULL;" 2>/dev/null || echo "0")
    if [[ "$BUFFER_COUNT" -gt 0 ]]; then
        success "pg_buffercache reporting buffer usage: $BUFFER_COUNT buffers in use"
    else
        info "pg_buffercache: No buffers currently in use (may be normal)"
    fi
    
    # Test buffer cache size calculation
    BUFFER_SIZE=$(sudo -u postgres psql -d postgres -Atqc "SELECT pg_size_pretty(COUNT(*) * 8192) FROM pg_buffercache;" 2>/dev/null || echo "unknown")
    if [[ "$BUFFER_SIZE" != "unknown" ]]; then
        success "pg_buffercache total cache size: $BUFFER_SIZE"
    fi
else
    fail "pg_buffercache query failed"
fi

# 6.4 Test uuid-ossp functionality
info "Testing uuid-ossp functionality..."
if sudo -u postgres psql -d postgres -c "SELECT uuid_generate_v4();" >/dev/null 2>&1; then
    success "uuid-ossp is functional"
    
    # Generate and validate UUID
    TEST_UUID=$(sudo -u postgres psql -d postgres -Atqc "SELECT uuid_generate_v4();" 2>/dev/null || echo "")
    if [[ "$TEST_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
        success "uuid-ossp generating valid UUIDs: $TEST_UUID"
    else
        warn "uuid-ossp UUID format validation inconclusive"
    fi
    
    # Test multiple UUID generation functions
    UUID_FUNCTIONS=("uuid_generate_v1" "uuid_generate_v1mc" "uuid_generate_v4" "uuid_generate_v5")
    WORKING_FUNCS=0
    for func in "${UUID_FUNCTIONS[@]}"; do
        if sudo -u postgres psql -d postgres -c "SELECT $func(uuid_ns_dns(), 'test');" >/dev/null 2>&1 || \
           sudo -u postgres psql -d postgres -c "SELECT $func();" >/dev/null 2>&1; then
            ((WORKING_FUNCS++)) || true
        fi
    done
    if [[ "$WORKING_FUNCS" -ge 2 ]]; then
        success "uuid-ossp: $WORKING_FUNCS UUID generation functions working"
    else
        warn "uuid-ossp: Only $WORKING_FUNCS UUID generation functions verified"
    fi
else
    fail "uuid-ossp query failed"
fi

# 6.5 Test plpgsql functionality
info "Testing plpgsql functionality..."
if sudo -u postgres psql -d postgres -c "SELECT lanname FROM pg_language WHERE lanname = 'plpgsql';" 2>/dev/null | grep -q "plpgsql"; then
    success "plpgsql language is available"
    
    # Test creating a simple function
    PLPGSQL_TEST=$(sudo -u postgres psql -d postgres <<'PLPGSQL_EOF' 2>/dev/null
DO $$
DECLARE
    test_var INTEGER := 42;
BEGIN
    IF test_var = 42 THEN
        RAISE NOTICE 'plpgsql test successful';
    END IF;
END $$;
SELECT 'plpgsql_ok';
PLPGSQL_EOF
)
    
    if echo "$PLPGSQL_TEST" | grep -q "plpgsql_ok"; then
        success "plpgsql executing anonymous blocks successfully"
    else
        warn "plpgsql anonymous block execution test inconclusive"
    fi
    
    # Test function creation and execution
    if sudo -u postgres psql -d postgres >/dev/null 2>&1 <<'FUNC_EOF'
CREATE OR REPLACE FUNCTION test_plpgsql_func(val INTEGER) 
RETURNS INTEGER AS $$
BEGIN
    RETURN val * 2;
END;
$$ LANGUAGE plpgsql;
FUNC_EOF
    then
        success "plpgsql function creation successful"
        
        # Test function execution
        FUNC_RESULT=$(sudo -u postgres psql -d postgres -Atqc "SELECT test_plpgsql_func(21);" 2>/dev/null || echo "0")
        if [[ "$FUNC_RESULT" == "42" ]]; then
            success "plpgsql function execution successful (returned: $FUNC_RESULT)"
        else
            warn "plpgsql function execution test returned: $FUNC_RESULT (expected: 42)"
        fi
        
        # Cleanup test function
        sudo -u postgres psql -d postgres -c "DROP FUNCTION IF EXISTS test_plpgsql_func(INTEGER);" >/dev/null 2>&1
    else
        warn "plpgsql function creation test failed"
    fi
else
    fail "plpgsql language not available"
fi

# 6.6 Check extension schema and ownership
info "Testing extension schemas and ownership..."
EXT_SCHEMAS=$(sudo -u postgres psql -d postgres -Atqc "SELECT DISTINCT extnamespace::regnamespace FROM pg_extension WHERE extname IN ('pg_stat_statements', 'pg_buffercache', 'uuid-ossp', 'plpgsql');" 2>/dev/null || echo "")
if [[ -n "$EXT_SCHEMAS" ]]; then
    success "Extension schemas: $EXT_SCHEMAS"
else
    warn "Could not determine extension schemas"
fi

# 6.7 Verify extensions in shared_preload_libraries
info "Testing extensions in shared_preload_libraries configuration..."
PRELOAD_LIBS=$(sudo -u postgres psql -Atqc "SHOW shared_preload_libraries;" 2>/dev/null || echo "")

if echo "$PRELOAD_LIBS" | grep -q "pg_stat_statements"; then
    success "pg_stat_statements in shared_preload_libraries"
else
    warn "pg_stat_statements not in shared_preload_libraries (may reduce functionality)"
fi

if echo "$PRELOAD_LIBS" | grep -q "pg_buffercache"; then
    success "pg_buffercache in shared_preload_libraries"
else
    warn "pg_buffercache not in shared_preload_libraries (may reduce functionality)"
fi

# 6.8 Test extension available functions count
info "Testing extension function availability..."
for ext in "pg_stat_statements" "pg_buffercache" "uuid-ossp"; do
    FUNC_COUNT=$(sudo -u postgres psql -d postgres -Atqc "SELECT COUNT(*) FROM pg_proc WHERE pronamespace IN (SELECT oid FROM pg_namespace WHERE nspname = (SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname = '$ext'));" 2>/dev/null || echo "0")
    if [[ "$FUNC_COUNT" -gt 0 ]]; then
        success "Extension '$ext' provides $FUNC_COUNT functions"
    else
        info "Extension '$ext' function count: $FUNC_COUNT"
    fi
done

# 6.9 Test pg_stat_statements configuration parameters
info "Testing pg_stat_statements configuration..."
PGSS_MAX=$(sudo -u postgres psql -Atqc "SHOW pg_stat_statements.max;" 2>/dev/null || echo "0")
PGSS_TRACK=$(sudo -u postgres psql -Atqc "SHOW pg_stat_statements.track;" 2>/dev/null || echo "none")

if [[ "$PGSS_MAX" == "10000" ]]; then
    success "pg_stat_statements.max: $PGSS_MAX (configured)"
else
    warn "pg_stat_statements.max: $PGSS_MAX (expected: 10000)"
fi

if [[ "$PGSS_TRACK" == "all" ]]; then
    success "pg_stat_statements.track: $PGSS_TRACK (tracking all statements)"
else
    info "pg_stat_statements.track: $PGSS_TRACK"
fi

# 6.10 Extension upgrade readiness check
info "Testing extension upgrade readiness..."
for ext in "pg_stat_statements" "pg_buffercache" "uuid-ossp" "plpgsql"; do
    AVAILABLE_VERSION=$(sudo -u postgres psql -d postgres -Atqc "SELECT default_version FROM pg_available_extensions WHERE name = '$ext';" 2>/dev/null || echo "unknown")
    INSTALLED_VERSION=$(sudo -u postgres psql -d postgres -Atqc "SELECT extversion FROM pg_extension WHERE extname = '$ext';" 2>/dev/null || echo "unknown")
    
    if [[ "$AVAILABLE_VERSION" != "unknown" && "$INSTALLED_VERSION" != "unknown" ]]; then
        if [[ "$AVAILABLE_VERSION" == "$INSTALLED_VERSION" ]]; then
            success "Extension '$ext': up-to-date (version $INSTALLED_VERSION)"
        else
            warn "Extension '$ext': upgrade available ($INSTALLED_VERSION → $AVAILABLE_VERSION)"
        fi
    fi
done

# 6.11 Test extensions in template1 database
info "Testing extensions in template1 database..."
TEMPLATE1_EXTENSIONS=("pg_stat_statements" "pg_buffercache" "uuid-ossp" "plpgsql")
TEMPLATE1_EXT_COUNT=0

for ext in "${TEMPLATE1_EXTENSIONS[@]}"; do
    TEMPLATE1_EXT_EXISTS=$(sudo -u postgres psql -d template1 -Atqc "SELECT COUNT(*) FROM pg_extension WHERE extname = '$ext';" 2>/dev/null || echo "0")
    if [[ "$TEMPLATE1_EXT_EXISTS" == "1" ]]; then
        success "Extension '$ext' installed in template1"
        ((TEMPLATE1_EXT_COUNT++)) || true
        
        # Get extension version and schema from template1
        TEMPLATE1_EXT_VERSION=$(sudo -u postgres psql -d template1 -Atqc "SELECT extversion FROM pg_extension WHERE extname = '$ext';" 2>/dev/null || echo "unknown")
        TEMPLATE1_EXT_SCHEMA=$(sudo -u postgres psql -d template1 -Atqc "SELECT extnamespace::regnamespace FROM pg_extension WHERE extname = '$ext';" 2>/dev/null || echo "unknown")
        info "  → template1: Version: $TEMPLATE1_EXT_VERSION, Schema: $TEMPLATE1_EXT_SCHEMA"
    else
        warn "Extension '$ext' not installed in template1 (new databases won't have it by default)"
    fi
done

if [[ "$TEMPLATE1_EXT_COUNT" == "4" ]]; then
    success "All 4 extensions installed in template1 database (new databases will inherit them)"
elif [[ "$TEMPLATE1_EXT_COUNT" -gt 0 ]]; then
    warn "Only $TEMPLATE1_EXT_COUNT/4 extensions installed in template1"
else
    warn "No extensions installed in template1 database"
fi

# 6.12 Verify extension schemas match expected values
info "Verifying extension schemas match expected values..."
EXPECTED_SCHEMAS=(
    "pg_stat_statements:public"
    "pg_buffercache:public"
    "uuid-ossp:public"
    "plpgsql:pg_catalog"
)

for ext_schema in "${EXPECTED_SCHEMAS[@]}"; do
    EXT_NAME="${ext_schema%%:*}"
    EXPECTED_SCHEMA="${ext_schema##*:}"
    
    ACTUAL_SCHEMA=$(sudo -u postgres psql -d postgres -Atqc "SELECT extnamespace::regnamespace FROM pg_extension WHERE extname = '$EXT_NAME';" 2>/dev/null || echo "unknown")
    
    if [[ "$ACTUAL_SCHEMA" == "$EXPECTED_SCHEMA" ]]; then
        success "Extension '$EXT_NAME' in correct schema: $EXPECTED_SCHEMA"
    elif [[ "$ACTUAL_SCHEMA" == "unknown" ]]; then
        warn "Cannot determine schema for extension '$EXT_NAME'"
    else
        warn "Extension '$EXT_NAME' in schema: $ACTUAL_SCHEMA (expected: $EXPECTED_SCHEMA)"
    fi
done

# 6.13 Display comprehensive extension information (like \dx output)
info "Displaying comprehensive extension information..."
sudo -u postgres psql -d postgres <<'EXT_DISPLAY_EOF' 2>/dev/null || true
SELECT 
    e.extname AS "Name",
    e.extversion AS "Version",
    n.nspname AS "Schema",
    CASE 
        WHEN e.extname = 'plpgsql' THEN 'PL/pgSQL procedural language'
        WHEN e.extname = 'pg_stat_statements' THEN 'track planning and execution statistics of all SQL statements executed'
        WHEN e.extname = 'pg_buffercache' THEN 'examine the shared buffer cache'
        WHEN e.extname = 'uuid-ossp' THEN 'generate universally unique identifiers (UUIDs)'
        ELSE c.description
    END AS "Description"
FROM pg_extension e
LEFT JOIN pg_namespace n ON n.oid = e.extnamespace
LEFT JOIN pg_description c ON c.objoid = e.oid AND c.classoid = 'pg_extension'::regclass
WHERE e.extname IN ('plpgsql', 'pg_stat_statements', 'pg_buffercache', 'uuid-ossp')
ORDER BY e.extname;
EXT_DISPLAY_EOF

# ============================================================================
# HEALTH ENDPOINTS TESTS
# ============================================================================
section "7. HEALTH ENDPOINTS"

# 7.1 PostgreSQL health endpoint
info "Testing PostgreSQL health endpoint..."
if [[ -f /usr/local/bin/final-pg-health.py ]]; then
    success "PostgreSQL health script exists"
    
    if [[ -x /usr/local/bin/final-pg-health.py ]]; then
        success "PostgreSQL health script is executable"
    else
        fail "PostgreSQL health script is not executable"
    fi
else
    fail "PostgreSQL health script not found"
fi

if systemctl is-active --quiet final-pg-health.service; then
    success "PostgreSQL health service is active"
else
    warn "PostgreSQL health service is not active"
fi

PG_HEALTH_RESPONSE=$(timeout 5 curl -s http://localhost:8001 2>/dev/null || echo "")
if echo "$PG_HEALTH_RESPONSE" | grep -q "status"; then
    success "PostgreSQL health endpoint responding"
    
    if echo "$PG_HEALTH_RESPONSE" | grep -q '"status": "healthy"'; then
        success "PostgreSQL health status: healthy"
    else
        warn "PostgreSQL health status: unhealthy"
    fi
    
    if echo "$PG_HEALTH_RESPONSE" | grep -q '"role"'; then
        HEALTH_ROLE=$(echo "$PG_HEALTH_RESPONSE" | grep -o '"role": "[^"]*"' | cut -d'"' -f4)
        success "PostgreSQL health role: $HEALTH_ROLE"
    fi
else
    fail "PostgreSQL health endpoint not responding"
fi

# 7.2 PgBouncer health endpoint
info "Testing PgBouncer health endpoint..."
if [[ -f /usr/local/bin/final-pgbouncer-health.py ]]; then
    success "PgBouncer health script exists"
    
    if [[ -x /usr/local/bin/final-pgbouncer-health.py ]]; then
        success "PgBouncer health script is executable"
    else
        fail "PgBouncer health script is not executable"
    fi
else
    fail "PgBouncer health script not found"
fi

PGB_HEALTH_RESPONSE=$(timeout 5 curl -s http://localhost:8002 2>/dev/null || echo "")
if echo "$PGB_HEALTH_RESPONSE" | grep -q "service.*pgbouncer"; then
    success "PgBouncer health endpoint responding"
    
    if echo "$PGB_HEALTH_RESPONSE" | grep -q '"status": "healthy"'; then
        success "PgBouncer health status: healthy"
    else
        warn "PgBouncer health status: unhealthy"
    fi
else
    fail "PgBouncer health endpoint not responding"
fi

# ============================================================================
# FAILOVER CONFIGURATION TESTS
# ============================================================================
section "8. FAILOVER CONFIGURATION"

# 8.1 Failover script
info "Testing failover script..."
if [[ -f /usr/local/bin/pg-failover-manager.sh ]]; then
    success "Failover script exists"
    
    if [[ -x /usr/local/bin/pg-failover-manager.sh ]]; then
        success "Failover script is executable"
    else
        fail "Failover script is not executable"
    fi
else
    fail "Failover script not found"
fi

# 8.2 Failover configuration
info "Testing failover configuration..."
if [[ -f /etc/postgresql/failover.conf ]]; then
    success "Failover configuration exists"
    
    if grep -q "REPLICATION_USER=\"repuser\"" /etc/postgresql/failover.conf; then
        success "Failover config uses repuser"
    else
        warn "Failover config may not use repuser"
    fi
else
    fail "Failover configuration not found"
fi

# 8.3 Failover service (standby only)
if [[ "$CURRENT_ROLE" == "standby" ]]; then
    info "Testing failover service on standby..."
    if systemctl is-enabled --quiet pg-failover-manager.service; then
        success "Failover service is enabled"
    else
        warn "Failover service is not enabled"
    fi
    
    if systemctl is-active --quiet pg-failover-manager.service; then
        success "Failover service is active"
    else
        warn "Failover service is not active"
    fi
fi

# 8.4 Sudoers configuration
info "Testing sudoers configuration for failover..."
if [[ -f /etc/sudoers.d/postgres-failover ]]; then
    success "Sudoers file for postgres exists"
    
    SUDOERS_PERMS=$(stat -c '%a' /etc/sudoers.d/postgres-failover)
    if [[ "$SUDOERS_PERMS" == "440" ]]; then
        success "Sudoers permissions: 440"
    else
        warn "Sudoers permissions: $SUDOERS_PERMS (expected: 440)"
    fi
else
    fail "Sudoers file for postgres not found"
fi

# ============================================================================
# REPLICATION FUNCTIONALITY TESTS
# ============================================================================
if [[ "$CURRENT_ROLE" == "primary" ]] && [[ -n "$STANDBY_HOST" ]]; then
    section "9. REPLICATION FUNCTIONALITY TESTS"
    
    info "Creating test table and data on primary..."
    TEST_ID=$((RANDOM % 10000))
    
    if sudo -u postgres psql -d postgres -c "CREATE TABLE IF NOT EXISTS validation_test_$TEST_ID (id INT PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT NOW());" >/dev/null 2>&1; then
        success "Test table created on primary"
        
        if sudo -u postgres psql -d postgres -c "INSERT INTO validation_test_$TEST_ID VALUES (1, 'test_data_$TEST_ID', NOW());" >/dev/null 2>&1; then
            success "Test data inserted on primary"
            
            info "Waiting 3 seconds for replication..."
            sleep 3
            
            # Try to read from standby if accessible
            if timeout 5 sudo -u postgres psql -h "$STANDBY_HOST" -p 5432 -d postgres -c "SELECT * FROM validation_test_$TEST_ID WHERE id = 1;" >/dev/null 2>&1; then
                success "Test data replicated to standby"
            else
                warn "Cannot verify replication to standby (standby may not be accessible from this host)"
            fi
            
            # Cleanup
            sudo -u postgres psql -d postgres -c "DROP TABLE validation_test_$TEST_ID;" >/dev/null 2>&1
            success "Test table cleaned up"
        else
            fail "Failed to insert test data"
        fi
    else
        fail "Failed to create test table"
    fi
fi

# ============================================================================
# LOGGING & MONITORING TESTS
# ============================================================================
section "10. LOGGING & MONITORING"

# 10.1 Bootstrap logs
info "Testing bootstrap logs..."
if [[ -d /var/log/pg-bootstrap ]]; then
    success "Bootstrap log directory exists"
    
    if [[ -f /var/log/pg-bootstrap/bootstrap.log ]]; then
        success "Bootstrap log file exists"
        
        LOG_SIZE=$(stat -c%s /var/log/pg-bootstrap/bootstrap.log)
        if [[ "$LOG_SIZE" -gt 0 ]]; then
            success "Bootstrap log contains data (${LOG_SIZE} bytes)"
        else
            warn "Bootstrap log is empty"
        fi
    else
        fail "Bootstrap log file not found"
    fi
else
    fail "Bootstrap log directory not found"
fi

# 10.2 PostgreSQL logs
info "Testing PostgreSQL logs..."
PG_LOG_DIR="/var/log/postgresql"
if [[ -d "$PG_LOG_DIR" ]]; then
    success "PostgreSQL log directory exists"
    
    LOG_FILES=$(find "$PG_LOG_DIR" -name "postgresql-17-main.log" -o -name "postgresql-*.log" 2>/dev/null | wc -l)
    if [[ "$LOG_FILES" -gt 0 ]]; then
        success "PostgreSQL log files found"
    else
        warn "No PostgreSQL log files found"
    fi
else
    warn "PostgreSQL log directory not found at $PG_LOG_DIR"
fi

# 10.3 Check for errors in logs
info "Checking for critical errors in recent logs..."
if [[ -f /var/log/postgresql/postgresql-17-main.log ]]; then
    RECENT_ERRORS=$(tail -100 /var/log/postgresql/postgresql-17-main.log | grep -i "FATAL\|PANIC" | wc -l)
    if [[ "$RECENT_ERRORS" -eq 0 ]]; then
        success "No FATAL/PANIC errors in recent logs"
    else
        warn "Found $RECENT_ERRORS FATAL/PANIC error(s) in recent logs"
    fi
fi

# ============================================================================
# PERFORMANCE & RESOURCE TESTS
# ============================================================================
section "11. PERFORMANCE & RESOURCE CONFIGURATION"

# 11.1 shared_buffers
info "Testing PostgreSQL performance settings..."
SHARED_BUFFERS=$(sudo -u postgres psql -Atqc "SHOW shared_buffers;" 2>/dev/null || echo "unknown")
info "shared_buffers: $SHARED_BUFFERS"

# 11.2 max_connections
MAX_CONNECTIONS=$(sudo -u postgres psql -Atqc "SHOW max_connections;" 2>/dev/null || echo "unknown")
if [[ "$MAX_CONNECTIONS" == "200" ]]; then
    success "max_connections: $MAX_CONNECTIONS"
else
    warn "max_connections: $MAX_CONNECTIONS (expected: 200)"
fi

# 11.3 work_mem
WORK_MEM=$(sudo -u postgres psql -Atqc "SHOW work_mem;" 2>/dev/null || echo "unknown")
info "work_mem: $WORK_MEM"

# 11.4 Current connections
CURRENT_CONNECTIONS=$(sudo -u postgres psql -Atqc "SELECT COUNT(*) FROM pg_stat_activity;" 2>/dev/null || echo "unknown")
success "Current active connections: $CURRENT_CONNECTIONS"

# ============================================================================
# SECURITY CONFIGURATION TESTS
# ============================================================================
section "12. SECURITY CONFIGURATION"

# 12.1 SSL configuration
info "Testing SSL configuration..."
SSL_STATUS=$(sudo -u postgres psql -Atqc "SHOW ssl;" 2>/dev/null || echo "off")
if [[ "$SSL_STATUS" == "on" ]]; then
    success "SSL is enabled"
else
    warn "SSL is not enabled"
fi

# 12.2 Password encryption
info "Testing password encryption..."
PASSWORD_ENCRYPTION=$(sudo -u postgres psql -Atqc "SHOW password_encryption;" 2>/dev/null || echo "unknown")
info "Password encryption: $PASSWORD_ENCRYPTION"

# 12.3 File permissions
info "Testing file permissions..."
DATA_DIR_PERMS=$(stat -c '%a' /var/lib/postgresql/17/main 2>/dev/null || echo "unknown")
if [[ "$DATA_DIR_PERMS" == "700" ]]; then
    success "Data directory permissions: 700"
else
    warn "Data directory permissions: $DATA_DIR_PERMS (expected: 700)"
fi

# ============================================================================
# ADVANCED POSTGRESQL CONFIGURATION TESTS
# ============================================================================
section "13. ADVANCED POSTGRESQL CONFIGURATIONS"

# 13.1 Shared preload libraries
info "Testing shared_preload_libraries..."
PRELOAD_LIBS=$(sudo -u postgres psql -Atqc "SHOW shared_preload_libraries;" 2>/dev/null || echo "")
if echo "$PRELOAD_LIBS" | grep -q "pg_stat_statements"; then
    success "pg_stat_statements in shared_preload_libraries"
else
    fail "pg_stat_statements not in shared_preload_libraries"
fi

if echo "$PRELOAD_LIBS" | grep -q "pg_buffercache"; then
    success "pg_buffercache in shared_preload_libraries"
else
    fail "pg_buffercache not in shared_preload_libraries"
fi

# 13.2 WAL configuration
info "Testing WAL configuration..."
WAL_KEEP_SIZE=$(sudo -u postgres psql -Atqc "SHOW wal_keep_size;" 2>/dev/null || echo "0")
if [[ "$WAL_KEEP_SIZE" == "2048MB" || "$WAL_KEEP_SIZE" == "2GB" ]]; then
    success "wal_keep_size: $WAL_KEEP_SIZE"
else
    warn "wal_keep_size: $WAL_KEEP_SIZE (expected: 2048MB)"
fi

# 13.3 Archive mode
info "Testing archive configuration..."
ARCHIVE_MODE=$(sudo -u postgres psql -Atqc "SHOW archive_mode;" 2>/dev/null || echo "off")
if [[ "$ARCHIVE_MODE" == "on" ]]; then
    success "Archive mode enabled"
else
    warn "Archive mode is off"
fi

# 13.4 Hot standby feedback
info "Testing hot_standby_feedback..."
HOT_STANDBY_FEEDBACK=$(sudo -u postgres psql -Atqc "SHOW hot_standby_feedback;" 2>/dev/null || echo "off")
if [[ "$HOT_STANDBY_FEEDBACK" == "on" ]]; then
    success "hot_standby_feedback enabled"
else
    warn "hot_standby_feedback: $HOT_STANDBY_FEEDBACK"
fi

# 13.5 Track commit timestamp
info "Testing track_commit_timestamp..."
TRACK_COMMIT=$(sudo -u postgres psql -Atqc "SHOW track_commit_timestamp;" 2>/dev/null || echo "off")
if [[ "$TRACK_COMMIT" == "on" ]]; then
    success "track_commit_timestamp enabled"
else
    warn "track_commit_timestamp: $TRACK_COMMIT"
fi

# 13.6 Max replication slots
info "Testing max_replication_slots..."
MAX_REPL_SLOTS=$(sudo -u postgres psql -Atqc "SHOW max_replication_slots;" 2>/dev/null || echo "0")
if [[ "$MAX_REPL_SLOTS" == "10" ]]; then
    success "max_replication_slots: $MAX_REPL_SLOTS"
else
    warn "max_replication_slots: $MAX_REPL_SLOTS (expected: 10)"
fi

# 13.7 Checkpoint settings
info "Testing checkpoint configuration..."
CHECKPOINT_TARGET=$(sudo -u postgres psql -Atqc "SHOW checkpoint_completion_target;" 2>/dev/null || echo "0")
if [[ "$CHECKPOINT_TARGET" == "0.7" ]]; then
    success "checkpoint_completion_target: $CHECKPOINT_TARGET"
else
    warn "checkpoint_completion_target: $CHECKPOINT_TARGET (expected: 0.7)"
fi

# 13.8 Effective cache size
info "Testing effective_cache_size..."
EFFECTIVE_CACHE=$(sudo -u postgres psql -Atqc "SHOW effective_cache_size;" 2>/dev/null || echo "unknown")
if [[ "$EFFECTIVE_CACHE" == "1GB" ]]; then
    success "effective_cache_size: $EFFECTIVE_CACHE"
else
    warn "effective_cache_size: $EFFECTIVE_CACHE (expected: 1GB)"
fi

# 13.9 Maintenance work mem
info "Testing maintenance_work_mem..."
MAINT_WORK_MEM=$(sudo -u postgres psql -Atqc "SHOW maintenance_work_mem;" 2>/dev/null || echo "unknown")
if [[ "$MAINT_WORK_MEM" == "64MB" ]]; then
    success "maintenance_work_mem: $MAINT_WORK_MEM"
else
    warn "maintenance_work_mem: $MAINT_WORK_MEM (expected: 64MB)"
fi

# 13.10 WAL buffers
info "Testing wal_buffers..."
WAL_BUFFERS=$(sudo -u postgres psql -Atqc "SHOW wal_buffers;" 2>/dev/null || echo "unknown")
if [[ "$WAL_BUFFERS" == "16MB" ]]; then
    success "wal_buffers: $WAL_BUFFERS"
else
    info "wal_buffers: $WAL_BUFFERS"
fi

# 13.11 Listen addresses
info "Testing listen_addresses..."
LISTEN_ADDRESSES=$(sudo -u postgres psql -Atqc "SHOW listen_addresses;" 2>/dev/null || echo "unknown")
if [[ "$LISTEN_ADDRESSES" == "*" ]]; then
    success "listen_addresses: * (listening on all interfaces)"
elif [[ "$LISTEN_ADDRESSES" == "0.0.0.0" ]]; then
    success "listen_addresses: 0.0.0.0 (listening on all IPv4 interfaces)"
else
    info "listen_addresses: $LISTEN_ADDRESSES"
fi

# 13.12 Archive command
info "Testing archive_command..."
ARCHIVE_COMMAND=$(sudo -u postgres psql -Atqc "SHOW archive_command;" 2>/dev/null || echo "unknown")
if [[ "$ARCHIVE_COMMAND" == *"wal_archive"* ]]; then
    success "archive_command configured: $ARCHIVE_COMMAND"
elif [[ "$ARCHIVE_COMMAND" == "(disabled)" || "$ARCHIVE_COMMAND" == "" ]]; then
    warn "archive_command not configured"
else
    info "archive_command: $ARCHIVE_COMMAND"
fi

# 13.13 Max standby streaming delay
info "Testing max_standby_streaming_delay..."
MAX_STANDBY_DELAY=$(sudo -u postgres psql -Atqc "SHOW max_standby_streaming_delay;" 2>/dev/null || echo "unknown")
if [[ "$MAX_STANDBY_DELAY" == "30s" ]]; then
    success "max_standby_streaming_delay: $MAX_STANDBY_DELAY (default)"
else
    info "max_standby_streaming_delay: $MAX_STANDBY_DELAY"
fi

# 13.14 WAL receiver status interval
info "Testing wal_receiver_status_interval..."
WAL_RECEIVER_INTERVAL=$(sudo -u postgres psql -Atqc "SHOW wal_receiver_status_interval;" 2>/dev/null || echo "unknown")
if [[ "$WAL_RECEIVER_INTERVAL" == "10s" ]]; then
    success "wal_receiver_status_interval: $WAL_RECEIVER_INTERVAL (default)"
else
    info "wal_receiver_status_interval: $WAL_RECEIVER_INTERVAL"
fi

# ============================================================================
# COMPREHENSIVE CONFIGURATION DISPLAY
# ============================================================================
section "13B. COMPREHENSIVE CONFIGURATION SUMMARY"

info "Displaying comprehensive PostgreSQL configuration..."

# Create configuration summary
cat <<'CONFIG_SUMMARY_EOF'

╔═════════════════════════════════════════════════════════════════╗
║           COMPREHENSIVE POSTGRESQL CONFIGURATION                ║
╠═════════════════════════════════════════════════════════════════╣
CONFIG_SUMMARY_EOF

echo "║ NETWORK & CONNECTIVITY"
echo "╟─────────────────────────────────────────────────────────────────╢"
printf "║   listen_addresses:              %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW listen_addresses;" 2>/dev/null || echo "unknown")"
printf "║   max_connections:               %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW max_connections;" 2>/dev/null || echo "unknown")"
printf "║   ssl:                           %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW ssl;" 2>/dev/null || echo "unknown")"

echo "║"
echo "║ REPLICATION CONFIGURATION"
echo "╟─────────────────────────────────────────────────────────────────╢"
printf "║   wal_level:                     %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW wal_level;" 2>/dev/null || echo "unknown")"
printf "║   archive_mode:                  %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW archive_mode;" 2>/dev/null || echo "unknown")"

ARCHIVE_CMD=$(sudo -u postgres psql -Atqc "SHOW archive_command;" 2>/dev/null | cut -c1-30 || echo "unknown")
printf "║   archive_command:               %-30s ║\n" "$ARCHIVE_CMD"

printf "║   max_wal_senders:               %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW max_wal_senders;" 2>/dev/null || echo "unknown")"
printf "║   max_replication_slots:         %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW max_replication_slots;" 2>/dev/null || echo "unknown")"
printf "║   wal_keep_size:                 %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW wal_keep_size;" 2>/dev/null || echo "unknown")"

echo "║"
echo "║ STANDBY CONFIGURATION"
echo "╟─────────────────────────────────────────────────────────────────╢"
printf "║   hot_standby:                   %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW hot_standby;" 2>/dev/null || echo "unknown")"
printf "║   hot_standby_feedback:          %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW hot_standby_feedback;" 2>/dev/null || echo "unknown")"
printf "║   max_standby_streaming_delay:   %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW max_standby_streaming_delay;" 2>/dev/null || echo "unknown")"
printf "║   wal_receiver_status_interval:  %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW wal_receiver_status_interval;" 2>/dev/null || echo "unknown")"

if [[ "$CURRENT_ROLE" == "standby" ]]; then
    PRIMARY_CONN=$(sudo -u postgres psql -Atqc "SHOW primary_conninfo;" 2>/dev/null | cut -c1-30 || echo "not configured")
    printf "║   primary_conninfo:              %-30s ║\n" "$PRIMARY_CONN"
fi

echo "║"
echo "║ MEMORY CONFIGURATION"
echo "╟─────────────────────────────────────────────────────────────────╢"
printf "║   shared_buffers:                %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW shared_buffers;" 2>/dev/null || echo "unknown")"
printf "║   work_mem:                      %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW work_mem;" 2>/dev/null || echo "unknown")"
printf "║   maintenance_work_mem:          %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW maintenance_work_mem;" 2>/dev/null || echo "unknown")"
printf "║   effective_cache_size:          %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW effective_cache_size;" 2>/dev/null || echo "unknown")"
printf "║   wal_buffers:                   %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW wal_buffers;" 2>/dev/null || echo "unknown")"

echo "║"
echo "║ PERFORMANCE TUNING"
echo "╟─────────────────────────────────────────────────────────────────╢"
printf "║   checkpoint_completion_target:  %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW checkpoint_completion_target;" 2>/dev/null || echo "unknown")"
printf "║   synchronous_commit:            %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW synchronous_commit;" 2>/dev/null || echo "unknown")"
printf "║   synchronous_standby_names:     %-30s ║\n" "$(sudo -u postgres psql -Atqc "SHOW synchronous_standby_names;" 2>/dev/null | cut -c1-30 || echo "not configured")"

echo "║"
echo "║ EXTENSIONS & PRELOAD"
echo "╟─────────────────────────────────────────────────────────────────╢"
PRELOAD=$(sudo -u postgres psql -Atqc "SHOW shared_preload_libraries;" 2>/dev/null | cut -c1-30 || echo "none")
printf "║   shared_preload_libraries:      %-30s ║\n" "$PRELOAD"

echo "╚═════════════════════════════════════════════════════════════════╝"

# Additional validation for critical settings
info "Validating critical configuration parameters..."

# Validate listen_addresses
LISTEN_ADDR=$(sudo -u postgres psql -Atqc "SHOW listen_addresses;" 2>/dev/null || echo "unknown")
if [[ "$LISTEN_ADDR" == "*" || "$LISTEN_ADDR" == "0.0.0.0" ]]; then
    success "listen_addresses correctly configured for replication"
elif [[ "$LISTEN_ADDR" == "localhost" ]]; then
    fail "listen_addresses is 'localhost' - replication will not work"
else
    warn "listen_addresses: $LISTEN_ADDR - verify this is correct for your setup"
fi

# Validate wal_level
WAL_LEVEL_CHECK=$(sudo -u postgres psql -Atqc "SHOW wal_level;" 2>/dev/null || echo "unknown")
if [[ "$WAL_LEVEL_CHECK" == "replica" ]]; then
    success "wal_level: replica (correct for streaming replication)"
elif [[ "$WAL_LEVEL_CHECK" == "logical" ]]; then
    success "wal_level: logical (supports replication and logical decoding)"
else
    fail "wal_level: $WAL_LEVEL_CHECK (should be 'replica' or 'logical')"
fi

# Validate hot_standby
HOT_STANDBY_CHECK=$(sudo -u postgres psql -Atqc "SHOW hot_standby;" 2>/dev/null || echo "off")
if [[ "$HOT_STANDBY_CHECK" == "on" ]]; then
    success "hot_standby: on (read queries allowed on standby)"
else
    warn "hot_standby: $HOT_STANDBY_CHECK (standby will be read-only without queries)"
fi

# Validate archive_mode
ARCHIVE_MODE_CHECK=$(sudo -u postgres psql -Atqc "SHOW archive_mode;" 2>/dev/null || echo "off")
if [[ "$ARCHIVE_MODE_CHECK" == "on" ]]; then
    success "archive_mode: on (WAL archiving enabled)"
    
    # Check if archive_command is actually configured
    ARCHIVE_CMD_CHECK=$(sudo -u postgres psql -Atqc "SHOW archive_command;" 2>/dev/null || echo "")
    if [[ -n "$ARCHIVE_CMD_CHECK" && "$ARCHIVE_CMD_CHECK" != "(disabled)" ]]; then
        success "archive_command is configured"
    else
        warn "archive_mode is on but archive_command is not configured"
    fi
else
    info "archive_mode: $ARCHIVE_MODE_CHECK (WAL archiving disabled)"
fi

# ============================================================================
# LOGGING CONFIGURATION TESTS
# ============================================================================
section "14. LOGGING CONFIGURATION"

# 14.1 Log replication commands
info "Testing log_replication_commands..."
LOG_REPL_CMDS=$(sudo -u postgres psql -Atqc "SHOW log_replication_commands;" 2>/dev/null || echo "off")
if [[ "$LOG_REPL_CMDS" == "on" ]]; then
    success "log_replication_commands enabled"
else
    warn "log_replication_commands: $LOG_REPL_CMDS"
fi

# 14.2 Log checkpoints
info "Testing log_checkpoints..."
LOG_CHECKPOINTS=$(sudo -u postgres psql -Atqc "SHOW log_checkpoints;" 2>/dev/null || echo "off")
if [[ "$LOG_CHECKPOINTS" == "on" ]]; then
    success "log_checkpoints enabled"
else
    warn "log_checkpoints: $LOG_CHECKPOINTS"
fi

# 14.3 Log connections
info "Testing log_connections..."
LOG_CONNECTIONS=$(sudo -u postgres psql -Atqc "SHOW log_connections;" 2>/dev/null || echo "off")
if [[ "$LOG_CONNECTIONS" == "on" ]]; then
    success "log_connections enabled"
else
    warn "log_connections: $LOG_CONNECTIONS"
fi

# 14.4 Log disconnections
info "Testing log_disconnections..."
LOG_DISCONN=$(sudo -u postgres psql -Atqc "SHOW log_disconnections;" 2>/dev/null || echo "off")
if [[ "$LOG_DISCONN" == "on" ]]; then
    success "log_disconnections enabled"
else
    warn "log_disconnections: $LOG_DISCONN"
fi

# 14.5 Log lock waits
info "Testing log_lock_waits..."
LOG_LOCK_WAITS=$(sudo -u postgres psql -Atqc "SHOW log_lock_waits;" 2>/dev/null || echo "off")
if [[ "$LOG_LOCK_WAITS" == "on" ]]; then
    success "log_lock_waits enabled"
else
    warn "log_lock_waits: $LOG_LOCK_WAITS"
fi

# 14.6 Log temp files
info "Testing log_temp_files..."
LOG_TEMP=$(sudo -u postgres psql -Atqc "SHOW log_temp_files;" 2>/dev/null || echo "-1")
if [[ "$LOG_TEMP" == "0" ]]; then
    success "log_temp_files: $LOG_TEMP (logs all temp files)"
else
    info "log_temp_files: $LOG_TEMP"
fi

# ============================================================================
# BOOTSTRAP SENTINEL FILES TESTS
# ============================================================================
section "15. BOOTSTRAP SENTINEL FILES"

# 15.1 Bootstrap completion sentinel
info "Testing bootstrap sentinel files..."
if [[ -f /var/lib/postgresql/.bootstrap/done ]]; then
    success "Bootstrap completion sentinel exists"
else
    warn "Bootstrap completion sentinel not found"
fi

# 15.2 Role-specific sentinels
if [[ "$CURRENT_ROLE" == "primary" ]]; then
    if [[ -f /var/lib/postgresql/.bootstrap/primary.init ]]; then
        success "Primary initialization sentinel exists"
    else
        warn "Primary initialization sentinel not found"
    fi
elif [[ "$CURRENT_ROLE" == "standby" ]]; then
    if [[ -f /var/lib/postgresql/.bootstrap/standby.cloned ]]; then
        success "Standby clone sentinel exists"
    else
        warn "Standby clone sentinel not found"
    fi
fi

# 15.3 Sentinel directory permissions
if [[ -d /var/lib/postgresql/.bootstrap ]]; then
    SENTINEL_PERMS=$(stat -c '%a' /var/lib/postgresql/.bootstrap)
    if [[ "$SENTINEL_PERMS" == "755" ]]; then
        success "Sentinel directory permissions: 755"
    else
        warn "Sentinel directory permissions: $SENTINEL_PERMS"
    fi
fi

# ============================================================================
# CLOUD CONFIGURATION TESTS
# ============================================================================
section "16. CLOUD CONFIGURATION"

# 16.1 Cloud-init hostname preservation
info "Testing cloud-init configuration..."
if [[ -f /etc/cloud/cloud.cfg ]]; then
    if grep -q "preserve_hostname: true" /etc/cloud/cloud.cfg; then
        success "Cloud-init configured to preserve hostname"
    else
        warn "Cloud-init hostname preservation not configured"
    fi
else
    info "Cloud-init not installed (not running in cloud environment)"
fi

# ============================================================================
# PACKAGE DEPENDENCIES TESTS
# ============================================================================
section "17. PACKAGE DEPENDENCIES"

# 17.1 Required packages
info "Testing required packages..."
REQUIRED_PKGS=("wget" "curl" "jq" "openssl" "lsof" "bc" "socat" "python3")
for pkg in "${REQUIRED_PKGS[@]}"; do
    if command -v "$pkg" >/dev/null 2>&1; then
        success "Package '$pkg' installed"
    else
        fail "Package '$pkg' not found"
    fi
done

# 17.2 PostgreSQL client tools
info "Testing PostgreSQL client tools..."
if command -v psql >/dev/null 2>&1; then
    success "psql client installed"
else
    fail "psql client not found"
fi

if command -v pg_basebackup >/dev/null 2>&1; then
    success "pg_basebackup installed"
else
    fail "pg_basebackup not found"
fi

# ============================================================================
# STANDBY CONFIGURATION TESTS
# ============================================================================
if [[ "$CURRENT_ROLE" == "standby" ]]; then
    section "18. STANDBY-SPECIFIC CONFIGURATION"
    
    # 18.1 Standby signal file
    info "Testing standby signal file..."
    if [[ -f /var/lib/postgresql/17/main/standby.signal ]]; then
        success "standby.signal file exists"
    else
        fail "standby.signal file not found"
    fi
    
    # 18.2 Primary connection info
    info "Testing primary_conninfo..."
    PRIMARY_CONNINFO=$(sudo -u postgres psql -Atqc "SHOW primary_conninfo;" 2>/dev/null || echo "")
    if echo "$PRIMARY_CONNINFO" | grep -q "repuser"; then
        success "primary_conninfo uses repuser"
    else
        fail "primary_conninfo doesn't use repuser"
    fi
    
    if echo "$PRIMARY_CONNINFO" | grep -q "application_name=standby_sync"; then
        success "primary_conninfo has application_name=standby_sync"
    else
        warn "primary_conninfo missing application_name=standby_sync"
    fi
    
    # 18.3 Recovery target timeline
    info "Testing recovery_target_timeline..."
    RECOVERY_TIMELINE=$(sudo -u postgres psql -Atqc "SHOW recovery_target_timeline;" 2>/dev/null || echo "")
    if [[ "$RECOVERY_TIMELINE" == "latest" ]]; then
        success "recovery_target_timeline: latest"
    else
        warn "recovery_target_timeline: $RECOVERY_TIMELINE"
    fi
fi

# ============================================================================
# NETWORK CONNECTIVITY TESTS
# ============================================================================
section "19. NETWORK CONNECTIVITY"

# 19.1 PostgreSQL listening on all interfaces
info "Testing PostgreSQL network binding..."
if netstat -tln 2>/dev/null | grep -q "0.0.0.0:5432"; then
    success "PostgreSQL listening on all interfaces (0.0.0.0:5432)"
elif ss -tln 2>/dev/null | grep -q "0.0.0.0:5432"; then
    success "PostgreSQL listening on all interfaces (0.0.0.0:5432)"
else
    warn "PostgreSQL may not be listening on all interfaces"
fi

# 19.2 PgBouncer listening on all interfaces
info "Testing PgBouncer network binding..."
if netstat -tln 2>/dev/null | grep -q "0.0.0.0:6432"; then
    success "PgBouncer listening on all interfaces (0.0.0.0:6432)"
elif ss -tln 2>/dev/null | grep -q "0.0.0.0:6432"; then
    success "PgBouncer listening on all interfaces (0.0.0.0:6432)"
else
    warn "PgBouncer may not be listening on all interfaces"
fi

# 19.3 Health endpoints listening
info "Testing health endpoints network binding..."
if netstat -tln 2>/dev/null | grep -q ":8001"; then
    success "PostgreSQL health endpoint listening on port 8001"
elif ss -tln 2>/dev/null | grep -q ":8001"; then
    success "PostgreSQL health endpoint listening on port 8001"
else
    warn "PostgreSQL health endpoint may not be listening"
fi

if netstat -tln 2>/dev/null | grep -q ":8002"; then
    success "PgBouncer health endpoint listening on port 8002"
elif ss -tln 2>/dev/null | grep -q ":8002"; then
    success "PgBouncer health endpoint listening on port 8002"
else
    warn "PgBouncer health endpoint may not be listening"
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================
section "VALIDATION SUMMARY"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    VALIDATION RESULTS                          ║"
echo "╠════════════════════════════════════════════════════════════════╣"
printf "║ ${GREEN}Passed Tests:${NC}  %-45s ║\n" "$PASSED_TESTS / $TOTAL_TESTS"
printf "║ ${RED}Failed Tests:${NC}  %-45s ║\n" "$FAILED_TESTS"
printf "║ ${YELLOW}Warnings:${NC}      %-45s ║\n" "$WARNINGS"
printf "║ ${CYAN}Current Role:${NC}  %-45s ║\n" "$CURRENT_ROLE"
printf "║ ${CYAN}PostgreSQL:${NC}    %-45s ║\n" "$PG_VERSION"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$FAILED_TESTS" -gt 0 ]]; then
    echo -e "${RED}Failed Tests:${NC}"
    for test in "${FAILED_TEST_NAMES[@]}"; do
        echo -e "  ${RED}✗${NC} $test"
    done
    echo ""
fi

# Calculate success percentage
if [[ "$TOTAL_TESTS" -gt 0 ]]; then
    SUCCESS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    
    if [[ "$SUCCESS_RATE" -ge 90 ]]; then
        echo -e "${GREEN}🎉 SUCCESS RATE: ${SUCCESS_RATE}% - PRODUCTION READY!${NC}"
        exit 0
    elif [[ "$SUCCESS_RATE" -ge 75 ]]; then
        echo -e "${YELLOW}⚠️  SUCCESS RATE: ${SUCCESS_RATE}% - Review warnings before production${NC}"
        exit 1
    else
        echo -e "${RED}❌ SUCCESS RATE: ${SUCCESS_RATE}% - Critical issues found${NC}"
        exit 2
    fi
else
    echo -e "${RED}❌ No tests were executed${NC}"
    exit 3
fi