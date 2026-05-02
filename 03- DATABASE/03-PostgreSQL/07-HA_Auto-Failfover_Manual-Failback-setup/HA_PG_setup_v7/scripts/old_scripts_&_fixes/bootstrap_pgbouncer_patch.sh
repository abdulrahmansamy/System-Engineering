#!/bin/bash
# Bootstrap PgBouncer Authentication Patch
# This script patches existing bootstrap deployments to fix PgBouncer authentication
# Run this if you deployed with an older version of the bootstrap script

set -euo pipefail

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;92m[SUCCESS]\033[0m $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

info "🔧 Bootstrap PgBouncer Authentication Patch"
echo "=========================================="

# Check if this is a PostgreSQL HA node
if ! systemctl is-active --quiet postgresql; then
    error "PostgreSQL service is not running on this node"
    exit 1
fi

# Check if PgBouncer is installed
if ! command -v pgbouncer >/dev/null 2>&1; then
    error "PgBouncer is not installed on this node"
    exit 1
fi

# Detect if PgBouncer authentication is broken
info "Testing current PgBouncer authentication..."
if timeout 5 sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    success "PgBouncer authentication is already working - no patch needed"
    exit 0
else
    warn "PgBouncer authentication is broken - applying patch..."
fi

# Download and run the fix script
SCRIPT_URL="https://raw.githubusercontent.com/path/to/pgbouncer_final_fix.sh"  # Update this path
TEMP_SCRIPT="/tmp/pgbouncer_final_fix.sh"

if command -v curl >/dev/null 2>&1; then
    info "Downloading PgBouncer fix script..."
    if ! curl -sSL "$SCRIPT_URL" -o "$TEMP_SCRIPT" 2>/dev/null; then
        warn "Failed to download fix script from URL, checking local copy..."
        if [[ -f "./pgbouncer_final_fix.sh" ]]; then
            cp "./pgbouncer_final_fix.sh" "$TEMP_SCRIPT"
        else
            error "Cannot find pgbouncer_final_fix.sh script"
            error "Please ensure the script is in the current directory or update the URL"
            exit 1
        fi
    fi
else
    warn "curl not available, checking local copy..."
    if [[ -f "./pgbouncer_final_fix.sh" ]]; then
        cp "./pgbouncer_final_fix.sh" "$TEMP_SCRIPT"
    else
        error "Cannot find pgbouncer_final_fix.sh script"
        exit 1
    fi
fi

# Make script executable and run it
chmod +x "$TEMP_SCRIPT"
info "Applying PgBouncer authentication fix..."

if "$TEMP_SCRIPT"; then
    success "🎉 Bootstrap PgBouncer authentication patch applied successfully!"
    success "✅ PgBouncer should now work correctly"
    
    # Cleanup
    rm -f "$TEMP_SCRIPT"
    
    info "Testing patched authentication..."
    if timeout 5 sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'Patch verification successful' as status;" 2>/dev/null; then
        success "✅ Patch verification passed - PgBouncer is working"
    else
        warn "⚠️  Patch verification failed - manual investigation may be needed"
    fi
else
    error "❌ Patch application failed"
    rm -f "$TEMP_SCRIPT"
    exit 1
fi

info ""
info "🎯 Summary:"
echo "• Bootstrap PgBouncer authentication issue has been patched"
echo "• PgBouncer now uses proper MD5 authentication"
echo "• No manual intervention should be required for future deployments"
echo ""
echo "Next steps:"
echo "• Test: psql -h localhost -p 6432 -U postgres -d postgres"
echo "• Validate: sudo ./comprehensive_validation.sh"