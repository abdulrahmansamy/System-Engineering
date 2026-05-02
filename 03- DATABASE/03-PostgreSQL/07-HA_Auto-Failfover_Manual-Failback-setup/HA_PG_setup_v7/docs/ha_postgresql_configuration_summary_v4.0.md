# HA PostgreSQL Configuration Summary

**Environment:** IPA Production HA PostgreSQL Cluster  
**PostgreSQL Version:** 17  
**Audit Date:** 2026-01-12  
**Document Version:** 4.0

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Cluster Topology](#cluster-topology)
3. [Network Architecture](#network-architecture)
4. [PostgreSQL Configuration](#postgresql-configuration)
5. [Replication Configuration](#replication-configuration)
6. [PgBouncer Connection Pooling](#pgbouncer-connection-pooling)
7. [Load Balancer Configuration](#load-balancer-configuration)
8. [Backup Strategy](#backup-strategy)
9. [High Availability Assessment](#high-availability-assessment)
10. [Security Configuration](#security-configuration)
11. [Recommendations](#recommendations)
12. [Appendices](#appendices)

---

## Executive Summary

### Cluster Overview

| Component | Status | Details |
|-----------|--------|---------|
| **Primary Node** | ✅ Active | prd-ipa-pgdb1 (192.168.24.21) |
| **Standby Node** | ✅ Active | prd-ipa-pgdb2 (192.168.24.22) |
| **PostgreSQL Version** | 17 | Latest stable release |
| **Replication Type** | Streaming Replication | Asynchronous |
| **Connection Pooling** | PgBouncer | Installed on both nodes |
| **Write Load Balancer** | ✅ Active | VIP: 192.168.24.15:6432 |
| **Read Load Balancer** | ✅ Active | VIP: 192.168.24.14:6432 |
| **Automated Failover** | ⚠️ Semi-Automated | gcp-lb-manager.sh health check |
| **Backup Strategy** | ✅ Configured | Cron-based with GCS upload |
| **HA Status** | ⚠️ Partial | Requires automated orchestration |

### Key Findings

✅ **Strengths:**
- Streaming replication properly configured and active
- PgBouncer connection pooling deployed on both nodes
- **GCP Internal Load Balancer for write/read traffic separation**
- **Health check script on port 8002 for automatic traffic routing**
- Comprehensive backup strategy with cloud storage (GCS)
- WAL archiving enabled with GCS upload
- Proper file permissions and ownership
- Separate DNS endpoints for read and write operations

⚠️ **Areas for Improvement:**
- **Load balancer failover is semi-automated** (requires manual standby promotion)
- No cluster orchestration tool (Patroni/repmgr not installed)
- Asynchronous replication (potential data loss during failover)
- Manual intervention required for standby promotion
- No monitoring/alerting system detected
- No automated PgBouncer reconfiguration during failover

---

## Cluster Topology

### Node Information

#### Primary Node (prd-ipa-pgdb1)
```
Hostname: prd-ipa-pgdb1 / primary-pgdb1
Internal IP: 192.168.24.21
Role: Primary (Read-Write)
OS: Linux 6.14.0-1020-gcp x86_64 GNU/Linux
Machine Type: n2-highmem-32
vCPUs: 32
Memory: 256 GB
Zone: me-central2-a
Data Directory: /var/lib/postgresql/17/main
Data Disk: 10 TB SSD (pd-ssd)
PgBouncer Port: 6432
PostgreSQL Port: 5432
Health Check Port: 8002 (HTTP)
Health Response: "primary"
Load Balancer Backend: Active (ipa-prd-ig-pg-primary-group-01)
```

#### Standby Node (prd-ipa-pgdb2)
```
Hostname: prd-ipa-pgdb2 / standby-pgdb2
Internal IP: 192.168.24.22
Role: Standby (Read-Only Hot Standby)
OS: Linux 6.14.0-1020-gcp x86_64 GNU/Linux
Machine Type: n2-highmem-32
vCPUs: 32
Memory: 256 GB
Zone: me-central2-b
Data Directory: /var/lib/postgresql/17/main
Data Disk: 10 TB SSD (pd-ssd)
Standby Indicator: /var/lib/postgresql/17/main/standby.signal (present, 0 bytes)
PgBouncer Port: 6432
PostgreSQL Port: 5432
Health Check Port: 8002 (HTTP)
Health Response: "standby"
Load Balancer Backend: Active (ipa-prd-ig-pg-standby-group-01)
```

### Network Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Application Layer                            │
│          (Connects to GCP Internal Load Balancer VIPs)          │
└─────────────────────┬──────────────────┬────────────────────────┘
                      │                  │
        Write Traffic │                  │ Read Traffic
        Port 6432     │                  │ Port 6432
                      │                  │
                      ▼                  ▼
        ┌──────────────────────┐  ┌──────────────────────┐
        │ Write Load Balancer  │  │ Read Load Balancer   │
        │ VIP: 192.168.24.15   │  │ VIP: 192.168.24.14   │
        │ DNS: pg-write...     │  │ DNS: pg-read...      │
        └──────────┬───────────┘  └──────────┬───────────┘
                   │                         │
                   │ Health Check: 8002      │ Health Check: 8002
                   │ Backend: Primary IG     │ Backend: Standby IG
                   │                         │
                   ▼                         ▼
        ┌──────────────────────┐  ┌──────────────────────┐
        │  PgBouncer (Primary) │  │ PgBouncer (Standby)  │
        │  192.168.24.21:6432  │  │  192.168.24.22:6432  │
        │  Max Clients: 20,000 │  │  Max Clients: 2,000  │
        │  Pool Size: 1,500    │  │  Pool Size: 1,500    │
        └──────────┬───────────┘  └──────────┬───────────┘
                   │ Port 5432              │ Port 5432
                   │ →192.168.24.21         │ →192.168.24.22
                   ▼                         ▼
        ┌──────────────────────┐  ┌──────────────────────┐
        │ PostgreSQL 17        │  │ PostgreSQL 17        │
        │ PRIMARY              │──│→STANDBY              │
        │ (Read-Write)         │  │ (Read-Only)          │
        │ 192.168.24.21:5432   │  │ 192.168.24.22:5432   │
        │                      │  │                      │
        │ Health: 8002 ✓       │  │ Health: 8002 ✓       │
        │ Status: "primary"    │  │ Status: "standby"    │
        └──────────┬───────────┘  └──────────────────────┘
                   │                Zone: me-central2-b
                   │                
                   │ Streaming Replication (Async)
                   └────────────────────────────────────────▶
                   
                   │
                   │ Backups + WAL Archive
                   ▼
        ┌──────────────────────────────────────────┐
        │  Local Backup Storage                     │
        │  /var/lib/postgresql/pg_care/backup/     │
        │  - Logical (pg_dumpall): Daily 23:00     │
        │  - Physical (pg_basebackup): Daily 23:30 │
        │  - WAL: 4x daily (00:33,06:33,12:33,15:33)│
        └──────────┬───────────────────────────────┘
                   │
                   │ gsutil upload (scheduled via cron)
                   ▼
        ┌───────────────────────────────────────────────────────┐
        │  GCS Bucket (Tiered Storage)                          │
        │  ipa-nominations-prd-tiered-backup-storage-bucket-01  │
        │                                                        │
        │  pgsql/                                               │
        │   ├── daily/    (7-day retention)                     │
        │   ├── weekly/   (30-day retention)                    │
        │   └── monthly/  (365-day retention)                   │
        └───────────────────────────────────────────────────────┘
```

---

## Network Architecture

### Subnet Configuration

| Subnet Type | Name | CIDR | Purpose |
|-------------|------|------|---------|
| **Application** | prod-application-subnet | 10.164.0.0/20 | Application workloads |
| **Database** | prod-database-subnet | 192.168.24.0/24 | Database instances |

### IP Address Allocation

| IP Address | Hostname/Purpose | Assignment | Resource Name |
|------------|------------------|------------|---------------|
| 192.168.24.21 | prd-ipa-pgdb1 (Primary) | Static (Reserved) | ipa-prd-ip-pg-primary-01 |
| 192.168.24.22 | prd-ipa-pgdb2 (Standby) | Static (Reserved) | ipa-prd-ip-pg-standby-01 |
| 192.168.24.15 | Write Load Balancer VIP | Static (Reserved) | ipa-prd-ip-pgbouncer-write-01 |
| 192.168.24.14 | Read Load Balancer VIP | Static (Reserved) | ipa-prd-ip-pgbouncer-read-02 |

### DNS Configuration

**Private DNS Zone:** `db.prd.internal.ipa.edu.sa`

| DNS Record | Type | Value | TTL | Purpose |
|------------|------|-------|-----|---------|
| pg-write.db.prd.internal.ipa.edu.sa | A | 192.168.24.15 | 300s | Write endpoint |
| pg-read.db.prd.internal.ipa.edu.sa | A | 192.168.24.14 | 300s | Read endpoint |

---

## PostgreSQL Configuration

### Version and Installation

| Parameter | Value |
|-----------|-------|
| **PostgreSQL Version** | 17 |
| **Installation Method** | APT (PostgreSQL official repository) |
| **Data Directory** | /var/lib/postgresql/17/main |
| **Configuration Directory** | /etc/postgresql/17/main |
| **Binary Directory** | /usr/lib/postgresql/17/bin |
| **Port** | 5432 |
| **Unix Socket Directory** | /var/run/postgresql |

### Configuration Files

**Primary Node:**
- Main Config: `/etc/postgresql/17/main/postgresql.conf` (30,630 bytes, modified 2025-12-03)
- HBA Config: `/etc/postgresql/17/main/pg_hba.conf` (6,824 bytes, modified 2025-12-10)
- Ident Config: `/etc/postgresql/17/main/pg_ident.conf` (2,640 bytes)
- Auto Config: `/var/lib/postgresql/17/main/postgresql.auto.conf` (470 bytes)

**Standby Node:**
- Main Config: `/etc/postgresql/17/main/postgresql.conf` (30,630 bytes, modified 2025-12-03)
- HBA Config: `/etc/postgresql/17/main/pg_hba.conf` (6,824 bytes, modified 2025-12-10)
- Ident Config: `/etc/postgresql/17/main/pg_ident.conf` (2,640 bytes)
- Auto Config: `/var/lib/postgresql/17/main/postgresql.auto.conf` (470 bytes)

### Key Configuration Parameters

#### Streaming Replication Settings

```ini
# Write-Ahead Log
wal_level = replica                     # Enable replication
fsync = on
synchronous_commit = off                # Asynchronous replication
wal_compression = on
wal_log_hints = on
wal_buffers = 16MB

# Replication
max_wal_senders = 10                    # Max concurrent replication connections
max_replication_slots = 10              # Max replication slots
hot_standby = on                        # Allow read queries on standby
hot_standby_feedback = on               # Reduce query cancellations

# Archiving (Primary)
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f'
archive_timeout = 300                   # Force WAL switch every 5 minutes

# Synchronous Replication (Disabled)
synchronous_standby_names = ''          # Empty = asynchronous
```

#### Performance Tuning

```ini
# Memory
shared_buffers = 64GB                   # 25% of RAM (256GB system)
effective_cache_size = 192GB            # 75% of RAM
work_mem = 128MB                        # Per-operation memory
maintenance_work_mem = 2GB              # For VACUUM, CREATE INDEX
max_connections = 2000                  # Matches PgBouncer pool

# Autovacuum
autovacuum = on
autovacuum_max_workers = 6
autovacuum_naptime = 10s

# Checkpoints
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
max_wal_size = 32GB
min_wal_size = 8GB

# Planner
random_page_cost = 1.1                  # SSD storage
effective_io_concurrency = 200          # SSD parallelism
```

---

## Replication Configuration

### Standby Configuration

**Standby Signal File:** `/var/lib/postgresql/17/main/standby.signal`
- Size: 0 bytes (marker file)
- Modified: 2025-11-21 18:23:22

**Connection String (from metadata):**
```
primary_conninfo = 'host=192.168.24.21 port=5432 user=replicator application_name=standby'
```

### WAL Archiving

**Archive Location (Standby):** `/var/lib/postgresql/17/main/archive/`

**Files Found:**
- 000000010000000000000001
- 000000010000000000000002
- 000000010000000000000003

**⚠️ Note:** WAL archives on primary stored at `/var/lib/postgresql/wal_archive/` with local retention of 15 days.

### Authentication Configuration (pg_hba.conf)

```conf
# TYPE  DATABASE    USER        ADDRESS           METHOD

# Local connections
local   all         postgres                      peer
local   all         all                           peer

# Replication
host    replication replicator  192.168.24.0/24   scram-sha-256
host    replication replicator  127.0.0.1/32      scram-sha-256

# Database connections
host    all         all         192.168.24.0/24   scram-sha-256
host    all         all         10.164.0.0/20     scram-sha-256
host    all         all         127.0.0.1/32      scram-sha-256
```

---

## PgBouncer Connection Pooling

### Primary Node Configuration

**Config File:** `/etc/pgbouncer/pgbouncer.ini` (1,270 bytes, modified 2025-12-11 15:58:36)

```ini
[databases]
postgres = host=192.168.24.21 port=5432 dbname=postgres
template1 = host=192.168.24.21 port=5432 dbname=template1
* = host=192.168.24.21 port=5432

[pgbouncer]
listen_addr = 192.168.24.21,192.168.24.15,192.168.24.14
listen_port = 6432

auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

pool_mode = transaction
max_client_conn = 20000                 # 10x higher than standby
default_pool_size = 1500
reserve_pool_size = 5
max_db_connections = 1500

server_connect_timeout = 15
server_login_retry = 3
query_timeout = 3600                    # 1 hour
query_wait_timeout = 120                # 2 minutes
client_idle_timeout = 3600              # 1 hour
server_idle_timeout = 600               # 10 minutes
server_lifetime = 3600                  # 1 hour

logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid

log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

admin_users = pgbouncer_admin,postgres
stats_users = pgbouncer_admin,postgres

ignore_startup_parameters = extra_float_digits,search_path
server_reset_query = DISCARD ALL
unix_socket_dir = /var/run/postgresql
```

### Standby Node Configuration

**Config File:** `/etc/pgbouncer/pgbouncer.ini` (1,270 bytes, modified 2025-12-11 15:50:02)

**Key Differences from Primary:**
```ini
[databases]
* = host=192.168.24.22 port=5432        # Points to local standby

[pgbouncer]
listen_addr = 192.168.24.22,192.168.24.15,192.168.24.14
max_client_conn = 2000                  # 10% of primary (read workload)
```

### Connection Pooling Analysis

| Setting | Primary | Standby | Purpose |
|---------|---------|---------|---------|
| `max_client_conn` | 20,000 | 2,000 | Max client connections to PgBouncer |
| `default_pool_size` | 1,500 | 1,500 | Connections per database pool |
| `max_db_connections` | 1,500 | 1,500 | Max connections to PostgreSQL |
| `pool_mode` | transaction | transaction | Transaction-level pooling |

**Listen Addresses:** Both nodes listen on:
- Their own IP (192.168.24.21 / 192.168.24.22)
- Write VIP (192.168.24.15)
- Read VIP (192.168.24.14)

---

## Load Balancer Configuration

### Write Load Balancer

**Purpose:** Route all write operations to the active primary node.

| Component | Value |
|-----------|-------|
| **Name** | ipa-prd-bs-pgbouncer-write-01 |
| **Type** | GCP Internal TCP Load Balancer |
| **VIP** | 192.168.24.15:6432 |
| **DNS** | pg-write.db.prd.internal.ipa.edu.sa |
| **Protocol** | TCP |
| **Backend Service** | ipa-prd-bs-pgbouncer-write-01 |
| **Instance Group** | ipa-prd-ig-pg-primary-group-01 |
| **Health Check** | ipa-prd-hc-pgbouncer-health-01 |
| **Session Affinity** | CLIENT_IP |
| **Connection Draining** | 300 seconds |

### Read Load Balancer

**Purpose:** Route all read operations to the standby node.

| Component | Value |
|-----------|-------|
| **Name** | ipa-prd-bs-pgbouncer-read-01 |
| **Type** | GCP Internal TCP Load Balancer |
| **VIP** | 192.168.24.14:6432 |
| **DNS** | pg-read.db.prd.internal.ipa.edu.sa |
| **Protocol** | TCP |
| **Backend Service** | ipa-prd-bs-pgbouncer-read-01 |
| **Instance Group** | ipa-prd-ig-pg-standby-group-01 |
| **Health Check** | ipa-prd-hc-pgbouncer-health-01 |
| **Session Affinity** | NONE |
| **Connection Draining** | 300 seconds |

### Health Check Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| **Name** | ipa-prd-hc-pgbouncer-health-01 | Shared health check |
| **Protocol** | HTTP | Health check protocol |
| **Port** | 8002 | Health check port |
| **Request Path** | / | HTTP endpoint |
| **Check Interval** | 5 seconds | How often to check |
| **Timeout** | 5 seconds | Max time to wait |
| **Healthy Threshold** | 2 successes | Marks backend HEALTHY |
| **Unhealthy Threshold** | 2 failures | Marks backend UNHEALTHY |

**Health Check Logic:**
```python
# Pseudo-code for health check endpoint
# Implemented by gcp-lb-manager.sh on port 8002

def health_check():
    if not pg_isready():
        return HTTP 503
    
    if not pgbouncer_running():
        return HTTP 503
    
    role = query("SELECT pg_is_in_recovery()")
    
    if role == False:  # Primary
        return HTTP 200 "primary"
    else:  # Standby
        return HTTP 200 "standby"
```

### Failover Process with Load Balancer

#### Current Process (Semi-Automated)

1. **Primary Failure Detected**
   - GCP LB health check fails on primary (port 8002 unresponsive)
   - After 2 failed checks (10 seconds), primary marked UNHEALTHY
   - **Write traffic stops** (no healthy backend)

2. **Manual Standby Promotion**
   ```bash
   # DBA connects to standby
   ssh prd-ipa-pgdb2
   
   # Promote standby
   sudo -u postgres pg_ctl promote -D /var/lib/postgresql/17/main
   # OR
   sudo -u postgres psql -c "SELECT pg_promote();"
   ```

3. **Automatic Traffic Restoration**
   - `gcp-lb-manager.sh` detects role change on standby
   - Opens port 8002 on newly promoted primary
   - GCP health check succeeds after 2 checks (10 seconds)
   - **LB automatically routes write traffic to new primary**

**Total Failover Time:** ~30-60 seconds (manual promotion + health check)

---

## Backup Strategy

### Backup Architecture

**Primary Node Only** - All backups configured via `postgres` user crontab.

### Local Backup Schedule

| Job Name | Schedule | Script | Location |
|----------|----------|--------|----------|
| Logical Backup | 23:00 daily | ipa_pg_dumpall.sh | /var/lib/postgresql/pg_care/backup/AllDBData/ |
| Physical Backup | 23:30 daily | ipa_pg_basebackup.sh | /var/lib/postgresql/pg_care/backup/phybackup/ |
| WAL Backup | 4x daily (00:33, 06:33, 12:33, 15:33) | ipa_pg_walbackup.sh | /var/lib/postgresql/pg_care/backup/walbackup/ |
| Monthly Archive | 04:00 (Day 26) | ipa_pg_mv_monthly.sh | Monthly retention |
| WAL Cleanup | 11:40 daily | ipa_pg_archivecleanup_*.sh | 15-day retention |

### Cloud Backup Upload Schedule

**Script:** `/u01/backup/script/push_backups_to_oss_bucket.sh`

**GCS Bucket:** `ipa-nominations-prd-tiered-backup-storage-bucket-01`

| Job Type | Schedule | Target Folder | Retention |
|----------|----------|---------------|-----------|
| Logical (daily) | 01:00 daily | pgsql/daily/logical/ | 7 days (auto-delete) |
| Physical (daily) | 01:30 daily | pgsql/daily/physical/ | 7 days (auto-delete) |
| WAL (6-hourly) | 01:00, 07:00, 13:00, 19:00 | pgsql/daily/wal/ | 7 days (auto-delete) |
| Weekly | 02:00 Friday | pgsql/weekly/ | 30 days (auto-delete) |
| Monthly | 03:00 (Day 1) | pgsql/monthly/ | 365 days (auto-delete) |

### Cron Configuration (Primary Node)

```cron
# Local backups
00 23 * * * /u01/backup/script/ipa_pg_dumpall.sh 2>> /u01/backup/log/ipa_pg_dumpall.log
30 23 * * * /u01/backup/script/ipa_pg_basebackup.sh 2>> /u01/backup/log/ipa_pg_basebackup.log
33 06,12,15,00 * * * /u01/backup/script/ipa_pg_walbackup.sh 2>> /u01/backup/log/ipa_pg_walbackup.log
00 04 26 * * /u01/backup/script/ipa_pg_mv_monthly.sh 2>> /u01/backup/log/ipa_pg_mv_monthly.log

# Cleanup
40 11 16-24 * * /u01/backup/script/ipa_pg_archivecleanup_ret15daysdate1to9.sh 2>> /u01/backup/log/ipa_pg_archivecleanup_ret15daysdate1to9.log
40 11 25-31,1-15 * * /u01/backup/script/ipa_pg_archivecleanup_ret15daysdate10to31.sh 2>> /u01/backup/log/ipa_pg_archivecleanup_ret15daysdate10to31.log

# Cloud uploads
0 1 * * * /u01/backup/script/push_backups_to_oss_bucket.sh logical >> /u01/backup/log/push_logical_backups.log 2>&1
30 1 * * * /u01/backup/script/push_backups_to_oss_bucket.sh physical >> /u01/backup/log/push_physical_backups.log 2>&1
0 1,7,13,19 * * * /u01/backup/script/push_backups_to_oss_bucket.sh wal >> /u01/backup/log/push_wal_backups.log 2>&1
0 2 * * 5 /u01/backup/script/push_backups_to_oss_bucket.sh weekly >> /u01/backup/log/push_weekly_backups.log 2>&1
0 3 1 * * /u01/backup/script/push_backups_to_oss_bucket.sh monthly >> /u01/backup/log/push_monthly_backups.log 2>&1
```

### GCS Bucket Structure

```
gs://ipa-nominations-prd-tiered-backup-storage-bucket-01/
└── pgsql/
    ├── daily/              # 7-day retention
    │   ├── logical/YYYYMMDD-HHMMSS/
    │   ├── physical/YYYYMMDD-HHMMSS/
    │   └── wal/YYYYMMDD-HHMMSS/
    │
    ├── weekly/             # 30-day retention
    │   ├── logical/YYYYMMDD-HHMMSS/
    │   └── physical/YYYYMMDD-HHMMSS/
    │
    └── monthly/            # 365-day retention
        ├── logical/YYYYMMDD-HHMMSS/
        └── physical/YYYYMMDD-HHMMSS/
```

---

## High Availability Assessment

### Current HA Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| **Streaming Replication** | ✅ Configured | Asynchronous mode |
| **Hot Standby** | ✅ Active | Read queries on standby |
| **Network Failover** | ✅ GCP LB | Health-based routing |
| **Traffic Separation** | ✅ Active | Separate write/read VIPs |
| **Automatic Failover** | ⚠️ Semi-Automated | Requires manual promotion |
| **Connection Pooling** | ✅ Configured | PgBouncer on both nodes |
| **Load Balancing** | ✅ GCP Internal LB | VIP-based routing |
| **Split-Brain Protection** | ⚠️ Partial | Network-level only |
| **Automated Recovery** | ❌ None | Manual re-sync required |
| **Health Monitoring** | ✅ Active | Port 8002 HTTP health check |

### HA Tools Assessment

#### GCP Load Balancer + Health Check Script
- **Status:** ✅ Active and Functional
- **Benefits:**
  - Single write endpoint (192.168.24.15)
  - Single read endpoint (192.168.24.14)
  - Automatic traffic routing based on health
  - Fast failure detection (10 seconds)
- **Limitations:**
  - Does not perform automatic failover
  - Requires manual standby promotion
  - No orchestration capabilities

#### Patroni
- **Status:** ❌ Not Installed
- **Impact:** No automated failover decision-making

#### repmgr
- **Status:** ❌ Not Installed
- **Impact:** No automated failover orchestration

---

## Security Configuration

### File Permissions

**PostgreSQL Configuration Files:**
```
-rw-r----- postgres:postgres /etc/postgresql/17/main/pg_hba.conf
-rw-r----- postgres:postgres /etc/postgresql/17/main/pg_ident.conf
-rw-r--r-- postgres:postgres /etc/postgresql/17/main/postgresql.conf
-rw------- postgres:postgres /var/lib/postgresql/17/main/postgresql.auto.conf
```

**PgBouncer Configuration:**
```
-rw-r--r-- postgres:postgres /etc/pgbouncer/pgbouncer.ini
-rw-r----- postgres:postgres /etc/pgbouncer/userlist.txt
```

**Data Files:**
```
-rw------- postgres:postgres /var/lib/postgresql/17/main/*
```

### Database Users

| Username | Purpose | Authentication |
|----------|---------|----------------|
| `postgres` | Superuser | scram-sha-256 |
| `replicator` | Replication | scram-sha-256 |
| `pg_monitor_user` | Monitoring | scram-sha-256 |
| `appuser` | Generic application | scram-sha-256 |
| `wso2user` | WSO2 Identity Server | scram-sha-256 |
| `tmsuser` | TMS application | scram-sha-256 |
| `examuser` | Exam system | scram-sha-256 |
| `helpdeskuser` | Helpdesk system | scram-sha-256 |
| `konguser` | Kong API Gateway | scram-sha-256 |

**Password Management:** All passwords stored in GCP Secret Manager.

---

## Recommendations

### Critical Priority (Implement Within 1 Week)

#### 1. Implement Automated Failover with Patroni ⚠️ **HIGH PRIORITY**

**Current State:** Manual standby promotion required  
**Risk:** Extended downtime, human error  
**Recommendation:** Deploy Patroni for automated failover

**Benefits:**
- RTO reduced from 30-90s to 10-30s
- Automated consensus-based failover
- Split-brain protection via DCS
- Automatic standby rebuild

#### 2. Automate PgBouncer Reconfiguration

**Current State:** PgBouncer configs are static  
**Risk:** Confusion after failover  
**Recommendation:** Integrate PgBouncer reconfiguration into failover script

```bash
# Add to gcp-lb-manager.sh --promote function
promote_node() {
    sudo -u postgres pg_ctl promote -D /var/lib/postgresql/17/main
    
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    sudo sed -i "s/host=[0-9.]\+/host=$LOCAL_IP/g" /etc/pgbouncer/pgbouncer.ini
    sudo sed -i 's/max_client_conn = [0-9]\+/max_client_conn = 20000/' /etc/pgbouncer/pgbouncer.ini
    
    sudo systemctl reload pgbouncer
}
```

#### 3. Implement Monitoring and Alerting 🔥 **CRITICAL**

**Monitoring Stack:**
- Prometheus + Grafana
- postgres_exporter on both nodes
- GCP Cloud Monitoring integration

**Key Metrics:**
- Replication lag
- Connection pool usage
- Backup job success/failure
- GCP LB health check status
- Disk space (WAL archive)

**Alerting Rules:**
- Primary down for > 30 seconds
- Replication lag > 60 seconds
- Backup failure
- No healthy backends in LB

### High Priority (Implement Within 1 Month)

#### 4. Implement Synchronous Replication for Critical Data

```sql
ALTER SYSTEM SET synchronous_commit = 'remote_apply';
ALTER SYSTEM SET synchronous_standby_names = 'standby';
SELECT pg_reload_conf();
```

**Trade-off:** Slight performance impact for zero data loss guarantee.

#### 5. Set Up GCP Cloud Monitoring Integration

- Install GCP Monitoring Agent
- Configure custom metrics
- Set up alerting policies

#### 6. Automate Old Primary Recovery

Create script to rebuild failed primary as new standby:
```bash
#!/bin/bash
# rebuild-standby.sh
OLD_PRIMARY=$1
NEW_PRIMARY=$2

ssh $OLD_PRIMARY "sudo systemctl stop postgresql@17-main"
ssh $OLD_PRIMARY "sudo -u postgres rm -rf /var/lib/postgresql/17/main/*"
ssh $OLD_PRIMARY "sudo -u postgres pg_basebackup -h $NEW_PRIMARY -D /var/lib/postgresql/17/main -U replicator -P -R"
ssh $OLD_PRIMARY "sudo systemctl start postgresql@17-main"
```

---

## Appendices

### Appendix A: Connection Examples

**Write Connection (via DNS):**
```
postgresql://username:password@pg-write.db.prd.internal.ipa.edu.sa:6432/database_name
```

**Read Connection (via DNS):**
```
postgresql://username:password@pg-read.db.prd.internal.ipa.edu.sa:6432/database_name
```

**Write Connection (via IP):**
```
postgresql://username:password@192.168.24.15:6432/database_name
```

**Read Connection (via IP):**
```
postgresql://username:password@192.168.24.14:6432/database_name
```

### Appendix B: Quick Reference Commands

#### Check Replication Status (Primary)
```sql
SELECT application_name, client_addr, state, sync_state, 
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

#### Check Replication Status (Standby)
```sql
SELECT pg_is_in_recovery();
SELECT status, received_lsn, latest_end_lsn
FROM pg_stat_wal_receiver;
```

#### Manual Failover
```bash
# Promote standby to primary
sudo -u postgres pg_ctl promote -D /var/lib/postgresql/17/main

# OR
sudo -u postgres psql -c "SELECT pg_promote();"
```

#### PgBouncer Administration
```bash
# Connect to admin console
psql -h 192.168.24.15 -p 6432 -U pgbouncer pgbouncer

# Inside console
SHOW POOLS;
SHOW CLIENTS;
SHOW SERVERS;
RELOAD;
```

#### GCP Load Balancer Status
```bash
# Check backend health
gcloud compute backend-services get-health \
  ipa-prd-bs-pgbouncer-write-01 --region=me-central2

# View health check logs
gcloud logging read "resource.type=gce_health_check" --limit 50
```

---

## Document Control

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-12 | Auto-generated | Initial configuration summary |
| 2.0 | 2026-01-12 | Auto-generated | Added GCP LB integration |
| 3.0 | 2026-01-12 | Auto-generated | Added PgBouncer configuration |
| 4.0 | 2026-01-12 | Auto-generated | Complete as-built with all components |

**Next Review Date:** 2026-02-12

---

**End of Document**
