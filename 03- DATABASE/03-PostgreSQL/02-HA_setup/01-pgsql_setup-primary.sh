#!/bin/bash
# Setup PostgreSQL 17 Primary with repmgr and PgBouncer
# Usage: ./01-pgsql_setup-primary.sh [PRIMARY_IP] [STANDBY_IP]

set -e

# ====================================
# CONFIGURATION VARIABLES
# ====================================
# Get IPs from command line arguments or prompt user
PRIMARY_IP="$1"
STANDBY_IP="$2"

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

# Get STANDBY_IP if not provided
if [[ -z "$STANDBY_IP" ]]; then
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

# Ask for production mode
echo -e "${YELLOW}${BOLD}Configuration:${RESET}"
echo -e "${YELLOW}Primary IP: ${PRIMARY_IP}${RESET}"
echo -e "${YELLOW}Standby IP: ${STANDBY_IP}${RESET}"

# Production mode selection
echo -e "${CYAN}${BOLD}Select deployment mode:${RESET}"
echo -e "${CYAN}1) Development (basic settings)${RESET}"
echo -e "${CYAN}2) Production (enhanced security, performance, monitoring)${RESET}"
echo -e "${CYAN}Enter choice [1-2]: ${RESET}"
read -r DEPLOYMENT_MODE

if [[ "$DEPLOYMENT_MODE" != "1" && "$DEPLOYMENT_MODE" != "2" ]]; then
    echo -e "${YELLOW}Invalid choice, defaulting to Development mode${RESET}"
    DEPLOYMENT_MODE="1"
fi

echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort...${RESET}"
read

echo -e "${CYAN}${BOLD}Installing PostgreSQL 17 and repmgr...${RESET}"
sudo apt update -y
sudo apt install -y curl ca-certificates gnupg lsb-release

# Add PGDG repo
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -sSf -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
VERSION_CODENAME=$(lsb_release -cs)
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update -y
sudo apt install -y postgresql-17 postgresql-client-17 postgresql-doc-17 repmgr pgbouncer

echo -e "${CYAN}${BOLD}Configuring PostgreSQL for replication...${RESET}"
sudo sed -i "s/^#listen_addresses.*/listen_addresses = '${PRIMARY_IP},${STANDBY_IP}'/" /etc/postgresql/17/main/postgresql.conf

# Base configuration
echo "wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/17/wal_archive/%f && cp %p /var/lib/postgresql/17/wal_archive/%f'
archive_timeout = 300
shared_preload_libraries = 'repmgr'" | sudo tee -a /etc/postgresql/17/main/postgresql.conf

# Production-specific configuration
if [[ "$DEPLOYMENT_MODE" == "2" ]]; then
    echo -e "${CYAN}${BOLD}Applying production-grade configurations...${RESET}"
    
    # Get system memory for tuning
    TOTAL_MEM=$(free -m | grep '^Mem:' | awk '{print $2}')
    SHARED_BUFFERS=$((TOTAL_MEM / 4))
    EFFECTIVE_CACHE_SIZE=$((TOTAL_MEM * 3 / 4))
    
    # Performance tuning
    echo "# Production Performance Settings
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
ssl = on
ssl_prefer_server_ciphers = on

# Logging Settings
log_destination = 'csvlog'
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on

# Connection Settings
tcp_keepalives_idle = 600
tcp_keepalives_interval = 30
tcp_keepalives_count = 3" | sudo tee -a /etc/postgresql/17/main/postgresql.conf

    echo -e "${CYAN}${BOLD}Setting up SSL certificates...${RESET}"
    # Generate self-signed SSL certificates for production
    sudo mkdir -p /etc/postgresql/17/main/ssl
    sudo openssl req -new -x509 -days 365 -nodes -text \
        -out /etc/postgresql/17/main/ssl/server.crt \
        -keyout /etc/postgresql/17/main/ssl/server.key \
        -subj "/CN=postgresql-primary"
    
    sudo chown postgres:postgres /etc/postgresql/17/main/ssl/server.*
    sudo chmod 600 /etc/postgresql/17/main/ssl/server.key
    sudo chmod 644 /etc/postgresql/17/main/ssl/server.crt
    
    # Update SSL configuration
    echo "ssl_cert_file = '/etc/postgresql/17/main/ssl/server.crt'
ssl_key_file = '/etc/postgresql/17/main/ssl/server.key'" | sudo tee -a /etc/postgresql/17/main/postgresql.conf
fi

echo -e "${CYAN}${BOLD}Setting up backup infrastructure...${RESET}"
# Create WAL archive directory
sudo mkdir -p /var/lib/postgresql/17/wal_archive
sudo chown postgres:postgres /var/lib/postgresql/17/wal_archive
sudo chmod 750 /var/lib/postgresql/17/wal_archive

# Create backup directories
sudo mkdir -p /var/backups/postgresql/{base,logical,scripts}
sudo chown postgres:postgres /var/backups/postgresql/{base,logical,scripts}
sudo chmod 750 /var/backups/postgresql/{base,logical,scripts}

# Create base backup script
sudo tee /var/backups/postgresql/scripts/pg_ha_base_backup.sh > /dev/null <<'EOF'
#!/bin/bash
# PostgreSQL HA Base Backup Script
BACKUP_DIR="/var/backups/postgresql/base"
DATE=$(date +%Y%m%d_%H%M%S)
PRIMARY_IP="REPLACE_PRIMARY_IP"
RETENTION_DAYS=7

echo "$(date): Starting base backup"
sudo -u postgres pg_basebackup -h $PRIMARY_IP -D $BACKUP_DIR/base_backup_$DATE -Ft -z -Xs -P

# Backup cluster configuration
sudo -u postgres pg_dumpall -h $PRIMARY_IP --roles-only > $BACKUP_DIR/roles_$DATE.sql
sudo -u postgres pg_dumpall -h $PRIMARY_IP --tablespaces-only > $BACKUP_DIR/tablespaces_$DATE.sql

# Clean old backups
find $BACKUP_DIR -name "base_backup_*" -mtime +$RETENTION_DAYS -exec rm -rf {} \;
find $BACKUP_DIR -name "roles_*" -mtime +$RETENTION_DAYS -delete
find $BACKUP_DIR -name "tablespaces_*" -mtime +$RETENTION_DAYS -delete

echo "$(date): Base backup completed: base_backup_$DATE"
EOF

# Create logical backup script
sudo tee /var/backups/postgresql/scripts/pg_ha_logical_backup.sh > /dev/null <<'EOF'
#!/bin/bash
# PostgreSQL HA Logical Backup Script
# Usage: ./pg_ha_logical_backup.sh [database1,database2,...]
# Special keywords: 'all' for all user databases, 'system' to include system DBs

BACKUP_DIR="/var/backups/postgresql/logical"
DATE=$(date +%Y%m%d_%H%M%S)
PRIMARY_IP="REPLACE_PRIMARY_IP"
RETENTION_DAYS=14

# Color codes
GREEN="\e[1;32m"
CYAN="\e[1;36m"
YELLOW="\e[1;33m"
RESET="\e[0m"

# Check if running interactively (has a controlling terminal)
if [[ -t 0 ]]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

# Get databases from argument or prompt (only if interactive)
if [[ -n "$1" ]]; then
    if [[ "$1" == "all" ]]; then
        # Backup all user databases (excluding templates and postgres)
        DATABASES=()
        while IFS= read -r db; do
            db=$(echo "$db" | xargs)
            if [[ -n "$db" ]]; then
                DATABASES+=("$db")
            fi
        done < <(sudo -u postgres psql -h $PRIMARY_IP -t -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname != 'postgres';")
        echo "$(date): Selected all user databases: ${DATABASES[*]}"
    elif [[ "$1" == "system" ]]; then
        # Backup all databases including system ones
        DATABASES=()
        while IFS= read -r db; do
            db=$(echo "$db" | xargs)
            if [[ -n "$db" ]]; then
                DATABASES+=("$db")
            fi
        done < <(sudo -u postgres psql -h $PRIMARY_IP -t -c "SELECT datname FROM pg_database WHERE NOT datistemplate;")
        echo "$(date): Selected all databases including system: ${DATABASES[*]}"
    else
        # Parse comma-separated database list
        IFS=',' read -ra DATABASES <<< "$1"
        echo "$(date): Selected specified databases: ${DATABASES[*]}"
    fi
elif [[ "$INTERACTIVE" == "true" ]]; then
    echo -e "${YELLOW}No databases specified as argument.${RESET}"
    echo -e "${CYAN}Available user databases:${RESET}"
    sudo -u postgres psql -h $PRIMARY_IP -t -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname != 'postgres';" | grep -v "^$"
    
    echo -e "${CYAN}Options:${RESET}"
    echo -e "${CYAN}  - Enter database names (comma-separated)${RESET}"
    echo -e "${CYAN}  - Enter 'all' for all user databases${RESET}"
    echo -e "${CYAN}  - Enter 'system' for all databases including system${RESET}"
    echo -e "${CYAN}  - Press Enter for default (repmgr only)${RESET}"
    echo -e "${CYAN}Choice: ${RESET}"
    read -r db_input
    
    if [[ -z "$db_input" ]]; then
        DATABASES=("repmgr")
    elif [[ "$db_input" == "all" ]]; then
        DATABASES=()
        while IFS= read -r db; do
            db=$(echo "$db" | xargs)
            if [[ -n "$db" ]]; then
                DATABASES+=("$db")
            fi
        done < <(sudo -u postgres psql -h $PRIMARY_IP -t -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname != 'postgres';")
    elif [[ "$db_input" == "system" ]]; then
        DATABASES=()
        while IFS= read -r db; do
            db=$(echo "$db" | xargs)
            if [[ -n "$db" ]]; then
                DATABASES+=("$db")
            fi
        done < <(sudo -u postgres psql -h $PRIMARY_IP -t -c "SELECT datname FROM pg_database WHERE NOT datistemplate;")
    else
        IFS=',' read -ra DATABASES <<< "$db_input"
    fi
else
    # Non-interactive mode (cron job) - use conservative default (repmgr only)
    DATABASES=("repmgr")
    echo "$(date): Non-interactive mode: backing up default database (repmgr)"
fi

echo "$(date): Starting logical backup for databases: ${DATABASES[*]}"

# Track backup statistics
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0

for db in "${DATABASES[@]}"; do
    db=$(echo "$db" | xargs)  # trim whitespace
    if [[ -n "$db" ]]; then
        echo "$(date): Backing up database: $db"
        if sudo -u postgres pg_dump -h $PRIMARY_IP -d "$db" -Fc > "$BACKUP_DIR/${db}_$DATE.dump" 2>/dev/null; then
            ((SUCCESSFUL_BACKUPS++))
            if [[ "$INTERACTIVE" == "true" ]]; then
                echo -e "${GREEN}✓ Successfully backed up: $db${RESET}"
            else
                echo "$(date): Successfully backed up: $db"
            fi
        else
            ((FAILED_BACKUPS++))
            if [[ "$INTERACTIVE" == "true" ]]; then
                echo -e "${YELLOW}⚠ Warning: Could not backup database '$db' (may not exist)${RESET}"
            else
                echo "$(date): Warning: Could not backup database '$db' (may not exist)"
            fi
        fi
    fi
done

# Full cluster dump (always included)
echo "$(date): Creating full cluster dump"
if sudo -u postgres pg_dumpall -h $PRIMARY_IP > $BACKUP_DIR/full_cluster_$DATE.sql; then
    gzip $BACKUP_DIR/full_cluster_$DATE.sql
    echo "$(date): Full cluster dump completed"
else
    echo "$(date): Warning: Full cluster dump failed"
fi

# Cleanup old backups
find $BACKUP_DIR -name "*.dump" -mtime +$RETENTION_DAYS -delete
find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "$(date): Logical backup completed - Success: $SUCCESSFUL_BACKUPS, Failed: $FAILED_BACKUPS"
EOF

# Create database-specific backup script
sudo tee /var/backups/postgresql/scripts/pg_ha_db_backup.sh > /dev/null <<'EOF'
#!/bin/bash
# PostgreSQL HA Database-Specific Backup Script
# Usage: ./pg_ha_db_backup.sh [database_name]

BACKUP_DIR="/var/backups/postgresql/logical"
DATE=$(date +%Y%m%d_%H%M%S)
PRIMARY_IP="REPLACE_PRIMARY_IP"

# Color codes
GREEN="\e[1;32m"
CYAN="\e[1;36m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
RESET="\e[0m"

# Check if running interactively
if [[ -t 0 ]]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

# Get database name from argument or prompt (only if interactive)
if [[ -n "$1" ]]; then
    DATABASE="$1"
elif [[ "$INTERACTIVE" == "true" ]]; then
    echo -e "${YELLOW}No database specified as argument.${RESET}"
    echo -e "${CYAN}Available databases:${RESET}"
    sudo -u postgres psql -h $PRIMARY_IP -t -c "SELECT datname FROM pg_database WHERE NOT datistemplate;" | grep -v "^$"
    
    echo -e "${CYAN}Enter database name: ${RESET}"
    read -r DATABASE
else
    echo "$(date): Error: No database name provided and running non-interactively"
    exit 1
fi

if [[ -z "$DATABASE" ]]; then
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo -e "${RED}Error: No database name provided${RESET}"
    else
        echo "$(date): Error: No database name provided"
    fi
    exit 1
fi

echo "$(date): Starting backup for database: $DATABASE"

# Create database-specific directory
mkdir -p "$BACKUP_DIR/$DATABASE"

# Backup database
if sudo -u postgres pg_dump -h $PRIMARY_IP -d "$DATABASE" -Fc > "$BACKUP_DIR/$DATABASE/${DATABASE}_$DATE.dump"; then
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo -e "${GREEN}✓ Successfully backed up database: $DATABASE${RESET}"
        echo -e "${GREEN}Backup location: $BACKUP_DIR/$DATABASE/${DATABASE}_$DATE.dump${RESET}"
    else
        echo "$(date): Successfully backed up database: $DATABASE"
        echo "$(date): Backup location: $BACKUP_DIR/$DATABASE/${DATABASE}_$DATE.dump"
    fi
else
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo -e "${RED}✗ Failed to backup database: $DATABASE${RESET}"
    else
        echo "$(date): Error: Failed to backup database: $DATABASE"
    fi
    exit 1
fi

# Also create SQL format backup
sudo -u postgres pg_dump -h $PRIMARY_IP -d "$DATABASE" > "$BACKUP_DIR/$DATABASE/${DATABASE}_$DATE.sql"
gzip "$BACKUP_DIR/$DATABASE/${DATABASE}_$DATE.sql"

echo "$(date): Database backup completed for: $DATABASE"
EOF

# Make backup scripts executable
sudo chmod +x /var/backups/postgresql/scripts/*.sh

# Replace IP placeholders in backup scripts
sudo sed -i "s/REPLACE_PRIMARY_IP/${PRIMARY_IP}/g" /var/backups/postgresql/scripts/pg_ha_base_backup.sh
sudo sed -i "s/REPLACE_PRIMARY_IP/${PRIMARY_IP}/g" /var/backups/postgresql/scripts/pg_ha_logical_backup.sh
sudo sed -i "s/REPLACE_PRIMARY_IP/${PRIMARY_IP}/g" /var/backups/postgresql/scripts/pg_ha_db_backup.sh

# Enhanced pg_hba.conf for production
echo "host replication repmgr ${STANDBY_IP}/32 md5" | sudo tee -a /etc/postgresql/17/main/pg_hba.conf
echo "host repmgr repmgr ${STANDBY_IP}/32 md5" | sudo tee -a /etc/postgresql/17/main/pg_hba.conf
echo "host repmgr repmgr ${PRIMARY_IP}/32 trust" | sudo tee -a /etc/postgresql/17/main/pg_hba.conf

if [[ "$DEPLOYMENT_MODE" == "2" ]]; then
    # Production: require SSL and use scram-sha-256
    sudo sed -i 's/md5/scram-sha-256/g' /etc/postgresql/17/main/pg_hba.conf
    echo "hostssl all all 0.0.0.0/0 scram-sha-256" | sudo tee -a /etc/postgresql/17/main/pg_hba.conf
fi

echo -e "${CYAN}${BOLD}Creating repmgr user and database...${RESET}"
if [[ "$DEPLOYMENT_MODE" == "2" ]]; then
    # Production: create additional roles
    sudo -u postgres psql <<EOF
CREATE USER repmgr WITH REPLICATION PASSWORD 'StrongPass' LOGIN;
CREATE DATABASE repmgr OWNER repmgr;

-- Create application roles
CREATE ROLE app_readonly;
GRANT CONNECT ON DATABASE repmgr TO app_readonly;
GRANT USAGE ON SCHEMA public TO app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_readonly;

-- Create monitoring user for prometheus
CREATE USER postgres_exporter WITH PASSWORD 'monitor_password';
ALTER USER postgres_exporter SET SEARCH_PATH TO postgres_exporter,pg_catalog;
GRANT CONNECT ON DATABASE postgres TO postgres_exporter;
GRANT pg_monitor TO postgres_exporter;
EOF
else
    # Development: basic setup
    sudo -u postgres psql <<EOF
CREATE USER repmgr WITH REPLICATION PASSWORD 'StrongPass' LOGIN;
CREATE DATABASE repmgr OWNER repmgr;
EOF
fi

echo -e "${CYAN}${BOLD}Registering primary node with repmgr...${RESET}"
sudo tee /etc/repmgr.conf > /dev/null <<EOF
node_id=1
node_name='primary'
conninfo='host=${PRIMARY_IP} user=repmgr dbname=repmgr password=StrongPass'
data_directory='/var/lib/postgresql/17/main'
EOF

sudo -u postgres repmgr -f /etc/repmgr.conf primary register

# Automatic failover settings
sudo tee -a /etc/repmgr.conf > /dev/null <<EOF

# Automatic failover settings
failover='automatic'
promote_command='/usr/bin/repmgr standby promote -f /etc/repmgr.conf --log-to-file'
follow_command='/usr/bin/repmgr standby follow -f /etc/repmgr.conf --log-to-file --upstream-node-id=%n'
monitoring_history=yes
monitor_interval_secs=2
EOF

# Start repmgrd daemon
sudo systemctl enable repmgrd
sudo systemctl restart repmgrd

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

sudo systemctl enable pgbouncer
sudo systemctl restart postgresql
sudo systemctl restart pgbouncer

echo -e "${CYAN}${BOLD}Setting up backup cron jobs...${RESET}"
# Setup automated backups
(sudo -u postgres crontab -l 2>/dev/null; echo "0 2 * * * /var/backups/postgresql/scripts/pg_ha_base_backup.sh >> /var/log/postgresql/backup.log 2>&1") | sudo -u postgres crontab -
# Default cron job backs up only repmgr database - admin can modify to specify other databases
(sudo -u postgres crontab -l 2>/dev/null; echo "0 */6 * * * /var/backups/postgresql/scripts/pg_ha_logical_backup.sh repmgr >> /var/log/postgresql/backup.log 2>&1") | sudo -u postgres crontab -

# Create example cron entries file for admin reference
sudo tee /var/backups/postgresql/scripts/cron_examples.txt > /dev/null <<'EOF'
# PostgreSQL Backup Cron Job Examples
# Edit postgres user's crontab: sudo -u postgres crontab -e

# Backup specific databases every 6 hours
0 */6 * * * /var/backups/postgresql/scripts/pg_ha_logical_backup.sh database01,database02 >> /var/log/postgresql/backup.log 2>&1

# Backup all user databases daily at 1 AM
0 1 * * * /var/backups/postgresql/scripts/pg_ha_logical_backup.sh all >> /var/log/postgresql/backup.log 2>&1

# Backup all databases including system databases weekly
0 1 * * 0 /var/backups/postgresql/scripts/pg_ha_logical_backup.sh system >> /var/log/postgresql/backup.log 2>&1

# Base backup daily at 2 AM (already configured)
0 2 * * * /var/backups/postgresql/scripts/pg_ha_base_backup.sh >> /var/log/postgresql/backup.log 2>&1

# Single database backup
0 3 * * * /var/backups/postgresql/scripts/pg_ha_db_backup.sh important_db >> /var/log/postgresql/backup.log 2>&1
EOF

echo -e "${GREEN}${BOLD}Primary node setup complete!${RESET}"

if [[ "$DEPLOYMENT_MODE" == "2" ]]; then
    echo -e "${CYAN}${BOLD}Production features configured:${RESET}"
    echo -e "${CYAN}  ✓ SSL/TLS encryption enabled${RESET}"
    echo -e "${CYAN}  ✓ Performance tuning applied${RESET}"
    echo -e "${CYAN}  ✓ Enhanced security settings${RESET}"
    echo -e "${CYAN}  ✓ Monitoring setup (prometheus exporter)${RESET}"
    echo -e "${CYAN}  ✓ Automated maintenance tasks${RESET}"
    echo -e "${CYAN}  ✓ Production-grade logging${RESET}"
    echo -e "${YELLOW}${BOLD}Next Steps:${RESET}"
    echo -e "${YELLOW}  1. Start postgres_exporter: sudo systemctl start postgres_exporter${RESET}"
    echo -e "${YELLOW}  2. Configure Prometheus to scrape localhost:9187${RESET}"
    echo -e "${YELLOW}  3. Set up Grafana dashboards for PostgreSQL${RESET}"
    echo -e "${YELLOW}  4. Configure log rotation for /var/log/postgresql/pg_log/${RESET}"
else
    echo -e "${CYAN}${BOLD}Development mode - basic configuration applied${RESET}"
fi

echo -e "${CYAN}  - Usage: pg_ha_logical_backup.sh [db1,db2,...|all|system] or pg_ha_db_backup.sh [database]${RESET}"
echo -e "${CYAN}  - Cron examples: /var/backups/postgresql/scripts/cron_examples.txt${RESET}"
