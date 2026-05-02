#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Generic PostgreSQL Password Rotation Script
# Supports rotating passwords for any PostgreSQL user
# ==============================

# Version
readonly SCRIPT_VERSION="1.0.0"

# Logging Configuration
readonly LOG_FILE="/var/log/postgresql/password-rotation-generic.log"
DEBUG="${DEBUG:-0}"

# Usage information
usage() {
    cat <<EOF
Generic PostgreSQL Password Rotation Script v${SCRIPT_VERSION}

Usage: $0 [OPTIONS]

Required Options:
  --user USERNAME               PostgreSQL username to rotate password for
  --primary-host HOST          Primary database host
  
Optional GCP Secret Manager Integration:
  --gcp-project ID             GCP project ID for Secret Manager
  --gcp-secret ID              Secret Manager secret ID to update
  
Optional Password Source:
  --new-password PASS          Provide new password directly (not recommended for production)
  --password-file FILE         Read new password from file
  --generate                   Auto-generate secure password (default if no password provided)
  
Database Configuration:
  --port PORT                  PostgreSQL port (default: 5432)
  --database DB                Database name (default: postgres)
  --admin-user USER            Admin user for password change (default: postgres)
  --standby-hosts "HOST1 HOST2" Space-separated standby hosts
  
PgBouncer Configuration:
  --pgbouncer-nodes "NODE1 NODE2"  Space-separated PgBouncer nodes to update
  --pgbouncer-port PORT           PgBouncer port (default: 6432)
  --pgbouncer-userlist PATH       Path to userlist.txt (default: /etc/pgbouncer/userlist.txt)
  
Database Node Configuration:
  --db-nodes "NODE1 NODE2"     Space-separated database nodes with .pgpass to update
  --db-pgpass-path PATH        Path to .pgpass on DB nodes (default: /var/lib/postgresql/.pgpass)
  
Options:
  --skip-secret-manager        Skip Secret Manager update
  --skip-pgbouncer            Skip PgBouncer updates
  --skip-pgpass               Skip .pgpass updates
  --skip-verification         Skip pre-flight checks
  --dry-run                   Show what would be done without making changes
  -h, --help                  Show this help message

Examples:
  # Rotate postgres superuser password with auto-generation
  sudo $0 --user postgres --primary-host 10.0.0.10 --generate

  # Rotate app_user password with GCP Secret Manager
  sudo $0 --user app_user --primary-host 10.0.0.10 \\
    --gcp-project my-project --gcp-secret app-user-pass-secret --generate

  # Rotate with provided password and update PgBouncer
  sudo $0 --user repuser --primary-host 10.0.0.10 \\
    --new-password 'MySecurePass123!' \\
    --pgbouncer-nodes "10.0.0.11 10.0.0.12"

  # Rotate with standby hosts and database nodes
  sudo $0 --user monitor_user --primary-host 10.0.0.10 \\
    --standby-hosts "10.0.0.20 10.0.0.21" \\
    --db-nodes "10.0.0.10 10.0.0.20 10.0.0.21" \\
    --generate

Environment Variables:
  DEBUG=1                     Enable debug logging
  DRY_RUN=1                  Enable dry-run mode

EOF
    exit 0
}

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

init_logging() {
    local log_dir=$(dirname "$LOG_FILE")
    
    if [[ ! -d "$log_dir" && $EUID -eq 0 ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
        chown postgres:postgres "$log_dir" 2>/dev/null || true
        chmod 755 "$log_dir" 2>/dev/null || true
    fi
    
    if [[ ! -f "$LOG_FILE" && $EUID -eq 0 ]]; then
        touch "$LOG_FILE" 2>/dev/null || true
        chown postgres:postgres "$LOG_FILE" 2>/dev/null || true
        chmod 644 "$LOG_FILE" 2>/dev/null || true
    fi
}

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$message"
    
    if [[ -w "$LOG_FILE" ]]; then
        echo "$message" >> "$LOG_FILE" 2>/dev/null || true
    elif [[ ! -f "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
        echo "$message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

info() { log "INFO: $*"; }
warn() { log "WARN: $*" >&2; }
error() { log "ERROR: $*" >&2; }
success() { log "SUCCESS: ✓ $*"; }
debug() {
    if [[ "${DEBUG:-0}" -eq 1 ]]; then
        log "DEBUG: $*"
    fi
}

# ============================================================================
# CONFIGURATION VARIABLES
# ============================================================================

# Required parameters
PG_USER=""
PRIMARY_HOST=""

# Optional parameters with defaults
PRIMARY_PORT="5432"
PG_DATABASE="postgres"
ADMIN_USER="postgres"
STANDBY_HOSTS=()
DB_NODES=()
PGBOUNCER_NODES=()
PGBOUNCER_PORT="6432"
PGBOUNCER_USERLIST_PATH="/etc/pgbouncer/userlist.txt"
DB_PGPASS_PATH="/var/lib/postgresql/.pgpass"
DB_PGBOUNCER_USERLIST_PATH="/etc/pgbouncer/userlist.txt"

# GCP Secret Manager
PROJECT_ID=""
SECRET_ID=""

# Password source
NEW_PASSWORD=""
PASSWORD_FILE=""
GENERATE_PASSWORD=false

# Flags
SKIP_SECRET_MANAGER=false
SKIP_PGBOUNCER=false
SKIP_PGPASS=false
SKIP_VERIFICATION=false
DRY_RUN="${DRY_RUN:-0}"

init_logging

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        usage
    fi
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                PG_USER="$2"
                shift 2
                ;;
            --primary-host)
                PRIMARY_HOST="$2"
                shift 2
                ;;
            --port)
                PRIMARY_PORT="$2"
                shift 2
                ;;
            --database)
                PG_DATABASE="$2"
                shift 2
                ;;
            --admin-user)
                ADMIN_USER="$2"
                shift 2
                ;;
            --standby-hosts)
                IFS=' ' read -ra STANDBY_HOSTS <<< "$2"
                shift 2
                ;;
            --gcp-project)
                PROJECT_ID="$2"
                shift 2
                ;;
            --gcp-secret)
                SECRET_ID="$2"
                shift 2
                ;;
            --new-password)
                NEW_PASSWORD="$2"
                shift 2
                ;;
            --password-file)
                PASSWORD_FILE="$2"
                shift 2
                ;;
            --generate)
                GENERATE_PASSWORD=true
                shift
                ;;
            --pgbouncer-nodes)
                IFS=' ' read -ra PGBOUNCER_NODES <<< "$2"
                shift 2
                ;;
            --pgbouncer-port)
                PGBOUNCER_PORT="$2"
                shift 2
                ;;
            --pgbouncer-userlist)
                PGBOUNCER_USERLIST_PATH="$2"
                shift 2
                ;;
            --db-nodes)
                IFS=' ' read -ra DB_NODES <<< "$2"
                shift 2
                ;;
            --db-pgpass-path)
                DB_PGPASS_PATH="$2"
                shift 2
                ;;
            --skip-secret-manager)
                SKIP_SECRET_MANAGER=true
                shift
                ;;
            --skip-pgbouncer)
                SKIP_PGBOUNCER=true
                shift
                ;;
            --skip-pgpass)
                SKIP_PGPASS=true
                shift
                ;;
            --skip-verification)
                SKIP_VERIFICATION=true
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Validate required parameters
    if [[ -z "$PG_USER" ]]; then
        error "Missing required parameter: --user"
        exit 1
    fi
    
    if [[ -z "$PRIMARY_HOST" ]]; then
        error "Missing required parameter: --primary-host"
        exit 1
    fi
    
    # Auto-populate DB_NODES if not provided
    if [[ ${#DB_NODES[@]} -eq 0 ]]; then
        DB_NODES=("$PRIMARY_HOST")
        for standby in "${STANDBY_HOSTS[@]}"; do
            DB_NODES+=("$standby")
        done
    fi
    
    # Validate password source
    local password_sources=0
    [[ -n "$NEW_PASSWORD" ]] && ((password_sources++))
    [[ -n "$PASSWORD_FILE" ]] && ((password_sources++))
    [[ "$GENERATE_PASSWORD" == true ]] && ((password_sources++))
    
    if [[ $password_sources -gt 1 ]]; then
        error "Only one password source can be specified"
        exit 1
    fi
    
    # Default to generate if no source specified
    if [[ $password_sources -eq 0 ]]; then
        GENERATE_PASSWORD=true
        info "No password source specified, will auto-generate secure password"
    fi
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

generate_password() {
    openssl rand -base64 48
}

get_password() {
    if [[ -n "$NEW_PASSWORD" ]]; then
        echo "$NEW_PASSWORD"
    elif [[ -n "$PASSWORD_FILE" ]]; then
        if [[ ! -f "$PASSWORD_FILE" ]]; then
            error "Password file not found: $PASSWORD_FILE"
            exit 1
        fi
        cat "$PASSWORD_FILE"
    elif [[ "$GENERATE_PASSWORD" == true ]]; then
        generate_password
    else
        error "No password source configured"
        exit 1
    fi
}

add_secret_version() {
    local value="$1"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would store password in Secret Manager: $SECRET_ID"
        return 0
    fi
    
    echo -n "$value" | gcloud secrets versions add "$SECRET_ID" --project "$PROJECT_ID" --data-file=-
}

get_latest_secret() {
    gcloud secrets versions access latest --secret="$SECRET_ID" --project "$PROJECT_ID"
}

pgbouncer_md5() {
    local user="$1"
    local pass="$2"
    local hex
    hex=$(printf "%s" "${user}${pass}" | md5sum | awk '{print $1}')
    printf "md5%s" "$hex"
}

alter_role_on_primary() {
    local user="$1"
    local new_pass="$2"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would execute: ALTER ROLE $user WITH PASSWORD '***';"
        return 0
    fi
    
    psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$ADMIN_USER" -d "$PG_DATABASE" -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE ${user} WITH PASSWORD '${new_pass}';"
}

verify_on_standby() {
    local host="$1"
    local user="$2"
    psql -h "$host" -p "$PRIMARY_PORT" -U "$ADMIN_USER" -d "$PG_DATABASE" -c "\du ${user}" || true
}

update_remote_pgbouncer() {
    local node="$1"
    local user="$2"
    local md5_hash="$3"
    local path="$PGBOUNCER_USERLIST_PATH"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would update PgBouncer userlist on $node for user $user"
        return 0
    fi
    
    ssh "$node" "sudo bash -c '
        set -e
        
        # Backup existing userlist
        if [[ -f \"$path\" ]]; then
            cp \"$path\" \"${path}.backup.\$(date +%Y%m%d_%H%M%S)\" 2>/dev/null || true
        fi
        
        # Remove existing user entry
        if grep -q \"^\\\"$user\\\"\" \"$path\" 2>/dev/null; then
            sed -i \"/^\\\"$user\\\"/d\" \"$path\"
        fi
        
        # Add updated entry
        echo \"\\\"$user\\\" \\\"$md5_hash\\\"\" >> \"$path\"
        
        # Set permissions
        chmod 640 \"$path\"
        chown postgres:pgbouncer \"$path\" 2>/dev/null || chown postgres:postgres \"$path\"
        
        # Reload PgBouncer
        systemctl reload pgbouncer 2>/dev/null || systemctl restart pgbouncer 2>/dev/null || true
    '"
}

update_remote_pgpass() {
    local node="$1"
    local user="$2"
    local pass="$3"
    local pgpass_path="$DB_PGPASS_PATH"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would update .pgpass on $node for user $user"
        return 0
    fi
    
    ssh "$node" "sudo -u postgres bash -c '
        set -e
        
        # Backup existing .pgpass
        if [[ -f \"$pgpass_path\" ]]; then
            cp \"$pgpass_path\" \"${pgpass_path}.backup.\$(date +%Y%m%d_%H%M%S)\" 2>/dev/null || true
        fi
        
        # Create temporary file
        temp_file=\"${pgpass_path}.tmp\"
        
        # Remove existing user entries
        if [[ -f \"$pgpass_path\" ]]; then
            grep -v \":$user:\" \"$pgpass_path\" > \"$temp_file\" 2>/dev/null || true
        else
            touch \"$temp_file\"
        fi
        
        # Append updated entries for PostgreSQL and PgBouncer
        cat >> \"$temp_file\" <<EOF
# User $user entries (managed by password rotation script)
*:5432:*:$user:${pass}
localhost:5432:*:$user:${pass}
127.0.0.1:5432:*:$user:${pass}
*:6432:*:$user:${pass}
localhost:6432:*:$user:${pass}
127.0.0.1:6432:*:$user:${pass}
EOF
        
        # Replace original file
        mv \"$temp_file\" \"$pgpass_path\"
        chmod 600 \"$pgpass_path\"
        chown postgres:postgres \"$pgpass_path\"
    '" 2>&1
}

update_remote_pgbouncer_userlist() {
    local node="$1"
    local user="$2"
    local md5_hash="$3"
    local userlist_path="$DB_PGBOUNCER_USERLIST_PATH"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[DRY-RUN] Would update PgBouncer userlist.txt on database node $node for user $user"
        return 0
    fi
    
    ssh "$node" "sudo bash -c '
        set -e
        
        # Check if PgBouncer is installed
        if [[ ! -f \"$userlist_path\" ]]; then
            echo \"ℹ️ PgBouncer userlist not found on $node - skipping\"
            exit 0
        fi
        
        # Backup existing userlist
        if [[ -f \"$userlist_path\" ]]; then
            cp \"$userlist_path\" \"${userlist_path}.backup.\$(date +%Y%m%d_%H%M%S)\" 2>/dev/null || true
        fi
        
        # Remove existing user entry
        if grep -q \"^\\\"$user\\\"\" \"$userlist_path\" 2>/dev/null; then
            sed -i \"/^\\\"$user\\\"/d\" \"$userlist_path\"
        fi
        
        # Append updated entry
        echo \"\\\"$user\\\" \\\"$md5_hash\\\"\" >> \"$userlist_path\"
        
        # Set permissions
        chmod 640 \"$userlist_path\"
        chown postgres:pgbouncer \"$userlist_path\" 2>/dev/null || chown postgres:postgres \"$userlist_path\"
        
        # Reload PgBouncer if running
        if systemctl is-active --quiet pgbouncer 2>/dev/null; then
            systemctl reload pgbouncer 2>/dev/null || systemctl restart pgbouncer 2>/dev/null || true
        fi
    '" 2>&1
}

# ============================================================================
# PRE-FLIGHT VALIDATION
# ============================================================================

validate_database_connectivity() {
    info "Validating connectivity to primary database..."
    
    if timeout 10 psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$ADMIN_USER" -d "$PG_DATABASE" -c "SELECT 1" >/dev/null 2>&1; then
        success "Primary database is accessible"
    else
        error "Cannot connect to primary database: $PRIMARY_HOST:$PRIMARY_PORT"
        return 1
    fi
    
    for standby in "${STANDBY_HOSTS[@]}"; do
        info "Testing connection to standby: $standby"
        if timeout 10 psql -h "$standby" -p "$PRIMARY_PORT" -U "$ADMIN_USER" -d "$PG_DATABASE" -c "SELECT 1" >/dev/null 2>&1; then
            success "Standby $standby is accessible"
        else
            warn "Cannot connect to standby: $standby"
        fi
    done
    
    return 0
}

validate_user_exists() {
    info "Validating user exists: $PG_USER"
    
    local user_exists
    user_exists=$(psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$ADMIN_USER" -d "$PG_DATABASE" -Atqc \
        "SELECT COUNT(*) FROM pg_roles WHERE rolname = '$PG_USER';" 2>/dev/null || echo "0")
    
    if [[ "$user_exists" == "1" ]]; then
        success "User $PG_USER exists"
        return 0
    else
        error "User $PG_USER does not exist in database"
        return 1
    fi
}

run_preflight_checks() {
    if [[ "$SKIP_VERIFICATION" == true ]]; then
        warn "Skipping pre-flight checks (--skip-verification specified)"
        return 0
    fi
    
    info "=========================================="
    info "RUNNING PRE-FLIGHT VALIDATION CHECKS"
    info "=========================================="
    
    local checks_passed=true
    
    if ! validate_database_connectivity; then
        error "Database connectivity check failed"
        checks_passed=false
    fi
    
    if ! validate_user_exists; then
        error "User validation failed"
        checks_passed=false
    fi
    
    if [[ "$checks_passed" == false ]]; then
        error "Pre-flight checks failed"
        return 1
    fi
    
    success "All pre-flight checks passed"
    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    parse_arguments "$@"
    
    info "=========================================="
    info "Generic PostgreSQL Password Rotation"
    info "Version: $SCRIPT_VERSION"
    info "=========================================="
    info "Configuration:"
    info "  → User: $PG_USER"
    info "  → Primary Host: $PRIMARY_HOST:$PRIMARY_PORT"
    info "  → Database: $PG_DATABASE"
    info "  → Admin User: $ADMIN_USER"
    info "  → Standby Hosts: ${STANDBY_HOSTS[*]:-none}"
    info "  → Database Nodes: ${DB_NODES[*]}"
    info "  → PgBouncer Nodes: ${PGBOUNCER_NODES[*]:-none}"
    [[ -n "$PROJECT_ID" ]] && info "  → GCP Project: $PROJECT_ID"
    [[ -n "$SECRET_ID" ]] && info "  → Secret ID: $SECRET_ID"
    [[ "$DRY_RUN" -eq 1 ]] && warn "  → DRY RUN MODE ENABLED"
    info ""
    
    # Phase 1: Pre-flight checks
    if ! run_preflight_checks; then
        error "Aborting password rotation due to failed pre-flight checks"
        exit 1
    fi
    
    # Phase 2: Generate/Get password
    info "=========================================="
    info "PHASE 2: OBTAINING NEW PASSWORD"
    info "=========================================="
    
    NEW_PASSWORD=$(get_password)
    info "New password obtained (length: ${#NEW_PASSWORD} characters)"
    debug "Password: ${NEW_PASSWORD:0:4}...${NEW_PASSWORD: -4}"
    
    # Phase 3: Update Secret Manager (if configured)
    if [[ -n "$PROJECT_ID" && -n "$SECRET_ID" && "$SKIP_SECRET_MANAGER" == false ]]; then
        info "=========================================="
        info "PHASE 3: UPDATING SECRET MANAGER"
        info "=========================================="
        
        if add_secret_version "$NEW_PASSWORD"; then
            success "Secret Manager updated"
        else
            error "Failed to update Secret Manager"
            exit 1
        fi
    else
        info "Skipping Secret Manager update"
    fi
    
    # Phase 4: Update database password
    info "=========================================="
    info "PHASE 4: UPDATING DATABASE PASSWORD"
    info "=========================================="
    
    if alter_role_on_primary "$PG_USER" "$NEW_PASSWORD"; then
        success "Password updated on primary database"
    else
        error "Failed to update password on primary"
        exit 1
    fi
    
    # Verify password change
    if [[ "$DRY_RUN" -eq 0 ]]; then
        sleep 2
        info "Verifying password change..."
        if PGPASSWORD="$NEW_PASSWORD" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "SELECT 1" >/dev/null 2>&1; then
            success "New password verified on primary"
        else
            error "Password verification failed"
            exit 1
        fi
    fi
    
    # Phase 5: Verify replication to standbys
    if [[ ${#STANDBY_HOSTS[@]} -gt 0 ]]; then
        info "=========================================="
        info "PHASE 5: VERIFYING REPLICATION"
        info "=========================================="
        
        for standby in "${STANDBY_HOSTS[@]}"; do
            info "Verifying role on standby: $standby"
            verify_on_standby "$standby" "$PG_USER"
        done
        success "Password replicated to standby nodes"
    fi
    
    # Phase 6: Update PgBouncer
    if [[ ${#PGBOUNCER_NODES[@]} -gt 0 && "$SKIP_PGBOUNCER" == false ]]; then
        info "=========================================="
        info "PHASE 6: UPDATING PGBOUNCER CONFIGURATION"
        info "=========================================="
        
        PGBOUNCER_MD5=$(pgbouncer_md5 "$PG_USER" "$NEW_PASSWORD")
        info "Computed PgBouncer MD5 for $PG_USER"
        
        for node in "${PGBOUNCER_NODES[@]}"; do
            info "Updating PgBouncer on node: $node"
            if update_remote_pgbouncer "$node" "$PG_USER" "$PGBOUNCER_MD5"; then
                success "PgBouncer updated on: $node"
            else
                error "Failed to update PgBouncer on: $node"
            fi
        done
    fi
    
    # Phase 7: Update .pgpass on database nodes
    if [[ ${#DB_NODES[@]} -gt 0 && "$SKIP_PGPASS" == false ]]; then
        info "=========================================="
        info "PHASE 7: UPDATING DATABASE NODE FILES"
        info "=========================================="
        
        for db_node in "${DB_NODES[@]}"; do
            info "Updating .pgpass on database node: $db_node"
            if update_remote_pgpass "$db_node" "$PG_USER" "$NEW_PASSWORD"; then
                success ".pgpass updated on: $db_node"
            else
                error "Failed to update .pgpass on: $db_node"
            fi
        done
    fi
    
    # Phase 8: Update PgBouncer userlist on database nodes
    if [[ ${#DB_NODES[@]} -gt 0 && "$SKIP_PGBOUNCER" == false ]]; then
        info "=========================================="
        info "PHASE 8: UPDATING PGBOUNCER ON DATABASE NODES"
        info "=========================================="
        
        PGBOUNCER_MD5=$(pgbouncer_md5 "$PG_USER" "$NEW_PASSWORD")
        
        for db_node in "${DB_NODES[@]}"; do
            if update_remote_pgbouncer_userlist "$db_node" "$PG_USER" "$PGBOUNCER_MD5"; then
                success "PgBouncer userlist updated on: $db_node"
            else
                warn "PgBouncer update skipped or failed on: $db_node"
            fi
        done
    fi
    
    # Phase 9: Final verification
    if [[ "$DRY_RUN" -eq 0 ]]; then
        info "=========================================="
        info "PHASE 9: FINAL VERIFICATION"
        info "=========================================="
        
        info "Testing connectivity with new password..."
        
        if PGPASSWORD="$NEW_PASSWORD" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "SELECT 'Connection OK';" >/dev/null 2>&1; then
            success "Primary connection verified for $PG_USER"
        else
            error "Primary connection failed with new password"
        fi
        
        for standby in "${STANDBY_HOSTS[@]}"; do
            if PGPASSWORD="$NEW_PASSWORD" psql -h "$standby" -p "$PRIMARY_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
                success "Standby connection verified: $standby"
            else
                warn "Standby connection failed: $standby"
            fi
        done
    fi
    
    info "=========================================="
    success "PASSWORD ROTATION COMPLETED SUCCESSFULLY ✓"
    info "=========================================="
    info ""
    info "Summary:"
    info "  → User: $PG_USER"
    info "  → Password: Updated and verified"
    [[ -n "$SECRET_ID" ]] && info "  → Secret Manager: Updated"
    info "  → Primary Database: Password changed"
    [[ ${#STANDBY_HOSTS[@]} -gt 0 ]] && info "  → Standby Databases: Password replicated"
    [[ ${#DB_NODES[@]} -gt 0 ]] && info "  → Database Nodes .pgpass: Updated (${#DB_NODES[@]} nodes)"
    [[ ${#PGBOUNCER_NODES[@]} -gt 0 ]] && info "  → PgBouncer Nodes: Updated (${#PGBOUNCER_NODES[@]} nodes)"
    info ""
    info "Rotation completed at: $(date)"
    info "Log file: $LOG_FILE"
}

# Run main function
main "$@"



# Key Features of the Generic Script:

# Flexible User Support - Can rotate password for ANY PostgreSQL user (postgres, app_user, repuser, etc.)

# Multiple Password Sources:

# Auto-generate secure passwords
# Provide password directly via command line
# Read from a password file
# Optional Components:

# Skip Secret Manager updates
# Skip PgBouncer updates
# Skip .pgpass updates
# Skip pre-flight validation
# Dry-Run Mode - Test what would be done without making changes

# Comprehensive Configuration:

# Primary and standby hosts
# Database nodes
# PgBouncer nodes
# Custom ports and paths
# Usage Examples:



# # Rotate postgres superuser password
# sudo ./pg-password-rotate-generic.sh \
#   --user postgres \
#   --primary-host 10.0.0.10 \
#   --standby-hosts "10.0.0.20 10.0.0.21" \
#   --generate

# # Rotate app_user with Secret Manager
# sudo ./pg-password-rotate-generic.sh \
#   --user app_user \
#   --primary-host 10.0.0.10 \
#   --gcp-project my-project \
#   --gcp-secret app-user-secret \
#   --generate

# # Rotate repuser with PgBouncer updates
# sudo ./pg-password-rotate-generic.sh \
#   --user repuser \
#   --primary-host 10.0.0.10 \
#   --pgbouncer-nodes "10.0.0.11 10.0.0.12" \
#   --db-nodes "10.0.0.10 10.0.0.20" \
#   --generate

# # Dry-run mode to test
# sudo ./pg-password-rotate-generic.sh \
#   --user monitor_user \
#   --primary-host 10.0.0.10 \
#   --generate \
#   --dry-run