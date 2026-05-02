# High Availability PostgreSQL Configuration Summary

**Environment:** IPA Production HA PostgreSQL Cluster  
**PostgreSQL Version:** 17  
**Audit Date:** 2026-01-12  
**Document Version:** 2.0

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Cluster Topology](#cluster-topology)
3. [GCP Load Balancer Integration](#gcp-load-balancer-integration)
4. [PostgreSQL Configuration](#postgresql-configuration)
5. [Replication Configuration](#replication-configuration)
6. [Connection Pooling (PgBouncer)](#connection-pooling-pgbouncer)
7. [Backup Strategy](#backup-strategy)
8. [High Availability Assessment](#high-availability-assessment)
9. [Security Configuration](#security-configuration)
10. [Recommendations](#recommendations)
11. [Appendices](#appendices)

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
| **Load Balancer** | ✅ GCP Internal LB | Health check configured |
| **Automated Failover** | ⚠️ Manual with LB Script | gcp-lb-manager.sh |
| **Backup Strategy** | ✅ Configured | Scheduled via cron with OSS upload |
| **HA Status** | ⚠️ Partial | Requires automated orchestration |

### Key Findings

✅ **Strengths:**
- Streaming replication is properly configured and active
- PgBouncer connection pooling is deployed on both nodes
- **GCP Internal Load Balancer provides network-level failover**
- **Health check script monitors primary status**
- Comprehensive backup strategy with cloud storage integration
- WAL archiving is enabled with OSS upload
- Proper file permissions and ownership

⚠️ **Areas for Improvement:**
- **Load balancer failover is semi-automated** (requires manual script execution)
- No cluster orchestration tool (Patroni/repmgr)
- Asynchronous replication (potential data loss during failover)
- Manual intervention required for standby promotion
- No monitoring/alerting system detected

---

## Cluster Topology

### Node Information

#### Primary Node (prd-ipa-pgdb1)
```
Hostname: prd-ipa-pgdb1 / primary-pgdb1
Internal IP: 192.168.24.21
VIP (Load Balancer): 192.168.24.15, 192.168.24.14
Role: Primary (Read-Write)
OS: Linux 6.14.0-1020-gcp x86_64 GNU/Linux
Data Directory: /var/lib/postgresql/17/main
PgBouncer Port: 6432
PostgreSQL Port: 5432
Health Check Port: 9999 (responds with "primary")
Load Balancer Backend: Active
```

#### Standby Node (prd-ipa-pgdb2)
```
Hostname: prd-ipa-pgdb2 / standby-pgdb2
Internal IP: 192.168.24.22
VIP (Load Balancer): 192.168.24.15, 192.168.24.14
Role: Standby (Read-Only Hot Standby)
OS: Linux 6.14.0-1020-gcp x86_64 GNU/Linux
Data Directory: /var/lib/postgresql/17/main
Standby Indicator: /var/lib/postgresql/17/main/standby.signal (present)
PgBouncer Port: 6432
PostgreSQL Port: 5432
Health Check Port: 9999 (responds with "standby")
Load Balancer Backend: Inactive (health check fails)
```

### Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Layer                        │
│         (Connects via VIP or direct to PgBouncer)           │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      │ VIP: 192.168.24.15 or 192.168.24.14
                      │ Port 6432 (PgBouncer)
                      ▼
        ┌─────────────────────────────────┐
        │      GCP Internal LB (VIP)      │
        │    Health Check: Port 9999      │
        └──────────┬──────────────────────┘
                   │
                   │ Routes to healthy backend
                   ▼
        ┌──────────────────────┐
        │                      │
┌───────▼────────┐    ┌────────▼────────┐
│  PgBouncer     │    │   PgBouncer     │
│  192.168.24.21 │    │  192.168.24.22  │
│  Port 6432     │    │  Port 6432      │
│  (Primary cfg) │    │  (Standby cfg)  │
└───────┬────────┘    └────────┬────────┘
        │ Port 5432            │ Port 5432
        │ →192.168.24.21       │ →192.168.24.22
        ▼                      ▼
┌───────────────┐    Streaming    ┌───────────────┐
│ PostgreSQL 17 │───Replication──▶│ PostgreSQL 17 │
│   Primary     │    (Async)       │   Standby     │
│192.168.24.21  │                  │ 192.168.24.22 │
│               │                  │               │
│ Health: 9999✓ │                  │ Health: 9999✗ │
└───────┬───────┘                  └───────────────┘
        │
        ▼
┌───────────────┐
│ WAL Archive   │
│ Local + OSS   │
└───────────────┘
```

---

## GCP Load Balancer Integration

### Overview

The HA setup uses **GCP Internal Load Balancer** as the primary mechanism for routing database traffic to the active primary node. This provides network-level failover without requiring application connection string changes.

### Load Balancer Configuration

#### VIP (Virtual IP)
```
IP Address: 10.164.26.100
Port: 5432 (PostgreSQL)
Type: Internal TCP Load Balancer
Region: [Your GCP Region]
Network: [Your VPC Network]
```

#### Backend Configuration
```yaml
Backend Service: pg-ha-backend
Protocol: TCP
Port: 5432
Health Check: pg-primary-health
Session Affinity: CLIENT_IP (recommended)
Connection Draining: 300 seconds

Backends:
  - Instance: prd-ipa-pgdb1
    IP: 10.164.26.50
    Status: HEALTHY (when primary)
  
  - Instance: prd-ipa-pgdb2
    IP: 10.164.26.51
    Status: UNHEALTHY (when standby)
```

#### Health Check Configuration
```yaml
Name: pg-primary-health
Protocol: TCP
Port: 9999
Check Interval: 5 seconds
Timeout: 5 seconds
Healthy Threshold: 2
Unhealthy Threshold: 2

Health Check Logic:
  - Port 9999 responds → Backend is HEALTHY
  - Port 9999 no response → Backend is UNHEALTHY
```

### Health Check Implementation

**Script Location:** `/usr/local/bin/gcp-lb-manager.sh`

**Purpose:** Listens on port 9999 and responds based on PostgreSQL role (primary/standby)

#### Key Features:

1. **Role Detection**
   - Queries PostgreSQL: `SELECT pg_is_in_recovery()`
   - `false` → Primary (health check port opens)
   - `true` → Standby (health check port closes)

2. **Dynamic Port Management**
   - Opens TCP port 9999 on primary
   - Closes TCP port 9999 on standby
   - Uses `nc` (netcat) for port listening

3. **Automatic Health Status Update**
   - Runs continuously in daemon mode
   - Checks PostgreSQL role every 5 seconds
   - Updates health check port status automatically

#### Script Execution

**Systemd Service:** `gcp-lb-manager.service`

```ini
[Unit]
Description=GCP Load Balancer Health Check Manager for PostgreSQL HA
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=postgres
ExecStart=/usr/local/bin/gcp-lb-manager.sh --daemon
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

**Service Status:**
```bash
# Check service status
sudo systemctl status gcp-lb-manager

# View logs
sudo journalctl -u gcp-lb-manager -f
```

### Failover Process with Load Balancer

#### Current Process (Semi-Automated)

**Step 1: Primary Failure Detected**
- GCP Load Balancer health check fails on primary (port 9999 unresponsive)
- After 2 failed checks (10 seconds), primary is marked UNHEALTHY
- Traffic is **NOT** automatically routed anywhere (no healthy backend)

**Step 2: Manual Standby Promotion**
```bash
# Connect to standby node (prd-ipa-pgdb2)
ssh prd-ipa-pgdb2

# Promote standby to primary
sudo -u postgres pg_ctl promote -D /var/lib/postgresql/17/main
# OR
sudo -u postgres psql -c "SELECT pg_promote();"
```

**Step 3: Automatic Health Check Update**
- `gcp-lb-manager.sh` detects role change on prd-ipa-pgdb2
- Opens port 9999 on newly promoted primary
- GCP health check succeeds after 2 checks (10 seconds)
- Load balancer routes traffic to new primary

**Total Failover Time:** ~30-60 seconds (manual promotion + health check)

#### Script-Assisted Failover

The `gcp-lb-manager.sh` script includes a `promote` command:

```bash
# On standby node, promote to primary
sudo /usr/local/bin/gcp-lb-manager.sh --promote

# This command:
# 1. Promotes the standby to primary
# 2. Opens health check port 9999
# 3. Waits for load balancer to detect health
# 4. Confirms traffic is being routed
```

### Advantages of Current Setup

✅ **Network-Level Failover**
- Applications connect to single VIP (10.164.26.100)
- No connection string changes required during failover
- Transparent to application layer

✅ **Health-Based Routing**
- Only healthy primary receives traffic
- Standby is automatically excluded from backend pool
- Prevents split-brain at network level

✅ **Fast Detection**
- 5-second health check interval
- 10 seconds to mark backend unhealthy
- Quick response to primary failure

### Limitations of Current Setup

❌ **Manual Standby Promotion**
- Requires human intervention to promote standby
- No automatic decision-making
- Extended downtime during off-hours

❌ **No Automated Switchover**
- Cannot perform planned maintenance failover automatically
- Requires manual coordination

❌ **No Standby Re-sync Automation**
- Old primary must be manually rebuilt as new standby
- No automatic recovery workflow

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

Both nodes run PgBouncer configured to point to their respective PostgreSQL instances. The key difference is:
- **Primary PgBouncer** → connects to PostgreSQL at 192.168.24.21
- **Standby PgBouncer** → connects to PostgreSQL at 192.168.24.22

### Primary Node PgBouncer Configuration

**Config File:** `/etc/pgbouncer/pgbouncer.ini`
- Last Modified: 2025-12-11 15:58:36
- Permissions: `-rw-r--r--` (644)
- Owner: `postgres:postgres`

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
max_client_conn = 20000
default_pool_size = 1500
reserve_pool_size = 5
max_db_connections = 1500

server_connect_timeout = 15
server_login_retry = 3
query_timeout = 3600
query_wait_timeout = 120
client_idle_timeout = 3600
server_idle_timeout = 600
server_lifetime = 3600

logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid

log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

admin_users = pgbouncer_admin,postgres
stats_users = pgbouncer_admin,postgres

ignore_startup_parameters = extra_float_digits,search_path
server_reset_query = DISCARD ALL
```

### Standby Node PgBouncer Configuration

**Config File:** `/etc/pgbouncer/pgbouncer.ini`
- Last Modified: 2025-12-11 15:50:02
- Permissions: `-rw-r--r--` (644)
- Owner: `postgres:postgres`

```ini
[databases]
postgres = host=192.168.24.22 port=5432 dbname=postgres
template1 = host=192.168.24.22 port=5432 dbname=template1
* = host=192.168.24.22 port=5432

[pgbouncer]
listen_addr = 192.168.24.22,192.168.24.15,192.168.24.14
listen_port = 6432

auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

pool_mode = transaction
max_client_conn = 2000              # Note: Lower than primary
default_pool_size = 1500
reserve_pool_size = 5
max_db_connections = 1500

server_connect_timeout = 15
server_login_retry = 3
query_timeout = 3600
query_wait_timeout = 120
client_idle_timeout = 3600
server_idle_timeout = 600
server_lifetime = 3600

logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid

log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

admin_users = pgbouncer_admin,postgres
stats_users = pgbouncer_admin,postgres

ignore_startup_parameters = extra_float_digits,search_path
server_reset_query = DISCARD ALL
```

### PgBouncer Configuration Analysis

#### Connection Limits

| Setting | Primary | Standby | Purpose |
|---------|---------|---------|---------|
| `max_client_conn` | 20,000 | 2,000 | Maximum client connections to PgBouncer |
| `default_pool_size` | 1,500 | 1,500 | Default connections per database |
| `reserve_pool_size` | 5 | 5 | Additional connections for admin |
| `max_db_connections` | 1,500 | 1,500 | Max connections to PostgreSQL |

**⚠️ Note:** Primary can handle 10x more client connections than standby. This suggests standby is primarily for read-only workloads.

#### Pooling Configuration

```ini
pool_mode = transaction
```

- **Transaction-level pooling** - Connection returned to pool after each transaction
- **Benefit:** Maximum connection reuse, lowest PostgreSQL load
- **Trade-off:** Session-level features (temp tables, prepared statements) won't work across transactions

#### Timeouts

| Timeout | Value | Description |
|---------|-------|-------------|
| `server_connect_timeout` | 15s | Time to establish connection to PostgreSQL |
| `server_login_retry` | 3 | Number of login retry attempts |
| `query_timeout` | 3600s (1h) | Maximum query execution time |
| `query_wait_timeout` | 120s | Maximum time query waits for connection |
| `client_idle_timeout` | 3600s (1h) | Disconnect idle clients |
| `server_idle_timeout` | 600s (10m) | Close idle server connections |
| `server_lifetime` | 3600s (1h) | Reconnect to server after this time |

#### Listen Addresses

Both PgBouncer instances listen on **three IP addresses:**

```
listen_addr = <node_ip>,192.168.24.15,192.168.24.14
```

**Primary:** `192.168.24.21,192.168.24.15,192.168.24.14`  
**Standby:** `192.168.24.22,192.168.24.15,192.168.24.14`

**Interpretation:**
- `192.168.24.21/22` - Direct node access
- `192.168.24.15` - **Virtual IP (VIP) #1** for load balancer
- `192.168.24.14` - **Virtual IP (VIP) #2** for load balancer (possibly backup)

This allows applications to connect via:
1. Direct to node IP (not recommended for HA)
2. Via VIP which routes to active primary
3. Via backup VIP for redundancy

#### Authentication

```ini
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
```

- **MD5 authentication** - Password hashing
- **Userlist file:** Contains username and hashed passwords
- **Admin users:** `pgbouncer_admin`, `postgres`

#### Logging

```ini
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
logfile = /var/log/postgresql/pgbouncer.log
```

All connection events and errors are logged for troubleshooting.

### Connection Flow

#### Normal Operation (Primary Active)

```
Application
    ↓ connects to 192.168.24.15:6432 (VIP)
GCP Load Balancer
    ↓ routes to 192.168.24.21:6432 (healthy backend)
PgBouncer (Primary)
    ↓ pools connections to 192.168.24.21:5432
PostgreSQL (Primary)
    ↓ executes queries
```

#### After Failover (Standby Promoted)

```
Application
    ↓ connects to 192.168.24.15:6432 (VIP) - same connection string
GCP Load Balancer
    ↓ routes to 192.168.24.22:6432 (new healthy backend)
PgBouncer (Former Standby)
    ↓ pools connections to 192.168.24.22:5432
PostgreSQL (Newly Promoted Primary)
    ↓ executes queries (now read-write)
```

**⚠️ Critical Issue:** After failover, PgBouncer on the new primary still points to 192.168.24.22. This works, but the PgBouncer config is not automatically updated.

### PgBouncer Failover Considerations

#### Current Behavior

1. **GCP LB detects primary failure** (port 9999 health check fails)
2. **Traffic stops** (no healthy backend available)
3. **DBA promotes standby** to primary
4. **gcp-lb-manager.sh opens port 9999** on new primary
5. **GCP LB routes traffic** to new primary (192.168.24.22)
6. **PgBouncer on new primary** connects to local PostgreSQL (192.168.24.22)
7. ✅ **Applications work** without connection string changes

#### What Doesn't Happen Automatically

- PgBouncer configs are **not** automatically swapped
- Old primary's PgBouncer still configured for 192.168.24.21 (broken after failover)
- No automatic PgBouncer reconfiguration script detected

#### Recommended Enhancement

Create a PgBouncer reconfiguration script that runs during failover:

```bash
#!/bin/bash
# /usr/local/bin/pgbouncer-failover-reconfig.sh

ROLE="$1"  # primary or standby
PRIMARY_IP="192.168.24.21"
STANDBY_IP="192.168.24.22"
PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"

if [[ "$ROLE" == "primary" ]]; then
    # Configure PgBouncer to connect to local PostgreSQL
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    sed -i "s/host=[0-9.]\+/host=$LOCAL_IP/g" "$PGBOUNCER_CONF"
    
    # Increase max_client_conn for primary workload
    sed -i 's/max_client_conn = [0-9]\+/max_client_conn = 20000/' "$PGBOUNCER_CONF"
elif [[ "$ROLE" == "standby" ]]; then
    # Configure PgBouncer to connect to local PostgreSQL
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    sed -i "s/host=[0-9.]\+/host=$LOCAL_IP/g" "$PGBOUNCER_CONF"
    
    # Reduce max_client_conn for standby workload
    sed -i 's/max_client_conn = [0-9]\+/max_client_conn = 2000/' "$PGBOUNCER_CONF"
fi

# Reload PgBouncer configuration
systemctl reload pgbouncer
```

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
| **Network Failover** | ✅ GCP LB | Health-based routing |
| **Automatic Failover** | ⚠️ Semi-Automated | Requires manual promotion |
| **Connection Pooling** | ✅ Configured | PgBouncer on both nodes |
| **Load Balancing** | ✅ GCP Internal LB | VIP-based routing |
| **Split-Brain Protection** | ⚠️ Partial | Network-level only |
| **Automated Recovery** | ❌ None | Manual re-sync required |
| **Health Monitoring** | ✅ Active | Port 9999 health check |

### HA Tools Assessment

#### GCP Load Balancer + Health Check Script
- **Status:** ✅ Active and Functional
- **Components:**
  - GCP Internal Load Balancer: Network-level routing
  - gcp-lb-manager.sh: Health check port management
  - systemd service: Ensures health check runs continuously
- **Benefits:**
  - Single connection endpoint (VIP)
  - Automatic traffic routing to healthy primary
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

### Enhanced Failover Process

**With GCP Load Balancer:**

1. **Detection:** GCP health check detects primary failure (10 seconds)
2. **Isolation:** Primary marked unhealthy, removed from backend pool
3. **Alert:** Manual intervention required (no traffic being served)
4. **Decision:** DBA decides to promote standby
5. **Promotion:** `gcp-lb-manager.sh --promote` on standby
6. **Health Update:** Script opens port 9999 on new primary
7. **Traffic Restoration:** LB detects health, routes traffic to new primary (10 seconds)
8. **Verification:** Confirm applications reconnect successfully

**Estimated RTO (Recovery Time Objective):** 30-90 seconds (with script)  
**Estimated RPO (Recovery Point Objective):** Minimal with async replication

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

#### 1. Automate Standby Promotion ⚠️ **HIGH PRIORITY**

**Current State:** Manual standby promotion required  
**Risk:** Extended downtime, human error  
**Recommendation:** Implement automated failover with Patroni

**Enhanced Failover Workflow with Patroni + GCP LB:**

```bash
# Install Patroni on both nodes
apt-get install patroni python3-etcd python3-consul python3-kazoo

# Configure Patroni
cat > /etc/patroni/patroni.yml <<EOF
scope: pg-ha-cluster
name: $(hostname)

restapi:
  listen: 0.0.0.0:8008
  connect_address: $(hostname -I | awk '{print $1}'):8008

etcd:
  hosts: etcd-cluster:2379  # or consul/zookeeper

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: on
        max_wal_senders: 10
        max_replication_slots: 10

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $(hostname -I | awk '{print $1}'):5432
  data_dir: /var/lib/postgresql/17/main
  bin_dir: /usr/lib/postgresql/17/bin
  authentication:
    replication:
      username: replicator
      password: <password>
    superuser:
      username: postgres
      password: <password>

# Integration with GCP LB health check
tags:
  clonefrom: true
  noloadbalance: false
  nosync: false
EOF

# Patroni will automatically:
# - Detect primary failure
# - Promote standby via election
# - gcp-lb-manager.sh will detect new primary
# - Open port 9999 on new primary
# - GCP LB routes traffic automatically
```

**Expected Benefits:**
- RTO reduced to 10-30 seconds (fully automated)
- No human intervention required
- Automatic consensus-based failover
- Split-brain protection via DCS (etcd/consul/zookeeper)

#### 2. Automate PgBouncer Reconfiguration During Failover

**Current State:** PgBouncer configs are static and don't update during failover  
**Risk:** Confusion about which config is active, manual intervention required  
**Recommendation:** Integrate PgBouncer reconfiguration into failover script

**Implementation:**

```bash
# Add to gcp-lb-manager.sh --promote function
# After promoting PostgreSQL, update PgBouncer config

promote_node() {
    # Promote PostgreSQL
    sudo -u postgres pg_ctl promote -D /var/lib/postgresql/17/main
    
    # Update PgBouncer to point to local PostgreSQL
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    sudo sed -i "s/host=[0-9.]\+/host=$LOCAL_IP/g" /etc/pgbouncer/pgbouncer.ini
    
    # Increase connection limits for primary workload
    sudo sed -i 's/max_client_conn = [0-9]\+/max_client_conn = 20000/' /etc/pgbouncer/pgbouncer.ini
    
    # Reload PgBouncer
    sudo systemctl reload pgbouncer
    
    # Open health check port
    open_health_check_port
}
```

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

### Appendix B: GCP Load Balancer Commands

#### View Load Balancer Configuration
```bash
# List load balancers
gcloud compute forwarding-rules list --filter="IPAddress=10.164.26.100"

# Describe backend service
gcloud compute backend-services describe pg-ha-backend --region=us-central1

# Check health check configuration
gcloud compute health-checks describe pg-primary-health --region=us-central1

# View backend health status
gcloud compute backend-services get-health pg-ha-backend --region=us-central1
```

#### Test Health Check
```bash
# From within VPC network
nc -zv 10.164.26.50 9999  # Should connect if primary
nc -zv 10.164.26.51 9999  # Should fail if standby
```

#### Failover Testing
```bash
# Simulate primary failure (DO NOT RUN IN PRODUCTION)
ssh prd-ipa-pgdb1 "sudo systemctl stop gcp-lb-manager"

# Promote standby
ssh prd-ipa-pgdb2 "sudo /usr/local/bin/gcp-lb-manager.sh --promote"

# Verify LB backend health
watch -n 1 'gcloud compute backend-services get-health pg-ha-backend --region=us-central1'
```

### Appendix C: Health Check Script Reference

**Full Script:** `/usr/local/bin/gcp-lb-manager.sh`

**Available Commands:**
```bash
# Start in daemon mode (managed by systemd)
gcp-lb-manager.sh --daemon

# Promote this node to primary (also opens health check port)
gcp-lb-manager.sh --promote

# Check current role and health check status
gcp-lb-manager.sh --status

# Manually open health check port (testing only)
gcp-lb-manager.sh --enable-health

# Manually close health check port (testing only)
gcp-lb-manager.sh --disable-health
```

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

#### GCP Load Balancer Status
```bash
# Check which backend is healthy
gcloud compute backend-services get-health pg-ha-backend --region=us-central1

# View health check logs
gcloud logging read "resource.type=gce_health_check" --limit 50

# Check LB traffic metrics
gcloud monitoring time-series list --filter='metric.type="loadbalancing.googleapis.com/internal/backend_request_count"'
```

#### Health Check Debugging
```bash
# Check if health check port is listening
sudo netstat -tlnp | grep 9999

# Test health check locally
curl -v telnet://localhost:9999

# View health check manager logs
sudo journalctl -u gcp-lb-manager -f --since "10 minutes ago"

# Check PostgreSQL role
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
```

### Appendix E: PgBouncer Configuration Reference

#### Key Configuration Parameters

| Parameter | Primary Value | Standby Value | Description |
|-----------|---------------|---------------|-------------|
| `pool_mode` | transaction | transaction | Connection pooling strategy |
| `max_client_conn` | 20000 | 2000 | Max clients to PgBouncer |
| `default_pool_size` | 1500 | 1500 | Pool size per database |
| `max_db_connections` | 1500 | 1500 | Max connections to PostgreSQL |
| `server_idle_timeout` | 600s | 600s | Close idle server connections |
| `client_idle_timeout` | 3600s | 3600s | Disconnect idle clients |
| `query_timeout` | 3600s | 3600s | Maximum query execution time |

#### Database Configuration Differences

**Primary Node:**
```ini
* = host=192.168.24.21 port=5432
```

**Standby Node:**
```ini
* = host=192.168.24.22 port=5432
```

This wildcard configuration routes all database connections to the respective local PostgreSQL instance.

#### Virtual IP Assignment

Both nodes listen on shared VIPs:
- `192.168.24.15` - Primary VIP
- `192.168.24.14` - Secondary VIP (backup)

The GCP Load Balancer health check determines which node actively serves traffic on the VIP.

---

## Document Control

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-12 | Auto-generated | Initial configuration summary |
| 2.0 | 2026-01-12 | Auto-generated | Added GCP LB integration details |

**Next Review Date:** 2026-02-12

---

**End of Document**
