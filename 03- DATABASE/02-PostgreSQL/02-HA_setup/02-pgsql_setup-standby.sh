#!/bin/bash
# Setup PostgreSQL 17 Standby with repmgr and PgBouncer
# Usage: ./02-pgsql_setup-standby.sh [PRIMARY_IP] [STANDBY_IP]

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

echo -e "${YELLOW}${BOLD}Configuration:${RESET}"
echo -e "${YELLOW}Primary IP: ${PRIMARY_IP}${RESET}"
echo -e "${YELLOW}Standby IP: ${STANDBY_IP}${RESET}"
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

echo -e "${CYAN}${BOLD}Configuring repmgr...${RESET}"
sudo tee /etc/repmgr.conf > /dev/null <<EOF
node_id=2
node_name='standby'
conninfo='host=${STANDBY_IP} user=repmgr dbname=repmgr password=StrongPass'
data_directory='/var/lib/postgresql/17/main'
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

sudo systemctl enable pgbouncer
sudo systemctl restart pgbouncer

echo -e "${CYAN}${BOLD}Setting up standby backup infrastructure...${RESET}"
# Create backup directories for standby
sudo mkdir -p /var/backups/postgresql/{base,logical,scripts}
sudo chown postgres:postgres /var/backups/postgresql/{base,logical,scripts}
sudo chmod 750 /var/backups/postgresql/{base,logical,scripts}

# Create standby backup script (offload primary)
sudo tee /var/backups/postgresql/scripts/pg_standby_backup.sh > /dev/null <<'EOF'
#!/bin/bash
# PostgreSQL Standby Backup Script (Read-only backups)
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)
STANDBY_IP="REPLACE_STANDBY_IP"
RETENTION_DAYS=7

echo "$(date): Starting standby backup"

# Base backup from standby (reduces primary load)
sudo -u postgres pg_basebackup -h $STANDBY_IP -D $BACKUP_DIR/base/standby_backup_$DATE -Ft -z -Xs -P

# Logical backup from standby
sudo -u postgres pg_dump -h $STANDBY_IP -d repmgr -Fc > $BACKUP_DIR/logical/repmgr_standby_$DATE.dump

# Clean old backups
find $BACKUP_DIR/base -name "standby_backup_*" -mtime +$RETENTION_DAYS -exec rm -rf {} \;
find $BACKUP_DIR/logical -name "*_standby_*" -mtime +$RETENTION_DAYS -delete

echo "$(date): Standby backup completed"
EOF

# Make backup script executable
sudo chmod +x /var/backups/postgresql/scripts/pg_standby_backup.sh

# Replace IP placeholder
sudo sed -i "s/REPLACE_STANDBY_IP/${STANDBY_IP}/g" /var/backups/postgresql/scripts/pg_standby_backup.sh

echo -e "${GREEN}${BOLD}Standby node setup complete!${RESET}"

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

echo -e "${YELLOW}${BOLD}Standby node configured with:${RESET}"
echo -e "${YELLOW}Primary IP: ${PRIMARY_IP}${RESET}"
echo -e "${YELLOW}Standby IP: ${STANDBY_IP}${RESET}"
echo -e "${YELLOW}Cluster setup complete!${RESET}"
echo -e "${GREEN}${BOLD}You can now check cluster status with:${RESET}"
echo -e "${GREEN}sudo -u postgres repmgr -f /etc/repmgr.conf cluster show${RESET}"
echo -e "${CYAN}${BOLD}Backup scripts created in: /var/backups/postgresql/scripts/${RESET}"
echo -e "${CYAN}${BOLD}Primary has automated daily base backups and 6-hourly logical backups${RESET}"
echo -e "${CYAN}${BOLD}Standby backup script available: pg_standby_backup.sh${RESET}"
