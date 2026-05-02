#!/bin/bash
# PostgreSQL HA Cluster Timezone Configuration Script
# Synchronizes timezone settings between OS and PostgreSQL
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

get_metadata() {
  local key="$1"
  curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}" 2>/dev/null || echo ""
}

detect_appropriate_timezone() {
    section "Detecting Appropriate Timezone"
    
    local tz metadata_tz
    
    # Try to get timezone from metadata first
    metadata_tz=$(get_metadata timezone)
    
    if [[ -n "$metadata_tz" && -f "/usr/share/zoneinfo/$metadata_tz" ]]; then
        tz="$metadata_tz"
        info "Using timezone from metadata: $tz"
        echo "$tz"
        return 0
    fi
    
    # Try to detect from GCE zone if available
    if curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' >/dev/null 2>&1; then
        local gce_zone
        gce_zone=$(curl -sf -H 'Metadata-Flavor: Google' \
                   'http://metadata.google.internal/computeMetadata/v1/instance/zone' 2>/dev/null | cut -d'/' -f4 || echo "")
        
        info "Detected GCE zone: $gce_zone"
        
        case "$gce_zone" in
            *central2*|*middle-east*) tz="Asia/Riyadh" ;;  # Middle East zones
            *us-central*) tz="America/Chicago" ;;
            *us-east*) tz="America/New_York" ;;
            *us-west*) tz="America/Los_Angeles" ;;
            *europe-west*) tz="Europe/London" ;;
            *europe-central*) tz="Europe/Berlin" ;;
            *asia-southeast*) tz="Asia/Singapore" ;;
            *asia-northeast*) tz="Asia/Tokyo" ;;
            *australia-southeast*) tz="Australia/Sydney" ;;
            *) tz="UTC" ;;
        esac
        
        if [[ -n "$metadata_tz" ]]; then
            warn "Invalid timezone in metadata: $metadata_tz"
            info "Using zone-based detection: $tz"
        else
            info "No timezone metadata, using zone-based detection: $tz"
        fi
    else
        # Not on GCE, try to detect from system
        local current_tz
        current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")
        tz="$current_tz"
        info "Using current system timezone: $tz"
    fi
    
    echo "$tz"
}

configure_system_timezone() {
    local target_tz="$1"
    section "Configuring System Timezone"
    
    if [[ ! -f "/usr/share/zoneinfo/$target_tz" ]]; then
        error "Timezone not found in system: $target_tz"
        info "Available zones matching pattern:"
        find /usr/share/zoneinfo -name "*$(basename "$target_tz")*" 2>/dev/null | head -10 || true
        return 1
    fi
    
    info "Setting system timezone to: $target_tz"
    
    # Use timedatectl if available (preferred method)
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl set-timezone "$target_tz"; then
            success "System timezone set using timedatectl"
        else
            error "Failed to set timezone using timedatectl"
            return 1
        fi
        
        # Enable NTP synchronization if not already enabled
        local ntp_status
        ntp_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
        if [[ "$ntp_status" != "yes" ]]; then
            info "Enabling NTP synchronization..."
            if timedatectl set-ntp true; then
                success "NTP synchronization enabled"
            else
                warn "Failed to enable NTP synchronization"
            fi
        else
            success "NTP synchronization already active"
        fi
    else
        # Fallback method for older systems
        info "Using traditional timezone configuration method"
        ln -sf "/usr/share/zoneinfo/$target_tz" /etc/localtime
        echo "$target_tz" > /etc/timezone
        success "System timezone set using traditional method"
    fi
    
    # Verify timezone was set correctly
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
    if [[ "$current_tz" == "$target_tz" ]]; then
        success "System timezone verified: $current_tz"
    else
        error "System timezone verification failed - expected: $target_tz, got: $current_tz"
        return 1
    fi
    
    # Show current system time
    info "Current system time: $(date)"
    
    return 0
}

configure_postgresql_timezone() {
    local target_tz="$1"
    section "Configuring PostgreSQL Timezone"
    
    # Check if PostgreSQL is running
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        error "PostgreSQL is not running. Please start PostgreSQL first."
        return 1
    fi
    
    # Wait for PostgreSQL to be ready
    local retries=0
    while [[ $retries -lt 30 ]]; do
        if sudo -u postgres psql -c "SELECT 1" >&/dev/null; then
            break
        fi
        ((retries++))
        sleep 2
        info "Waiting for PostgreSQL to be ready... ($retries/30)"
    done
    
    if [[ $retries -eq 30 ]]; then
        error "PostgreSQL not responding after 60 seconds"
        return 1
    fi
    
    info "Setting PostgreSQL timezone to: $target_tz"
    
    # Set PostgreSQL timezone
    if sudo -u postgres psql <<EOF
-- Show current timezone
SELECT 'Current PostgreSQL timezone: ' || current_setting('timezone') as current_tz;

-- Set timezone for current session
SET timezone = '$target_tz';

-- Set timezone permanently in postgresql.conf
ALTER SYSTEM SET timezone = '$target_tz';

-- Reload configuration to apply changes
SELECT pg_reload_conf();

-- Verify new timezone setting
SELECT 'PostgreSQL timezone updated to: ' || current_setting('timezone') as new_tz;
SELECT 'Current PostgreSQL time: ' || now()::text as current_time;
EOF
    then
        success "PostgreSQL timezone configuration completed"
    else
        error "Failed to configure PostgreSQL timezone"
        return 1
    fi
    
    # Verify the timezone was set correctly
    local pg_tz
    pg_tz=$(sudo -u postgres psql -Atqc "SHOW timezone;" 2>/dev/null || echo "unknown")
    
    if [[ "$pg_tz" == "$target_tz" ]]; then
        success "PostgreSQL timezone verified: $pg_tz"
    else
        error "PostgreSQL timezone verification failed - expected: $target_tz, got: $pg_tz"
        return 1
    fi
    
    return 0
}

verify_timezone_synchronization() {
    section "Verifying Timezone Synchronization"
    
    # Get current timezones
    local system_tz pg_tz
    system_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
    pg_tz=$(sudo -u postgres psql -Atqc "SHOW timezone;" postgres 2>/dev/null || echo "unknown")
    
    info "Timezone Status:"
    info "  System timezone: $system_tz"
    info "  PostgreSQL timezone: $pg_tz"
    
    if [[ "$system_tz" == "$pg_tz" ]]; then
        success "✅ System and PostgreSQL timezones are synchronized"
    else
        error "❌ Timezone mismatch detected!"
        return 1
    fi
    
    # Check time synchronization
    info "Time Verification:"
    info "  System time: $(date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
    
    local pg_time_formatted
    pg_time_formatted=$(sudo -u postgres psql -Atqc "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS TZ (OF)');" postgres 2>/dev/null || echo "unknown")
    info "  PostgreSQL time: $pg_time_formatted"
    
    # Check for time differences
    local system_epoch pg_epoch time_diff
    system_epoch=$(date +%s)
    pg_epoch=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(EPOCH FROM now())::bigint;" postgres 2>/dev/null || echo "0")
    
    if [[ "$pg_epoch" != "0" ]] && [[ "$system_epoch" != "0" ]]; then
        time_diff=$((system_epoch - pg_epoch))
        if [[ ${time_diff#-} -lt 5 ]]; then  # Within 5 seconds
            success "✅ System and PostgreSQL times are synchronized (diff: ${time_diff}s)"
        else
            warn "⚠️ Time difference detected: ${time_diff} seconds"
        fi
    fi
    
    # Check NTP status
    if command -v timedatectl >/dev/null 2>&1; then
        local ntp_status
        ntp_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
        if [[ "$ntp_status" == "yes" ]]; then
            success "✅ NTP time synchronization is active"
        else
            warn "⚠️ NTP time synchronization is not active"
        fi
        
        info "Detailed time status:"
        timedatectl status 2>/dev/null | grep -E "synchronized|NTP|Time zone" | sed 's/^/    /' || true
    fi
    
    return 0
}

show_timezone_menu() {
    echo
    info "Available timezone configuration options:"
    echo "1. Auto-detect timezone (recommended)"
    echo "2. Set specific timezone"
    echo "3. Show current timezone status"
    echo "4. List common timezones"
    echo "5. Exit"
    echo
}

list_common_timezones() {
    section "Common Timezones"
    
    info "Popular timezone options:"
    cat << EOF
Americas:
  • America/New_York (US Eastern)
  • America/Chicago (US Central)
  • America/Denver (US Mountain)
  • America/Los_Angeles (US Pacific)
  • America/Toronto (Canada Eastern)

Europe:
  • Europe/London (UK)
  • Europe/Paris (France/Central Europe)
  • Europe/Berlin (Germany)
  • Europe/Rome (Italy)

Asia/Middle East:
  • Asia/Riyadh (Saudi Arabia)
  • Asia/Dubai (UAE)
  • Asia/Tokyo (Japan)
  • Asia/Shanghai (China)
  • Asia/Singapore (Singapore)

Other:
  • UTC (Universal Coordinated Time)
  • Australia/Sydney (Australia)
EOF
}

main() {
    printf "%b" "$BLUE"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║      PostgreSQL HA Timezone Configuration           ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # Check if PostgreSQL is installed
    if ! command -v psql >/dev/null 2>&1; then
        error "PostgreSQL is not installed"
        exit 1
    fi
    
    while true; do
        show_timezone_menu
        read -p "Select an option (1-5): " choice
        
        case $choice in
            1)
                section "Auto-detecting Timezone"
                local detected_tz
                detected_tz=$(detect_appropriate_timezone)
                
                info "Detected timezone: $detected_tz"
                read -p "Apply this timezone? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if configure_system_timezone "$detected_tz" && configure_postgresql_timezone "$detected_tz"; then
                        verify_timezone_synchronization
                        success "Timezone configuration completed successfully!"
                    else
                        error "Timezone configuration failed"
                    fi
                fi
                ;;
                
            2)
                echo
                read -p "Enter timezone (e.g., Asia/Riyadh, UTC, America/New_York): " user_tz
                if [[ -n "$user_tz" ]]; then
                    if configure_system_timezone "$user_tz" && configure_postgresql_timezone "$user_tz"; then
                        verify_timezone_synchronization
                        success "Timezone configuration completed successfully!"
                    else
                        error "Timezone configuration failed"
                    fi
                else
                    warn "No timezone specified"
                fi
                ;;
                
            3)
                verify_timezone_synchronization
                ;;
                
            4)
                list_common_timezones
                ;;
                
            5)
                info "Exiting timezone configuration"
                break
                ;;
                
            *)
                warn "Invalid choice. Please select 1-5."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

main "$@"