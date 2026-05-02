#!/bin/bash
# Manual Read/Write Test Script for PostgreSQL HA DNS Endpoints
# Tests pg-read and pg-write DNS endpoints manually
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
WRITE_DNS="pg-write.db.internal.nprd.ipa.edu.sa"
READ_DNS="pg-read.db.internal.nprd.ipa.edu.sa"
DB_PORT="6432"
USERNAME="postgres"
DATABASE="postgres"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

# Get credentials
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    if PG_SUPER_PASS=$(timeout 5 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
        export PG_SUPER_PASS
        success "Retrieved password from Secret Manager"
    else
        warn "Using default password"
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

# Function to test read operations
test_read_endpoint() {
    local endpoint="$1"
    local description="$2"
    
    section "Testing READ Operations on $description"
    
    info "Endpoint: $endpoint:$DB_PORT"
    
    # 1. Basic connectivity test
    info "1️⃣ Testing basic connectivity..."
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "SELECT 1 as connectivity_test;" 2>/dev/null; then
        success "✅ Basic connectivity working"
    else
        error "❌ Basic connectivity failed"
        return 1
    fi
    
    # 2. Check which node we're connected to
    info "2️⃣ Checking node role and details..."
    local node_info
    node_info=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        SELECT 
            inet_server_addr() as server_ip,
            CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role,
            version() as pg_version,
            current_timestamp as connection_time;
    " 2>/dev/null || echo "Query failed")
    
    if [[ "$node_info" != "Query failed" ]]; then
        info "📊 Connection Details:"
        echo "$node_info"
    else
        error "❌ Failed to get node information"
    fi
    
    # 3. Test various read operations
    info "3️⃣ Testing read operations..."
    
    # Simple SELECT
    info "  → Testing simple SELECT..."
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "SELECT current_timestamp, current_user, current_database();" >/dev/null 2>&1; then
        success "    ✅ Simple SELECT works"
    else
        error "    ❌ Simple SELECT failed"
    fi
    
    # Count from system tables
    info "  → Testing system table queries..."
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "SELECT count(*) as total_databases FROM pg_database;" >/dev/null 2>&1; then
        success "    ✅ System table queries work"
    else
        error "    ❌ System table queries failed"
    fi
    
    # Check replication status (if on primary)
    info "  → Testing replication status query..."
    local repl_result
    repl_result=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "FAILED")
    
    if [[ "$repl_result" != "FAILED" ]]; then
        success "    ✅ Replication status query works (Found $repl_result replication connections)"
    else
        warn "    ⚠️ Replication status query failed (expected on STANDBY)"
    fi
    
    success "✅ READ endpoint testing completed for $description"
}

# Function to test write operations
test_write_endpoint() {
    local endpoint="$1"
    local description="$2"
    
    section "Testing WRITE Operations on $description"
    
    info "Endpoint: $endpoint:$DB_PORT"
    
    # 1. Basic connectivity test
    info "1️⃣ Testing basic connectivity..."
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "SELECT 1 as connectivity_test;" 2>/dev/null; then
        success "✅ Basic connectivity working"
    else
        error "❌ Basic connectivity failed"
        return 1
    fi
    
    # 2. Check which node we're connected to
    info "2️⃣ Checking node role and details..."
    local node_info role
    node_info=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        SELECT 
            inet_server_addr() as server_ip,
            CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role,
            version() as pg_version,
            current_timestamp as connection_time;
    " 2>/dev/null || echo "Query failed")
    
    if [[ "$node_info" != "Query failed" ]]; then
        info "📊 Connection Details:"
        echo "$node_info"
        
        # Extract role for validation
        role=$(echo "$node_info" | grep -E "PRIMARY|STANDBY" | head -1 | awk '{print $4}' || echo "UNKNOWN")
    else
        error "❌ Failed to get node information"
        role="UNKNOWN"
    fi
    
    # 3. Validate we're on a PRIMARY node
    if [[ "$role" == "STANDBY" ]]; then
        warn "⚠️ Connected to STANDBY node - write operations will fail"
        warn "This indicates a load balancer configuration issue"
        return 1
    elif [[ "$role" != "PRIMARY" ]]; then
        error "❌ Unable to determine node role"
        return 1
    fi
    
    success "✅ Connected to PRIMARY node - proceeding with write tests"
    
    # 4. Test write operations
    info "3️⃣ Testing write operations..."
    
    local test_table="manual_test_$(date +%s)_$$"
    
    # Create table test
    info "  → Testing table creation..."
    if timeout 15 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        CREATE TABLE $test_table (
            id SERIAL PRIMARY KEY,
            test_data TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT NOW()
        );
    " >/dev/null 2>&1; then
        success "    ✅ Table creation successful"
    else
        error "    ❌ Table creation failed"
        return 1
    fi
    
    # Insert test
    info "  → Testing data insertion..."
    if timeout 15 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        INSERT INTO $test_table (test_data) VALUES 
        ('Test data 1'),
        ('Test data 2'),
        ('Test data 3');
    " >/dev/null 2>&1; then
        success "    ✅ Data insertion successful"
    else
        error "    ❌ Data insertion failed"
    fi
    
    # Update test
    info "  → Testing data update..."
    if timeout 15 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        UPDATE $test_table SET test_data = 'Updated: ' || test_data WHERE id = 1;
    " >/dev/null 2>&1; then
        success "    ✅ Data update successful"
    else
        error "    ❌ Data update failed"
    fi
    
    # Read back test
    info "  → Testing data read-back..."
    local read_result
    read_result=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "SELECT count(*) FROM $test_table;" 2>/dev/null || echo "FAILED")
    
    if [[ "$read_result" != "FAILED" ]]; then
        success "    ✅ Data read-back successful"
        info "    📊 Records found: $(echo "$read_result" | tail -1 | xargs)"
    else
        error "    ❌ Data read-back failed"
    fi
    
    # Delete test
    info "  → Testing data deletion..."
    if timeout 15 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        DELETE FROM $test_table WHERE id = 3;
    " >/dev/null 2>&1; then
        success "    ✅ Data deletion successful"
    else
        error "    ❌ Data deletion failed"
    fi
    
    # Cleanup
    info "  → Cleaning up test table..."
    timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "DROP TABLE IF EXISTS $test_table;" >/dev/null 2>&1 || warn "Cleanup may have failed"
    
    success "✅ WRITE endpoint testing completed for $description"
}

# Function to test transaction operations
test_transaction_operations() {
    local endpoint="$1"
    local description="$2"
    
    section "Testing TRANSACTION Operations on $description"
    
    info "Endpoint: $endpoint:$DB_PORT"
    
    local test_table="transaction_test_$(date +%s)_$$"
    
    info "1️⃣ Testing transaction with COMMIT..."
    
    # Transaction test with commit
    local tx_result
    tx_result=$(timeout 20 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        BEGIN;
        CREATE TABLE $test_table (id INT, data TEXT);
        INSERT INTO $test_table VALUES (1, 'Transaction test');
        COMMIT;
        SELECT count(*) FROM $test_table;
        DROP TABLE $test_table;
    " 2>/dev/null || echo "FAILED")
    
    if [[ "$tx_result" != "FAILED" ]]; then
        success "    ✅ Transaction with COMMIT successful"
    else
        error "    ❌ Transaction with COMMIT failed"
    fi
    
    info "2️⃣ Testing transaction with ROLLBACK..."
    
    # Transaction test with rollback
    local rollback_table="rollback_test_$(date +%s)_$$"
    local rollback_result
    rollback_result=$(timeout 20 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "
        BEGIN;
        CREATE TABLE $rollback_table (id INT, data TEXT);
        INSERT INTO $rollback_table VALUES (1, 'This should be rolled back');
        ROLLBACK;
        SELECT count(*) FROM information_schema.tables WHERE table_name = '$rollback_table';
    " 2>/dev/null || echo "FAILED")
    
    if [[ "$rollback_result" != "FAILED" ]] && echo "$rollback_result" | grep -q "0"; then
        success "    ✅ Transaction with ROLLBACK successful (table correctly not created)"
    else
        error "    ❌ Transaction with ROLLBACK failed"
    fi
    
    success "✅ TRANSACTION testing completed for $description"
}

# Function to show DNS resolution
show_dns_info() {
    section "DNS Resolution Information"
    
    info "Resolving DNS endpoints..."
    
    local write_ip read_ip
    write_ip=$(dig +short "$WRITE_DNS" 2>/dev/null | head -1 || echo "RESOLUTION_FAILED")
    read_ip=$(dig +short "$READ_DNS" 2>/dev/null | head -1 || echo "RESOLUTION_FAILED")
    
    info "📊 DNS Resolution Results:"
    info "  • $WRITE_DNS → $write_ip"
    info "  • $READ_DNS → $read_ip"
    
    # Test if IPs are reachable
    for ip in "$write_ip" "$read_ip"; do
        if [[ "$ip" != "RESOLUTION_FAILED" ]]; then
            if timeout 3 nc -z "$ip" "$DB_PORT" 2>/dev/null; then
                success "    ✅ $ip:$DB_PORT is reachable"
            else
                error "    ❌ $ip:$DB_PORT is not reachable"
            fi
        fi
    done
}

# Interactive menu
show_menu() {
    echo
    printf "%b%s%b\n" "$CYAN$BOLD" "PostgreSQL HA DNS Endpoint Testing Menu:" "$NC"
    echo "1. Test READ endpoint (pg-read)"
    echo "2. Test WRITE endpoint (pg-write)"  
    echo "3. Test both READ and WRITE endpoints"
    echo "4. Test transaction operations on WRITE endpoint"
    echo "5. Show DNS resolution information"
    echo "6. Run comprehensive test (all operations)"
    echo "7. Interactive SQL session (READ endpoint)"
    echo "8. Interactive SQL session (WRITE endpoint)"
    echo "9. Exit"
    echo
}

# Interactive SQL session
interactive_sql() {
    local endpoint="$1"
    local description="$2"
    
    section "Interactive SQL Session - $description"
    
    info "Connecting to: $endpoint:$DB_PORT"
    info "Use \\q to exit the session"
    echo
    
    env PGPASSWORD="$PG_SUPER_PASS" psql -h "$endpoint" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE"
}

# Main function
main() {
    printf "%b" "$BLUE$BOLD"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║    PostgreSQL HA DNS Endpoint Manual Testing        ║
║         Read/Write Operations Validator              ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    info "Timestamp: $(date)"
    info "Testing DNS endpoints:"
    info "  • READ: $READ_DNS:$DB_PORT"
    info "  • WRITE: $WRITE_DNS:$DB_PORT"
    
    while true; do
        show_menu
        read -p "Enter your choice (1-9): " choice
        
        case $choice in
            1)
                test_read_endpoint "$READ_DNS" "READ Endpoint"
                ;;
            2)
                test_write_endpoint "$WRITE_DNS" "WRITE Endpoint"
                ;;
            3)
                test_read_endpoint "$READ_DNS" "READ Endpoint"
                echo
                test_write_endpoint "$WRITE_DNS" "WRITE Endpoint"
                ;;
            4)
                test_transaction_operations "$WRITE_DNS" "WRITE Endpoint"
                ;;
            5)
                show_dns_info
                ;;
            6)
                show_dns_info
                echo
                test_read_endpoint "$READ_DNS" "READ Endpoint"
                echo
                test_write_endpoint "$WRITE_DNS" "WRITE Endpoint"
                echo
                test_transaction_operations "$WRITE_DNS" "WRITE Endpoint"
                ;;
            7)
                interactive_sql "$READ_DNS" "READ Endpoint"
                ;;
            8)
                interactive_sql "$WRITE_DNS" "WRITE Endpoint"
                ;;
            9)
                info "Exiting DNS endpoint testing"
                break
                ;;
            *)
                warn "Invalid choice. Please select 1-9."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
    
    success "Manual DNS endpoint testing session completed"
}

main "$@"