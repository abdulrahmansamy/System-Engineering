#!/bin/bash
# PostgreSQL HA Cluster MOTD Setup Script
# Creates custom message of the day with cluster information
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

REPMGR_CONF_FILE="/etc/repmgr/repmgr.conf"
PG_VERSION="17"

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }


ascii_psql_primary_logo=$(cat <<'EOF'
______         _                 _____  _____ _      ______     _                            
| ___ \       | |               /  ___||  _  | |     | ___ \   (_)                           
| |_/ /__  ___| |_ __ _ _ __ ___\ `--. | | | | |     | |_/ / __ _ _ __ ___   __ _ _ __ _   _ 
|  __/ _ \/ __| __/ _` | '__/ _ \`--. \| | | | |     |  __/ '__| | '_ ` _ \ / _` | '__| | | |
| | | (_) \__ \ || (_| | | |  __/\__/ /\ \/' / |____ | |  | |  | | | | | | | (_| | |  | |_| |
\_|  \___/|___/\__\__, |_|  \___\____/  \_/\_\_____/ \_|  |_|  |_|_| |_| |_|\__,_|_|   \__, |
                   __/ |                                                                __/ |
                  |___/                                                                |___/ 
EOF
)                                                                                             
                                                                                             
                                                                                             
ascii_psql_standby_logo=$(cat <<'EOF'
______         _                 _____  _____ _       _____ _                  _ _           
| ___ \       | |               /  ___||  _  | |     /  ___| |                | | |          
| |_/ /__  ___| |_ __ _ _ __ ___\ `--. | | | | |     \ `--.| |_ __ _ _ __   __| | |__  _   _ 
|  __/ _ \/ __| __/ _` | '__/ _ \`--. \| | | | |      `--. \ __/ _` | '_ \ / _` | '_ \| | | |
| | | (_) \__ \ || (_| | | |  __/\__/ /\ \/' / |____ /\__/ / || (_| | | | | (_| | |_) | |_| |
\_|  \___/|___/\__\__, |_|  \___\____/  \_/\_\_____/ \____/ \__\__,_|_| |_|\__,_|_.__/ \__, |
                   __/ |                                                                __/ |
                  |___/                                                                |___/ 
EOF
)


get_pg_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        echo "STANDBY"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
        echo "PRIMARY"
    else
        echo "UNKNOWN"
    fi
}

create_dynamic_motd_script() {
    section "Creating Dynamic MOTD Script"
    
    local motd_script="/etc/update-motd.d/99-postgresql-cluster"
    
    info "Creating PostgreSQL cluster MOTD script..."
    
    cat > "$motd_script" << 'EOF'
#!/bin/bash
# PostgreSQL HA Cluster Information for MOTD
# Auto-generated - DO NOT EDIT MANUALLY

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Function to get PostgreSQL role
get_pg_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        echo "STANDBY"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
        echo "PRIMARY"
    else
        echo "UNKNOWN"
    fi
}

# Function to get service status
get_service_status() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        printf "${GREEN}●${NC} RUNNING"
    else
        printf "${RED}●${NC} STOPPED"
    fi
}

# Function to get health endpoint status
get_health_status() {
    local port="$1"
    if timeout 2 curl -s "http://localhost:$port" >/dev/null 2>&1; then
        printf "${GREEN}●${NC} HEALTHY"
    else
        printf "${RED}●${NC} DOWN"
    fi
}

# Main MOTD display
printf "${BLUE}${BOLD}"
cat << 'HEADER'
╔══════════════════════════════════════════════════════╗
║            PostgreSQL HA Cluster Node                ║
╚══════════════════════════════════════════════════════╝
HEADER
printf "${NC}"

# Basic system information
printf "\n${CYAN}${BOLD}System Information:${NC}\n"
printf "  Hostname: $(hostname)\n"
printf "  IP Address: $(hostname -I | awk '{print $1}')\n"
printf "  Timezone: $(timedatectl show --property=Timezone --value 2>/dev/null || echo 'Unknown')\n"
printf "  Last Boot: $(uptime -s 2>/dev/null || echo 'Unknown')\n"

# PostgreSQL cluster information
ROLE=$(get_pg_role)
printf "\n${CYAN}${BOLD}PostgreSQL Cluster Status:${NC}\n"
printf "  Node Role: "
case "$ROLE" in
    "PRIMARY")
        printf "${GREEN}${BOLD}PRIMARY${NC} (Read/Write)\n"
        ;;
    "STANDBY")
        printf "${YELLOW}${BOLD}STANDBY${NC} (Read-Only)\n"
        ;;
    *)
        printf "${RED}${BOLD}UNKNOWN${NC}\n"
        ;;
esac

printf "  PostgreSQL: $(get_service_status postgresql)\n"
printf "  Repmgr: $(get_service_status repmgrd)\n"
printf "  PgBouncer: $(get_service_status pgbouncer)\n"

# Health endpoints
printf "\n${CYAN}${BOLD}Health Endpoints:${NC}\n"
printf "  PostgreSQL HA: $(get_health_status 8001)\n"
printf "  PgBouncer: $(get_health_status 8002)\n"

# Connection information
printf "\n${CYAN}${BOLD}Connection Endpoints:${NC}\n"
printf "  Direct PostgreSQL: $(hostname -I | awk '{print $1}'):5432\n"
printf "  PgBouncer Pool: $(hostname -I | awk '{print $1}'):6432\n"

# Replication information
if [[ "$ROLE" == "PRIMARY" ]]; then
    STANDBY_COUNT=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" postgres 2>/dev/null || echo "0")
    printf "  Connected Standbys: $STANDBY_COUNT\n"
elif [[ "$ROLE" == "STANDBY" ]]; then
    LAG=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" postgres 2>/dev/null || echo "unknown")
    if [[ "$LAG" != "unknown" ]]; then
        printf "  Replication Lag: ${LAG}s\n"
    else
        printf "  Replication Lag: Unknown\n"
    fi
fi

# Cluster information
printf "\n${CYAN}${BOLD}Cluster Information:${NC}\n"
if command -v repmgr >/dev/null 2>&1 && [[ -f /etc/repmgr/repmgr.conf ]]; then
    CLUSTER_STATUS=$(sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null | grep -c "running" 2>/dev/null || echo "0")
    printf "  Active Nodes: $CLUSTER_STATUS\n"
else
    printf "  Cluster Status: Configuration not found\n"
fi

# Load balancer endpoints (if available)
if curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' >/dev/null 2>&1; then
    printf "\n${CYAN}${BOLD}Load Balancer Endpoints:${NC}\n"
    printf "  Write: pg-write.db.internal.nprd.ipa.edu.sa:6432\n"
    printf "  Read: pg-read.db.internal.nprd.ipa.edu.sa:6432\n"
fi

# Last update
printf "\n${CYAN}${BOLD}Last Updated:${NC} $(date)\n"

printf "\n${YELLOW}⚠️  This is a production PostgreSQL HA cluster node${NC}\n"
printf "${YELLOW}   Please follow change management procedures${NC}\n\n"
EOF

    chmod +x "$motd_script"
    success "Created dynamic MOTD script: $motd_script"
}

create_static_motd() {
    section "Creating Static MOTD Content"
    
    local role
    role=$(get_pg_role)
    local hostname
    hostname=$(hostname)
    local ip_address
    ip_address=$(hostname -I | awk '{print $1}')
    
    info "Creating static MOTD with current cluster information..."
    
    cat > /etc/motd << EOF
╔══════════════════════════════════════════════════════╗
║            PostgreSQL HA Cluster Node                ║
╚══════════════════════════════════════════════════════╝

System Information:
  Hostname: $hostname
  IP Address: $ip_address
  Node Role: $role
  PostgreSQL Version: $PG_VERSION

Services:
  ● PostgreSQL (port 5432)
  ● PgBouncer (port 6432)  
  ● Repmgr (automatic failover)

Health Endpoints:
  ● PostgreSQL HA: http://$ip_address:8001
  ● PgBouncer: http://$ip_address:8002

Connection Examples:
  Direct:     psql -h $ip_address -p 5432 -U username -d database
  Pooled:     psql -h $ip_address -p 6432 -U username -d database
  
Load Balancer Endpoints:
  Write:      psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U username -d database
  Read:       psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U username -d database

⚠️  This is a production PostgreSQL HA cluster node
   Please follow change management procedures

Last Updated: $(date)
EOF

    success "Created static MOTD: /etc/motd"
}

update_motd() {
    section "Updating MOTD"
    
    info "Updating MOTD..."
    if command -v update-motd >/dev/null 2>&1; then
        update-motd
        success "MOTD updated successfully"
    else
        warn "update-motd command not found, MOTD will update on next login"
    fi
    
    info "Preview of new MOTD:"
    echo "----------------------------------------"
    cat /etc/motd 2>/dev/null || echo "No static MOTD found"
    echo "----------------------------------------"
}

remove_default_motd() {
    section "Removing Default MOTD Components"
    
    # Disable some default Ubuntu MOTD scripts that aren't needed
    local scripts_to_disable=(
        "10-help-text"
        "50-motd-news"
        "80-esm"
        "95-hwe-eol"
    )
    
    for script in "${scripts_to_disable[@]}"; do
        local script_path="/etc/update-motd.d/$script"
        if [[ -f "$script_path" ]]; then
            chmod -x "$script_path"
            info "Disabled default MOTD script: $script"
        fi
    done
}

main() {
    printf "%b" "$BLUE"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║         PostgreSQL HA Cluster MOTD Setup             ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    info "Setting up custom MOTD for PostgreSQL HA cluster..."
    
    # Create both dynamic and static MOTD
    create_dynamic_motd_script
    create_static_motd
    remove_default_motd
    update_motd

    # Disable static pam_motd for SSH to ensure MOTD is shown correctly
    info "Disabling static pam_motd for SSH..."
    sudo sed -i 's/^session\s\+optional\s\+pam_motd.so\s\+noupdate/#&/' /etc/pam.d/sshd

    
    success "MOTD setup completed successfully!"
    info "Users will now see cluster information when they log in"
}

main "$@"