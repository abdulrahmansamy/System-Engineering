#!/bin/bash
# Setup PostgreSQL 17 Standby with repmgr and PgBouncer for GCP Compute Engine
# Usage: ./02-pgsql_setup-standby-gcp.sh [PRIMARY_IP] [STANDBY_IP]

set -e

# ====================================
# GCP METADATA INTEGRATION
# ====================================
# Function to get metadata from GCE metadata service
get_gce_metadata() {
    local endpoint="$1"
    curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/$endpoint" 2>/dev/null || echo ""
}

# Detect if running on GCE
GCE_INSTANCE=$(get_gce_metadata "instance/name")
if [[ -n "$GCE_INSTANCE" ]]; then
    IS_GCE=true
    echo "Detected GCE environment: $GCE_INSTANCE"
else
    IS_GCE=false
fi

# Get IPs from command line arguments, GCE metadata, or prompt user
PRIMARY_IP="$1"
STANDBY_IP="$2"

# For GCE: Try to get IPs from metadata or instance discovery
if [[ "$IS_GCE" == "true" ]]; then
    # Get standby IP from current instance
    if [[ -z "$STANDBY_IP" ]]; then
        STANDBY_IP=$(get_gce_metadata "instance/network-interfaces/0/ip")
        echo "Detected STANDBY_IP from GCE metadata: $STANDBY_IP"
    fi
    
    # Try to get primary IP from instance attributes or zone instances
    if [[ -z "$PRIMARY_IP" ]]; then
        PRIMARY_IP=$(get_gce_metadata "instance/attributes/primary-ip" 2>/dev/null)
        if [[ -z "$PRIMARY_IP" ]]; then
            # Look for primary instance in the same zone
            PROJECT_ID=$(get_gce_metadata "project/project-id")
            ZONE=$(get_gce_metadata "instance/zone" | cut -d'/' -f4)
            
            # Look for instance with 'primary' in name or postgresql-primary-ready=true
            if command -v gcloud &> /dev/null; then
                PRIMARY_INSTANCE=$(gcloud compute instances list --project="$PROJECT_ID" --zones="$ZONE" --filter="name~primary OR metadata.postgresql-primary-ready=true" --format="value(networkInterfaces[0].networkIP)" 2>/dev/null | head -1)
                if [[ -n "$PRIMARY_INSTANCE" ]]; then
                    PRIMARY_IP="$PRIMARY_INSTANCE"
                    echo "Detected PRIMARY_IP from GCE instances: $PRIMARY_IP"
                fi
            fi
        else
            echo "Detected PRIMARY_IP from instance attributes: $PRIMARY_IP"
        fi
    fi
    
    # Wait for primary to be ready (GCE-specific)
    if [[ -n "$PRIMARY_IP" ]]; then
        echo -e "${CYAN}${BOLD}Waiting for primary instance to be ready...${RESET}"
        RETRY_COUNT=0
        MAX_RETRIES=30
        
        while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
            if curl -s --connect-timeout 5 "http://${PRIMARY_IP}:8080" | grep -q "Healthy"; then
                echo "Primary instance is ready!"
                break
            fi
            
            echo "Waiting for primary... (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
            sleep 30
            ((RETRY_COUNT++))
        done
        
        if [[ $RETRY_COUNT -eq $MAX_RETRIES ]]; then
            echo -e "${YELLOW}Warning: Primary health check failed, proceeding anyway${RESET}"
        fi
    fi
fi

# Color codes
BOLD="\e[1m"
GREEN="\e[1;32m"
CYAN="\e[1;36m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
RESET="\e[0m"

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Get PRIMARY_IP if not provided
if [[ -z "$PRIMARY_IP" ]]; then
    if [[ "$IS_GCE" == "true" ]]; then
        echo -e "${RED}${BOLD}Cannot determine PRIMARY_IP automatically. Please set it via:${RESET}"
        echo -e "${YELLOW}1. Instance attribute: gcloud compute instances add-metadata INSTANCE --metadata=primary-ip=IP${RESET}"
        echo -e "${YELLOW}2. Command line argument: $0 PRIMARY_IP STANDBY_IP${RESET}"
        exit 1
    else
        echo -e "${YELLOW}${BOLD}PRIMARY_IP not provided as argument.${RESET}"
        while true; do
            echo -e "${CYAN}Please enter the PRIMARY server IP address: ${RESET}"
            read -r PRIMARY_IP
            if validate_ip "$PRIMARY_IP"; then
                break
            else
                echo -e "${RED}Invalid IP address format. Please try again.${RESET}"
            fi
        done
    fi
fi

# Get STANDBY_IP if not provided
if [[ -z "$STANDBY_IP" ]]; then
    if [[ "$IS_GCE" == "true" ]]; then
        echo -e "${RED}${BOLD}Cannot determine STANDBY_IP automatically. Please set it via:${RESET}"
        echo -e "${YELLOW}1. Instance attribute: gcloud compute instances add-metadata INSTANCE --metadata=standby-ip=IP${RESET}"
        echo -e "${YELLOW}2. Command line argument: $0 PRIMARY_IP STANDBY_IP${RESET}"
        exit 1
    else
        echo -e "${YELLOW}${BOLD}STANDBY_IP not provided as argument.${RESET}"
        while true; do
            echo -e "${CYAN}Please enter the STANDBY server IP address: ${RESET}"
            read -r STANDBY_IP
            if validate_ip "$STANDBY_IP"; then
                break
            else
                echo -e "${RED}Invalid IP address format. Please try again.${RESET}"
            fi
        done
    fi
fi

# For GCE user-data: skip interactive confirmation
if [[ "$IS_GCE" == "true" ]]; then
    echo -e "${CYAN}${BOLD}GCE User-data mode - proceeding automatically${RESET}"
    echo -e "${YELLOW}Primary IP: ${PRIMARY_IP}${RESET}"
    echo -e "${YELLOW}Standby IP: ${STANDBY_IP}${RESET}"
    
    # Log to GCE console
    logger -t postgresql-setup "Starting PostgreSQL HA standby setup: Primary=$PRIMARY_IP, Standby=$STANDBY_IP"
else
    echo -e "${YELLOW}${BOLD}Configuration:${RESET}"
    echo -e "${YELLOW}Primary IP: ${PRIMARY_IP}${RESET}"
    echo -e "${YELLOW}Standby IP: ${STANDBY_IP}${RESET}"
    echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort...${RESET}"
    read
fi

# Update packages (non-interactive for GCE)
export DEBIAN_FRONTEND=noninteractive
sudo apt update -y
sudo apt upgrade -y

# For GCE: Install gcloud SDK if not present
if [[ "$IS_GCE" == "true" ]] && ! command -v gcloud &> /dev/null; then
    echo -e "${CYAN}${BOLD}Installing Google Cloud SDK...${RESET}"
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
    sudo apt update -y
    sudo apt install -y google-cloud-sdk
fi

echo -e "${CYAN}${BOLD}Installing PostgreSQL 17 and repmgr...${RESET}"
sudo apt install -y curl ca-certificates gnupg lsb-release netcat-openbsd

# Add PGDG repo
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -sSf -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
VERSION_CODENAME=$(lsb_release -cs)
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update -y
sudo apt install -y postgresql-17 postgresql-client-17 postgresql-doc-17 repmgr pgbouncer

echo -e "${CYAN}${BOLD}Configuring repmgr...${RESET}"
sudo tee /etc/repmgr.conf > /dev/null <<EOF
node_id=2
node_name='standby'
conninfo='host=${STANDBY_IP} user=repmgr dbname=repmgr password=StrongPass'
data_directory='/var/lib/postgresql/17/main'

# Automatic failover settings
failover='automatic'
promote_command='/usr/bin/repmgr standby promote -f /etc/repmgr.conf --log-to-file'
follow_command='/usr/bin/repmgr standby follow -f /etc/repmgr.conf --log-to-file --upstream-node-id=%n'
monitoring_history=yes
monitor_interval_secs=2
EOF

echo -e "${CYAN}${BOLD}Cloning data from primary...${RESET}"
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/17/main
sudo -u postgres repmgr -h ${PRIMARY_IP} -U repmgr -d repmgr -f /etc/repmgr.conf standby clone

echo -e "${CYAN}${BOLD}Starting PostgreSQL and registering standby...${RESET}"
sudo systemctl start postgresql
sudo -u postgres repmgr -f /etc/repmgr.conf standby register

echo -e "${CYAN}${BOLD}Configuring PgBouncer...${RESET}"
sudo tee /etc/pgbouncer/pgbouncer.ini > /dev/null <<EOF
[databases]
repmgr = host=127.0.0.1 port=5432 dbname=repmgr user=repmgr password=StrongPass

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 100
default_pool_size = 20
EOF

echo '"repmgr" "StrongPass"' | sudo tee /etc/pgbouncer/userlist.txt

sudo systemctl enable pgbouncer repmgrd
sudo systemctl restart pgbouncer repmgrd

echo -e "${CYAN}${BOLD}Setting up standby backup infrastructure...${RESET}"
# Create backup directories for standby
sudo mkdir -p /var/backups/postgresql/{base,logical,scripts}
sudo chown postgres:postgres /var/backups/postgresql/{base,logical,scripts}
sudo chmod 750 /var/backups/postgresql/{base,logical,scripts}

# Create standby backup script (offload primary)
sudo tee /var/backups/postgresql/scripts/pg_standby_backup.sh > /dev/null <<EOF
#!/bin/bash
# PostgreSQL Standby Backup Script (Read-only backups to offload primary)
BACKUP_DIR="/var/backups/postgresql"
DATE=\$(date +%Y%m%d_%H%M%S)
STANDBY_IP="${STANDBY_IP}"
RETENTION_DAYS=7

echo "\$(date): Starting standby backup (offloading primary)"

# Base backup from standby (reduces primary load)
sudo -u postgres pg_basebackup -h \$STANDBY_IP -D \$BACKUP_DIR/base/standby_backup_\$DATE -Ft -z -Xs -P

# Logical backup from standby
sudo -u postgres pg_dump -h \$STANDBY_IP -d repmgr -Fc > \$BACKUP_DIR/logical/repmgr_standby_\$DATE.dump

# Clean old backups
find \$BACKUP_DIR/base -name "standby_backup_*" -mtime +\$RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null
find \$BACKUP_DIR/logical -name "*_standby_*" -mtime +\$RETENTION_DAYS -delete 2>/dev/null

echo "\$(date): Standby backup completed"
EOF

sudo chmod +x /var/backups/postgresql/scripts/pg_standby_backup.sh

# GCE health check endpoint for standby
if [[ "$IS_GCE" == "true" ]]; then
    echo -e "${CYAN}${BOLD}Setting up GCE health check endpoint for standby...${RESET}"
    
    sudo tee /etc/systemd/system/postgresql-health.service > /dev/null <<EOF
[Unit]
Description=PostgreSQL Standby Health Check Service for GCE Load Balancer
After=postgresql.service repmgrd.service

[Service]
Type=simple
User=postgres
ExecStart=/bin/bash -c 'while true; do if sudo -u postgres psql -t -c "SELECT 1" >/dev/null 2>&1; then echo -e "HTTP/1.1 200 OK\nContent-Type: text/plain\n\nPostgreSQL Standby: Healthy" | nc -l -p 8080 -q 1; else echo -e "HTTP/1.1 503 Service Unavailable\nContent-Type: text/plain\n\nPostgreSQL Standby: Unhealthy" | nc -l -p 8080 -q 1; fi; done'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl enable postgresql-health
    sudo systemctl start postgresql-health
fi

# Create startup completion marker for GCE
if [[ "$IS_GCE" == "true" ]]; then
    echo "$(date): PostgreSQL standby setup completed" | sudo tee /var/log/postgresql-setup-complete.log
    logger -t postgresql-setup "PostgreSQL HA standby setup completed successfully"
    
    # Set instance metadata to indicate completion
    gcloud compute instances add-metadata "$GCE_INSTANCE" --metadata=postgresql-standby-ready=true --quiet 2>/dev/null || echo "Could not set completion metadata"
fi

echo -e "${GREEN}${BOLD}PostgreSQL HA Standby setup complete!${RESET}"

if [[ "$IS_GCE" == "true" ]]; then
    echo -e "${CYAN}${BOLD}GCP-specific features configured:${RESET}"
    echo -e "${CYAN}  ✓ Automatic primary detection and waiting${RESET}"
    echo -e "${CYAN}  ✓ Health check endpoint for standby (port 8080)${RESET}"
    echo -e "${CYAN}  ✓ Instance metadata integration${RESET}"
    echo -e "${CYAN}  ✓ Backup scripts for offloading primary${RESET}"
fi

echo -e "${YELLOW}${BOLD}Configuration Summary:${RESET}"
echo -e "${YELLOW}  Primary IP: ${PRIMARY_IP}${RESET}"
echo -e "${YELLOW}  Standby IP: ${STANDBY_IP}${RESET}"
echo -e "${CYAN}  PostgreSQL Port: 5432${RESET}"
echo -e "${CYAN}  PgBouncer Port: 6432${RESET}"
echo -e "${CYAN}  Health Check Port: 8080${RESET}"

echo -e "${GREEN}${BOLD}Cluster setup complete! You can now check cluster status with:${RESET}"
echo -e "${GREEN}sudo -u postgres repmgr -f /etc/repmgr.conf cluster show${RESET}"
