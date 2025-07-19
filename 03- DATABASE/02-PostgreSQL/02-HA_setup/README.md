# PostgreSQL High Availability Setup

This directory contains scripts to set up a PostgreSQL 17 HA cluster with automatic failover using repmgr and PgBouncer.

## Script Usage

### Command Syntax
```bash
# Primary node setup
./01-pgsql_setup-primary.sh [PRIMARY_IP] [STANDBY_IP]

# Standby node setup
./02-pgsql_setup-standby.sh [PRIMARY_IP] [STANDBY_IP]
```

### Usage Examples

1. **Full Command-line Arguments**:
   ```bash
   # On primary server
   sudo ./01-pgsql_setup-primary.sh 192.168.1.10 192.168.1.11
   
   # On standby server
   sudo ./02-pgsql_setup-standby.sh 192.168.1.10 192.168.1.11
   ```

2. **Interactive Mode** (no arguments):
   ```bash
   sudo ./01-pgsql_setup-primary.sh
   # Output:
   # PRIMARY_IP not provided as argument.
   # Please enter the PRIMARY server IP address: 192.168.1.10
   # STANDBY_IP not provided as argument.
   # Please enter the STANDBY server IP address: 192.168.1.11
   ```

3. **Partial Arguments**:
   ```bash
   sudo ./01-pgsql_setup-primary.sh 192.168.1.10
   # Will prompt only for STANDBY_IP
   ```

### IP Validation
The scripts include built-in IP validation:
- Validates IPv4 format (xxx.xxx.xxx.xxx)
- Checks that each octet is between 0-255
- Prompts again if invalid IP is entered

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             HA Cluster with Backup Infrastructure                │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌─────────────────┐    Streaming     ┌─────────────────┐                      │
│  │   Primary       │   Replication    │    Standby      │                      │
│  │ 192.168.1.10    │ ───────────────► │ 192.168.1.11    │                      │
│  │ ┌─────────────┐ │                  │ ┌─────────────┐ │                      │
│  │ │PostgreSQL 17│ │                  │ │PostgreSQL 17│ │                      │
│  │ │Port: 5432   │ │                  │ │Port: 5432   │ │                      │
│  │ └─────────────┘ │                  │ └─────────────┘ │                      │
│  │ ┌─────────────┐ │                  │ ┌─────────────┐ │                      │
│  │ │ repmgrd     │ │◄─── Monitoring ──┤ │ repmgrd     │ │                      │
│  │ │ (daemon)    │ │                  │ │ (daemon)    │ │                      │
│  │ └─────────────┘ │                  │ └─────────────┘ │                      │
│  │ ┌─────────────┐ │                  │ ┌─────────────┐ │                      │
│  │ │ PgBouncer   │ │                  │ │ PgBouncer   │ │                      │
│  │ │Port: 6432   │ │                  │ │Port: 6432   │ │                      │
│  │ └─────────────┘ │                  │ └─────────────┘ │                      │
│  │                 │                  │                 │                      │
│  │ ┌─────────────┐ │                  │ ┌─────────────┐ │                      │
│  │ │WAL Archive  │ │                  │ │Backup       │ │                      │
│  │ │/var/lib/... │ │                  │ │Scripts      │ │                      │
│  │ └─────────────┘ │                  │ └─────────────┘ │                      │
│  └─────────────────┘                  └─────────────────┘                      │
│           │                                     │                               │
│           │ WAL Archiving                       │ Offload Backups               │
│           │                                     │                               │
│           ▼                                     ▼                               │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                        Backup Storage                                   │   │
│  │                    /var/backups/postgresql/                             │   │
│  │                                                                         │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │   │
│  │  │Base Backups │  │Logical      │  │WAL Archive  │  │Scripts &    │   │   │
│  │  │(Physical)   │  │Backups      │  │Files        │  │Monitoring   │   │   │
│  │  │Daily 2AM    │  │.dump/.sql   │  │Continuous   │  │Automation   │   │   │
│  │  │.tar.gz      │  │.dump/.sql   │  │Point-in-Time│  │Verification │   │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │   │
│  │                                                                         │   │
│  │  Backup Types:                                                          │   │
│  │  • Base: pg_basebackup (full cluster)                                  │   │
│  │  • Logical: pg_dump (specific databases)                               │   │
│  │  • WAL: Continuous archiving                                           │   │
│  │  • Retention: 7 days (base), 14 days (logical)                        │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                         Backup Automation                               │   │
│  │                                                                         │   │
│  │  Cron Jobs (postgres user):                                            │   │
│  │  • 0 2 * * *   - Daily base backup                                     │   │
│  │  • 0 */6 * * * - 6-hourly logical backup                               │   │
│  │  • 0 1 * * 0   - Weekly full system backup                             │   │
│  │                                                                         │   │
│  │  Smart Features:                                                        │   │
│  │  • Interactive/Non-interactive modes                                    │   │
│  │  • Database selection: all, system, specific                           │   │
│  │  • Backup verification & statistics                                     │   │
│  │  • Automatic cleanup & retention                                        │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘

Data Flow:
┌─────────────┐ Replication ┌─────────────┐
│   Primary   │────────────►│   Standby   │
│             │             │             │
│             │ WAL Archive │             │
│             │──────────── ┘             │
│             │                           │
│             │ Base Backup               │ Offload Backup
│             │◄────────────────────────── ┘
└─────────────┘                           └─────────────┘
       │                                         │
       │ Logical Backup                          │
       ▼                                         ▼
┌─────────────────────────────────────────────────────┐
│              Backup Repository                      │
│  • Point-in-time Recovery (WAL + Base)             │
│  • Database-specific Restores (Logical)            │
│  • Cross-site Replication Ready                    │
└─────────────────────────────────────────────────────┘
```

### Backup Infrastructure Components

1. **WAL Archiving**:
   - Continuous archiving from primary
   - Point-in-time recovery capability
   - Stored in `/var/lib/postgresql/17/wal_archive/`

2. **Base Backups**:
   - Physical cluster backups via `pg_basebackup`
   - Full cluster state capture
   - Daily automated via cron

3. **Logical Backups**:
   - Database-specific dumps via `pg_dump`
   - Flexible restore options
   - Supports selective database backup

4. **Backup Offloading**:
   - Standby can perform backups
   - Reduces primary server load
   - Maintains backup availability during primary maintenance

## Deployment Process

### Step 1: Prepare Environment
```bash
# Make scripts executable
chmod +x *.sh

# Ensure network connectivity between servers
ping 192.168.1.11  # From primary to standby
ping 192.168.1.10  # From standby to primary
```

### Step 2: Deploy Primary Node
```bash
# Option 1: With arguments (recommended for automation)
sudo ./01-pgsql_setup-primary.sh 192.168.1.10 192.168.1.11

# Option 2: Interactive mode
sudo ./01-pgsql_setup-primary.sh
```

**Primary script will:**
- Install PostgreSQL 17, repmgr, PgBouncer
- Configure streaming replication
- Create repmgr user and database
- Set up pg_hba.conf authentication
- Register primary node in cluster
- Enable automatic failover monitoring

### Step 3: Deploy Standby Node
```bash
# Use same IPs as primary setup
sudo ./02-pgsql_setup-standby.sh 192.168.1.10 192.168.1.11
```

**Standby script will:**
- Install required packages
- Clone data from primary using repmgr
- Register as standby node
- Configure automatic failover
- Start monitoring daemon

### Step 4: Verify Setup
```bash
# Check cluster status
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show

# Expected output:
#  ID | Name    | Role    | Status    | Upstream | Location | Priority | Timeline | Connection string
# ----+---------+---------+-----------+----------+----------+----------+----------+------------------
#  1  | primary | primary | * running |          | default  | 100      | 1        | host=192.168.1.10...
#  2  | standby | standby |   running | primary  | default  | 100      | 1        | host=192.168.1.11...
```

## Script Features

### Error Handling
- **Set -e**: Scripts exit on any command failure
- **IP Validation**: Prevents invalid IP addresses
- **User Confirmation**: Shows configuration before proceeding
- **Service Verification**: Checks if services start correctly

### Security Features
- **Authentication Setup**: Configures proper pg_hba.conf rules
- **Password Management**: Uses consistent passwords across setup
- **Network Security**: Restricts access to specific IP addresses

### Automation Support
- **Non-interactive Mode**: Run with arguments for CI/CD
- **Clear Exit Codes**: Proper error codes for automation
- **Logging**: Colored output for easy troubleshooting

## Configuration Files Generated

### repmgr.conf
```ini
node_id=1                               # 1 for primary, 2 for standby
node_name='primary'                     # Node identifier
conninfo='host=192.168.1.10 user=repmgr dbname=repmgr password=StrongPass'
data_directory='/var/lib/postgresql/17/main'
failover='automatic'                    # Enable automatic failover
monitor_interval_secs=2                 # Health check frequency
```

### pg_hba.conf additions
```
host replication repmgr 192.168.1.11/32 md5    # Standby replication access
host repmgr repmgr 192.168.1.11/32 md5          # Standby repmgr access
host repmgr repmgr 192.168.1.10/32 trust        # Primary repmgr access
```

## Testing Failover

### Manual Failover Test
```bash
# On primary - simulate failure
sudo systemctl stop postgresql

# On standby - monitor automatic promotion
sudo tail -f /var/log/postgresql/postgresql-17-main.log

# Check new cluster status
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show
```

### Connection Test
```bash
# Test PostgreSQL connection
psql -h 192.168.1.10 -U repmgr -d repmgr -p 5432

# Test PgBouncer connection
psql -h 192.168.1.10 -U repmgr -d repmgr -p 6432
```

## Troubleshooting

### Common Issues and Solutions

1. **"Connection refused" during clone**:
   ```bash
   # Check PostgreSQL is running on primary
   sudo systemctl status postgresql
   
   # Verify pg_hba.conf allows connections
   sudo cat /etc/postgresql/17/main/pg_hba.conf | grep repmgr
   ```

2. **IP validation failure**:
   ```bash
   # Script validates format: xxx.xxx.xxx.xxx where xxx <= 255
   # Ensure IPs are in correct format
   ```

3. **Service start failures**:
   ```bash
   # Check logs
   sudo journalctl -u postgresql
   sudo journalctl -u repmgrd
   ```

## Component References & Documentation

### PostgreSQL 17 High Availability
- **Official HA Documentation**: https://www.postgresql.org/docs/17/high-availability.html
- **Streaming Replication**: https://www.postgresql.org/docs/17/warm-standby.html#STREAMING-REPLICATION
- **WAL Configuration**: https://www.postgresql.org/docs/17/wal-configuration.html
- **Recovery Configuration**: https://www.postgresql.org/docs/17/recovery-config.html

### repmgr Configuration & Usage
- **repmgr Documentation**: https://repmgr.org/docs/current/
- **Installation Guide**: https://repmgr.org/docs/current/installation.html
- **Configuration File Reference**: https://repmgr.org/docs/current/configuration.html
- **Failover Scenarios**: https://repmgr.org/docs/current/failover-manual.html
- **Monitoring with repmgr**: https://repmgr.org/docs/current/repmgrd-monitoring.html

### PgBouncer Setup & Tuning
- **PgBouncer Documentation**: https://www.pgbouncer.org/usage.html
- **Configuration Parameters**: https://www.pgbouncer.org/config.html
- **Pool Modes Explained**: https://www.pgbouncer.org/features.html#pool-modes
- **Authentication**: https://www.pgbouncer.org/config.html#authentication

### Backup & Recovery References
- **pg_basebackup Manual**: https://www.postgresql.org/docs/17/app-pgbasebackup.html
- **Continuous Archiving**: https://www.postgresql.org/docs/17/continuous-archiving.html
- **Point-in-Time Recovery**: https://www.postgresql.org/docs/17/recovery-target-settings.html
- **Backup Strategies**: https://www.postgresql.org/docs/17/backup-dump.html

### SSL/TLS Security
- **PostgreSQL SSL Configuration**: https://www.postgresql.org/docs/17/ssl-tcp.html
- **Client Certificates**: https://www.postgresql.org/docs/17/ssl-tcp.html#SSL-CLIENT-CERTIFICATES
- **OpenSSL Certificate Generation**: https://www.openssl.org/docs/man1.1.1/man1/openssl-req.html

### Performance & Monitoring
- **PostgreSQL Performance Tips**: https://wiki.postgresql.org/wiki/Performance_Optimization
- **System Monitoring**: https://www.postgresql.org/docs/17/monitoring.html
- **Statistics Collector**: https://www.postgresql.org/docs/17/monitoring-stats.html
- **pg_stat_statements**: https://www.postgresql.org/docs/17/pgstatstatements.html

### Prometheus Integration
- **postgres_exporter**: https://github.com/prometheus-community/postgres_exporter
- **Prometheus Configuration**: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- **PostgreSQL Grafana Dashboards**: https://grafana.com/grafana/dashboards/9628-postgresql-database/

## Troubleshooting Resources

### PostgreSQL Troubleshooting
- **Error Reporting**: https://www.postgresql.org/docs/17/error-reporting.html
- **Log Analysis**: https://www.postgresql.org/docs/17/logfile-maintenance.html
- **Common Issues**: https://wiki.postgresql.org/wiki/Troubleshooting

### repmgr Troubleshooting
- **Common Issues**: https://repmgr.org/docs/current/troubleshooting.html
- **Event Notifications**: https://repmgr.org/docs/current/event-notifications.html
- **Log Analysis**: https://repmgr.org/docs/current/appendix-signatures.html

### PgBouncer Troubleshooting
- **FAQ**: https://www.pgbouncer.org/faq.html
- **Admin Console**: https://www.pgbouncer.org/usage.html#admin-console
- **Debugging**: https://www.pgbouncer.org/config.html#log-settings

### System-Level Troubleshooting
- **Ubuntu Server Guide**: https://help.ubuntu.com/lts/serverguide/
- **systemd Troubleshooting**: https://www.freedesktop.org/software/systemd/man/systemd.service.html
- **Network Troubleshooting**: https://help.ubuntu.com/community/NetworkConfigurationCommandLine

## Version Compatibility Matrix

| Component | Version | PostgreSQL 17 Compatibility | Notes |
|-----------|---------|----------------------------|-------|
| repmgr | 5.4+ | ✅ Full Support | Recommended for PG 17 |
| PgBouncer | 1.21+ | ✅ Full Support | Latest features supported |
| Ubuntu | 24.04 LTS | ✅ Fully Supported | Native packages available |
| Prometheus Exporter | 0.15+ | ✅ Full Support | All metrics supported |

## Best Practices Documentation

### PostgreSQL Best Practices
- **Production Checklist**: https://wiki.postgresql.org/wiki/Production_Checklist
- **Security Checklist**: https://wiki.postgresql.org/wiki/Security
- **Performance Checklist**: https://wiki.postgresql.org/wiki/Performance_Optimization

### Backup Best Practices
- **Backup & Recovery**: https://www.postgresql.org/docs/17/backup.html
- **Recovery Testing**: https://wiki.postgresql.org/wiki/Recovery_Testing

### High Availability Best Practices
- **HA Deployment Guide**: https://www.postgresql.org/docs/17/different-replication-solutions.html
- **Monitoring Replication**: https://www.postgresql.org/docs/17/monitoring-replication.html
ls -lah /var/backups/postgresql/logical/

# Verify specific database backups
ls -lah /var/backups/postgresql/logical/your_database/
```

**Backup Statistics in Logs**:
The scripts now provide detailed statistics:
```
2024-01-15 02:00:01: Starting logical backup for databases: app_db user_db
2024-01-15 02:00:15: Successfully backed up: app_db
2024-01-15 02:00:28: Successfully backed up: user_db
2024-01-15 02:00:35: Full cluster dump completed
2024-01-15 02:00:35: Logical backup completed - Success: 2, Failed: 0
```

## Backup Strategies for HA Setup

### 1. Continuous WAL Archiving
Configure WAL archiving on the primary node for point-in-time recovery:

```bash
# Edit postgresql.conf on primary
sudo nano /etc/postgresql/17/main/postgresql.conf

# Add WAL archiving configuration
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/17/wal_archive/%f && cp %p /var/lib/postgresql/17/wal_archive/%f'
archive_timeout = 300  # Archive WAL files every 5 minutes
```

Create archive directory:
```bash
sudo mkdir -p /var/lib/postgresql/17/wal_archive
sudo chown postgres:postgres /var/lib/postgresql/17/wal_archive
sudo systemctl restart postgresql
```

### 2. Base Backups
Regular base backups from the primary or standby:

```bash
# Backup script for HA cluster
#!/bin/bash
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)
PRIMARY_IP="192.168.1.10"
STANDBY_IP="192.168.1.11"

# Create backup directory
sudo mkdir -p $BACKUP_DIR

# Take base backup from primary
sudo -u postgres pg_basebackup -h $PRIMARY_IP -D $BACKUP_DIR/base_backup_$DATE -Ft -z -Xs -P

# Backup cluster configuration
sudo -u postgres pg_dumpall -h $PRIMARY_IP --roles-only > $BACKUP_DIR/roles_$DATE.sql
sudo -u postgres pg_dumpall -h $PRIMARY_IP --tablespaces-only > $BACKUP_DIR/tablespaces_$DATE.sql

# Clean old backups (keep last 7 days)
find $BACKUP_DIR -name "base_backup_*" -mtime +7 -exec rm -rf {} \;
find $BACKUP_DIR -name "roles_*" -mtime +7 -delete
find $BACKUP_DIR -name "tablespaces_*" -mtime +7 -delete

echo "Backup completed: $BACKUP_DIR/base_backup_$DATE"
```

### 3. Logical Backups
Regular logical backups for specific databases:

```bash
# Logical backup script
#!/bin/bash
BACKUP_DIR="/var/backups/postgresql/logical"
DATE=$(date +%Y%m%d_%H%M%S)
PRIMARY_IP="192.168.1.10"
DATABASES=("repmgr" "your_app_db")  # Add your databases

sudo mkdir -p $BACKUP_DIR

for db in "${DATABASES[@]}"; do
    echo "Backing up database: $db"
    sudo -u postgres pg_dump -h $PRIMARY_IP -d $db -Fc > $BACKUP_DIR/${db}_$DATE.dump
done

# Full cluster dump
sudo -u postgres pg_dumpall -h $PRIMARY_IP > $BACKUP_DIR/full_cluster_$DATE.sql
gzip $BACKUP_DIR/full_cluster_$DATE.sql

# Cleanup old logical backups
find $BACKUP_DIR -name "*.dump" -mtime +14 -delete
find $BACKUP_DIR -name "*.sql.gz" -mtime +14 -delete
```

### 4. Standby Backups (Offload Primary)
Use standby server for backups to reduce primary load:

```bash
# Backup from standby script
#!/bin/bash
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)
STANDBY_IP="192.168.1.11"

# Base backup from standby (read-only)
sudo -u postgres pg_basebackup -h $STANDBY_IP -D $BACKUP_DIR/standby_backup_$DATE -Ft -z -Xs -P

# Logical backup from standby
sudo -u postgres pg_dump -h $STANDBY_IP -d repmgr -Fc > $BACKUP_DIR/repmgr_standby_$DATE.dump
```

### 5. Automated Backup Scheduling
Set up cron jobs for automated backups:

```bash
# Edit crontab for postgres user
sudo -u postgres crontab -e

# Add backup schedules
# Daily base backup at 2 AM
0 2 * * * /usr/local/bin/pg_ha_base_backup.sh

# Hourly logical backup of critical databases
0 * * * * /usr/local/bin/pg_ha_logical_backup.sh

# Weekly full cluster backup
0 3 * * 0 /usr/local/bin/pg_ha_full_backup.sh
```

### 6. Backup Verification
Regular backup verification script:

```bash
#!/bin/bash
# Backup verification script
BACKUP_DIR="/var/backups/postgresql"
TEST_DIR="/tmp/pg_backup_test"
LATEST_BACKUP=$(ls -t $BACKUP_DIR/base_backup_* | head -1)

echo "Verifying backup: $LATEST_BACKUP"

# Create test directory
sudo mkdir -p $TEST_DIR
sudo chown postgres:postgres $TEST_DIR

# Extract and verify backup
sudo -u postgres tar -xf $LATEST_BACKUP/base.tar.gz -C $TEST_DIR

# Check for critical files
if [[ -f "$TEST_DIR/PG_VERSION" && -f "$TEST_DIR/postgresql.conf" ]]; then
    echo "✓ Backup verification successful"
    sudo rm -rf $TEST_DIR
    exit 0
else
    echo "✗ Backup verification failed"
    sudo rm -rf $TEST_DIR
    exit 1
fi
```

### 7. Disaster Recovery Procedures

**Complete Cluster Failure Recovery:**
```bash
# 1. Restore base backup on new primary server
sudo -u postgres tar -xf /path/to/backup/base.tar.gz -C /var/lib/postgresql/17/main/

# 2. Create recovery.conf (PostgreSQL 12+: postgresql.auto.conf)
echo "restore_command = 'cp /var/lib/postgresql/17/wal_archive/%f %p'" | sudo -u postgres tee /var/lib/postgresql/17/main/postgresql.auto.conf

# 3. Start PostgreSQL in recovery mode
sudo systemctl start postgresql

# 4. Once recovered, setup new standby using existing scripts
sudo ./02-pgsql_setup-standby.sh 192.168.1.10 192.168.1.11
```

**Primary Failure with Standby Available:**
```bash
# Standby automatically promotes (if repmgrd is running)
# Or manually promote:
sudo -u postgres repmgr -f /etc/repmgr.conf standby promote

# Setup new standby on recovered primary server
sudo ./02-pgsql_setup-standby.sh 192.168.1.11 192.168.1.10  # Note: IPs swapped
```

### 8. Backup Monitoring
Monitor backup status and health:

```bash
#!/bin/bash
# Backup monitoring script
BACKUP_DIR="/var/backups/postgresql"
ALERT_EMAIL="admin@yourcompany.com"

# Check if recent backups exist
LATEST_BASE=$(find $BACKUP_DIR -name "base_backup_*" -mtime -1 | wc -l)
LATEST_LOGICAL=$(find $BACKUP_DIR -name "*.dump" -mtime -1 | wc -l)

if [[ $LATEST_BASE -eq 0 ]]; then
    echo "WARNING: No base backup in last 24 hours" | mail -s "PostgreSQL Backup Alert" $ALERT_EMAIL
fi

if [[ $LATEST_LOGICAL -eq 0 ]]; then
    echo "WARNING: No logical backup in last 24 hours" | mail -s "PostgreSQL Backup Alert" $ALERT_EMAIL
fi

# Check WAL archive status
LATEST_WAL=$(find /var/lib/postgresql/17/wal_archive -name "*.gz" -mtime -1 | wc -l)
if [[ $LATEST_WAL -eq 0 ]]; then
    echo "WARNING: No WAL files archived in last 24 hours" | mail -s "PostgreSQL WAL Archive Alert" $ALERT_EMAIL
fi
```

### 9. Best Practices for HA Backups

- **3-2-1 Rule**: Keep 3 copies, on 2 different media, with 1 offsite
- **Test Restores**: Regularly test backup restoration procedures
- **Monitor Replication Lag**: Ensure standby is not too far behind
- **Document Procedures**: Maintain updated disaster recovery documentation
- **Automate Where Possible**: Use scripts and monitoring for consistency
- **Secure Backups**: Encrypt sensitive backup data
- **Cross-Region Backups**: Store backups in different geographical locations

This enhanced setup provides a robust, production-ready PostgreSQL HA cluster with comprehensive backup and disaster recovery capabilities.

## Production-Grade Enhancements

### Security Hardening

#### SSL/TLS Configuration
```bash
# Generate SSL certificates
sudo mkdir -p /etc/postgresql/17/main/ssl
sudo openssl req -new -x509 -days 365 -nodes -text -out /etc/postgresql/17/main/ssl/server.crt -keyout /etc/postgresql/17/main/ssl/server.key -subj "/CN=postgresql-primary"

# Update postgresql.conf
echo "ssl = on
ssl_cert_file = '/etc/postgresql/17/main/ssl/server.crt'
ssl_key_file = '/etc/postgresql/17/main/ssl/server.key'
ssl_prefer_server_ciphers = on" | sudo tee -a /etc/postgresql/17/main/postgresql.conf

# Update pg_hba.conf for SSL-only connections
sudo sed -i 's/md5/scram-sha-256/g' /etc/postgresql/17/main/pg_hba.conf
echo "hostssl all all 0.0.0.0/0 scram-sha-256" | sudo tee -a /etc/postgresql/17/main/pg_hba.conf
```

#### Enhanced Authentication
```bash
# Create application-specific users with limited privileges
sudo -u postgres psql <<EOF
CREATE ROLE app_readonly;
GRANT CONNECT ON DATABASE your_app_db TO app_readonly;
GRANT USAGE ON SCHEMA public TO app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_readonly;

CREATE USER app_read_user WITH PASSWORD 'strong_password' IN ROLE app_readonly;
EOF
```

### Performance Optimization

#### Memory and Resource Tuning
```bash
# Production postgresql.conf settings
cat >> /etc/postgresql/17/main/postgresql.conf <<EOF
# Memory settings (adjust for your server)
shared_buffers = 512MB                    # 25% of RAM for 2GB server
effective_cache_size = 1536MB             # 75% of RAM
work_mem = 8MB                            # Per operation memory
maintenance_work_mem = 128MB              # For maintenance operations
max_connections = 150                     # Based on application needs

# Checkpoint and WAL settings
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_wal_size = 2GB
min_wal_size = 512MB

# Query planner settings
random_page_cost = 1.1                    # For SSD storage
effective_io_concurrency = 200            # For SSD storage

# Connection settings
tcp_keepalives_idle = 600
tcp_keepalives_interval = 30
tcp_keepalives_count = 3
EOF
```

#### Query Optimization
```bash
# Enable slow query logging
cat >> /etc/postgresql/17/main/postgresql.conf <<EOF
# Logging settings
log_destination = 'csvlog'
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_min_duration_statement = 1000        # Log queries taking > 1 second
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
EOF
```

### Advanced Monitoring

#### Prometheus Integration
```bash
# Install postgres_exporter
wget https://github.com/prometheus-community/postgres_exporter/releases/latest/download/postgres_exporter-*linux-amd64.tar.gz
tar xzf postgres_exporter-*linux-amd64.tar.gz
sudo mv postgres_exporter-*/postgres_exporter /usr/local/bin/

# Create monitoring user
sudo -u postgres psql <<EOF
CREATE USER postgres_exporter WITH PASSWORD 'exporter_password';
ALTER USER postgres_exporter SET SEARCH_PATH TO postgres_exporter,pg_catalog;
GRANT CONNECT ON DATABASE postgres TO postgres_exporter;
GRANT pg_monitor TO postgres_exporter;
EOF

# Create systemd service
sudo tee /etc/systemd/system/postgres_exporter.service <<EOF
[Unit]
Description=Prometheus PostgreSQL Exporter
After=network.target

[Service]
Type=simple
User=postgres
Environment=DATA_SOURCE_NAME="postgresql://postgres_exporter:exporter_password@localhost:5432/postgres?sslmode=disable"
ExecStart=/usr/local/bin/postgres_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable postgres_exporter
sudo systemctl start postgres_exporter
```

### Disaster Recovery Enhancements

#### Point-in-Time Recovery Setup
```bash
# Enhanced WAL archiving with compression and remote storage
cat >> /etc/postgresql/17/main/postgresql.conf <<EOF
# Enhanced archiving
archive_command = 'gzip < %p > /var/lib/postgresql/17/wal_archive/%f.gz && rsync /var/lib/postgresql/17/wal_archive/%f.gz backup_server:/postgresql_archive/'
restore_command = 'gunzip < /var/lib/postgresql/17/wal_archive/%f.gz > %p'
archive_cleanup_command = 'pg_archivecleanup /var/lib/postgresql/17/wal_archive %r'
EOF
```

#### Automated Failover Testing
```bash
# Create failover test script
sudo tee /var/backups/postgresql/scripts/test_failover.sh <<'EOF'
#!/bin/bash
# Automated failover test (use with caution)
echo "$(date): Starting failover test"

# Check initial cluster status
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show

# Simulate primary failure (on test environment only)
if [[ "$ENVIRONMENT" == "test" ]]; then
    sudo systemctl stop postgresql
    sleep 30
    
    # Check if standby promoted
    ssh standby_server "sudo -u postgres repmgr -f /etc/repmgr.conf cluster show"
    
    # Restore primary as standby
    sudo systemctl start postgresql
    sudo -u postgres repmgr -f /etc/repmgr.conf node rejoin -d 'host=standby_ip user=repmgr dbname=repmgr' --force-rewind
fi

echo "$(date): Failover test completed"
EOF
```
