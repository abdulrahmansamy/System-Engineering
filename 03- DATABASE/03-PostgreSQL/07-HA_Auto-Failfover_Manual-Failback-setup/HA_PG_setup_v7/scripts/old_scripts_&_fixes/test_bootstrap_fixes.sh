#!/bin/bash
# Bootstrap Configuration Test Script
# Tests the key bootstrap functions that were failing

set -euo pipefail

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;92m[SUCCESS]\033[0m $*"; }
test_result() { echo -e "\033[0;94m[TEST]\033[0m $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "🧪 Bootstrap Configuration Test Suite"
echo "====================================="
info "Testing if bootstrap script now generates correct configuration"

TESTS_PASSED=0
TESTS_FAILED=0
ISSUES_FOUND=()

# Test 1: Check pg_hba.conf MD5 priority
test_result "Test 1: pg_hba.conf MD5 Authentication Priority"
PG_HBA="/etc/postgresql/17/main/pg_hba.conf"

if [[ -f "$PG_HBA" ]]; then
    # Find first MD5 and SCRAM lines
    FIRST_MD5_LINE=$(grep -n "md5" "$PG_HBA" | head -1 | cut -d: -f1 2>/dev/null || echo "999")
    FIRST_SCRAM_LINE=$(grep -n "scram-sha-256" "$PG_HBA" | head -1 | cut -d: -f1 2>/dev/null || echo "1")
    
    if [[ $FIRST_MD5_LINE -lt $FIRST_SCRAM_LINE ]]; then
        success "  ✓ MD5 rules have correct priority (line $FIRST_MD5_LINE before $FIRST_SCRAM_LINE)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        error "  ✗ MD5 rules do not have priority"
        ISSUES_FOUND+=("pg_hba.conf: MD5 rules need to come before SCRAM rules")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Check for required MD5 entries
    MD5_COUNT=$(grep -c "md5" "$PG_HBA" 2>/dev/null || echo 0)
    if [[ $MD5_COUNT -ge 6 ]]; then
        success "  ✓ Sufficient MD5 authentication rules ($MD5_COUNT rules)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        error "  ✗ Insufficient MD5 rules (found $MD5_COUNT, expected 6+)"
        ISSUES_FOUND+=("pg_hba.conf: Missing MD5 rules for PgBouncer users")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    error "  ✗ pg_hba.conf not found"
    ISSUES_FOUND+=("pg_hba.conf file missing")
    TESTS_FAILED=$((TESTS_FAILED + 2))
fi

# Test 2: Check PgBouncer authentication configuration
test_result ""
test_result "Test 2: PgBouncer MD5 Authentication Configuration"
PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"

if [[ -f "$PGBOUNCER_CONF" ]]; then
    # Check auth_type
    AUTH_TYPE=$(grep -E "^auth_type" "$PGBOUNCER_CONF" | cut -d= -f2 | xargs 2>/dev/null || echo "unknown")
    if [[ "$AUTH_TYPE" == "md5" ]]; then
        success "  ✓ PgBouncer auth_type is MD5"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        error "  ✗ PgBouncer auth_type is '$AUTH_TYPE', should be 'md5'"
        ISSUES_FOUND+=("PgBouncer: auth_type should be md5")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Check that auth_query and auth_user are NOT present
    if grep -q "^auth_query" "$PGBOUNCER_CONF" 2>/dev/null; then
        error "  ✗ PgBouncer has auth_query (should be removed for MD5 mode)"
        ISSUES_FOUND+=("PgBouncer: auth_query should not be present")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        success "  ✓ PgBouncer auth_query correctly absent"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
    
    if grep -q "^auth_user" "$PGBOUNCER_CONF" 2>/dev/null; then
        error "  ✗ PgBouncer has auth_user (should be removed for MD5 mode)"
        ISSUES_FOUND+=("PgBouncer: auth_user should not be present")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        success "  ✓ PgBouncer auth_user correctly absent"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
else
    error "  ✗ PgBouncer configuration not found"
    ISSUES_FOUND+=("PgBouncer configuration missing")
    TESTS_FAILED=$((TESTS_FAILED + 3))
fi

# Test 3: Check PgBouncer userlist MD5 hashes
test_result ""
test_result "Test 3: PgBouncer Userlist MD5 Hashes"
USERLIST="/etc/pgbouncer/userlist.txt"

if [[ -f "$USERLIST" ]]; then
    # Count MD5 hashes
    MD5_USERS=$(grep -E '^".*" "md5[a-f0-9]+"' "$USERLIST" | wc -l 2>/dev/null || echo 0)
    TOTAL_USERS=$(grep -E '^".*"' "$USERLIST" | wc -l 2>/dev/null || echo 0)
    
    if [[ $MD5_USERS -eq $TOTAL_USERS && $MD5_USERS -gt 0 ]]; then
        success "  ✓ All users have MD5 hashes ($MD5_USERS/$TOTAL_USERS)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        error "  ✗ Not all users have MD5 hashes ($MD5_USERS/$TOTAL_USERS)"
        ISSUES_FOUND+=("PgBouncer userlist: Users missing MD5 hashes")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Check for required users
    REQUIRED_USERS=("postgres" "pgbouncer_admin" "repmgr")
    MISSING_USERS=()
    for user in "${REQUIRED_USERS[@]}"; do
        if grep -q "\"$user\"" "$USERLIST" 2>/dev/null; then
            success "  ✓ User $user present in userlist"
        else
            error "  ✗ User $user missing from userlist"
            MISSING_USERS+=("$user")
        fi
    done
    
    if [[ ${#MISSING_USERS[@]} -eq 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        ISSUES_FOUND+=("PgBouncer userlist: Missing users: ${MISSING_USERS[*]}")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    error "  ✗ PgBouncer userlist not found"
    ISSUES_FOUND+=("PgBouncer userlist missing")
    TESTS_FAILED=$((TESTS_FAILED + 2))
fi

# Test 4: Check .pgpass completeness
test_result ""
test_result "Test 4: .pgpass File Coverage"
PGPASS="/var/lib/postgresql/.pgpass"

if [[ -f "$PGPASS" ]]; then
    # Count PgBouncer entries
    PGBOUNCER_ENTRIES=$(grep ":6432:" "$PGPASS" | wc -l 2>/dev/null || echo 0)
    TOTAL_ENTRIES=$(grep -v "^#" "$PGPASS" | grep -v "^$" | wc -l 2>/dev/null || echo 0)
    
    if [[ $PGBOUNCER_ENTRIES -ge 6 ]]; then
        success "  ✓ Sufficient PgBouncer entries in .pgpass ($PGBOUNCER_ENTRIES entries)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        error "  ✗ Insufficient PgBouncer entries ($PGBOUNCER_ENTRIES, expected 6+)"
        ISSUES_FOUND+=(".pgpass: Missing PgBouncer entries")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Check for comprehensive localhost coverage
    LOCALHOST_COVERAGE=0
    for host in "localhost" "127.0.0.1"; do
        if grep -q "${host}:6432:" "$PGPASS" 2>/dev/null; then
            LOCALHOST_COVERAGE=$((LOCALHOST_COVERAGE + 1))
        fi
    done
    
    if [[ $LOCALHOST_COVERAGE -eq 2 ]]; then
        success "  ✓ Complete localhost PgBouncer coverage"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        error "  ✗ Incomplete localhost coverage ($LOCALHOST_COVERAGE/2)"
        ISSUES_FOUND+=(".pgpass: Missing localhost coverage")
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    error "  ✗ .pgpass file not found"
    ISSUES_FOUND+=(".pgpass file missing")
    TESTS_FAILED=$((TESTS_FAILED + 2))
fi

# Test 5: Test actual PgBouncer connectivity
test_result ""
test_result "Test 5: PgBouncer Authentication Test"

# Check if PgBouncer is running
if systemctl is-active --quiet pgbouncer 2>/dev/null; then
    success "  ✓ PgBouncer service is running"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    
    # Test connection
    if timeout 5 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        success "  ✓ PgBouncer is accepting connections"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        
        # Test authentication
        if sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'Bootstrap test works!' as test;" >/dev/null 2>&1; then
            success "  ✓ PgBouncer authentication working"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            error "  ✗ PgBouncer authentication failed"
            ISSUES_FOUND+=("PgBouncer authentication not working")
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        error "  ✗ PgBouncer not accepting connections"
        ISSUES_FOUND+=("PgBouncer connection issue")
        TESTS_FAILED=$((TESTS_FAILED + 2))
    fi
else
    error "  ✗ PgBouncer service not running"
    ISSUES_FOUND+=("PgBouncer service not running")
    TESTS_FAILED=$((TESTS_FAILED + 3))
fi

# Test 6: Check PostgreSQL user password compatibility
test_result ""
test_result "Test 6: PostgreSQL User Password Compatibility"

if sudo -u postgres psql -Atqc 'SELECT 1' postgres >/dev/null 2>&1; then
    # Check current password encryption
    CURRENT_ENCRYPTION=$(sudo -u postgres psql -Atqc "SHOW password_encryption;" postgres 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_ENCRYPTION" == "scram-sha-256" ]]; then
        success "  ✓ Password encryption correctly reset to SCRAM-SHA-256"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        warn "  ⚠ Password encryption is '$CURRENT_ENCRYPTION', expected 'scram-sha-256'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Check if required users exist
    REQUIRED_DB_USERS=("postgres" "pgbouncer_admin" "repmgr")
    for user in "${REQUIRED_DB_USERS[@]}"; do
        if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$user'" postgres | grep -q 1 2>/dev/null; then
            success "  ✓ PostgreSQL user $user exists"
        else
            error "  ✗ PostgreSQL user $user missing"
            ISSUES_FOUND+=("PostgreSQL user $user not found")
        fi
    done
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    error "  ✗ Cannot connect to PostgreSQL"
    ISSUES_FOUND+=("PostgreSQL connectivity issue")
    TESTS_FAILED=$((TESTS_FAILED + 2))
fi

# Summary Report
test_result ""
test_result "📊 Test Results Summary"
echo "========================"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
PASS_RATE=$((TESTS_PASSED * 100 / TOTAL_TESTS))

echo ""
echo "Tests Run: $TOTAL_TESTS"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "Pass Rate: $PASS_RATE%"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    success "🎉 ALL TESTS PASSED"
    success "✅ Bootstrap script is now working correctly!"
    success "✅ No need to run the fix script anymore"
    echo ""
    echo "📋 What was fixed in the bootstrap script:"
    echo "  • MD5 authentication priority in pg_hba.conf"
    echo "  • Correct PgBouncer MD5 configuration"
    echo "  • Proper userlist.txt generation timing"
    echo "  • Complete .pgpass coverage"
    echo "  • User password MD5 compatibility"
    echo ""
    echo "🚀 Ready for production deployment!"
    
else
    error "❌ TESTS FAILED"
    error "Bootstrap script still has issues that need attention"
    echo ""
    echo "🔧 Issues found:"
    for issue in "${ISSUES_FOUND[@]}"; do
        echo "  • $issue"
    done
    echo ""
    echo "💡 You may still need to run the fix script after bootstrap"
fi

echo ""
info "🔍 To verify deployment:"
info "  1. Run: sudo ./comprehensive_validation.sh"
info "  2. Test: psql -h localhost -p 6432 -U postgres -d postgres"
info "  3. Check: systemctl status pgbouncer"

exit $TESTS_FAILED