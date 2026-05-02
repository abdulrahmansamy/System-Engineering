#!/bin/bash
# =============================================================================
# Setup Script for PostgreSQL HA Automated Failover Tester
# =============================================================================

# Make all scripts executable
chmod +x automated_ha_failover_tester.sh
chmod +x debug_helper.sh
chmod +x replication_troubleshooter.sh
chmod +x fix_replication_connection.sh
chmod +x validate_replication.sh
chmod +x unified_ha_validator.sh
chmod +x simple_ha_validator.sh

echo "✅ PostgreSQL HA Automated Failover Tester Setup Complete!"
echo
echo "📋 AVAILABLE SCRIPTS:"
echo "   1. ./automated_ha_failover_tester.sh   - Main HA testing suite"
echo "   2. ./debug_helper.sh [on|off|verbose]  - Debug mode controller"
echo "   3. ./replication_troubleshooter.sh     - Diagnose replication issues"
echo "   4. ./fix_replication_connection.sh     - 🎯 FIX your specific issue"
echo "   5. ./validate_replication.sh           - Quick replication validator"
echo "   6. ./simple_ha_validator.sh            - 🚀 SIMPLIFIED HA VALIDATOR"
echo "   7. ./unified_ha_validator.sh           - � ULTIMATE HA VALIDATOR"
echo
echo "🚀 RECOMMENDED WORKFLOW:"
echo "   # 1. Since replication is working, run comprehensive testing:"
echo "   ./simple_ha_validator.sh"
echo "   # Choose option 5: Run all scenarios (full suite)"
echo
echo "🔥 ADVANCED TESTING (requires bc package):"
echo "   # For advanced performance metrics:"
echo "   ./unified_ha_validator.sh"
echo
echo "🎯 QUICK VALIDATION:"
echo "   # Quick replication check:"
echo "   ./validate_replication.sh"
echo
echo "🔧 TROUBLESHOOTING (if needed):"
echo "   # For detailed analysis:"
echo "   ./replication_troubleshooter.sh"
echo "   # For targeted fixes:"
echo "   ./fix_replication_connection.sh"
echo "   # For step-by-step debugging:"
echo "   ./debug_helper.sh on && ./automated_ha_failover_tester.sh"
echo
echo "🔍 DEBUGGING FEATURES:"
echo "   • Enhanced logging with DEBUG_MODE=true"
echo "   • Verbose SQL output with VERBOSE_SQL=true"
echo "   • Detailed LSN tracking and lag calculation"
echo "   • Step-by-step replication analysis"
echo "   • Network connectivity verification"
echo
echo "⚠️  REQUIREMENTS:"
echo "   • SSH key access to both PostgreSQL nodes"
echo "   • gcloud authentication for Secret Manager"
echo "   • Network connectivity to cluster nodes"
echo
echo "🚀 Ready to debug PostgreSQL HA replication issues!"