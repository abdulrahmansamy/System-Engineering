# PostgreSQL Setup Scripts

This repository contains PostgreSQL installation and configuration scripts for different deployment scenarios.

## Directory Structure

- `01-single_node_setup/` - Single node PostgreSQL installation
- `02-HA_setup/` - High Availability setup with repmgr and PgBouncer
- `03-gcp_pgsql_HA_setup/` - GCP-optimized HA setup with cloud-native integration

## Comparison: Single Node vs HA Setup vs GCP HA

| Feature | Single Node | HA Setup | GCP HA Setup |
|---------|-------------|-----------|---------------|
| **Complexity** | Simple | Advanced | Advanced |
| **Arguments** | None | IP addresses required | Auto-detected or manual |
| **Installation Time** | ~2-3 minutes | ~5-10 minutes | ~5-10 minutes |
| **High Availability** | No | Yes (automatic failover) | Yes (automatic failover) |
| **Use Case** | Development/Small apps | Production | GCP Production |
| **Components** | PostgreSQL only | PostgreSQL + repmgr + PgBouncer | PostgreSQL + repmgr + PgBouncer + GCS |
| **Resource Usage** | Low | Medium | Medium |
| **Cloud Integration** | None | None | GCS, GCE metadata, firewall automation |
| **Maintenance** | Minimal | Regular monitoring needed | Regular monitoring + GCP tools |
| **Scalability** | Limited | Supports read replicas | Supports read replicas + GCP LB |
| **Backup Storage** | Local | Local + optional remote | Local + GCS with lifecycle |

## Quick Start

### Single Node Setup
```bash
cd 01-single_node_setup/
chmod +x 01-pgsql_single_node_setup.sh
sudo ./01-pgsql_single_node_setup.sh
```

### High Availability Setup
```bash
cd 02-HA_setup/

# On primary server - with command line arguments
sudo ./01-pgsql_setup-primary.sh 192.168.1.10 192.168.1.11

# On standby server - with command line arguments
sudo ./02-pgsql_setup-standby.sh 192.168.1.10 192.168.1.11

# Or run without arguments for interactive mode
sudo ./01-pgsql_setup-primary.sh  # Will prompt for IPs
```

### GCP High Availability Setup
```bash
cd 03-gcp_pgsql_HA_setup/

# Method 1: Manual execution with IPs
sudo ./01-pgsql_setup-primary-gcp.sh 10.0.1.10 10.0.1.11
sudo ./02-pgsql_setup-standby-gcp.sh 10.0.1.10 10.0.1.11

# Method 2: Auto-detection (GCE metadata)
sudo ./01-pgsql_setup-primary-gcp.sh  # Auto-detects IPs
sudo ./02-pgsql_setup-standby-gcp.sh  # Auto-detects IPs

# Method 3: User-data during instance creation
# See 03-gcp_pgsql_HA_setup/README.md for examples
```

## Architecture Overview

### Single Node Setup
Simple PostgreSQL 17 installation suitable for development or small applications.

### High Availability (HA) Setup
Production-ready HA cluster with:
- **Primary-Standby Replication**: Streaming replication for data redundancy
- **Automatic Failover**: repmgr monitors and promotes standby if primary fails
- **Connection Pooling**: PgBouncer manages database connections efficiently
- **Flexible Deployment**: Scripts accept IP addresses as arguments or prompt interactively

### GCP High Availability Setup
Cloud-native HA cluster optimized for Google Cloud Platform:
- **All HA features**: Same as standard HA setup
- **GCP Integration**: Automatic IP discovery, GCS backups, firewall automation
- **Health Checks**: Built-in endpoints for GCP Load Balancers
- **Auto-tuning**: Performance settings based on GCE instance specs
- **Zero-touch Deployment**: Runs via user-data during instance provisioning

## How the HA Setup Works

### Components

1. **PostgreSQL 17**: Main database engine with streaming replication
2. **repmgr**: Cluster management tool that handles:
   - Node registration and monitoring
   - Automatic failover and promotion
   - Cluster status tracking
3. **PgBouncer**: Connection pooler that:
   - Manages database connections
   - Reduces connection overhead
   - Provides connection pooling strategies

### Script Features

- **Command-line Arguments**: Pass IP addresses directly for automation
- **Interactive Mode**: Scripts prompt for missing IP addresses
- **IP Validation**: Built-in validation for IP address format
- **Error Handling**: Robust error checking and user confirmations
- **Clear Output**: Color-coded messages and progress indicators

### Usage Modes

1. **Automated Deployment**:
   ```bash
   ./01-pgsql_setup-primary.sh 192.168.1.10 192.168.1.11
   ```

2. **Interactive Mode**:
   ```bash
   ./01-pgsql_setup-primary.sh
   # Script will prompt: "Please enter the PRIMARY server IP address:"
   ```

3. **Mixed Mode**:
   ```bash
   ./01-pgsql_setup-primary.sh 192.168.1.10
   # Script will prompt only for the missing STANDBY IP
   ```

## Prerequisites for HA Setup

1. Two Ubuntu 24.04 LTS servers with network connectivity
2. Sufficient disk space for PostgreSQL data
3. Proper network configuration between servers
4. sudo privileges on both servers

## Security Considerations

- Change default passwords (`StrongPass`)
- Configure firewall rules for PostgreSQL (5432) and PgBouncer (6432)
- Use SSL/TLS for production deployments
- Implement proper backup strategies

## Monitoring and Maintenance

### Automated Backups
Both setups include automated backup scripts that work in two modes:

**Interactive Mode** (when run manually):
- Prompts for database names if not provided as arguments
- Shows colored output and progress indicators
- Allows user interaction
- Supports special keywords: `all`, `system`

**Non-Interactive Mode** (cron jobs):
- Uses conservative defaults if no arguments provided (repmgr only for HA)
- Plain text logging suitable for log files
- No user prompts (prevents cron job hanging)
- Supports database selection via arguments

**Usage Examples**:
```bash
# Interactive mode - prompts for selection
./pg_ha_logical_backup.sh

# Specific databases (works in both modes)
./pg_ha_logical_backup.sh database1,database2

# All user databases (excludes system databases)
./pg_ha_logical_backup.sh all

# All databases including system ones
./pg_ha_logical_backup.sh system

# Single database backup
./pg_ha_db_backup.sh mydatabase
```

### Backup Cron Job Examples
The HA setup creates a reference file with cron job examples at:
`/var/backups/postgresql/scripts/cron_examples.txt`

**Common Patterns**:
```bash
# Conservative - backup only critical databases every 6 hours
0 */6 * * * /var/backups/postgresql/scripts/pg_ha_logical_backup.sh repmgr,app_db

# Comprehensive - backup all user databases daily
0 1 * * * /var/backups/postgresql/scripts/pg_ha_logical_backup.sh all

# Complete - backup everything weekly (including system databases)
0 1 * * 0 /var/backups/postgresql/scripts/pg_ha_logical_backup.sh system

# Specific - backup important database multiple times per day
0 */4 * * * /var/backups/postgresql/scripts/pg_ha_db_backup.sh critical_app
```

### Backup Strategy Recommendations

**Development Environment**:
- Daily backups of all user databases: `all`
- Weekly full cluster backups

**Production Environment**:
- Hourly backups of critical databases: `db1,db2,db3`
- Daily backups of all user databases: `all`
- Weekly complete backups: `system`
- Daily base backups (physical)

### Cluster Status Commands
Check cluster status:
```bash
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show
```

View replication status:
```bash
sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"
```

Monitor PgBouncer:
```bash
psql -p 6432 -U repmgr -d pgbouncer -c "SHOW STATS;"
```

### Backup Monitoring
Check backup logs:
```bash
# View backup logs
sudo tail -f /var/log/postgresql/backup.log

# Check recent backups
ls -la /var/backups/postgresql/base/
ls -la /var/backups/postgresql/logical/
```

## Production-Grade Best Practices Assessment

### ✅ Currently Implemented
- **High Availability**: Primary-standby with automatic failover
- **Backup Strategy**: Multiple backup types (base, logical, WAL archiving)
- **Connection Pooling**: PgBouncer for connection management
- **Monitoring**: repmgr cluster monitoring and health checks
- **Automation**: Automated backup scheduling with retention policies
- **Error Handling**: Robust scripts with validation and logging

### 🔧 Recommended Enhancements for Production

#### Security Hardening
```bash
# SSL/TLS Configuration (add to postgresql.conf)
ssl = on
ssl_cert_file = '/etc/ssl/certs/postgresql.crt'
ssl_key_file = '/etc/ssl/private/postgresql.key'
ssl_ca_file = '/etc/ssl/certs/ca.crt'

# Enhanced authentication
password_encryption = 'scram-sha-256'
log_connections = on
log_disconnections = on
log_statement = 'all'  # or 'ddl' for production

# Network security
listen_addresses = 'primary_ip,standby_ip'  # Instead of '*'
```

#### Performance Optimization
```bash
# Memory settings (adjust based on server specs)
shared_buffers = '25% of RAM'
effective_cache_size = '75% of RAM'
work_mem = '4MB'
maintenance_work_mem = '256MB'
max_connections = 200

# Checkpoint settings
checkpoint_completion_target = 0.9
wal_buffers = '16MB'
```

#### Enhanced Monitoring
```bash
# Add monitoring tools
sudo apt install -y postgresql-contrib pgbadger

# Log analysis setup
log_destination = 'csvlog'
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_min_duration_statement = 1000  # Log slow queries
```

#### Backup Enhancements
```bash
# Offsite backup synchronization
rsync -av /var/backups/postgresql/ remote_server:/backups/postgresql/

# Backup encryption
gpg --cipher-algo AES256 --compress-algo 2 --symmetric backup.sql

# Backup testing automation
# Add to cron: weekly backup restore test
0 4 * * 0 /var/backups/postgresql/scripts/test_restore.sh
```

### 📋 Production Checklist

#### Pre-Deployment
- [ ] Change all default passwords
- [ ] Configure SSL certificates
- [ ] Set up firewall rules (UFW/iptables)
- [ ] Configure log rotation
- [ ] Set up monitoring alerts
- [ ] Test disaster recovery procedures
- [ ] Document runbooks

#### Security Configuration
- [ ] Enable SSL/TLS for all connections
- [ ] Configure proper pg_hba.conf rules
- [ ] Set up connection limits per user/database
- [ ] Enable audit logging
- [ ] Implement backup encryption
- [ ] Use secrets management (vault/k8s secrets)

#### Monitoring & Alerting
- [ ] Set up Prometheus + Grafana
- [ ] Configure PostgreSQL exporter
- [ ] Set up log aggregation (ELK/Loki)
- [ ] Create alerting rules for:
  - Replication lag
  - Connection count
  - Disk usage
  - Backup failures
  - Failover events

#### Backup & Recovery
- [ ] Test backup restoration procedures
- [ ] Set up cross-region backup replication
- [ ] Implement automated backup verification
- [ ] Document RTO/RPO requirements
- [ ] Create disaster recovery runbooks

### 🏗️ Enterprise-Grade Additions

#### Load Balancing & Read Replicas
```bash
# HAProxy for connection routing
frontend postgresql_frontend
    bind *:5432
    default_backend postgresql_primary

backend postgresql_primary
    server primary 192.168.1.10:5432 check
    server standby 192.168.1.11:5432 backup
```

#### Container Orchestration Ready
```yaml
# Kubernetes StatefulSet example
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql-ha
spec:
  serviceName: postgresql
  replicas: 2
  template:
    spec:
      containers:
      - name: postgresql
        image: postgres:17
        volumeMounts:
        - name: postgresql-storage
          mountPath: /var/lib/postgresql/data
```

#### Infrastructure as Code
```terraform
# Terraform example for cloud deployment
resource "aws_rds_cluster" "postgresql" {
  engine             = "aurora-postgresql"
  engine_version     = "17.0"
  master_username    = "postgres"
  backup_retention_period = 7
  backup_window      = "03:00-04:00"
  maintenance_window = "sun:04:00-sun:05:00"
}
```

### 📊 Performance Benchmarking

#### Built-in Testing
```bash
# pgbench for performance testing
createdb pgbench
pgbench -i -s 50 pgbench  # Initialize with scale factor 50
pgbench -c 10 -j 2 -t 1000 pgbench  # Run benchmark

# Connection pool testing
pgbench -h localhost -p 6432 -c 20 -j 4 -t 500 pgbench
```

### 🔄 Maintenance Procedures

#### Regular Maintenance Tasks
```bash
# Weekly maintenance script
#!/bin/bash
# Vacuum and analyze
sudo -u postgres vacuumdb --all --analyze --verbose

# Reindex if needed
sudo -u postgres reindexdb --all

# Update statistics
sudo -u postgres psql -c "ANALYZE;"

# Check for long-running queries
sudo -u postgres psql -c "SELECT * FROM pg_stat_activity WHERE state = 'active' AND query_start < NOW() - INTERVAL '1 hour';"
```

## Official Documentation & References

### Core Components

#### PostgreSQL 17
- **Official Website**: https://www.postgresql.org/
- **Documentation**: https://www.postgresql.org/docs/17/
- **Download**: https://www.postgresql.org/download/
- **Release Notes**: https://www.postgresql.org/docs/17/release-17.html
- **Configuration Reference**: https://www.postgresql.org/docs/17/runtime-config.html

#### repmgr (Replication Manager)
- **Official Website**: https://repmgr.org/
- **Documentation**: https://repmgr.org/docs/current/
- **GitHub Repository**: https://github.com/EnterpriseDB/repmgr
- **Configuration Guide**: https://repmgr.org/docs/current/configuration.html
- **Failover Guide**: https://repmgr.org/docs/current/promoting-standby.html

#### PgBouncer (Connection Pooler)
- **Official Website**: https://www.pgbouncer.org/
- **Documentation**: https://www.pgbouncer.org/usage.html
- **GitHub Repository**: https://github.com/pgbouncer/pgbouncer
- **Configuration Reference**: https://www.pgbouncer.org/config.html
- **Performance Tuning**: https://www.pgbouncer.org/faq.html

### Monitoring & Performance

#### Prometheus PostgreSQL Exporter
- **GitHub Repository**: https://github.com/prometheus-community/postgres_exporter
- **Metrics Guide**: https://github.com/prometheus-community/postgres_exporter/blob/master/README.md#metrics
- **Grafana Dashboards**: https://grafana.com/grafana/dashboards/9628-postgresql-database/

#### pgBadger (Log Analyzer)
- **Official Website**: https://pgbadger.darold.net/
- **GitHub Repository**: https://github.com/darold/pgbadger
- **Documentation**: https://github.com/darold/pgbadger/blob/master/README

#### Performance Testing Tools
- **pgbench**: https://www.postgresql.org/docs/17/pgbench.html
- **pg_stat_statements**: https://www.postgresql.org/docs/17/pgstatstatements.html

### Security & SSL/TLS

#### PostgreSQL Security
- **Security Guide**: https://www.postgresql.org/docs/17/security.html
- **SSL Support**: https://www.postgresql.org/docs/17/ssl-tcp.html
- **Authentication Methods**: https://www.postgresql.org/docs/17/auth-methods.html
- **pg_hba.conf**: https://www.postgresql.org/docs/17/auth-pg-hba-conf.html

#### OpenSSL (for SSL certificates)
- **Official Website**: https://www.openssl.org/
- **Documentation**: https://www.openssl.org/docs/

### Backup & Recovery

#### PostgreSQL Backup Tools
- **pg_basebackup**: https://www.postgresql.org/docs/17/app-pgbasebackup.html
- **pg_dump**: https://www.postgresql.org/docs/17/app-pgdump.html
- **pg_dumpall**: https://www.postgresql.org/docs/17/app-pg-dumpall.html
- **Continuous Archiving**: https://www.postgresql.org/docs/17/continuous-archiving.html
- **Point-in-Time Recovery**: https://www.postgresql.org/docs/17/recovery-target-settings.html

#### Backup Best Practices
- **PostgreSQL Backup Guide**: https://www.postgresql.org/docs/17/backup.html
- **WAL Archiving**: https://www.postgresql.org/docs/17/wal-configuration.html

### Operating System & Infrastructure

#### Ubuntu 24.04 LTS
- **Official Website**: https://ubuntu.com/
- **Server Guide**: https://ubuntu.com/server/docs
- **PostgreSQL on Ubuntu**: https://help.ubuntu.com/community/PostgreSQL

#### PostgreSQL APT Repository (PGDG)
- **Official Repository**: https://wiki.postgresql.org/wiki/Apt
- **Installation Guide**: https://www.postgresql.org/download/linux/ubuntu/

### Additional Tools & Utilities

#### System Monitoring
- **Prometheus**: https://prometheus.io/docs/
- **Grafana**: https://grafana.com/docs/
- **Node Exporter**: https://github.com/prometheus/node_exporter

#### Log Management
- **rsyslog**: https://www.rsyslog.com/doc/
- **logrotate**: https://linux.die.net/man/8/logrotate

#### Network & Firewall
- **UFW (Uncomplicated Firewall)**: https://help.ubuntu.com/community/UFW
- **iptables**: https://netfilter.org/documentation/

## Learning Resources

### PostgreSQL Learning
- **Official Tutorial**: https://www.postgresql.org/docs/17/tutorial.html
- **PostgreSQL Wiki**: https://wiki.postgresql.org/
- **Community Slack**: https://postgres-slack.herokuapp.com/

### High Availability & Clustering
- **PostgreSQL HA Guide**: https://www.postgresql.org/docs/17/high-availability.html
- **Streaming Replication**: https://www.postgresql.org/docs/17/warm-standby.html#STREAMING-REPLICATION

### Performance & Tuning
- **Performance Tips**: https://wiki.postgresql.org/wiki/Performance_Optimization
- **Configuration Tuning**: https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server
- **Query Optimization**: https://www.postgresql.org/docs/17/using-explain.html

### Security Best Practices
- **PostgreSQL Security Checklist**: https://www.postgresql.org/docs/17/security.html
- **Database Security Guide**: https://wiki.postgresql.org/wiki/Security

## Community & Support

### Official Support
- **PostgreSQL Mailing Lists**: https://www.postgresql.org/list/
- **Bug Reports**: https://www.postgresql.org/account/submitbug/
- **Professional Support**: https://www.postgresql.org/support/professional_support/

### Community Forums
- **PostgreSQL Forum**: https://www.postgresql.org/support/
- **Stack Overflow**: https://stackoverflow.com/questions/tagged/postgresql
- **Reddit**: https://www.reddit.com/r/PostgreSQL/

### Contributing
- **How to Contribute**: https://www.postgresql.org/developer/
- **Source Code**: https://git.postgresql.org/gitweb/?p=postgresql.git
- **Developer Documentation**: https://www.postgresql.org/docs/devel/