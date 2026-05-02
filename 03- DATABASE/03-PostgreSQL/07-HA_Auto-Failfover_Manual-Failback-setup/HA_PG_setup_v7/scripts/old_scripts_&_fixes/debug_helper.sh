#!/bin/bash
# =============================================================================
# Debug Helper for PostgreSQL HA Automated Testing Suite
# =============================================================================

show_usage() {
    echo "Usage: $0 [on|off|verbose]"
    echo ""
    echo "Commands:"
    echo "  on      - Enable debug mode"
    echo "  off     - Disable debug mode" 
    echo "  verbose - Enable maximum verbosity"
    echo ""
    echo "Current environment:"
    echo "  DEBUG_MODE=${DEBUG_MODE:-false}"
    echo "  VERBOSE_SQL=${VERBOSE_SQL:-false}"
    echo "  SHOW_COMMANDS=${SHOW_COMMANDS:-false}"
}

case "${1:-}" in
    "on")
        export DEBUG_MODE=true
        export VERBOSE_SQL=true
        export SHOW_COMMANDS=false
        echo "✅ Debug mode enabled"
        echo "   DEBUG_MODE=true"
        echo "   VERBOSE_SQL=true"
        echo "   SHOW_COMMANDS=false"
        echo ""
        echo "Run the HA tester now to see detailed debugging information."
        ;;
    "off")
        export DEBUG_MODE=false
        export VERBOSE_SQL=false
        export SHOW_COMMANDS=false
        echo "✅ Debug mode disabled"
        echo "   DEBUG_MODE=false"
        echo "   VERBOSE_SQL=false"
        echo "   SHOW_COMMANDS=false"
        ;;
    "verbose")
        export DEBUG_MODE=true
        export VERBOSE_SQL=true
        export SHOW_COMMANDS=true
        echo "✅ Maximum verbosity enabled"
        echo "   DEBUG_MODE=true"
        echo "   VERBOSE_SQL=true"
        echo "   SHOW_COMMANDS=true"
        echo ""
        echo "⚠️  Warning: This will show all commands and SQL output"
        ;;
    *)
        show_usage
        ;;
esac

# Save to environment file for persistence
if [[ "${1:-}" =~ ^(on|off|verbose)$ ]]; then
    cat > .debug_env << EOF
export DEBUG_MODE=$DEBUG_MODE
export VERBOSE_SQL=$VERBOSE_SQL
export SHOW_COMMANDS=$SHOW_COMMANDS
EOF
    echo ""
    echo "💾 Debug settings saved to .debug_env"
    echo "   Source with: source .debug_env"
fi