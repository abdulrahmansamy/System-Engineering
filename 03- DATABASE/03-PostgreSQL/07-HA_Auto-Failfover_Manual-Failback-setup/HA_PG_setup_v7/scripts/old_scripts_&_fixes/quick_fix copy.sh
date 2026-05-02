#!/bin/bash
# Quick fix for failover validation scripts
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }

echo "🔧 Fixing Failover Validation Scripts"
echo "======================================"

# Fix 1: Add missing function definition in data_sync_validator.sh
info "Fixing data_sync_validator.sh..."

if [[ -f "data_sync_validator.sh" ]]; then
    # Add is_primary function after the credentials section
    if ! grep -q "is_primary()" data_sync_validator.sh; then
        sed -i '/^fi$/a\\n# Helper function to check if a node is primary\nis_primary() {\n    local ip="$1"\n    local result\n    result=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN '"'"'STANDBY'"'"' ELSE '"'"'PRIMARY'"'"' END;" 2>/dev/null || echo "UNKNOWN")\n    [[ "$result" == "PRIMARY" ]]\n}' data_sync_validator.sh
        success "Added is_primary function to data_sync_validator.sh"
    else
        info "is_primary function already exists in data_sync_validator.sh"
    fi
else
    warn "data_sync_validator.sh not found in current directory"
fi

# Fix 2: Test basic connectivity
info "Testing basic PostgreSQL connectivity..."

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

# Test connections
for ip in "192.168.14.21" "192.168.14.22"; do
    if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p "6432" -U "postgres" -d "postgres" -c "SELECT 1;" >/dev/null 2>&1; then
        role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p "6432" -U "postgres" -d "postgres" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNKNOWN")
        success "✅ $ip is accessible (Role: $role)"
    else
        error "❌ $ip is not accessible via PgBouncer (port 6432)"
        
        # Try direct PostgreSQL connection
        if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p "5432" -U "postgres" -d "postgres" -c "SELECT 1;" >/dev/null 2>&1; then
            role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$ip" -p "5432" -U "postgres" -d "postgres" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNKNOWN")
            warn "⚠️ $ip is accessible via direct connection only (Role: $role)"
            warn "PgBouncer may not be running or configured properly"
        else
            error "❌ $ip is completely unreachable"
        fi
    fi
done

# Fix 3: Create a simple connectivity test script
info "Creating simple connectivity test script..."

cat > simple_connectivity_test.sh << 'EOF'
#!/bin/bash
# Simple PostgreSQL HA Connectivity Test
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }

# Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
DB_PORT="6432"
DB_DIRECT_PORT="5432"
USERNAME="postgres"
DATABASE="postgres"

# Get credentials
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    if PG_SUPER_PASS=$(timeout 5 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
        export PG_SUPER_PASS
    else
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

echo "🔍 PostgreSQL HA Connectivity Test"
echo "=================================="

# Test function
test_connection() {
    local host="$1" port="$2" description="$3"
    
    if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" -c "SELECT current_timestamp;" >/dev/null 2>&1; then
        local role
        role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNKNOWN")
        success "✅ $description: Connected (Role: $role)"
        return 0
    else
        error "❌ $description: Connection failed" 
        return 1
    fi
}

# Run tests
echo
info "Testing PgBouncer connections (port 6432):"
test_connection "$PRIMARY_IP" "$DB_PORT" "Primary via PgBouncer"
test_connection "$STANDBY_IP" "$DB_PORT" "Standby via PgBouncer"

echo
info "Testing direct PostgreSQL connections (port 5432):"
test_connection "$PRIMARY_IP" "$DB_DIRECT_PORT" "Primary Direct"
test_connection "$STANDBY_IP" "$DB_DIRECT_PORT" "Standby Direct"

echo
info "Testing DNS endpoints:"
for dns in "pg-write.db.internal.nprd.ipa.edu.sa" "pg-read.db.internal.nprd.ipa.edu.sa"; do
    if timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$dns" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
        role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$dns" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNKNOWN")
        success "✅ $dns: Connected (Role: $role)"
    else
        error "❌ $dns: Connection failed"
    fi
done

echo
info "Connectivity test completed!"
EOF

chmod +x simple_connectivity_test.sh
success "Created simple_connectivity_test.sh"

echo
echo "🎯 Quick Fix Summary:"
echo "====================="
info "1. Fixed data_sync_validator.sh function definitions"
info "2. Tested basic connectivity to both nodes"
info "3. Created simple_connectivity_test.sh for basic testing"
echo
success "Quick fixes applied! You can now run:"
success "  • ./simple_connectivity_test.sh - Basic connectivity test"
success "  • ./failover_validation_jumphost.sh - Full validation suite"
echo
warn "If you still see issues, ensure:"
warn "  • You're running from the jump host"
warn "  • PostgreSQL and PgBouncer are running on both nodes"
warn "  • Network connectivity exists between jump host and database nodes"