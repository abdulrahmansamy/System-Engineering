# High Availability PostgreSQL Setup - Complete Configuration Summary

## Overview

This document provides a comprehensive summary of the High Availability (HA) PostgreSQL infrastructure deployed on Google Cloud Platform (GCP).

## Architecture

### Infrastructure Components

1. **PostgreSQL Cluster**
   - **Version**: PostgreSQL 17
   - **Configuration**: Primary-Standby streaming replication
   - **Deployment**: GCP Compute Engine instances
   - **Data Directory**: `/var/lib/postgresql/17/main`
   - **Configuration Files**: `/etc/postgresql/17/main/`

2. **Instances**
   - **Primary Node**: `prd-ipa-pgdb1` (ipa-prd-ha-pg-primary-01)
   - **Standby Node**: `prd-ipa-pgdb2` (ipa-prd-ha-pg-standby-01)
   - **Connection Pooler**: PgBouncer on both nodes (port 6432)
   - **PostgreSQL Port**: 5432

3. **Load Balancer**
   - **Type**: GCP Internal TCP/UDP Load Balancer
   - **Purpose**: Automatic traffic routing to active primary
   - **Health Checks**: TCP connection on port 5432
   - **Failover**: Automatic backend switching on health check failure
   - **Management**: Custom script `gcp-lb-manager.sh` for backend updates

## Key Features

### 1. **Streaming Replication**
   - Asynchronous streaming replication from primary to standby
   - WAL archiving enabled for Point-in-Time Recovery (PITR)
   - Archive location: `/var/lib/postgresql/17/main/archive/`
   - Archive command configured for GCS backup integration

### 2. **Connection Pooling (PgBouncer)**
   - **Configuration**: Transaction pooling mode
   - **Max Connections**: Configured per instance resources
   - **User Authentication**: MD5 with userlist file
   - **Config Location**: `/etc/pgbouncer/pgbouncer.ini`

### 3. **High Availability Mechanisms**
   - **Auto-Failover**: Load balancer health checks detect failures
   - **Manual Failback**: Controlled process for returning to original primary
   - **Monitoring**: Health check endpoints and status validation

### 4. **Backup Strategy**
   - **WAL Archiving**: Continuous archival to local directory
   - **Backup Script**: `push_backups_to_oss_bucket_v1.1.sh`
   - **Target**: Cloud object storage (GCS) for offsite backups
   - **Retention**: Configurable backup retention policy

## PostgreSQL Configuration Highlights

### Replication Settings
- `wal_level = replica`
- `max_wal_senders = 10`
- `max_replication_slots = 10`
- `hot_standby = on` (standby)
- `archive_mode = on`
- `archive_command` configured for WAL shipping

### Performance Tuning
- `shared_buffers`: Optimized based on available RAM
- `effective_cache_size`: Tuned for system memory
- `work_mem`: Configured for query operations
- `maintenance_work_mem`: Set for maintenance tasks
- `checkpoint_completion_target`: Optimized for write performance

### Connection Settings
- `max_connections`: Set based on application requirements
- `listen_addresses = '*'`: All network interfaces
- Authentication via `pg_hba.conf` with host-based rules

## Network Configuration

### Firewall Rules
- PostgreSQL port (5432): Internal network access only
- PgBouncer port (6432): Application tier access
- SSH (22): Administrative access with restrictions
- Health check ports: Load balancer probe access

### IP Addressing
- Static internal IPs assigned to both instances
- Load balancer VIP for application connections
- Private network communication between nodes

## Security Features

1. **Authentication**
   - MD5 password authentication
   - Host-based access control (pg_hba.conf)
   - Replication user with restricted privileges

2. **Network Security**
   - VPC isolation
   - Firewall rules limiting access
   - No public IP exposure (internal LB only)

3. **Secrets Management**
   - Terraform-managed secrets
   - Encrypted connection passwords
   - Service account permissions

## Operational Procedures

### Failover Process
1. Health check detects primary failure
2. Load balancer automatically stops routing to failed primary
3. Applications experience brief connection interruption
4. Connections re-establish to standby (now serving)
5. Manual promotion of standby to primary if needed

### Failback Process (Manual)
1. Repair/restore original primary
2. Configure as new standby (replication from current primary)
3. Allow catch-up and synchronization
4. Execute controlled switchback during maintenance window
5. Update load balancer backend to original primary

### Monitoring & Maintenance
- PostgreSQL logs: `/var/log/postgresql/`
- Replication lag monitoring via `pg_stat_replication`
- WAL archive monitoring
- Disk space monitoring (data and archive directories)
- Connection pooler statistics via PgBouncer admin console

## Terraform Infrastructure

### Managed Resources
- Compute instances (primary and standby)
- Persistent disks for data storage
- VPC networks and subnets
- Firewall rules
- Load balancer components (forwarding rules, backend services, health checks)
- IAM roles and service accounts

### Configuration Files
- `compute.tf`: VM instance definitions
- `network.tf`: VPC and subnet configuration
- `firewall.tf`: Security rules
- `load_balancer.tf`: LB configuration
- `backends.tf`: Backend service definitions
- `addresses.tf`: Static IP reservations
- `iam.tf`: Service account and permissions
- `secrets.tf`: Sensitive data management

### Calculated Parameters
- `calc_GUC_parameters.tf`: Dynamic PostgreSQL tuning based on instance resources
- Automatic memory allocation calculations
- Connection limit optimization

## Database Configuration Analysis

### Primary Node Configuration (prd-ipa-pgdb1)
- **Role**: Active primary database server
- **Replication**: Sending WAL to standby
- **Archiving**: Active WAL archival
- **Status**: Accepting read/write connections
- **Standby File**: Not present (not in recovery)

### Standby Node Configuration (prd-ipa-pgdb2)
- **Role**: Hot standby replica
- **Replication**: Receiving WAL stream from primary
- **Status**: Read-only queries allowed
- **Standby File**: Present (in recovery mode)
- **Lag Monitoring**: Via `pg_stat_wal_receiver`

## Backup & Recovery

### WAL Archive Contents
- Continuous WAL segment archival
- Backup history files (`.backup` extension)
- Sequential WAL files for PITR capability
- Archive retention managed by backup script

### Recovery Capability
- Point-in-Time Recovery (PITR) supported
- Base backups with WAL archives
- Fast standby promotion for failover
- Restore procedures documented

## Performance Considerations

### Instance Sizing
- CPU and RAM allocated per workload requirements
- Disk IOPS provisioned for database performance
- Network bandwidth for replication traffic

### Query Optimization
- PgBouncer reduces connection overhead
- Connection pooling improves resource utilization
- Hot standby allows read query offloading

### Monitoring Metrics
- Replication lag (should be minimal)
- Connection pool utilization
- Disk I/O and space usage
- Query performance statistics

## Deployment Workflow

1. **Infrastructure Provisioning** (Terraform)
   - Execute `terraform init`
   - Review plan with `terraform plan`
   - Apply configuration with `terraform apply`

2. **PostgreSQL Setup**
   - Automated installation via startup scripts
   - Configuration file generation from templates
   - Replication setup and initialization

3. **Application Integration**
   - Connect via load balancer VIP
   - Use PgBouncer for connection pooling
   - Configure connection retry logic

4. **Validation**
   - Test primary connectivity
   - Verify replication status
   - Simulate failover scenario
   - Confirm backup operations

## Maintenance Tasks

### Regular Operations
- Monitor replication lag daily
- Review PostgreSQL logs for errors
- Check disk space utilization
- Verify backup completion
- Update statistics and vacuum

### Periodic Tasks
- PostgreSQL minor version updates
- Configuration tuning based on workload
- Firewall rule reviews
- Security patch application
- DR drill exercises

## Troubleshooting Guide

### Common Issues

**Replication Lag**
- Check network connectivity
- Verify WAL sender/receiver processes
- Review PostgreSQL logs
- Monitor disk I/O on standby

**Connection Issues**
- Verify PgBouncer status
- Check pg_hba.conf rules
- Review firewall rules
- Test load balancer health checks

**Failover Problems**
- Validate health check configuration
- Check load balancer backend status
- Verify standby readiness
- Review promotion procedures

## Future Enhancements

- Automated failback procedures
- Enhanced monitoring and alerting
- Backup encryption implementation
- Multi-region replication
- Read replica scaling
- Automated testing pipelines

## Contact & Support

- Infrastructure managed via Terraform
- Configuration stored in version control
- Documentation maintained in project repository
- Operational runbooks available for common scenarios

---

**Document Version**: 3.0  
**Last Updated**: Based on configuration analysis  
**PostgreSQL Version**: 17  
**Platform**: Google Cloud Platform
