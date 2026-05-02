#!/bin/bash
# =============================================================================
# PostgreSQL HA Role Detection Debugger
# =============================================================================

# Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
DB_PORT="6432"
DB_DIRECT_PORT="5432"
USERNAME="postgres"
DATABASE="postgres"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level="$1"
    shift
    printf "${GREEN}[$level]${NC} %s\n" "$*"
}

get_credentials() {
    if [[ -z "${PG_SUPER_PASS:-}" ]]; then
        if PG_SUPER_PASS=$(timeout 10 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
            if [[ -n "$PG_SUPER_PASS" ]]; then
                export PG_SUPER_PASS
                log "SUCCESS" "PostgreSQL password retrieved"
            else
                export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
                log "WARN" "Using fallback password"
            fi
        else
            export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
            log "WARN" "Using fallback password"
        fi
    fi
}

test_node() {
    local host="$1"
    local port="$2"
    local label="$3"
    
    printf "\n${BLUE}Testing $label ($host:$port)${NC}\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    # Test basic connectivity
    printf "1. Basic connectivity test... "
    if timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -c "SELECT 1;" >/dev/null 2>&1; then
        printf "${GREEN}✅ SUCCESS${NC}\n"
    else
        printf "${RED}❌ FAILED${NC}\n"
        return 1
    fi
    
    # Test role detection
    printf "2. Role detection test... "
    local role=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null)
    
    if [[ -n "$role" ]]; then
        printf "${GREEN}✅ Role: $role${NC}\n"
    else
        printf "${RED}❌ FAILED to detect role${NC}\n"
        return 1
    fi
    
    # Test detailed status
    printf "3. Recovery status... "
    local recovery_status=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
        -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null)
    
    printf "In recovery: $recovery_status\n"
    
    # Test replication info (if primary)
    if [[ "$role" == "PRIMARY" ]]; then
        printf "4. Replication status... "
        local repl_count=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
            -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
            -Atqc "SELECT COUNT(*) FROM pg_stat_replication;" 2>/dev/null)
        
        printf "Connected replicas: $repl_count\n"
        
        if [[ "$repl_count" != "0" ]]; then
            printf "5. Replica details:\n"
            timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
                -h "$host" -p "$port" -U "$USERNAME" -d "$DATABASE" \
                -c "SELECT application_name, client_addr, state FROM pg_stat_replication;" 2>/dev/null
        fi
    fi
    
    return 0
}

main() {
    printf "${BLUE}PostgreSQL HA Role Detection Debugger${NC}\n"
    printf "════════════════════════════════════════════════════════\n"
    
    get_credentials
    
    # Test both ports for each node
    test_node "$PRIMARY_IP" "$DB_PORT" "Primary via PgBouncer"
    test_node "$PRIMARY_IP" "$DB_DIRECT_PORT" "Primary Direct"
    
    test_node "$STANDBY_IP" "$DB_PORT" "Standby via PgBouncer"
    test_node "$STANDBY_IP" "$DB_DIRECT_PORT" "Standby Direct"
    
    printf "\n${BLUE}Summary${NC}\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    # Determine cluster state
    local primary_role_bouncer=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$PRIMARY_IP" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    
    local standby_role_bouncer=$(timeout 10 env PGPASSWORD="$PG_SUPER_PASS" psql \
        -h "$STANDBY_IP" -p "$DB_PORT" -U "$USERNAME" -d "$DATABASE" \
        -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
    
    printf "Primary node (via PgBouncer): $primary_role_bouncer\n"
    printf "Standby node (via PgBouncer): $standby_role_bouncer\n"
    
    if [[ "$primary_role_bouncer" == "PRIMARY" && "$standby_role_bouncer" == "STANDBY" ]]; then
        printf "${GREEN}✅ Cluster state: NORMAL${NC}\n"
    elif [[ "$primary_role_bouncer" == "STANDBY" && "$standby_role_bouncer" == "PRIMARY" ]]; then
        printf "${YELLOW}⚠️  Cluster state: FAILED_OVER${NC}\n"
    else
        printf "${RED}❌ Cluster state: BROKEN or UNKNOWN${NC}\n"
        printf "   Primary role: $primary_role_bouncer\n"
        printf "   Standby role: $standby_role_bouncer\n"
    fi
}

main "$@"