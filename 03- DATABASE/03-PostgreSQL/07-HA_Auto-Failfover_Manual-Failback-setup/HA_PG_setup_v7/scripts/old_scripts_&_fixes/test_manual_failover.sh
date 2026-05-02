#!/bin/bash
# PostgreSQL HA Manual Failover Test Script
# This script helps test manual failover scenarios

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

# Configuration
PRIMARY_HOST="${1:-192.168.14.21}"
STANDBY_HOST="${2:-192.168.14.22}"
TEST_DB="failover_test"

echo "=========================================="
echo "PostgreSQL HA Manual Failover Test"
echo "=========================================="
echo "Current Primary: $PRIMARY_HOST"
echo "Current Standby: $STANDBY_HOST"
echo ""

# Pre-failover checks
pre_failover_checks() {
    info "Running pre-failover checks..."
    
    # Check current roles
    local primary_role standby_role
    primary_role=$(sudo -u postgres psql -h "$PRIMARY_HOST" -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
    standby_role=$(sudo -u postgres psql -h "$STANDBY_HOST" -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
    
    if [[ "$primary_role" != "f" ]]; then
        error "Primary ($PRIMARY_HOST) is not in primary mode. Current status: $primary_role"
        return 1
    fi
    
    if [[ "$standby_role" != "t" ]]; then
        error "Standby ($STANDBY_HOST) is not in standby mode. Current status: $standby_role"
        return 1
    fi
    
    info "✓ Roles are correct: Primary ($PRIMARY_HOST) and Standby ($STANDBY_HOST)"
    
    # Check replication status
    local repl_count
    repl_count=$(sudo -u postgres psql -h "$PRIMARY_HOST" -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
    
    if [[ "$repl_count" -eq 0 ]]; then
        error "No active replication connections"
        return 1
    fi
    
    info "✓ Active replication connections: $repl_count"
    
    # Check replication lag
    local primary_lsn standby_lsn lag_bytes
    primary_lsn=$(sudo -u postgres psql -h "$PRIMARY_HOST" -Atqc "SELECT pg_current_wal_lsn();" 2>/dev/null)
    standby_lsn=$(sudo -u postgres psql -h "$STANDBY_HOST" -Atqc "SELECT pg_last_wal_replay_lsn();" 2>/dev/null)
    
    if [[ -n "$primary_lsn" && -n "$standby_lsn" ]]; then
        lag_bytes=$(sudo -u postgres psql -h "$PRIMARY_HOST" -Atqc "SELECT pg_wal_lsn_diff('$primary_lsn', '$standby_lsn');" 2>/dev/null)
        info "✓ Current replication lag: $lag_bytes bytes"
        
        if [[ "$lag_bytes" -gt 10485760 ]]; then  # 10MB
            warn "High replication lag detected. Consider waiting for sync before failover."
        fi
    fi
    
    return 0
}

# Create test data before failover
create_test_data() {
    info "Creating test data before failover..."
    
    # Create test database and table
    sudo -u postgres psql -h "$PRIMARY_HOST" -c "CREATE DATABASE IF NOT EXISTS $TEST_DB;" 2>/dev/null || true
    sudo -u postgres psql -h "$PRIMARY_HOST" -d "$TEST_DB" -c "
        CREATE TABLE IF NOT EXISTS failover_test (
            id SERIAL PRIMARY KEY,
            data TEXT,
            created_at TIMESTAMP DEFAULT NOW()
        );" 2>/dev/null || true
    
    # Insert test record
    local test_data="Pre-failover test data $(date '+%Y-%m-%d %H:%M:%S')"
    local test_id
    test_id=$(sudo -u postgres psql -h "$PRIMARY_HOST" -d "$TEST_DB" -Atqc "
        INSERT INTO failover_test (data) VALUES ('$test_data') RETURNING id;" 2>/dev/null)
    
    info "✓ Created test record with ID: $test_id"
    
    # Wait for replication
    sleep 2
    
    # Verify on standby
    local standby_data
    standby_data=$(sudo -u postgres psql -h "$STANDBY_HOST" -d "$TEST_DB" -Atqc "
        SELECT data FROM failover_test WHERE id = $test_id;" 2>/dev/null || echo "")
    
    if [[ "$standby_data" == "$test_data" ]]; then
        info "✓ Test data successfully replicated to standby"
        echo "$test_id"  # Return test ID for later verification
    else
        error "Test data not replicated to standby"
        return 1
    fi
}

# Perform manual failover
perform_failover() {
    local test_id="$1"
    
    warn "=========================================="
    warn "STARTING MANUAL FAILOVER PROCESS"
    warn "=========================================="
    
    info "Step 1: Stopping primary PostgreSQL service..."
    echo "Run this command on PRIMARY server ($PRIMARY_HOST):"
    echo "  sudo systemctl stop postgresql"
    echo ""
    read -p "Press Enter after stopping primary PostgreSQL service..."
    
    info "Step 2: Promoting standby to primary..."
    echo "Run this command on STANDBY server ($STANDBY_HOST):"
    echo "  sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf standby promote"
    echo ""
    read -p "Press Enter after promoting standby..."
    
    info "Step 3: Verifying new primary..."
    local attempts=0
    local max_attempts=10
    local promoted=false
    
    while [[ $attempts -lt $max_attempts ]]; do
        local new_primary_role
        new_primary_role=$(sudo -u postgres psql -h "$STANDBY_HOST" -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
        
        if [[ "$new_primary_role" == "f" ]]; then
            promoted=true
            break
        fi
        
        attempts=$((attempts + 1))
        sleep 2
    done
    
    if [[ "$promoted" == true ]]; then
        info "✓ Standby successfully promoted to primary"
    else
        error "✗ Standby promotion failed or timed out"
        return 1
    fi
    
    # Test write capability on new primary
    info "Step 4: Testing write capability on new primary..."
    local post_failover_data="Post-failover test data $(date '+%Y-%m-%d %H:%M:%S')"
    local new_test_id
    new_test_id=$(sudo -u postgres psql -h "$STANDBY_HOST" -d "$TEST_DB" -Atqc "
        INSERT INTO failover_test (data) VALUES ('$post_failover_data') RETURNING id;" 2>/dev/null || echo "")
    
    if [[ -n "$new_test_id" ]]; then
        info "✓ New primary accepts writes. New record ID: $new_test_id"
    else
        error "✗ New primary cannot accept writes"
        return 1
    fi
    
    # Verify data consistency
    info "Step 5: Verifying data consistency..."
    local pre_failover_data
    pre_failover_data=$(sudo -u postgres psql -h "$STANDBY_HOST" -d "$TEST_DB" -Atqc "
        SELECT data FROM failover_test WHERE id = $test_id;" 2>/dev/null || echo "")
    
    if [[ -n "$pre_failover_data" ]]; then
        info "✓ Pre-failover data is intact on new primary"
    else
        error "✗ Pre-failover data missing on new primary"
        return 1
    fi
    
    # Show current cluster status
    info "Step 6: Current cluster status:"
    sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null || warn "Cannot get cluster status"
    
    return 0
}

# Post-failover setup (optional)
setup_old_primary_as_standby() {
    warn "=========================================="
    warn "SETTING UP OLD PRIMARY AS NEW STANDBY"
    warn "=========================================="
    
    info "To set up the old primary ($PRIMARY_HOST) as a new standby:"
    echo ""
    echo "1. On the OLD PRIMARY server ($PRIMARY_HOST), run:"
    echo "   sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf node rejoin -d 'host=$STANDBY_HOST user=repmgr dbname=repmgr' --force-rewind"
    echo ""
    echo "2. Or, if that fails, clone from the new primary:"
    echo "   sudo systemctl stop postgresql"
    echo "   sudo -u postgres rm -rf /var/lib/postgresql/17/main/*"
    echo "   sudo -u postgres repmgr -h $STANDBY_HOST -U repmgr -d repmgr -f /etc/repmgr/repmgr.conf standby clone"
    echo "   sudo systemctl start postgresql"
    echo "   sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf standby register --force"
    echo ""
}

# Cleanup
cleanup() {
    info "Cleaning up test data..."
    # Try to connect to either host to cleanup
    if sudo -u postgres psql -h "$STANDBY_HOST" -c "DROP DATABASE IF EXISTS $TEST_DB;" 2>/dev/null; then
        info "✓ Cleanup completed on $STANDBY_HOST"
    elif sudo -u postgres psql -h "$PRIMARY_HOST" -c "DROP DATABASE IF EXISTS $TEST_DB;" 2>/dev/null; then
        info "✓ Cleanup completed on $PRIMARY_HOST"
    else
        warn "Could not cleanup test database"
    fi
}

# Main execution
main() {
    echo "This script will guide you through a manual failover test."
    echo ""
    warn "WARNING: This will cause a brief service interruption!"
    echo ""
    read -p "Do you want to continue? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        info "Failover test cancelled."
        exit 0
    fi
    
    # Run pre-checks
    if ! pre_failover_checks; then
        error "Pre-failover checks failed. Aborting."
        exit 1
    fi
    
    # Create test data
    local test_id
    if ! test_id=$(create_test_data); then
        error "Failed to create test data. Aborting."
        exit 1
    fi
    
    # Perform failover
    if perform_failover "$test_id"; then
        info "=========================================="
        info "MANUAL FAILOVER TEST COMPLETED SUCCESSFULLY!"
        info "=========================================="
        info "New primary: $STANDBY_HOST"
        info "Old primary: $PRIMARY_HOST (now offline)"
        echo ""
        setup_old_primary_as_standby
    else
        error "Manual failover test failed!"
        exit 1
    fi
    
    # Cleanup
    if [[ "${CLEANUP:-true}" != "false" ]]; then
        cleanup
    fi
}

# Handle help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [PRIMARY_HOST] [STANDBY_HOST]"
    echo ""
    echo "This script guides you through a manual failover test."
    echo ""
    echo "Options:"
    echo "  PRIMARY_HOST    Current primary host (default: 192.168.14.21)"
    echo "  STANDBY_HOST    Current standby host (default: 192.168.14.22)"
    echo ""
    echo "Environment variables:"
    echo "  CLEANUP=false   Skip cleanup of test data"
    echo ""
    exit 0
fi

main "$@"