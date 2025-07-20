# PostgreSQL Single Node Setup

This directory contains a script to install PostgreSQL 17 on Ubuntu 24.04 LTS for development or simple production use.

## Quick Start

```bash
# Make script executable
chmod +x 01-pgsql_single_node_setup.sh

# Run installation
sudo ./01-pgsql_single_node_setup.sh
```

## What the Script Does

The `01-pgsql_single_node_setup.sh` script performs the following operations:

### 1. Repository Setup
```bash
# Adds PostgreSQL official repository (PGDG)
# Installs signing key for package verification
# Configures apt source for PostgreSQL packages
```

### 2. Package Installation
- **postgresql-17**: Main PostgreSQL server
- **postgresql-client-17**: Command-line client tools
- **postgresql-doc-17**: Documentation and man pages

### 3. Basic Configuration
- Starts PostgreSQL service
- Enables automatic startup on boot
- Sets default postgres user password
- Creates a sample database

## Architecture

```
┌─────────────────────────────────────┐
│         Single Node Setup          │
├─────────────────────────────────────┤
│                                     │
│  ┌───────────────────────────────┐  │
│  │        PostgreSQL 17          │  │
│  │                               │  │
│  │  ┌─────────────────────────┐  │  │
│  │  │      Database           │  │  │
│  │  │      - postgres (admin) │  │  │
│  │  │      - sampledb         │  │  │
│  │  └─────────────────────────┘  │  │
│  │                               │  │
│  │  Port: 5432                   │  │
│  │  Data: /var/lib/postgresql/17 │  │
│  │  Config: /etc/postgresql/17   │  │
│  └───────────────────────────────┘  │
│                                     │
└─────────────────────────────────────┘
```

## Script Features

### Automated Installation
- **PGDG Repository**: Uses official PostgreSQL repository for latest packages
- **Version Detection**: Automatically detects Ubuntu codename for repository setup
- **Error Handling**: Uses `set -e` for robust error handling
- **Color Output**: Provides clear, colored status messages

### Post-Installation Setup
- **Service Management**: Enables PostgreSQL to start on boot
- **Default Security**: Sets up postgres user with known password
- **Sample Database**: Creates `sampledb` for testing
- **Clear Instructions**: Provides connection information

## Usage

### Running the Script
```bash
chmod +x 01-pgsql_single_node_setup.sh
sudo ./01-pgsql_single_node_setup.sh
```

### Expected Output
```
Setting up PostgreSQL 17 repository...
Configuring repository for noble...
Installing PostgreSQL 17...
Configuring PostgreSQL...
Setting up postgres user...
Creating sample database...
PostgreSQL 17 installed successfully!
Default postgres user password: postgres
Connection: psql -U postgres -h localhost
```

### Connecting to PostgreSQL
After installation, connect using:
```bash
# Connect as postgres user
sudo -u postgres psql

# Or connect with password
psql -U postgres -h localhost -W
```

### Default Credentials
- **Username**: postgres
- **Password**: postgres
- **Database**: postgres (default), sampledb (created)
- **Port**: 5432

## Migration Path

To upgrade from single node to HA setup:

1. **Export existing data**:
   ```bash
   sudo -u postgres pg_dumpall > full_backup.sql
   ```

2. **Set up HA cluster** using the HA scripts:
   ```bash
   cd ../02-HA_setup/
   sudo ./01-pgsql_setup-primary.sh 192.168.1.10 192.168.1.11
   ```

3. **Import data to new primary**:
   ```bash
   sudo -u postgres psql < full_backup.sql
   ```

## Post-Installation Steps

### 1. Security Hardening
```bash
# Change default password
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'your-strong-password';"

# Create application user
sudo -u postgres createuser --interactive myapp

# Create application database
sudo -u postgres createdb -O myapp myapp_db
```

### 2. Configure Remote Access (if needed)
```bash
# Edit PostgreSQL configuration
sudo nano /etc/postgresql/17/main/postgresql.conf

# Change listen_addresses
listen_addresses = '*'  # or specific IP

# Edit pg_hba.conf for authentication
sudo nano /etc/postgresql/17/main/pg_hba.conf

# Add client access rule
host    all             all             192.168.1.0/24          md5

# Restart PostgreSQL
sudo systemctl restart postgresql
```

### 3. Basic Performance Tuning
```bash
# Edit postgresql.conf
sudo nano /etc/postgresql/17/main/postgresql.conf

# Recommended settings for small to medium workloads
shared_buffers = 128MB          # 25% of RAM
effective_cache_size = 1GB      # 75% of RAM
work_mem = 4MB                  # For sorting/hashing
maintenance_work_mem = 64MB     # For maintenance tasks
```

## File Locations

### Important Directories
- **Data Directory**: `/var/lib/postgresql/17/main/`
- **Configuration**: `/etc/postgresql/17/main/`
- **Logs**: `/var/log/postgresql/`
- **Binaries**: `/usr/lib/postgresql/17/bin/`

### Key Configuration Files
- **postgresql.conf**: Main configuration file
- **pg_hba.conf**: Client authentication rules
- **postgresql.auto.conf**: Auto-generated settings (don't edit manually)

## Common Operations

### Service Management
```bash
# Start PostgreSQL
sudo systemctl start postgresql

# Stop PostgreSQL
sudo systemctl stop postgresql

# Restart PostgreSQL
sudo systemctl restart postgresql

# Check status
sudo systemctl status postgresql

# View logs
sudo tail -f /var/log/postgresql/postgresql-17-main.log
```

### Database Operations
```bash
# List databases
sudo -u postgres psql -l

# Create database
sudo -u postgres createdb mydatabase

# Drop database
sudo -u postgres dropdb mydatabase

# Backup database
sudo -u postgres pg_dump mydatabase > backup.sql

# Restore database
sudo -u postgres psql mydatabase < backup.sql
```

### User Management
```bash
# Create user
sudo -u postgres createuser --interactive username

# Create user with password
sudo -u postgres psql -c "CREATE USER username WITH PASSWORD 'password';"

# Grant privileges
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE mydatabase TO username;"

# List users
sudo -u postgres psql -c "\du"
```

## Troubleshooting

### Common Issues

1. **Service won't start**
   ```bash
   # Check logs
   sudo journalctl -u postgresql
   sudo tail -f /var/log/postgresql/postgresql-17-main.log
   ```

2. **Connection refused**
   ```bash
   # Check if PostgreSQL is running
   sudo systemctl status postgresql
   
   # Check listening ports
   sudo netstat -tlnp | grep 5432
   ```

3. **Permission denied**
   ```bash
   # Check pg_hba.conf authentication rules
   sudo cat /etc/postgresql/17/main/pg_hba.conf
   ```

### Performance Monitoring
```sql
-- Check active connections
SELECT * FROM pg_stat_activity;

-- Check database sizes
SELECT datname, pg_size_pretty(pg_database_size(datname)) 
FROM pg_database;

-- Check table sizes
SELECT schemaname, tablename, 
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
FROM pg_tables 
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

## Maintenance

### Regular Tasks
```bash
# Update statistics
sudo -u postgres psql -c "ANALYZE;"

# Vacuum tables
sudo -u postgres psql -c "VACUUM;"

# Reindex if needed
sudo -u postgres psql -c "REINDEX DATABASE postgres;"
```

### Backup Strategy
```bash
# Daily backup script example with database selection
#!/bin/bash
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)

# Option 1: Backup specific databases
sudo -u postgres /var/backups/postgresql/scripts/pg_single_backup.sh app_db,user_db

# Option 2: Backup all user databases (default when no arguments)
sudo -u postgres /var/backups/postgresql/scripts/pg_single_backup.sh

# Option 3: Single database backup
sudo -u postgres /var/backups/postgresql/scripts/pg_single_db_backup.sh important_db
```

### Enhanced Backup Features

The single node setup includes backup scripts that support:

- **Database Selection**: Specify which databases to backup via arguments
- **Multiple Formats**: Both custom format (.dump) and SQL format (.sql.gz)
- **Automatic Mode Detection**: Interactive vs. non-interactive execution
- **Conservative Defaults**: Backs up all user databases if no arguments provided
- **Error Handling**: Continues with remaining databases if one fails

**Usage Examples**:
```bash
# Interactive mode - shows available databases and prompts
./pg_single_backup.sh

# Backup specific databases
./pg_single_backup.sh myapp,reports,analytics

# Backup single database with multiple formats
./pg_single_db_backup.sh critical_database
```

**Cron Job Examples**:
```bash
# Edit postgres user's crontab
sudo -u postgres crontab -e

# Daily backup of all user databases at 3 AM (default)
0 3 * * * /var/backups/postgresql/scripts/pg_single_backup.sh >> /var/log/postgresql/backup.log 2>&1

# Backup specific databases twice daily
0 6,18 * * * /var/backups/postgresql/scripts/pg_single_backup.sh app_db,user_auth >> /var/log/postgresql/backup.log 2>&1

# Hourly backup of critical database
0 * * * * /var/backups/postgresql/scripts/pg_single_db_backup.sh critical_app >> /var/log/postgresql/backup.log 2>&1
```

This single node setup provides a solid foundation for PostgreSQL development and can be easily upgraded to the HA setup when high availability is required.

## Official Documentation & References

### PostgreSQL 17
- **Installation Guide**: https://www.postgresql.org/docs/17/installation.html
- **Server Setup**: https://www.postgresql.org/docs/17/runtime.html
- **Configuration**: https://www.postgresql.org/docs/17/runtime-config.html
- **Client Authentication**: https://www.postgresql.org/docs/17/client-authentication.html

### Ubuntu Package Installation
- **PGDG APT Repository**: https://wiki.postgresql.org/wiki/Apt
- **Ubuntu PostgreSQL**: https://help.ubuntu.com/community/PostgreSQL
- **Package Management**: https://www.postgresql.org/download/linux/ubuntu/

### Backup Tools Documentation
- **pg_dump Manual**: https://www.postgresql.org/docs/17/app-pgdump.html
- **pg_dumpall Manual**: https://www.postgresql.org/docs/17/app-pg-dumpall.html
- **Backup & Recovery Guide**: https://www.postgresql.org/docs/17/backup.html

### Performance & Tuning
- **Memory Configuration**: https://www.postgresql.org/docs/17/runtime-config-resource.html
- **Query Tuning**: https://www.postgresql.org/docs/17/performance-tips.html
- **EXPLAIN Documentation**: https://www.postgresql.org/docs/17/using-explain.html

### Security Configuration
- **Security Overview**: https://www.postgresql.org/docs/17/security.html
- **User Management**: https://www.postgresql.org/docs/17/user-manag.html
- **pg_hba.conf**: https://www.postgresql.org/docs/17/auth-pg-hba-conf.html

## Learning Resources for Single Node

### Getting Started
- **PostgreSQL Tutorial**: https://www.postgresql.org/docs/17/tutorial.html
- **First Steps**: https://www.postgresql.org/docs/17/tutorial-createdb.html
- **SQL Language**: https://www.postgresql.org/docs/17/sql.html

### Administration
- **Database Roles**: https://www.postgresql.org/docs/17/user-manag.html
- **Managing Databases**: https://www.postgresql.org/docs/17/managing-databases.html
- **Routine Maintenance**: https://www.postgresql.org/docs/17/maintenance.html

### Monitoring Single Node
- **Statistics Collector**: https://www.postgresql.org/docs/17/monitoring-stats.html
- **System Views**: https://www.postgresql.org/docs/17/monitoring-stats.html#MONITORING-STATS-VIEWS
- **Log Analysis**: https://www.postgresql.org/docs/17/logfile-maintenance.html
