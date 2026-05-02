#!/bin/bash
# PostgreSQL HA Bootstrap Validation Script
# Tests the bootstrap script and validates the cluster setup
# Version: 1.0.0
# Usage: ./validate_bootstrap.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Logging functions
info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[PASS]${NC} %s\n" "$*"; ((TESTS_PASSED++)); }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; ((TESTS_FAILED++)); }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

test_function() {
    local test_name="$1"
    local test_command="$2"
    ((TESTS_TOTAL++))
    
    info "Testing: $test_name"
    if eval "$test_command"; then
        success "$test_name"
        return 0
    else
        fail "$test_name"
        return 1
    fi
}

# Test script syntax
test_syntax() {
    bash -n /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/postgresql_ha_bootstrap_clean.sh
}

# Test required functions exist
test_functions_exist() {
    local script_content=$(cat /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/postgresql_ha_bootstrap_clean.sh)
    
    local required_functions=(
        "detect_configuration"
        "load_secrets"
        "install_packages" 
        "configure_postgresql"
        "configure_pg_hba"
        "generate_repmgr_conf"
        "setup_pgpass"
        "configure_pgbouncer"
        "create_pgbouncer_userlist"
        "init_primary"
        "init_standby"
        "sync_database_passwords"
        "setup_services"
        "setup_health_endpoints"
        "start_services"
        "main"
    )
    
    local missing_functions=()
    for func in "${required_functions[@]}"; do
        if ! echo "$script_content" | grep -q "^${func}()"; then
            missing_functions+=("$func")
        fi
    done
    
    if [[ ${#missing_functions[@]} -eq 0 ]]; then
        return 0
    else
        echo "Missing functions: ${missing_functions[*]}"
        return 1
    fi
}

# Test error handling
test_error_handling() {
    grep -q "set -euo pipefail" /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/postgresql_ha_bootstrap_clean.sh
}

# Test logging setup
test_logging() {
    local script_content=$(cat /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/postgresql_ha_bootstrap_clean.sh)
    echo "$script_content" | grep -q "log()" && 
    echo "$script_content" | grep -q "info()" &&
    echo "$script_content" | grep -q "error()" &&
    echo "$script_content" | grep -q "success()"
}

# Test metadata configuration
test_metadata_config() {
    local script_content=$(cat /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/postgresql_ha_bootstrap_clean.sh)
    echo "$script_content" | grep -q "get_metadata" &&
    echo "$script_content" | grep -q "pg_role" &&
    echo "$script_content" | grep -q "pg_cluster_id"
}

# Test secret manager integration
test_secret_manager() {
    local script_content=$(cat /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/postgresql_ha_bootstrap_clean.sh)
    echo "$script_content" | grep -q "get_secret" &&
    echo "$script_content" | grep -q "pg_superuser_secret_id" &&
    echo "$script_content" | grep -q "secretmanager.googleapis.com"
}

# Test health endpoints
test_health_endpoints() {
    local script_content=$(cat /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/postgresql_ha_bootstrap_clean.sh)
    echo "$script_content" | grep -q "pg-ha-health.sh" &&
    echo "$script_content" | grep -q "pgbouncer-health.sh" &&
    echo "$script_content" | grep -q "8001" &&
    echo "$script_content" | grep -q "8002"
}

# Main validation
main() {
    info "Starting PostgreSQL HA Bootstrap Script Validation"
    info "=================================================="
    
    test_function "Script Syntax Check" "test_syntax"
    test_function "Required Functions Exist" "test_functions_exist" 
    test_function "Error Handling Setup" "test_error_handling"
    test_function "Logging Functions" "test_logging"
    test_function "Metadata Configuration" "test_metadata_config"
    test_function "Secret Manager Integration" "test_secret_manager"
    test_function "Health Endpoints Setup" "test_health_endpoints"
    
    echo
    info "Validation Summary:"
    info "=================="
    printf "Total Tests: %d\n" $TESTS_TOTAL
    printf "${GREEN}Passed: %d${NC}\n" $TESTS_PASSED  
    printf "${RED}Failed: %d${NC}\n" $TESTS_FAILED
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        success "All validation tests passed! Bootstrap script is ready for deployment."
        return 0
    else
        fail "Some validation tests failed. Please review and fix the issues."
        return 1
    fi
}

main "$@"