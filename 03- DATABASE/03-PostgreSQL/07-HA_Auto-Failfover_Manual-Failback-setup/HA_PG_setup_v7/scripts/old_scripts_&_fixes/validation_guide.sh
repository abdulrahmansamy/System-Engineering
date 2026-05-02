#!/bin/bash
# PostgreSQL HA Validation Guide
# This script explains how to properly validate your HA cluster

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
guide() { echo -e "${BLUE}[GUIDE]${NC} $*"; }
warn() { echo -e "${YELLOW}[NOTE]${NC} $*"; }

echo "=========================================="
echo "PostgreSQL HA Cluster Validation Guide"
echo "=========================================="
echo ""

info "Your PostgreSQL HA cluster consists of:"
echo "• Primary:  192.168.14.21 (ipa-nprd-ha-pg-primary-01)"
echo "• Standby:  192.168.14.22 (ipa-nprd-ha-pg-standby-01)"
echo ""

info "RECOMMENDED VALIDATION APPROACH:"
echo ""

guide "Option 1: Individual Node Validation (BEST)"
echo "Run this script on each server separately for complete validation:"
echo ""
echo "  # On Primary Server (192.168.14.21):"
echo "  sudo ./validate_local_node.sh"
echo ""
echo "  # On Standby Server (192.168.14.22):"
echo "  sudo ./validate_local_node.sh"
echo ""
warn "This provides the most comprehensive and accurate validation results."
echo ""

guide "Option 2: Quick Health Check"
echo "For daily monitoring, run this on either server:"
echo ""
echo "  sudo ./quick_replication_check.sh"
echo ""
warn "This uses health endpoints and works well for automated monitoring."
echo ""

guide "Option 3: Remote Validation (LIMITED)"
echo "The comprehensive remote validation has limitations due to PostgreSQL security:"
echo ""
echo "  sudo ./validate_replication.sh"
echo ""
warn "Some tests may show warnings due to remote access restrictions - this is normal."
echo ""

info "QUICK STATUS CHECK:"
echo ""
echo "Check cluster health via HTTP endpoints:"
echo "  curl -s http://192.168.14.21:8001 | jq .  # Primary status"
echo "  curl -s http://192.168.14.22:8001 | jq .  # Standby status"
echo ""

info "REPMGR CLUSTER STATUS:"
echo ""
echo "Check cluster status from any node:"
echo "  sudo -u postgres repmgr -f /etc/repmgr/repmgr.conf cluster show"
echo ""

info "MANUAL FAILOVER TEST:"
echo ""
echo "To test failover capabilities:"
echo "  sudo ./test_manual_failover.sh"
echo ""
warn "This causes a brief service interruption - only use in testing!"
echo ""

info "KEY INDICATORS OF HEALTHY CLUSTER:"
echo ""
echo "✅ Both health endpoints return 'healthy' status"
echo "✅ Primary shows 'is_in_recovery': false"
echo "✅ Standby shows 'is_in_recovery': true" 
echo "✅ Repmgr shows both nodes as 'running'"
echo "✅ Replication lag is minimal (< 1MB)"
echo "✅ All services are 'active' (postgresql, repmgrd, pg-ha-health)"
echo ""

info "TROUBLESHOOTING:"
echo ""
echo "If you see connection errors in remote validation:"
echo "• This is expected - PostgreSQL restricts remote superuser access"
echo "• Use local validation (Option 1) for complete testing"
echo "• Health endpoints provide reliable status without direct DB access"
echo ""

info "MONITORING SETUP:"
echo ""
echo "For production monitoring, set up automated checks:"
echo ""
echo "# Add to crontab for automated monitoring:"
echo "*/5 * * * * /path/to/quick_replication_check.sh >> /var/log/pg-health.log 2>&1"
echo ""

echo "=========================================="
info "CURRENT CLUSTER STATUS:"
echo "=========================================="

# Quick status check
echo ""
guide "Primary Node Status:"
if curl -s "http://192.168.14.21:8001" >/dev/null 2>&1; then
    curl -s "http://192.168.14.21:8001" | jq . 2>/dev/null || echo "Health endpoint responding but JSON parse failed"
else
    warn "Primary health endpoint not responding"
fi

echo ""
guide "Standby Node Status:"
if curl -s "http://192.168.14.22:8001" >/dev/null 2>&1; then
    curl -s "http://192.168.14.22:8001" | jq . 2>/dev/null || echo "Health endpoint responding but JSON parse failed"
else
    warn "Standby health endpoint not responding"
fi

echo ""
echo "=========================================="
info "Run './validate_local_node.sh' on each server for detailed validation!"
echo "=========================================="