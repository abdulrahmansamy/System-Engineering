#!/bin/bash
# Deploy PostgreSQL 17 on Ubuntu 24.04 LTS (noble)

set -e

# Define bold color codes
BOLD="\e[1m"
GREEN="\e[1;32m"
CYAN="\e[1;36m"
YELLOW="\e[1;33m"
RESET="\e[0m"

echo -e "${CYAN}${BOLD}Setting up PostgreSQL 17 repository...${RESET}"

# Install prerequisite packages
sudo apt update -y
sudo apt install -y curl ca-certificates gnupg lsb-release

# Add PostgreSQL signing key
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc

# Add PostgreSQL Apt repository
VERSION_CODENAME=$(lsb_release -cs)
echo -e "${CYAN}${BOLD}Configuring repository for ${YELLOW}${BOLD}$VERSION_CODENAME${CYAN}${BOLD}...${RESET}"
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

# Update package lists
sudo apt update -y

# Install PostgreSQL 17
echo -e "${CYAN}${BOLD}Installing PostgreSQL 17...${RESET}"
sudo apt install -y postgresql-17 postgresql-client-17 postgresql-doc-17

echo -e "${CYAN}${BOLD}Configuring PostgreSQL...${RESET}"
# Start and enable PostgreSQL
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Set postgres user password
echo -e "${YELLOW}${BOLD}Setting up postgres user...${RESET}"
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"

# Create a sample database
echo -e "${CYAN}${BOLD}Creating sample database...${RESET}"
sudo -u postgres createdb sampledb

echo -e "${CYAN}${BOLD}Setting up backup infrastructure...${RESET}"
# Create backup directories
sudo mkdir -p /var/backups/postgresql/{dumps,scripts}
sudo chown postgres:postgres /var/backups/postgresql/{dumps,scripts}
sudo chmod 750 /var/backups/postgresql/{dumps,scripts}

# Create simple backup script for single node
sudo tee /var/backups/postgresql/scripts/pg_single_backup.sh > /dev/null <<'EOF'
#!/bin/bash
# PostgreSQL Single Node Backup Script
# Usage: ./pg_single_backup.sh [database1,database2,...]

BACKUP_DIR="/var/backups/postgresql/dumps"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7

# Color codes
GREEN="\e[1;32m"
CYAN="\e[1;36m"
YELLOW="\e[1;33m"
RESET="\e[0m"

echo "$(date): Starting PostgreSQL backup"

# Full cluster dump
sudo -u postgres pg_dumpall > $BACKUP_DIR/full_backup_$DATE.sql
gzip $BACKUP_DIR/full_backup_$DATE.sql
echo -e "${GREEN}✓ Full cluster backup completed${RESET}"

# Get databases from argument or use all user databases
if [[ -n "$1" ]]; then
    IFS=',' read -ra DATABASES <<< "$1"
    echo "$(date): Backing up specified databases: ${DATABASES[*]}"
else
    echo "$(date): Backing up all user databases"
    DATABASES=()
    while IFS= read -r db; do
        db=$(echo "$db" | xargs)  # trim whitespace
        if [[ -n "$db" ]]; then
            DATABASES+=("$db")
        fi
    done < <(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname != 'postgres';")
fi

# Individual database backups
for db in "${DATABASES[@]}"; do
    db=$(echo "$db" | xargs)  # trim whitespace
    if [[ -n "$db" ]]; then
        echo "$(date): Backing up database: $db"
        if sudo -u postgres pg_dump -Fc "$db" > "$BACKUP_DIR/${db}_$DATE.dump" 2>/dev/null; then
            echo -e "${GREEN}✓ Successfully backed up: $db${RESET}"
        else
            echo -e "${YELLOW}⚠ Warning: Could not backup database '$db'${RESET}"
        fi
    fi
done

# Clean old backups
find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete
find $BACKUP_DIR -name "*.dump" -mtime +$RETENTION_DAYS -delete

echo "$(date): Backup completed"
EOF

# Create single database backup script
sudo tee /var/backups/postgresql/scripts/pg_single_db_backup.sh > /dev/null <<'EOF'
#!/bin/bash
# PostgreSQL Single Node Database-Specific Backup Script
# Usage: ./pg_single_db_backup.sh [database_name]

BACKUP_DIR="/var/backups/postgresql/dumps"
DATE=$(date +%Y%m%d_%H%M%S)

# Color codes
GREEN="\e[1;32m"
CYAN="\e[1;36m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
RESET="\e[0m"

# Get database name from argument or prompt
if [[ -n "$1" ]]; then
    DATABASE="$1"
else
    echo -e "${YELLOW}No database specified as argument.${RESET}"
    echo -e "${CYAN}Available databases:${RESET}"
    sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE NOT datistemplate;" | grep -v "^$"
    
    echo -e "${CYAN}Enter database name: ${RESET}"
    read -r DATABASE
fi

if [[ -z "$DATABASE" ]]; then
    echo -e "${RED}Error: No database name provided${RESET}"
    exit 1
fi

echo "$(date): Starting backup for database: $DATABASE"

# Create database-specific directory
mkdir -p "$BACKUP_DIR/$DATABASE"

# Backup database in multiple formats
if sudo -u postgres pg_dump -Fc "$DATABASE" > "$BACKUP_DIR/$DATABASE/${DATABASE}_$DATE.dump"; then
    echo -e "${GREEN}✓ Custom format backup completed${RESET}"
else
    echo -e "${RED}✗ Failed to backup database: $DATABASE${RESET}"
    exit 1
fi

# SQL format backup
sudo -u postgres pg_dump "$DATABASE" > "$BACKUP_DIR/$DATABASE/${DATABASE}_$DATE.sql"
gzip "$BACKUP_DIR/$DATABASE/${DATABASE}_$DATE.sql"
echo -e "${GREEN}✓ SQL format backup completed${RESET}"

echo -e "${GREEN}Backup location: $BACKUP_DIR/$DATABASE/${RESET}"
echo "$(date): Database backup completed for: $DATABASE"
EOF

# Make backup script executable
sudo chmod +x /var/backups/postgresql/scripts/pg_single_backup.sh
sudo chmod +x /var/backups/postgresql/scripts/pg_single_db_backup.sh

# Setup automated backup (daily at 3 AM)
(sudo -u postgres crontab -l 2>/dev/null; echo "0 3 * * * /var/backups/postgresql/scripts/pg_single_backup.sh >> /var/log/postgresql/backup.log 2>&1") | sudo -u postgres crontab -

echo -e "${GREEN}${BOLD}PostgreSQL 17 installed successfully!${RESET}"
echo -e "${YELLOW}${BOLD}Default postgres user password: postgres${RESET}"
echo -e "${YELLOW}${BOLD}Connection: psql -U postgres -h localhost${RESET}"
echo -e "${CYAN}${BOLD}Backup script created: /var/backups/postgresql/scripts/pg_single_backup.sh${RESET}"
echo -e "${CYAN}${BOLD}Automated daily backups configured at 3 AM${RESET}"
echo -e "${CYAN}${BOLD}Backup location: /var/backups/postgresql/dumps/${RESET}"
echo -e "${CYAN}${BOLD}Usage: pg_single_backup.sh [db1,db2,...] or pg_single_db_backup.sh [database]${RESET}"
