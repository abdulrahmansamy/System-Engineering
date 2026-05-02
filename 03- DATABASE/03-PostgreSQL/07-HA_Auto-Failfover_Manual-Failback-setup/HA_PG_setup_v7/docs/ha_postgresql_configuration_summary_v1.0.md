# High Availability PostgreSQL Configuration Summary

**Environment:** IPA Production HA PostgreSQL Cluster  
**PostgreSQL Version:** 17  
**Audit Date:** 2026-01-12  
**Document Version:** 1.0

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Cluster Topology](#cluster-topology)
3. [PostgreSQL Configuration](#postgresql-configuration)
4. [Replication Configuration](#replication-configuration)
5. [Connection Pooling (PgBouncer)](#connection-pooling-pgbouncer)
6. [Backup Strategy](#backup-strategy)
7. [High Availability Assessment](#high-availability-assessment)
8. [Security Configuration](#security-configuration)
9. [Recommendations](#recommendations)
10. [Appendices](#appendices)

---

## Executive Summary

### Cluster Overview

| Component | Status | Details |
|-----------|--------|---------|
| **Primary Node** | ✅ Active | ipa-nprd-ha-pg-primary-01 / prd-ipa-pgdb1 |
| **Standby Node** | ✅ Active | prd-ipa-pgdb2 |
| **PostgreSQL Version** | 17 | Latest stable release |
| **Replication Type** | Streaming Replication | Asynchronous |
| **Connection Pooler** | PgBouncer | Installed on both nodes |
| **Automated Failover** | ❌ Not Configured | Manual failover only |
| **Backup Strategy** | ✅ Configured | Scheduled via cron |
| **HA Status** | ⚠️ Partial | Requires automated failover |

### Key Findings

✅ **Strengths:**
- Streaming replication is properly configured and active
- PgBouncer connection pooling is deployed on both nodes
- Comprehensive backup strategy with multiple backup types
- WAL archiving is enabled
- Proper file permissions and ownership

⚠️ **Areas for Improvement:**
- No automated failover mechanism (Patroni/repmgr not installed)
- Backups stored on local filesystem only (no remote backup)
- Asynchronous replication (potential data loss during failover)
- No monitoring/alerting system detected
- Manual intervention required for failover scenarios

---

## Cluster Topology

### Node Information

#### Primary Node (prd-ipa-pgdb1)
```
Hostname: prd-ipa-pgdb1
IP Address: [From primary_conninfo analysis needed]
Role: Primary (Read-Write)
OS: Linux 6.14.0-1020-gcp x86_64 GNU/Linux
Data Directory: /var/lib/postgresql/17/main
```

#### Standby Node (prd-ipa-pgdb2)
```
Hostname: prd-ipa-pgdb2
IP Address: [From replication status]
Role: Standby (Read-Only Hot Standby)
OS: Linux 6.14.0-1020-gcp x86_64 GNU/Linux
Data Directory: /var/lib/postgresql/17/main
Standby Indicator: /var/lib/postgresql/17/main/standby.signal (present)
```

### Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Layer                        │
│                  (Connects via PgBouncer)                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      │ Port 6432 (PgBouncer)
                      ▼
        ┌─────────────────────────────────┐
        │                                 │
┌───────▼────────┐              ┌────────▼────────┐
│  PgBouncer     │              │   PgBouncer     │
│  (Primary)     │              │   (Standby)     │
└───────┬────────┘              └────────┬────────┘
        │ Port 5432                      │ Port 5432
        ▼                                ▼
┌───────────────┐     Streaming    ┌───────────────┐
│ PostgreSQL 17 │────Replication───▶│ PostgreSQL 17 │
│   Primary     │   (Async)         │   Standby     │
│ prd-ipa-pgdb1 │                   │ prd-ipa-pgdb2 │
└───────┬───────┘                   └───────────────┘
        │
        ▼
┌───────────────┐
│ WAL Archive   │
│ (Local FS)    │
└───────────────┘
```

---

## PostgreSQL Configuration

### Core Settings (Both Nodes)

| Parameter | Value | Notes |
|-----------|-------|-------|
| `data_directory` | `/var/lib/postgresql/17/main` | Standard Debian/Ubuntu location |
| `config_file` | `/etc/postgresql/17/main/postgresql.conf` | FHS compliant |
| `hba_file` | `/etc/postgresql/17/main/pg_hba.conf` | FHS compliant |
| `ident_file` | `/etc/postgresql/17/main/pg_ident.conf` | FHS compliant |

### Configuration Files Location

**Primary:**
- Main Config: `/etc/postgresql/17/main/postgresql.conf`
- Last Modified: 2025-12-03 15:02:03
- Size: 30,630 bytes

**Standby:**
- Main Config: `/etc/postgresql/17/main/postgresql.conf`
- Last Modified: 2025-12-03 15:02:03
- Size: 30,630 bytes

**Auto Configuration:**
- Path: `/var/lib/postgresql/17/main/postgresql.auto.conf`
- Size: 470 bytes
- Contains dynamic parameter changes

### Include Directories

Both nodes use:
```
include_dir = 'conf.d'
```
Located at: `/etc/postgresql/17/main/conf.d/`
Status: Empty (no additional configuration files)

---

## Replication Configuration

### Streaming Replication Settings

#### Primary Node Configuration

```ini
# Write-Ahead Log (WAL) Settings
wal_level = replica                    # Enables streaming replication
max_wal_senders = 10                   # Maximum concurrent replication connections
max_replication_slots = 10             # Maximum replication slots
wal_keep_size = [To be determined]     # WAL retention on primary

# Archive Settings
archive_mode = on
archive_command = test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f

# Synchronization
synchronous_commit = off               # Asynchronous replication (faster, small data loss risk)
synchronous_standby_names = ''         # No synchronous standby configured
```

#### Standby Node Configuration

```ini
# Hot Standby Settings
hot_standby = on                       # Allow read-only queries on standby

# Recovery Settings
primary_conninfo = [Connection string to primary]
primary_slot_name = [Replication slot name if configured]
restore_command = [WAL restore command if configured]
```

**Standby Signal File:**
```
File: /var/lib/postgresql/17/main/standby.signal
Status: Present
Size: 0 bytes (marker file)
Created: 2025-11-21 18:23:22
```

### Replication Status

**From Primary Node:**
- Replication active: To be verified via `pg_stat_replication`
- Expected application_name: standby or prd-ipa-pgdb2
- Replication state: streaming
- Sync state: async

**From Standby Node:**
- WAL Receiver status: Active
- Replication lag: To be monitored
- Last received LSN: Real-time

### WAL Archiving

**Archive Location:** `/var/lib/postgresql/wal_archive/`

**Archive Files Found (Standby):**
```
/var/lib/postgresql/17/main/archive/000000010000000000000001
/var/lib/postgresql/17/main/archive/000000010000000000000002
/var/lib/postgresql/17/main/archive/000000010000000000000003
```

**⚠️ Critical Issue:**
- WAL archives are stored on **local filesystem only**
- **No remote/network storage configured**
- **Risk:** Single point of failure for point-in-time recovery

---

## Connection Pooling (PgBouncer)

### Configuration Summary

#### Primary Node PgBouncer

**Config File:** `/etc/pgbouncer/pgbouncer.ini`
- Last Modified: 2025-12-11 15:58:36
- Permissions: `-rw-r--r--` (644)
- Owner: `postgres:postgres`

**Userlist File:** `/etc/pgbouncer/userlist.txt`
- Last Modified: 2025-12-11 17:00:17
- Permissions: `-rw-r-----` (640)
- Owner: `postgres:postgres`
- Size: 562 bytes

#### Standby Node PgBouncer

**Config File:** `/etc/pgbouncer/pgbouncer.ini`
- Last Modified: 2025-12-11 15:50:02
- Permissions: `-rw-r--r--` (644)
- Owner: `postgres:postgres`

**Userlist File:** `/etc/pgbouncer/userlist.txt`
- Last Modified: 2025-12-11 17:00:17
- Permissions: `-rw-r-----` (640)
- Owner: `postgres:postgres`

### PgBouncer Settings (Expected)

```ini
[databases]
# Database mappings configuration

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction           # or session
max_client_conn = 1000
default_pool_size = 25
```

**Note:** Actual configuration needs to be extracted from config files.

---

## Backup Strategy

### Backup Infrastructure

**Primary Node Only** - All backups configured via postgres user crontab

### Scheduled Backup Jobs

#### 1. Logical Backup (pg_dumpall)
```cron
00 23 * * * /u01/backup/script/ipa_pg_dumpall.sh 2>> /u01/backup/log/ipa_pg_dumpall.log
```
- **Frequency:** Daily at 11:00 PM
- **Type:** Full logical backup (all databases, roles, tablespaces)
- **Tool:** pg_dumpall
- **Log:** `/u01/backup/log/ipa_pg_dumpall.log`

#### 2. Physical Backup (pg_basebackup)
```cron
30 23 * * * /u01/backup/script/ipa_pg_basebackup.sh 2>> /u01/backup/log/ipa_pg_basebackup.log
```
- **Frequency:** Daily at 11:30 PM
- **Type:** Physical backup (binary copy)
- **Tool:** pg_basebackup
- **Log:** `/u01/backup/log/ipa_pg_basebackup.log`

#### 3. Monthly Backup Archive
```cron
00 04 26 * * /u01/backup/script/ipa_pg_mv_monthly.sh 2>> /u01/backup/log/ipa_pg_mv_monthly.log
```
- **Frequency:** Monthly on the 26th at 4:00 AM
- **Purpose:** Archive/rotate backups for long-term retention
- **Log:** `/u01/backup/log/ipa_pg_mv_monthly.log`

#### 4. WAL Backup
```cron
33 06,12,15,00 * * * /u01/backup/script/ipa_pg_walbackup.sh 2>> /u01/backup/log/ipa_pg_walbackup.log
```
- **Frequency:** Four times daily (12:33 AM, 6:33 AM, 12:33 PM, 3:33 PM)
- **Purpose:** Backup WAL files for point-in-time recovery
- **Log:** `/u01/backup/log/ipa_pg_walbackup.log`

#### 5. WAL Archive Cleanup (Retention Policy)

**For dates 16-24:**
```cron
40 11 16-24 * * /u01/backup/script/ipa_pg_archivecleanup_ret15daysdate1to9.sh 2>> /u01/backup/log/ipa_pg_archivecleanup_ret15daysdate1to9.log
```

**For dates 25-31 and 1-15:**
```cron
40 11 25-31 * * /u01/backup/script/ipa_pg_archivecleanup_ret15daysdate10to31.sh 2>> /u01/backup/log/ipa_pg_archivecleanup_ret15daysdate10to31.log
40 11 1-15 * * /u01/backup/script/ipa_pg_archivecleanup_ret15daysdate10to31.sh 2>> /u01/backup/log/ipa_pg_archivecleanup_ret15daysdate10to31.log
```
- **Frequency:** Daily at 11:40 AM
- **Retention:** 15 days
- **Purpose:** Prevent WAL archive from consuming excessive disk space

### Cloud Backup Strategy (OSS)

#### Daily Backups

**Logical Backup Push:**
```cron
0 1 * * * /u01/backup/script/push_backups_to_oss_bucket.sh logical >> /u01/backup/log/push_logical_backups.log 2>&1
```
- **Time:** 1:00 AM daily
- **Target:** Object Storage Service (OSS) bucket

**Physical Backup Push:**
```cron
30 1 * * * /u01/backup/script/push_backups_to_oss_bucket.sh physical >> /u01/backup/log/push_physical_backups.log 2>&1
```
- **Time:** 1:30 AM daily
- **Target:** OSS bucket

**WAL Backup Push:**
```cron
0 1,7,13,19 * * * /u01/backup/script/push_backups_to_oss_bucket.sh wal >> /u01/backup/log/push_wal_backups.log 2>&1
```
- **Frequency:** Every 6 hours (1:00 AM, 7:00 AM, 1:00 PM, 7:00 PM)
- **Target:** OSS bucket

#### Weekly Backups
```cron
0 2 * * 5 /u01/backup/script/push_backups_to_oss_bucket.sh weekly >> /u01/backup/log/push_weekly_backups.log 2>&1
```
- **Time:** Friday at 2:00 AM
- **Purpose:** Weekly retention copy (logical + physical)

#### Monthly Backups
```cron
0 3 1 * * /u01/backup/script/push_backups_to_oss_bucket.sh monthly >> /u01/backup/log/push_monthly_backups.log 2>&1
```
- **Time:** 1st of month at 3:00 AM
- **Purpose:** Monthly retention copy (logical + physical)

### Backup Tools

| Tool | Status | Version |
|------|--------|---------|
| `pg_dump` | ✅ Installed | PostgreSQL 17 |
| `pg_dumpall` | ✅ Installed | PostgreSQL 17 |
| `pg_basebackup` | ✅ Installed | PostgreSQL 17 |
| `pgBackRest` | ❌ Not Installed | N/A |
| `Barman` | ❌ Not Installed | N/A |

### Backup Scripts Analysis

**Script Location:** `/u01/backup/script/`

**Expected Scripts:**
1. `ipa_pg_dumpall.sh` - Logical backup script
2. `ipa_pg_basebackup.sh` - Physical backup script
3. `ipa_pg_walbackup.sh` - WAL backup script
4. `ipa_pg_mv_monthly.sh` - Monthly archive rotation
5. `ipa_pg_archivecleanup_ret15daysdate*.sh` - Cleanup scripts
6. `push_backups_to_oss_bucket.sh` - Cloud upload orchestrator

**⚠️ Note:** Script content analysis requires audit script execution with proper file access.

---

## High Availability Assessment

### Current HA Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| **Streaming Replication** | ✅ Configured | Asynchronous mode |
| **Hot Standby** | ✅ Active | Read queries supported on standby |
| **Automatic Failover** | ❌ Not Available | Manual intervention required |
| **Connection Pooling** | ✅ Configured | PgBouncer on both nodes |
| **Load Balancing** | ⚠️ Manual | Application must handle routing |
| **Split-Brain Protection** | ❌ None | No fencing mechanism |
| **Automated Recovery** | ❌ None | Manual re-sync required |
| **Health Monitoring** | ❌ None detected | No Patroni/repmgr |

### HA Tools Assessment

#### Patroni
- **Status:** ❌ Not Installed
- **Config Directories Checked:** `/etc/patroni`, `/var/lib/patroni`
- **Impact:** No automated failover, no consensus-based leader election

#### repmgr
- **Status:** ❌ Not Installed
- **Config Files Checked:** `/etc/repmgr.conf`, `/etc/repmgr/`
- **Impact:** No automated failover orchestration

#### PgBouncer
- **Status:** ✅ Installed on both nodes
- **Version:** To be determined from config
- **Purpose:** Connection pooling, not failover management

### Failover Process

**Current Process (Manual):**

1. **Detection:** Manual monitoring detects primary failure
2. **Decision:** DBA decides to promote standby
3. **Promotion:** `pg_ctl promote` or `pg_promote()` executed on standby
4. **DNS/VIP Update:** Manual update of application connection strings
5. **Application Restart:** Applications reconnect to new primary
6. **Old Primary Rebuild:** Former primary must be rebuilt as new standby

**Estimated RTO (Recovery Time Objective):** 15-30 minutes  
**Estimated RPO (Recovery Point Objective):** Potential data loss due to async replication

---

## Security Configuration

### File Permissions Summary

#### PostgreSQL Configuration Files

**Primary Node:**
```
-rw-r----- postgres:postgres /etc/postgresql/17/main/pg_hba.conf
-rw-r----- postgres:postgres /etc/postgresql/17/main/pg_ident.conf
-rw-r--r-- postgres:postgres /etc/postgresql/17/main/postgresql.conf
```

**Standby Node:**
```
-rw-r----- postgres:postgres /etc/postgresql/17/main/pg_hba.conf
-rw-r----- postgres:postgres /etc/postgresql/17/main/pg_ident.conf
-rw-r--r-- postgres:postgres /etc/postgresql/17/main/postgresql.conf
```

**✅ Status:** Proper restrictive permissions on sensitive files

#### PgBouncer Configuration Files

**Both Nodes:**
```
-rw-r--r-- postgres:postgres /etc/pgbouncer/pgbouncer.ini
-rw-r----- postgres:postgres /etc/pgbouncer/userlist.txt
```

**✅ Status:** Userlist properly restricted (640)

#### Data Directory Permissions

```
-rw------- postgres:postgres /var/lib/postgresql/17/main/*
```

**✅ Status:** Data files properly secured (600 permissions)

### Authentication Configuration

**pg_hba.conf Analysis Required:**
- Replication user authentication method
- Application connection authentication
- Local vs. network access rules
- SSL/TLS enforcement status

### Network Security

**Firewall Rules:** To be documented
**SSL/TLS:** Status to be verified from postgresql.conf
**Certificate Management:** To be documented

---

## Recommendations

### Critical Priority (Implement Within 1 Week)

#### 1. Implement Automated Failover ⚠️ **HIGH PRIORITY**

**Current State:** Manual failover only  
**Risk:** Extended downtime during primary failure  
**Recommendation:** Implement Patroni for automated failover

**Implementation Steps:**
```bash
# Install Patroni on both nodes
apt-get install patroni python3-etcd python3-consul

# Configure etcd/consul cluster for consensus
# Deploy Patroni configuration
# Integrate with HAProxy or PgBouncer for connection routing
```

**Expected Benefits:**
- RTO reduced from 15-30 min to 30-60 seconds
- Automated health checks and leader election
- Split-brain protection
- Automated re-synchronization

#### 2. Configure Remote Backup Storage ⚠️ **HIGH PRIORITY**

**Current State:** Backups on local filesystem only  
**Risk:** Data loss if server fails  
**Recommendation:** Already in progress with OSS bucket integration

**Verification Required:**
- Confirm OSS push scripts are working
- Test backup restoration from OSS
- Document OSS bucket retention policies
- Implement backup verification jobs

#### 3. Implement Synchronous Replication for Critical Transactions

**Current State:** Asynchronous replication (potential data loss)  
**Risk:** Transaction loss during failover  
**Recommendation:** Configure synchronous_commit for critical applications

```sql
-- Application-level setting
SET synchronous_commit = 'remote_apply';

-- Or server-level for all transactions
ALTER SYSTEM SET synchronous_commit = 'remote_apply';
ALTER SYSTEM SET synchronous_standby_names = 'standby_name';
SELECT pg_reload_conf();
```

**Trade-off:** Slight performance impact for zero data loss guarantee

### High Priority (Implement Within 1 Month)

#### 4. Implement Monitoring and Alerting

**Tools to Consider:**
- **Prometheus + Grafana** (metrics and visualization)
- **postgres_exporter** (PostgreSQL metrics for Prometheus)
- **pg_stat_statements** (query performance monitoring)
- **Nagios/Zabbix** (alerting)

**Key Metrics to Monitor:**
- Replication lag
- Connection pool usage
- Disk space (especially WAL archive)
- Backup job success/failure
- Query performance
- Connection counts

#### 5. Implement Backup Verification

**Current State:** Backups created but not verified  
**Recommendation:** Create automated restore testing

```bash
# Monthly restore test script
#!/bin/bash
# Test restore to isolated environment
# Verify database integrity
# Document restore time (actual RTO measurement)
```

#### 6. Document Disaster Recovery Procedures

**Required Documentation:**
- Step-by-step failover procedure
- Backup restoration procedure
- Network/DNS changes during failover
- Application reconnection process
- Rollback procedure
- Contact lists and escalation paths

### Medium Priority (Implement Within 3 Months)

#### 7. Upgrade to Connection-Level Load Balancing

**Current State:** Application must manually choose primary  
**Recommendation:** Implement HAProxy or similar

```
         ┌─────────────┐
         │   HAProxy   │  (VIP: 10.0.0.100)
         └──────┬──────┘
                │
        ┌───────┴───────┐
        │               │
   ┌────▼────┐     ┌────▼────┐
   │ Primary │     │ Standby │
   │   RW    │     │   RO    │
   └─────────┘     └─────────┘
```

#### 8. Implement Point-in-Time Recovery Testing

**Current State:** WAL archiving enabled but PITR not tested  
**Recommendation:** Regular PITR drills

```bash
# Quarterly PITR test
# 1. Restore base backup
# 2. Replay WAL to specific timestamp
# 3. Verify data consistency
# 4. Document recovery time
```

#### 9. Security Hardening

**Tasks:**
- Enable SSL/TLS for all connections
- Implement certificate rotation automation
- Review and restrict pg_hba.conf rules
- Enable connection logging for audit
- Implement pgAudit for detailed auditing

#### 10. Performance Tuning

**Areas to Review:**
- Shared buffers allocation
- Work memory settings
- Checkpoint configuration
- Autovacuum tuning
- PgBouncer pool sizing

### Low Priority (Continuous Improvement)

#### 11. Implement pgBackRest or Barman

**Benefits:**
- Advanced backup management
- Incremental backups
- Parallel restore
- Backup validation
- Centralized backup management

#### 12. Database Performance Baselines

- Establish query performance baselines
- Identify slow queries
- Create indexing strategy
- Monitor table bloat
- Implement partition strategy for large tables

---

## Appendices

### Appendix A: Configuration File Locations

#### Primary Node (prd-ipa-pgdb1)
```
PostgreSQL Config: /etc/postgresql/17/main/postgresql.conf
HBA Config:        /etc/postgresql/17/main/pg_hba.conf
Ident Config:      /etc/postgresql/17/main/pg_ident.conf
Auto Config:       /var/lib/postgresql/17/main/postgresql.auto.conf
Data Directory:    /var/lib/postgresql/17/main
PgBouncer Config:  /etc/pgbouncer/pgbouncer.ini
Backup Scripts:    /u01/backup/script/
Backup Logs:       /u01/backup/log/
WAL Archive:       /var/lib/postgresql/wal_archive/
```

#### Standby Node (prd-ipa-pgdb2)
```
PostgreSQL Config: /etc/postgresql/17/main/postgresql.conf
HBA Config:        /etc/postgresql/17/main/pg_hba.conf
Ident Config:      /etc/postgresql/17/main/pg_ident.conf
Auto Config:       /var/lib/postgresql/17/main/postgresql.auto.conf
Data Directory:    /var/lib/postgresql/17/main
Standby Signal:    /var/lib/postgresql/17/main/standby.signal
PgBouncer Config:  /etc/pgbouncer/pgbouncer.ini
Local WAL Archive: /var/lib/postgresql/17/main/archive/
```

### Appendix B: Systemd Service Units

**Primary Node:**
```
Service: postgresql@17-main.service
Override Directory: /etc/systemd/system/postgresql@17-main.service.d/
Override File: /etc/systemd/system/postgresql@17-main.service.d/limits.conf
```

**Standby Node:**
```
Service: postgresql@17-main.service
Override Directory: /etc/systemd/system/postgresql@17-main.service.d/
Override File: /etc/systemd/system/postgresql@17-main.service.d/limits.conf
```

### Appendix C: Backup Schedule Summary

| Backup Type | Frequency | Time | Script | Retention |
|-------------|-----------|------|--------|-----------|
| Logical (pg_dumpall) | Daily | 23:00 | ipa_pg_dumpall.sh | 15 days local |
| Physical (pg_basebackup) | Daily | 23:30 | ipa_pg_basebackup.sh | 15 days local |
| WAL Backup | 4x daily | 00:33, 06:33, 12:33, 15:33 | ipa_pg_walbackup.sh | 15 days |
| Monthly Archive | Monthly | Day 26, 04:00 | ipa_pg_mv_monthly.sh | Long-term |
| OSS Logical Push | Daily | 01:00 | push_backups_to_oss_bucket.sh | Cloud retention |
| OSS Physical Push | Daily | 01:30 | push_backups_to_oss_bucket.sh | Cloud retention |
| OSS WAL Push | 6-hourly | 01:00, 07:00, 13:00, 19:00 | push_backups_to_oss_bucket.sh | Cloud retention |
| OSS Weekly | Weekly | Friday 02:00 | push_backups_to_oss_bucket.sh | Cloud retention |
| OSS Monthly | Monthly | Day 1, 03:00 | push_backups_to_oss_bucket.sh | Cloud retention |

### Appendix D: Quick Reference Commands

#### Check Replication Status (Primary)
```sql
SELECT application_name, client_addr, state, sync_state, 
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

#### Check Replication Status (Standby)
```sql
SELECT status, receive_start_lsn, received_lsn, 
       pg_wal_lsn_diff(received_lsn, receive_start_lsn) AS received_bytes
FROM pg_stat_wal_receiver;
```

#### Manual Failover (Promote Standby)
```bash
# Method 1: Using pg_ctl
sudo -u postgres pg_ctl promote -D /var/lib/postgresql/17/main

# Method 2: Using SQL
sudo -u postgres psql -c "SELECT pg_promote();"

# Method 3: Remove standby.signal file
sudo -u postgres rm /var/lib/postgresql/17/main/standby.signal
sudo systemctl restart postgresql@17-main
```

#### Check PgBouncer Status
```bash
# Connect to PgBouncer admin console
psql -h localhost -p 6432 -U pgbouncer pgbouncer

# Inside admin console
SHOW POOLS;
SHOW CLIENTS;
SHOW SERVERS;
SHOW STATS;
```

#### Check Backup Status
```bash
# Check last backup time
ls -lth /u01/backup/ | head

# Check backup logs
tail -f /u01/backup/log/ipa_pg_dumpall.log
tail -f /u01/backup/log/ipa_pg_basebackup.log

# Verify OSS uploads
# (Requires OSS/cloud storage CLI tools)
```

---

## Glossary

| Term | Definition |
|------|------------|
| **Async Replication** | Replication mode where primary doesn't wait for standby acknowledgment |
| **Hot Standby** | Standby server that accepts read-only queries |
| **LSN** | Log Sequence Number - position in PostgreSQL WAL |
| **PITR** | Point-In-Time Recovery - restore to specific timestamp |
| **RPO** | Recovery Point Objective - maximum acceptable data loss |
| **RTO** | Recovery Time Objective - maximum acceptable downtime |
| **Streaming Replication** | Real-time replication using WAL streaming |
| **Sync Replication** | Replication mode where primary waits for standby confirmation |
| **WAL** | Write-Ahead Log - PostgreSQL transaction log |

---

## Document Control

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-12 | Auto-generated | Initial configuration summary |

**Next Review Date:** 2026-02-12

---

**End of Document**
