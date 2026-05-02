#!/bin/bash
# Quick Diagnostic Script for Post-Failback Issues
# Analyzes current cluster state and provides immediate fixes

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PRIMARY_IP="192.168.14.21"
STANDBY_IP="192.168.14.22"
PRIMARY_SSH_HOST="ipa-nprd-ha-pg-primary-01"
STANDBY_SSH_HOST="ipa-nprd-ha-pg-standby-01"
SSH_USER="asamy_nominations_ipa_edu_sa"
SSH_OPTIONS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
DB_PORT="6432"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }

echo "🔍 Quick Cluster Diagnostic"
echo "=========================="

# Get credentials
if [[ -z "${PG_SUPER_PASS:-}" ]]; then
    if PG_SUPER_PASS=$(timeout 5 gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01" 2>/dev/null); then
        export PG_SUPER_PASS
    else
        export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
    fi
fi

echo
info "1️⃣ PostgreSQL Database Roles:"
primary_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")
standby_role=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$STANDBY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null || echo "UNREACHABLE")

echo "   • $PRIMARY_IP: $primary_role"
echo "   • $STANDBY_IP: $standby_role"

echo
info "2️⃣ repmgr Node Registration:"
ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo -u postgres psql -d repmgr -c 'SELECT node_id, type, node_name, active, upstream_node_id FROM repmgr.nodes ORDER BY node_id;'" 2>/dev/null || warn "Cannot query repmgr database"

echo
info "3️⃣ Replication Status:"
repl_count=$(timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -Atqc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
echo "   • Active connections: $repl_count"

if [[ "$repl_count" -gt 0 ]]; then
    timeout 5 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PRIMARY_IP" -p "$DB_PORT" -U postgres -d postgres -c "SELECT client_addr, application_name, state FROM pg_stat_replication;" 2>/dev/null || echo "Query failed"
fi

echo
info "4️⃣ Service Status:"
primary_pg=$(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl is-active postgresql" 2>/dev/null || echo "unknown")
standby_pg=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl is-active postgresql" 2>/dev/null || echo "unknown")
primary_repmgrd=$(ssh $SSH_OPTIONS "$SSH_USER@$PRIMARY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")
standby_repmgrd=$(ssh $SSH_OPTIONS "$SSH_USER@$STANDBY_SSH_HOST" "sudo systemctl is-active repmgrd" 2>/dev/null || echo "inactive")

echo "   • Primary PostgreSQL: $primary_pg"
echo "   • Standby PostgreSQL: $standby_pg"
echo "   • Primary repmgrd: $primary_repmgrd"
echo "   • Standby repmgrd: $standby_repmgrd"

echo
info "5️⃣ DNS Resolution:"
write_dns=$(dig +short pg-write.db.internal.nprd.ipa.edu.sa 2>/dev/null | head -1 || echo "FAILED")
read_dns=$(dig +short pg-read.db.internal.nprd.ipa.edu.sa 2>/dev/null | head -1 || echo "FAILED")
echo "   • Write DNS: $write_dns (should be 192.168.14.21)"
echo "   • Read DNS: $read_dns"

echo
echo "🔧 IMMEDIATE FIXES NEEDED:"
echo "========================"

if [[ "$primary_role" != "PRIMARY" ]]; then
    error "❌ Primary node is not PRIMARY!"
fi

if [[ "$standby_role" != "STANDBY" ]]; then
    error "❌ Standby node is not STANDBY!"
fi

if [[ "$repl_count" -eq 0 ]]; then
    error "❌ No replication connections!"
fi

if [[ "$primary_repmgrd" != "active" ]]; then
    error "❌ Primary repmgrd not running!"
fi

if [[ "$standby_repmgrd" != "active" ]]; then
    error "❌ Standby repmgrd not running!"
fi

if [[ "$write_dns" != "192.168.14.21" ]]; then
    error "❌ Write DNS pointing to wrong IP!"
fi

echo
echo "💡 TO FIX THESE ISSUES:"
echo "Run: ./post_failback_repair.sh"