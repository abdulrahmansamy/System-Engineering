#!/bin/bash
# Setup PostgreSQL 17 Primary with repmgr and PgBouncer for GCP Compute Engine
# Usage: ./01-pgsql_setup-primary-gcp.sh [PRIMARY_IP] [STANDBY_IP]
# For GCE user-data: Automatically detects IPs from metadata service

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

# For GCE: Try to get IPs from metadata or instance attributes
if [[ "$IS_GCE" == "true" ]]; then
    # Get primary IP from current instance
    if [[ -z "$PRIMARY_IP" ]]; then
        PRIMARY_IP=$(get_gce_metadata "instance/network-interfaces/0/ip")
        echo "Detected PRIMARY_IP from GCE metadata: $PRIMARY_IP"
    fi
    
    # Try to get standby IP from instance attributes or zone instances
    if [[ -z "$STANDBY_IP" ]]; then
        STANDBY_IP=$(get_gce_metadata "instance/attributes/standby-ip" 2>/dev/null)
        if [[ -z "$STANDBY_IP" ]]; then
            # Try to find standby instance in the same zone
            PROJECT_ID=$(get_gce_metadata "project/project-id")
            ZONE=$(get_gce_metadata "instance/zone" | cut -d'/' -f4)
            
            # Look for instance with 'standby' in name
            if command -v gcloud &> /dev/null; then
                STANDBY_INSTANCE=$(gcloud compute instances list --project="$PROJECT_ID" --zones="$ZONE" --filter="name~standby" --format="value(networkInterfaces[0].networkIP)" 2>/dev/null | head -1)
                if [[ -n "$STANDBY_INSTANCE" ]]; then
                    STANDBY_IP="$STANDBY_INSTANCE"
                    echo "Detected STANDBY_IP from GCE instances: $STANDBY_IP"
                fi
            fi
        else
            echo "Detected STANDBY_IP from instance attributes: $STANDBY_IP"
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
    
    # Log to GCE console for debugging
    logger -t postgresql-setup "Starting PostgreSQL HA primary setup: Primary=$PRIMARY_IP, Standby=$STANDBY_IP"
else
    echo -e "${YELLOW}${BOLD}Configuration:${RESET}"
    echo -e "${YELLOW}Primary IP: ${PRIMARY_IP}${RESET}"
    echo -e "${YELLOW}Standby IP: ${STANDBY_IP}${RESET}"
    echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort...${RESET}"
    read
fi

# Update package cache and install prerequisites
echo -e "${CYAN}${BOLD}Updating system packages...${RESET}"
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
sudo apt install -y curl ca-certificates gnupg lsb-release

# Add PGDG repo
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -sSf -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
VERSION_CODENAME=$(lsb_release -cs)
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update -y
sudo apt install -y postgresql-17 postgresql-client-17 postgresql-doc-17 repmgr pgbouncer

echo -e "${CYAN}${BOLD}Configuring PostgreSQL for replication...${RESET}"
# For GCE: Use specific IPs for better security
sudo sed -i "s/^#listen_addresses.*/listen_addresses = '${PRIMARY_IP},${STANDBY_IP},localhost'/" /etc/postgresql/17/main/postgresql.conf

# Get system memory for tuning
TOTAL_MEM=$(free -m | grep '^Mem:' | awk '{print $2}')
SHARED_BUFFERS=$((TOTAL_MEM / 4))
EFFECTIVE_CACHE_SIZE=$((TOTAL_MEM * 3 / 4))

# GCE-optimized PostgreSQL configuration
echo "# PostgreSQL HA Configuration for GCE
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/17/wal_archive/%f && cp %p /var/lib/postgresql/17/wal_archive/%f'
archive_timeout = 300
shared_preload_libraries = 'repmgr'

# Performance Settings (Auto-tuned for GCE)
shared_buffers = ${SHARED_BUFFERS}MB
effective_cache_size = ${EFFECTIVE_CACHE_SIZE}MB
work_mem = 8MB
maintenance_work_mem = 256MB
max_connections = 150
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_wal_size = 2GB
min_wal_size = 512MB
random_page_cost = 1.1
effective_io_concurrency = 200

# Security Settings
password_encryption = 'scram-sha-256'
log_connections = on
log_disconnections = on
log_lock_waits = on

# Logging Settings
log_destination = 'csvlog'
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on

# Connection Settings
tcp_keepalives_idle = 600
tcp_keepalives_interval = 30
tcp_keepalives_count = 3" | sudo tee -a /etc/postgresql/17/main/postgresql.conf

echo -e "${CYAN}${BOLD}Setting up backup infrastructure...${RESET}"
# Create WAL archive directory
sudo mkdir -p /var/lib/postgresql/17/wal_archive
sudo chown postgres:postgres /var/lib/postgresql/17/wal_archive
sudo chmod 750 /var/lib/postgresql/17/wal_archive

# Create backup directories
sudo mkdir -p /var/backups/postgresql/{base,logical,scripts}
sudo chown postgres:postgres /var/backups/postgresql/{base,logical,scripts}
sudo chmod 750 /var/backups/postgresql/{base,logical,scripts}

# GCE-specific backup configuration with Cloud Storage
if [[ "$IS_GCE" == "true" ]]; then
    echo -e "${CYAN}${BOLD}Configuring GCS backup integration...${RESET}"
    
    PROJECT_ID=$(get_gce_metadata "project/project-id")
    BUCKET_NAME=$(get_gce_metadata "instance/attributes/backup-bucket" 2>/dev/null || echo "${PROJECT_ID}-postgresql-backups")
    
    # Create GCS bucket if it doesn't exist
    gsutil mb -p "$PROJECT_ID" "gs://${BUCKET_NAME}" 2>/dev/null || echo "Bucket gs://${BUCKET_NAME} already exists or insufficient permissions"
    
    # Set lifecycle policy for cost optimization
    gsutil lifecycle set - "gs://${BUCKET_NAME}" << 'LIFECYCLE_EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 30}
    },
    {
      "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
      "condition": {"age": 7}
    }
  ]
}
LIFECYCLE_EOF

    # Enhanced backup script for GCS
    sudo tee /var/backups/postgresql/scripts/pg_ha_gcs_backup.sh > /dev/null <<EOF
#!/bin/bash
# PostgreSQL HA GCS Backup Script
BACKUP_DIR="/var/backups/postgresql"
DATE=\$(date +%Y%m%d_%H%M%S)
BUCKET="gs://${BUCKET_NAME}"
PRIMARY_IP="${PRIMARY_IP}"
INSTANCE_NAME="${GCE_INSTANCE}"
RETENTION_DAYS=7

echo "\$(date): Starting GCS backup for \$INSTANCE_NAME"

# Base backup
echo "\$(date): Creating base backup"
sudo -u postgres pg_basebackup -h \$PRIMARY_IP -D \$BACKUP_DIR/base/base_backup_\$DATE -Ft -z -Xs -P

# Backup cluster configuration
sudo -u postgres pg_dumpall -h \$PRIMARY_IP --roles-only > \$BACKUP_DIR/base/roles_\$DATE.sql
sudo -u postgres pg_dumpall -h \$PRIMARY_IP --tablespaces-only > \$BACKUP_DIR/base/tablespaces_\$DATE.sql

# Logical backup of repmgr database
sudo -u postgres pg_dump -h \$PRIMARY_IP -d repmgr -Fc > \$BACKUP_DIR/logical/repmgr_\$DATE.dump

# Sync to GCS
if command -v gsutil &> /dev/null; then
    echo "\$(date): Syncing backups to GCS bucket: \$BUCKET"
    gsutil -m rsync -r -d \$BACKUP_DIR/base/ \$BUCKET/\$INSTANCE_NAME/base/
    gsutil -m rsync -r -d \$BACKUP_DIR/logical/ \$BUCKET/\$INSTANCE_NAME/logical/
    
    echo "\$(date): GCS backup sync completed"
else
    echo "\$(date): Warning: gsutil not available, local backup only"
fi

# Clean old local backups
find \$BACKUP_DIR/base -name "base_backup_*" -mtime +\$RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null
find \$BACKUP_DIR/base -name "roles_*" -mtime +\$RETENTION_DAYS -delete 2>/dev/null
find \$BACKUP_DIR/base -name "tablespaces_*" -mtime +\$RETENTION_DAYS -delete 2>/dev/null
find \$BACKUP_DIR/logical -name "*.dump" -mtime +\$RETENTION_DAYS -delete 2>/dev/null

echo "\$(date): Backup cleanup completed"
EOF
    
    sudo chmod +x /var/backups/postgresql/scripts/pg_ha_gcs_backup.sh
fi

# Create standard backup scripts (fallback for non-GCE environments)
sudo tee /var/backups/postgresql/scripts/pg_ha_base_backup.sh > /dev/null <<EOF
#!/bin/bash
# PostgreSQL HA Base Backup Script
BACKUP_DIR="/var/backups/postgresql/base"
DATE=\$(date +%Y%m%d_%H%M%S)
PRIMARY_IP="${PRIMARY_IP}"
RETENTION_DAYS=7

echo "\$(date): Starting base backup"
sudo -u postgres pg_basebackup -h \$PRIMARY_IP -D \$BACKUP_DIR/base_backup_\$DATE -Ft -z -Xs -P

# Backup cluster configuration
sudo -u postgres pg_dumpall -h \$PRIMARY_IP --roles-only > \$BACKUP_DIR/roles_\$DATE.sql
sudo -u postgres pg_dumpall -h \$PRIMARY_IP --tablespaces-only > \$BACKUP_DIR/tablespaces_\$DATE.sql

# Clean old backups
find \$BACKUP_DIR -name "base_backup_*" -mtime +\$RETENTION_DAYS -exec rm -rf {} \;
find \$BACKUP_DIR -name "roles_*" -mtime +\$RETENTION_DAYS -delete
find \$BACKUP_DIR -name "tablespaces_*" -mtime +\$RETENTION_DAYS -delete

echo "\$(date): Base backup completed: base_backup_\$DATE"
EOF

sudo chmod +x /var/backups/postgresql/scripts/pg_ha_base_backup.sh

echo "host replication repmgr ${STANDBY_IP}/32 md5" | sudo tee -a /etc/postgresql/17/main/pg_hba.conf
echo "host repmgr repmgr ${STANDBY_IP}/32 md5" | sudo tee -a /etc/postgresql/17/main/pg_hba.conf
echo "host repmgr repmgr ${PRIMARY_IP}/32 trust" | sudo tee -a /etc/postgresql/17/main/pg_hba.conf

echo -e "${CYAN}${BOLD}Creating repmgr user and database...${RESET}"
sudo -u postgres psql <<EOF
CREATE USER repmgr WITH REPLICATION PASSWORD 'StrongPass' LOGIN;
CREATE DATABASE repmgr OWNER repmgr;

-- Create monitoring user for GCP monitoring
CREATE USER gcp_monitor WITH PASSWORD 'monitor_password';
ALTER USER gcp_monitor SET SEARCH_PATH TO gcp_monitor,pg_catalog;
GRANT CONNECT ON DATABASE postgres TO gcp_monitor;
GRANT pg_monitor TO gcp_monitor;
EOF

echo -e "${CYAN}${BOLD}Registering primary node with repmgr...${RESET}"
sudo tee /etc/repmgr.conf > /dev/null <<EOF
node_id=1
node_name='primary'
conninfo='host=${PRIMARY_IP} user=repmgr dbname=repmgr password=StrongPass'
data_directory='/var/lib/postgresql/17/main'

# Automatic failover settings
failover='automatic'
promote_command='/usr/bin/repmgr standby promote -f /etc/repmgr.conf --log-to-file'
follow_command='/usr/bin/repmgr standby follow -f /etc/repmgr.conf --log-to-file --upstream-node-id=%n'
monitoring_history=yes
monitor_interval_secs=2
EOF

sudo -u postgres repmgr -f /etc/repmgr.conf primary register

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
sudo systemctl restart postgresql
sudo systemctl restart pgbouncer repmgrd

# GCE-specific firewall configuration
if [[ "$IS_GCE" == "true" ]]; then
    echo -e "${CYAN}${BOLD}Configuring GCE firewall rules...${RESET}"
    
    # Create firewall rules for PostgreSQL and PgBouncer
    gcloud compute firewall-rules create postgresql-ha-5432 \
        --allow tcp:5432 \
        --source-ranges="${PRIMARY_IP}/32,${STANDBY_IP}/32" \
        --description="PostgreSQL HA cluster communication" \
        --quiet 2>/dev/null || echo "Firewall rule postgresql-ha-5432 already exists or insufficient permissions"
    
    gcloud compute firewall-rules create postgresql-ha-6432 \
        --allow tcp:6432 \
        --source-ranges="${PRIMARY_IP}/32,${STANDBY_IP}/32" \
        --description="PgBouncer HA cluster communication" \
        --quiet 2>/dev/null || echo "Firewall rule postgresql-ha-6432 already exists or insufficient permissions"
    
    gcloud compute firewall-rules create postgresql-health-8080 \
        --allow tcp:8080 \
        --description="PostgreSQL health check endpoint" \
        --quiet 2>/dev/null || echo "Firewall rule postgresql-health-8080 already exists or insufficient permissions"
fi

# GCE health check endpoint
if [[ "$IS_GCE" == "true" ]]; then
    echo -e "${CYAN}${BOLD}Setting up GCE health check endpoint...${RESET}"
    
    # Install netcat for health checks
    sudo apt install -y netcat-openbsd
    
    sudo tee /etc/systemd/system/postgresql-health.service > /dev/null <<EOF
[Unit]
Description=PostgreSQL Health Check Service for GCE Load Balancer
After=postgresql.service repmgrd.service

[Service]
Type=simple
User=postgres
ExecStart=/bin/bash -c 'while true; do if sudo -u postgres psql -t -c "SELECT 1" >/dev/null 2>&1 && sudo -u postgres repmgr -f /etc/repmgr.conf node check --role=primary >/dev/null 2>&1; then echo -e "HTTP/1.1 200 OK\nContent-Type: text/plain\n\nPostgreSQL Primary: Healthy" | nc -l -p 8080 -q 1; else echo -e "HTTP/1.1 503 Service Unavailable\nContent-Type: text/plain\n\nPostgreSQL Primary: Unhealthy" | nc -l -p 8080 -q 1; fi; done'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl enable postgresql-health
    sudo systemctl start postgresql-health
fi

echo -e "${CYAN}${BOLD}Setting up backup cron jobs...${RESET}"
# Setup automated backups
if [[ "$IS_GCE" == "true" ]]; then
    # Use GCS backup for GCE environments
    (sudo -u postgres crontab -l 2>/dev/null; echo "0 2 * * * /var/backups/postgresql/scripts/pg_ha_gcs_backup.sh >> /var/log/postgresql/backup.log 2>&1") | sudo -u postgres crontab -
else
    # Use local backup for non-GCE environments
    (sudo -u postgres crontab -l 2>/dev/null; echo "0 2 * * * /var/backups/postgresql/scripts/pg_ha_base_backup.sh >> /var/log/postgresql/backup.log 2>&1") | sudo -u postgres crontab -
fi

# Create startup completion marker for GCE
if [[ "$IS_GCE" == "true" ]]; then
    echo "$(date): PostgreSQL primary setup completed" | sudo tee /var/log/postgresql-setup-complete.log
    logger -t postgresql-setup "PostgreSQL HA primary setup completed successfully"
    
    # Set instance metadata to indicate completion
    gcloud compute instances add-metadata "$GCE_INSTANCE" --metadata=postgresql-primary-ready=true --quiet 2>/dev/null || echo "Could not set completion metadata"
fi

echo -e "${GREEN}${BOLD}PostgreSQL HA Primary setup complete!${RESET}"

if [[ "$IS_GCE" == "true" ]]; then
    echo -e "${CYAN}${BOLD}GCP-specific features configured:${RESET}"
    echo -e "${CYAN}  ✓ GCS backup integration${RESET}"
    echo -e "${CYAN}  ✓ Automated firewall rules${RESET}"
    echo -e "${CYAN}  ✓ Health check endpoint (port 8080)${RESET}"
    echo -e "${CYAN}  ✓ Instance metadata integration${RESET}"
    echo -e "${CYAN}  ✓ Performance auto-tuning based on instance specs${RESET}"
    echo -e "${YELLOW}${BOLD}Next Steps:${RESET}"
    echo -e "${YELLOW}  1. Run standby setup: ./02-pgsql_setup-standby-gcp.sh${RESET}"
    echo -e "${YELLOW}  2. Configure load balancer with health check on port 8080${RESET}"
    echo -e "${YELLOW}  3. Set up Cloud Monitoring for PostgreSQL metrics${RESET}"
fi

echo -e "${YELLOW}${BOLD}Configuration Summary:${RESET}"
echo -e "${YELLOW}  Primary IP: ${PRIMARY_IP}${RESET}"
echo -e "${YELLOW}  Standby IP: ${STANDBY_IP}${RESET}"
echo -e "${CYAN}  PostgreSQL Port: 5432${RESET}"
echo -e "${CYAN}  PgBouncer Port: 6432${RESET}"
echo -e "${CYAN}  Health Check Port: 8080${RESET}"
if [[ "$IS_GCE" == "true" ]]; then
    echo -e "${CYAN}  GCS Bucket: gs://${BUCKET_NAME}${RESET}"
fi
