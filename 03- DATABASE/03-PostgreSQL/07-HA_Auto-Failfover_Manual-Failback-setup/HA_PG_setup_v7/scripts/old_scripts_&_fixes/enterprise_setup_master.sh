#!/bin/bash
# PostgreSQL HA Enterprise Setup Master Script
# Runs all enterprise configuration scripts in the correct order
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

get_pg_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        echo "standby"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
        echo "primary"
    else
        echo "unknown"
    fi
}

run_script() {
    local script_name="$1"
    local description="$2"
    local script_path="$SCRIPT_DIR/$script_name"
    
    section "$description"
    
    if [[ -f "$script_path" ]]; then
        info "Running: $script_name"
        if bash "$script_path"; then
            success "$description completed successfully"
            return 0
        else
            error "$description failed"
            return 1
        fi
    else
        error "Script not found: $script_path"
        return 1
    fi
}

show_menu() {
    printf "\n%b%s%b\n" "$CYAN$BOLD" "PostgreSQL HA Enterprise Setup Options:" "$NC"
    echo "1. Run comprehensive validation (enhanced v2.0)"
    echo "2. Configure timezone synchronization"
    echo "3. Set up custom MOTD"
    echo "4. Configure GCS backups"
    echo "5. Set up monitoring and alerting"
    echo "6. Run failover testing (interactive)"
    echo "7. Run all enterprise setups (2,3,4,5)"
    echo "8. Full validation + enterprise setup (1,2,3,4,5)"
    echo "9. Exit"
    echo
}

main() {
    printf "%b" "$BLUE$BOLD"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║     PostgreSQL HA Enterprise Setup Master           ║
║                Version 1.0.0                        ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    local role
    role=$(get_pg_role)
    
    printf "\n%bSystem Information:%b\n" "$CYAN" "$NC"
    printf "  Hostname: %s\n" "$(hostname)"
    printf "  Node Role: %s\n" "$role"
    printf "  IP Address: %s\n" "$(hostname -I | awk '{print $1}')"
    printf "  Current Time: %s\n" "$(date)"
    
    while true; do
        show_menu
        read -p "Please select an option (1-8): " choice
        
        case $choice in
            1)
                section "Running Comprehensive Validation"
                if [[ -f "$SCRIPT_DIR/comprehensive_validation.sh" ]]; then
                    bash "$SCRIPT_DIR/comprehensive_validation.sh"
                else
                    error "comprehensive_validation.sh not found"
                fi
                ;;
                
            2)
                run_script "setup_timezone.sh" "Timezone Synchronization"
                ;;
                
            3)
                run_script "setup_custom_motd.sh" "Custom MOTD Setup"
                ;;
                
            4)
                run_script "setup_gcs_backups.sh" "GCS Backup Configuration"
                ;;
                
            5)
                run_script "setup_monitoring.sh" "Monitoring and Alerting Setup"
                ;;
                
            6)
                section "Interactive Failover Testing"
                if [[ -f "$SCRIPT_DIR/failover_test_script.sh" ]]; then
                    bash "$SCRIPT_DIR/failover_test_script.sh"
                else
                    error "failover_test_script.sh not found"
                fi
                ;;
                
            7)
                section "Running All Enterprise Setups"
                info "This will run Timezone, MOTD, GCS Backups, and Monitoring setup"
                read -p "Continue? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    run_script "setup_timezone.sh" "Timezone Synchronization"
                    run_script "setup_custom_motd.sh" "Custom MOTD Setup"
                    run_script "setup_gcs_backups.sh" "GCS Backup Configuration" 
                    run_script "setup_monitoring.sh" "Monitoring and Alerting Setup"
                    success "All enterprise setups completed!"
                else
                    info "Enterprise setup cancelled"
                fi
                ;;
                
            8)
                section "Full Validation + Enterprise Setup"
                info "This will run validation followed by all enterprise setups"
                read -p "Continue? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    # Run validation first
                    if [[ -f "$SCRIPT_DIR/comprehensive_validation.sh" ]]; then
                        bash "$SCRIPT_DIR/comprehensive_validation.sh"
                    fi
                    
                    # Then run enterprise setups
                    run_script "setup_timezone.sh" "Timezone Synchronization"
                    run_script "setup_custom_motd.sh" "Custom MOTD Setup"
                    run_script "setup_gcs_backups.sh" "GCS Backup Configuration"
                    run_script "setup_monitoring.sh" "Monitoring and Alerting Setup"
                    
                    success "Full validation and enterprise setup completed!"
                    
                    info "Your PostgreSQL HA cluster now includes:"
                    info "  ✅ Comprehensive validation (v2.0)"
                    info "  ✅ Synchronized timezone configuration"
                    info "  ✅ Custom MOTD with cluster information"
                    info "  ✅ Automated GCS backups"
                    info "  ✅ Enhanced monitoring and alerting"
                    info "  ✅ Production-ready configuration"
                else
                    info "Full setup cancelled"
                fi
                ;;
                
            9)
                info "Exiting PostgreSQL HA Enterprise Setup"
                break
                ;;
                
            *)
                warn "Invalid choice. Please select 1-9."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
    
    success "PostgreSQL HA Enterprise Setup session completed"
}

main "$@"