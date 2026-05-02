#!/bin/bash
# Make all PostgreSQL HA enterprise scripts executable
# Quick setup script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Making PostgreSQL HA enterprise scripts executable..."

# List of scripts to make executable
scripts=(
    "comprehensive_validation.sh"
    "failover_test_script.sh"
    "setup_custom_motd.sh"
    "setup_gcs_backups.sh"
    "setup_monitoring.sh"
    "setup_timezone.sh"
    "enterprise_setup_master.sh"
    "postgresql_ha_bootstrap_production_v4.0.sh"
)

for script in "${scripts[@]}"; do
    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        chmod +x "$SCRIPT_DIR/$script"
        echo "✓ Made executable: $script"
    else
        echo "⚠ Script not found: $script"
    fi
done

echo ""
echo "Enterprise script setup completed!"
echo ""
echo "Available scripts:"
echo "  • ./comprehensive_validation.sh - Enhanced validation with enterprise features"
echo "  • ./setup_timezone.sh - Configure timezone synchronization"
echo "  • ./setup_custom_motd.sh - Setup custom MOTD with cluster info"
echo "  • ./setup_gcs_backups.sh - Configure automated GCS backups"
echo "  • ./setup_monitoring.sh - Setup monitoring and alerting"
echo "  • ./failover_test_script.sh - Interactive failover testing"
echo "  • ./enterprise_setup_master.sh - Master script for all enterprise features"
echo ""
echo "Quick start: sudo ./enterprise_setup_master.sh"