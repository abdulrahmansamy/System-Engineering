#!/bin/bash
# PostgreSQL HA Cluster GCS Backup Setup Script
# Configures automated backups to Google Cloud Storage
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PG_VERSION="17"
BACKUP_DIR="/var/backups/postgresql"
SCRIPT_DIR="/usr/local/bin"

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

get_metadata_value() {
    local key="$1"
    curl -sf -H 'Metadata-Flavor: Google' \
         "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "unknown"
}

setup_backup_directory() {
    section "Setting up Backup Directory"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        info "Creating backup directory: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
        chown postgres:postgres "$BACKUP_DIR"
        chmod 750 "$BACKUP_DIR"
        success "Backup directory created"
    else
        success "Backup directory already exists"
    fi
    
    # Create subdirectories
    local subdirs=("dumps" "basebackups" "wals" "logs")
    for subdir in "${subdirs[@]}"; do
        if [[ ! -d "$BACKUP_DIR/$subdir" ]]; then
            mkdir -p "$BACKUP_DIR/$subdir"
            chown postgres:postgres "$BACKUP_DIR/$subdir"
            success "Created subdirectory: $subdir"
        fi
    done
}

create_backup_script() {
    section "Creating Backup Scripts"
    
    local backup_script="$SCRIPT_DIR/pg-backup-to-gcs.sh"
    
    info "Creating PostgreSQL backup script..."
    
    cat > "$backup_script" << 'EOF'
#!/bin/bash
# PostgreSQL Backup to GCS Script
# Auto-generated - Edit with caution

set -euo pipefail

# Configuration
BACKUP_DIR="/var/backups/postgresql"
PG_VERSION="17"
RETENTION_DAYS=30

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }
error() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; }
success() { printf "${GREEN}SUCCESS:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}WARNING:${NC} %s\n" "$*"; }

get_pg_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        echo "standby"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
        echo "primary"
    else
        echo "unknown"
    fi
}

get_metadata_value() {
    local key="$1"
    curl -sf -H 'Metadata-Flavor: Google' \
         "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "unknown"
}

backup_to_gcs() {
    local backup_type="$1"
    local role
    role=$(get_pg_role)
    
    log "Starting $backup_type backup (role: $role)"
    
    # Get GCS bucket from metadata
    local org_code env_code gcs_bucket
    org_code=$(get_metadata_value "org_code")
    env_code=$(get_metadata_value "env_code")
    
    if [[ "$org_code" != "unknown" && "$env_code" != "unknown" ]]; then
        gcs_bucket="${org_code}-${env_code}-backup-postgresql-01"
    else
        error "Cannot determine GCS bucket from metadata"
        return 1
    fi
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local hostname
    hostname=$(hostname)
    
    case "$backup_type" in
        "logical")
            if [[ "$role" == "primary" ]]; then
                log "Creating logical backup (pg_dump)"
                local dump_file="$BACKUP_DIR/dumps/${hostname}_logical_${timestamp}.sql.gz"
                
                if sudo -u postgres pg_dump -h localhost -p 5432 -U postgres --verbose --clean --no-owner --no-privileges postgres | gzip > "$dump_file"; then
                    success "Logical backup created: $dump_file"
                    
                    # Upload to GCS
                    if gsutil cp "$dump_file" "gs://$gcs_bucket/logical-backups/"; then
                        success "Logical backup uploaded to GCS"
                        rm -f "$dump_file"  # Remove local copy after successful upload
                    else
                        error "Failed to upload logical backup to GCS"
                        return 1
                    fi
                else
                    error "Failed to create logical backup"
                    return 1
                fi
            else
                warn "Skipping logical backup on $role node"
            fi
            ;;
            
        "physical")
            if [[ "$role" == "primary" ]]; then
                log "Creating physical backup (pg_basebackup)"
                local base_dir="$BACKUP_DIR/basebackups/${hostname}_physical_${timestamp}"
                
                if sudo -u postgres pg_basebackup -h localhost -p 5432 -U postgres -D "$base_dir" -Ft -z -P; then
                    success "Physical backup created: $base_dir"
                    
                    # Create tar file for upload
                    local tar_file="${base_dir}.tar.gz"
                    if tar -czf "$tar_file" -C "$BACKUP_DIR/basebackups" "$(basename "$base_dir")"; then
                        # Upload to GCS
                        if gsutil cp "$tar_file" "gs://$gcs_bucket/physical-backups/"; then
                            success "Physical backup uploaded to GCS"
                            rm -rf "$base_dir" "$tar_file"  # Cleanup after successful upload
                        else
                            error "Failed to upload physical backup to GCS"
                            return 1
                        fi
                    else
                        error "Failed to create tar file for physical backup"
                        return 1
                    fi
                else
                    error "Failed to create physical backup"
                    return 1
                fi
            else
                warn "Skipping physical backup on $role node"
            fi
            ;;
            
        *)
            error "Unknown backup type: $backup_type"
            return 1
            ;;
    esac
    
    log "Backup completed successfully"
}

cleanup_old_backups() {
    local gcs_bucket="$1"
    
    log "Cleaning up old backups (retention: $RETENTION_DAYS days)"
    
    # Calculate cutoff date
    local cutoff_date
    cutoff_date=$(date -d "$RETENTION_DAYS days ago" +%Y%m%d)
    
    # Cleanup logical backups
    if gsutil ls "gs://$gcs_bucket/logical-backups/" 2>/dev/null | while read -r backup; do
        local backup_date
        backup_date=$(echo "$backup" | grep -o '[0-9]\{8\}' | head -1)
        if [[ -n "$backup_date" && "$backup_date" -lt "$cutoff_date" ]]; then
            log "Removing old backup: $backup"
            gsutil rm "$backup"
        fi
    done; then
        success "Old logical backups cleaned up"
    fi
    
    # Cleanup physical backups
    if gsutil ls "gs://$gcs_bucket/physical-backups/" 2>/dev/null | while read -r backup; do
        local backup_date
        backup_date=$(echo "$backup" | grep -o '[0-9]\{8\}' | head -1)
        if [[ -n "$backup_date" && "$backup_date" -lt "$cutoff_date" ]]; then
            log "Removing old backup: $backup"
            gsutil rm "$backup"
        fi
    done; then
        success "Old physical backups cleaned up"
    fi
}

main() {
    local backup_type="${1:-logical}"
    
    log "PostgreSQL backup script starting"
    
    # Check if running on GCE
    if ! curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' >/dev/null 2>&1; then
        error "Not running on Google Cloud Platform"
        exit 1
    fi
    
    # Check if gcloud is available and authenticated
    if ! command -v gsutil >/dev/null 2>&1; then
        error "gsutil not found - please install Google Cloud SDK"
        exit 1
    fi
    
    # Get GCS bucket info
    local org_code env_code gcs_bucket
    org_code=$(get_metadata_value "org_code")
    env_code=$(get_metadata_value "env_code")
    gcs_bucket="${org_code}-${env_code}-backup-postgresql-01"
    
    # Perform backup
    if backup_to_gcs "$backup_type"; then
        cleanup_old_backups "$gcs_bucket"
        success "Backup process completed successfully"
    else
        error "Backup process failed"
        exit 1
    fi
}

# Log all output
exec > >(tee -a "$BACKUP_DIR/logs/backup.log")
exec 2>&1

main "$@"
EOF

    chmod +x "$backup_script"
    success "Backup script created: $backup_script"
}

create_backup_crontab() {
    section "Setting up Backup Cron Jobs"
    
    local role
    role=$(get_pg_role)
    
    info "Setting up cron jobs for $role node..."
    
    # Create crontab for postgres user
    local cron_file="/tmp/postgres_crontab"
    
    if [[ "$role" == "primary" ]]; then
        cat > "$cron_file" << EOF
# PostgreSQL HA Cluster Backup Cron Jobs
# Logical backup every 6 hours
0 */6 * * * $SCRIPT_DIR/pg-backup-to-gcs.sh logical >/dev/null 2>&1

# Physical backup daily at 2 AM
0 2 * * * $SCRIPT_DIR/pg-backup-to-gcs.sh physical >/dev/null 2>&1

# Cleanup old local files daily at 3 AM
0 3 * * * find $BACKUP_DIR -type f -mtime +2 -delete >/dev/null 2>&1
EOF
    else
        cat > "$cron_file" << EOF
# PostgreSQL HA Cluster Backup Cron Jobs (Standby Node)
# Only cleanup old local files daily at 3 AM
0 3 * * * find $BACKUP_DIR -type f -mtime +2 -delete >/dev/null 2>&1
EOF
    fi
    
    # Install crontab for postgres user
    if sudo -u postgres crontab "$cron_file"; then
        success "Cron jobs installed for postgres user"
    else
        error "Failed to install cron jobs"
        return 1
    fi
    
    rm -f "$cron_file"
    
    # Show current crontab
    info "Current postgres user crontab:"
    sudo -u postgres crontab -l | sed 's/^/    /'
}

setup_gcs_bucket() {
    section "Setting up GCS Bucket"
    
    local org_code env_code gcs_bucket
    org_code=$(get_metadata_value "org_code")
    env_code=$(get_metadata_value "env_code")
    
    if [[ "$org_code" == "unknown" || "$env_code" == "unknown" ]]; then
        error "Cannot determine org_code or env_code from metadata"
        return 1
    fi
    
    gcs_bucket="${org_code}-${env_code}-backup-postgresql-01"
    
    info "Checking GCS bucket: gs://$gcs_bucket"
    
    # Check if bucket exists
    if gsutil ls -b "gs://$gcs_bucket" >/dev/null 2>&1; then
        success "GCS bucket already exists: gs://$gcs_bucket"
    else
        warn "GCS bucket does not exist: gs://$gcs_bucket"
        info "Please create the bucket manually or contact your GCP administrator"
        info "Required bucket: gs://$gcs_bucket"
        return 1
    fi
    
    # Test write access
    local test_file="/tmp/test_backup_access.txt"
    echo "Test backup access $(date)" > "$test_file"
    
    if gsutil cp "$test_file" "gs://$gcs_bucket/test/" && gsutil rm "gs://$gcs_bucket/test/$(basename "$test_file")"; then
        success "GCS bucket write access confirmed"
    else
        error "Cannot write to GCS bucket - check permissions"
        return 1
    fi
    
    rm -f "$test_file"
}

main() {
    printf "%b" "$BLUE"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║         PostgreSQL HA GCS Backup Setup               ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # Check if running on GCE
    if ! curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' >/dev/null 2>&1; then
        error "This script requires Google Cloud Platform metadata"
        exit 1
    fi
    
    info "Setting up GCS backup for PostgreSQL HA cluster..."
    
    setup_backup_directory
    create_backup_script
    setup_gcs_bucket
    create_backup_crontab
    
    success "GCS backup setup completed successfully!"
    
    local role
    role=$(get_pg_role)
    
    info "Backup configuration summary:"
    info "  • Node role: $role"
    info "  • Backup directory: $BACKUP_DIR"
    info "  • Backup script: $SCRIPT_DIR/pg-backup-to-gcs.sh"
    
    if [[ "$role" == "primary" ]]; then
        info "  • Logical backups: Every 6 hours"
        info "  • Physical backups: Daily at 2 AM"
    else
        info "  • Backups run only on primary node"
    fi
    
    info "  • Log cleanup: Daily at 3 AM"
    info ""
    info "To run a manual backup:"
    info "  sudo $SCRIPT_DIR/pg-backup-to-gcs.sh logical"
    info "  sudo $SCRIPT_DIR/pg-backup-to-gcs.sh physical"
}

main "$@"