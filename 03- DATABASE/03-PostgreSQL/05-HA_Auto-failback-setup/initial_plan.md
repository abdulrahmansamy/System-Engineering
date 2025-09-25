# PostgreSQL 17+ high availability on GCP with pg_auto_failover

You want a system that feels like a managed database: predictable, fast, and transparent under stress. We’ll engineer automatic failover and true seamless failback with audit-grade automation, synchronous replication for RPO 0, and a connection layer that calmly rides out role changes without clients noticing.

---

## 1. System architecture design

### System diagram

```text
                         ┌──────────────────────────────────────────────────────┐
                         │                  Shared VPC (/22)                    │
                         │            e.g., 192.168.24.0/22 (pre-existing)      │
                         └──────────────────────────────────────────────────────┘
                                           │
                 ┌────────────────────────────────────────────────────────────────────┐
                 │                    GCP Internal Load Balancer                      │
                 │        (TCP Proxy LB: VIP → PgBouncer cluster health-checked)      │
                 └────────────────────────────────────────────────────────────────────┘
                                           │
                ┌─────────────────────────────────────────────────────────────────────┐
                │                         PgBouncer cluster                           │
                │  Zone A (us-central1-a): pgbouncer-a                                │
                │  Zone B (us-central1-b): pgbouncer-b                                │
                │       - TLS from clients, SCRAM+cert auth                           │
                │       - HA via LB health checks, shared auth                        │
                └─────────────────────────────────────────────────────────────────────┘
                                           │
          ┌────────────────────────────────────────────────────────────────────────────────┐
          │                              PostgreSQL data layer                              │
          │                                                                                 │
          │   Zone A (us-central1-a): pg-primary (node A)                                   │
          │   Zone B (us-central1-b): pg-standby  (node B)                                  │
          │   Zone C (us-central1-c): pg-monitor (pg_auto_failover monitor)                 │
          │                                                                                 │
          │   - Synchronous streaming replication                                           │
          │   - Dedicated WAL disk (pd-ssd)                                                 │
          │   - Separate data disk (pd-ssd, LVM, auto-resize)                               │
          │   - End-to-end TLS (client, replication, monitor)                               │
          │   - pg_auto_failover keeper on data nodes, monitor service on monitor node      │
          └────────────────────────────────────────────────────────────────────────────────┘

                    ┌──────────────────────────────────────────────────────────────────┐
                    │                        Backup & DR                               │
                    │   - pgBackRest on standby first policy → GCS bucket              │
                    │   - WAL archiving to GCS                                         │
                    │   - Cross-region GCS and cold standby design                     │
                    └──────────────────────────────────────────────────────────────────┘
```

### Data flow and control

- **Client connections:**
  - **Path:** Client → ILB VIP → Healthy PgBouncer → Active primary.
  - **Resilience:** ILB probes PgBouncer health; PgBouncer reconnects on backend role changes; TLS everywhere.

- **Replication:**
  - **Mode:** Synchronous streaming replication with quorum control via pg_auto_failover monitor.
  - **WAL path:** Primary WAL → standby over TLS; dedicated WAL disk for write isolation.
  - **RPO/RTO controls:** `synchronous_commit=remote_apply`, `synchronous_standby_names` managed by the monitor state machine. pg_auto_failover adds/removes secondaries from the replication quorum when unhealthy to prevent unsafe failover.

- **Monitoring and orchestration:**
  - **Monitor:** pg_auto_failover monitor (in PostgreSQL) coordinates node states and implements the HA state machine for automated failover; supports PostgreSQL 13–17.
  - **Failover/failback logic:** Automatic failover on primary health loss; automatic, zero-intervention failback to the original primary when it is healthy and within lag thresholds, enacted by the monitor and keeper with strict split-brain prevention (details below). Cloud SQL’s HA model informs the trade-offs and the notion of failback symmetry (failover in reverse) from a managed service perspective.

- **Role identification:**
  - **Mechanism:** GCE metadata/labels used by automation scripts for role detection; never relies on instance names.
  - **Labels:** `role=primary|standby|monitor`, `formation=default`, `pg_cluster_id`, `candidate_priority`, `replication_quorum`.

---

## 2. Infrastructure as code (Terraform) plan

### Compute and disks

- **GCE instances:**
  - **Types:** n2-standard-8 (data nodes), e2-standard-4 (monitor), e2-standard-4 (PgBouncer nodes).
  - **Disks:**
    - **Data disk:** pd-ssd, min 1024GB, LVM group `vg_pgdata` → `lv_pgdata`, ext4, `noatime`.
    - **WAL disk:** pd-ssd, min 100GB, ext4, `noatime`, separate mount.
  - **Startup scripts:** Cloud-init to:
    - Harden OS (CIS-aligned), enable UFW, AppArmor, auditd.
    - Install Postgres 17, pg_auto_failover packages (PGDG), PgBouncer.
    - Pull secrets from Secret Manager; render TLS certs and config.
    - Register node with pg_auto_failover monitor.

```hcl
# Example: Data node (primary or standby, role detected by metadata/labels)
resource "google_compute_instance" "pg_node_a" {
  name         = "pg-node-a"
  machine_type = "n2-standard-8"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-2404-lts"
      type  = "pd-ssd"
      size  = 100
    }
  }

  attached_disk {
    type        = "pd-ssd"
    mode        = "READ_WRITE"
    device_name = "pgdata-disk-a"
    # size via separate disk resource; omitted for brevity
  }

  attached_disk {
    type        = "pd-ssd"
    mode        = "READ_WRITE"
    device_name = "pgwal-disk-a"
  }

  metadata = {
    role            = "primary" # or "standby" on node B
    formation       = "default"
    pg_cluster_id   = "cluster-01"
    candidate_priority = "100"
    replication_quorum = "true"
    startup-script  = file("cloud-init/pg-node.sh")
  }

  labels = {
    role              = "primary"
    pg_cluster_id     = "cluster-01"
    formation         = "default"
  }

  service_account {
    email  = google_service_account.pg_nodes.email
    scopes = ["cloud-platform"]
  }

  network_interface {
    subnetwork = var.shared_vpc_subnet_self_link
    # IP alloc omitted
  }

  tags = ["pg", "pg17", "cis-hardened"]
}
```

> Sources: 

### Networking

- **Firewall rules:**
  - **Allow:** 5432 (PostgreSQL), 6432 (PgBouncer), 5433 (monitor), ICMP for health checks, and SSH from bastion only.
  - **TLS only:** Block plain TCP to sensitive ports from outside trusted ranges.

- **Internal Load Balancer:**
  - **Type:** Regional TCP Proxy ILB targeting PgBouncer MIG (two instances: `us-central1-a`, `us-central1-b`).
  - **Health checks:** TCP 6432 with mTLS or a custom HTTP health via sidecar.
  - **Session affinity:** None; PgBouncer handles pooling.

- **Cloud DNS:**
  - **Records:**
    - `db.example.internal` → ILB VIP.
    - Role-based records for observability only (never used by clients): `pg-primary.internal`, `pg-standby.internal` updated by automation.

### IAM and security

- **Service accounts:**
  - **pg-nodes:** Least-privilege:
    - Secret Manager access: `roles/secretmanager.secretAccessor` for specific secrets.
    - GCS write (backup buckets): `roles/storage.objectCreator`.
    - Monitoring write: `roles/monitoring.metricWriter`.
    - Read labels/metadata: `roles/compute.instanceAdmin.v1` (narrow with `compute.instances.get` via custom role).
  - **pgbouncer-sa:** Read connection secrets only.
  - **monitor-sa:** Minimal privileges, can read instance metadata for role auditing.

- **Secret Manager:**
  - **Secrets:**
    - `pg_tls_ca`, `pg_tls_server_cert`, `pg_tls_server_key`.
    - `pg_monitor_tls_cert`, `pg_monitor_tls_key`.
    - `replication_user_password` (if SCRAM).
    - `pgbouncer_userlist.txt` or `auth_query` password store.
    - `pgbackrest_gcs_key.json`.

---

## 3. Configuration and automation plan

### PostgreSQL configuration (primary and standby)

```ini
# /etc/postgresql/17/main/postgresql.conf (Ubuntu path)
# Core
listen_addresses = '*'
port = 5432
max_connections = 1000

# WAL / replication for RPO 0 + fast RTO
wal_level = replica
synchronous_commit = remote_apply
max_wal_senders = 16
max_replication_slots = 16
wal_keep_size = 2GB
hot_standby = on
max_standby_streaming_delay = 30000        # ms
max_standby_archive_delay = 30000          # ms

# Monitor-managed quorum (pg_auto_failover updates this)
synchronous_standby_names = 'FIRST 1 (pgaf_standby_1, pgaf_standby_2)'

# Performance
shared_buffers = 8GB
effective_cache_size = 24GB
work_mem = 32MB
maintenance_work_mem = 1GB
wal_compression = on
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
max_worker_processes = 16
max_parallel_workers = 8
max_parallel_workers_per_gxact = 4

# TLS
ssl = on
ssl_cert_file = '/etc/postgresql/ssl/server.crt'
ssl_key_file = '/etc/postgresql/ssl/server.key'
ssl_ca_file = '/etc/postgresql/ssl/ca.crt'

# Logging for audit-grade transitions
logging_collector = on
log_destination = 'csvlog'
log_line_prefix = '%m [%p] %u@%d %r %a %e %c '
log_min_duration_statement = 250
log_checkpoint = on
log_connections = on
log_disconnections = on
```

```ini
# /etc/postgresql/17/main/pg_hba.conf
# Local
local   all             all                                     peer

# Client SSL with SCRAM
hostssl all             all         192.168.24.0/22             scram-sha-256

# Replication SSL
hostssl replication     replicator  192.168.24.0/22             scram-sha-256

# Monitor SSL
hostssl all             pgaf_monitor 192.168.24.0/22            scram-sha-256
```

> Sources: PostgreSQL 17 HA basics and replication settings overview, pg_auto_failover orchestration of synchronous_standby_names and quorum control.

### pg_auto_failover setup and tuning

#### Monitor

```bash
# Monitor DB init (on us-central1-c)
sudo -u postgres psql -c "CREATE EXTENSION pgautofailover;"
sudo -u postgres psql -c "CREATE USER pgaf_monitor WITH LOGIN PASSWORD '<from SecretManager>';"
# Enable TLS on monitor's pg_hba and postgresql.conf (as above)
# Start monitor service via systemd (see below)
```

#### Keeper registration (data nodes)

- **Formation:** `default` with synchronous replication.
- **Candidate priority:** Set higher for the original primary to enable automatic failback preference once healthy.
- **Replication quorum:** Ensure at least 1 synchronous standby in quorum.

```bash
# On each data node (via cloud-init), retrieve metadata/labels
ROLE=$(curl -s -H "Metadata-Flavor: Google" \
  http://169.254.169.254/computeMetadata/v1/instance/attributes/role)

# Register with monitor securely
pg_autoctl create postgres \
  --pgdata /var/lib/postgresql/17/main \
  --pgctl /usr/lib/postgresql/17/bin/pg_ctl \
  --monitor "postgres://pgaf_monitor@pg-monitor.internal:5432/pg_auto_failover?sslmode=require" \
  --username postgres \
  --dbname postgres \
  --ssl-self-signed no \
  --ssl-ca-file /etc/postgresql/ssl/ca.crt \
  --ssl-crt-file /etc/postgresql/ssl/server.crt \
  --ssl-key-file /etc/postgresql/ssl/server.key

# Apply keeper node properties
pg_autoctl set node candidate-priority 100    # original primary
pg_autoctl set node replication-quorum true   # ensure quorum
```

- **Automatic failback:** pg_auto_failover’s monitor chooses the candidate with highest priority when healthy and lag-safe; removing unhealthy nodes from `synchronous_standby_names` prevents unsafe promotions and split-brain. This design leverages the monitor’s state machine for safe automated role transitions. The managed-service perspective (Cloud SQL) confirms failback symmetry and the operational expectation that failover in reverse restores the original topology once healthy.

- **Key tunables:**
  - **Promotion health thresholds:** `pg_autoctl` default health checks plus OS-level health (systemd).
  - **Lag thresholds for promotion:** ensure standby is within 100ms under load; monitor avoids promoting lagging nodes.
  - **Fencing hooks:** optional automation to block writes on a suspected primary during partitions (see playbooks).

### PgBouncer configuration and HA

```ini
# /etc/pgbouncer/pgbouncer.ini
[databases]
postgres = host=pg-primary.internal port=5432 dbname=postgres auth_user=pgbouncer

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
admin_users = pgbouncer
server_tls_sslmode = verify-full
server_tls_ca_file = /etc/pgbouncer/ca.crt
server_tls_key_file = /etc/pgbouncer/server.key
server_tls_cert_file = /etc/pgbouncer/server.crt
client_tls_sslmode = require
client_tls_ca_file = /etc/pgbouncer/ca.crt
client_tls_key_file = /etc/pgbouncer/server.key
client_tls_cert_file = /etc/pgbouncer/server.crt

pool_mode = transaction
server_reset_query = DISCARD ALL
query_wait_timeout = 600
max_client_conn = 5000
default_pool_size = 200
min_pool_size = 50

# Fast failover behavior
server_round_robin = 0
server_login_retry = 3
server_connect_timeout = 500
server_fast_close = 1
```

- **Backend target management:**
  - Automation updates `host=` to the current primary IP via label-driven scripts and in-memory reloads (`SIGHUP`) on role changes. Alternatively, use a single virtual IP record that automation flips to the primary; PgBouncer reconnect logic + LB health checks keep client flow steady.

- **HA via ILB:**
  - Two PgBouncer nodes behind ILB. Health endpoint (TCP 6432) plus an optional `/ready` HTTP sidecar ensures only ready nodes receive traffic.

### Systemd units

#### PostgreSQL

```ini
# /etc/systemd/system/postgresql.service
[Unit]
Description=PostgreSQL 17 database server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=postgres
ExecStart=/usr/lib/postgresql/17/bin/pg_ctl start -D /var/lib/postgresql/17/main -s -o "-c config_file=/etc/postgresql/17/main/postgresql.conf"
ExecStop=/usr/lib/postgresql/17/bin/pg_ctl stop -D /var/lib/postgresql/17/main -s -m fast
ExecReload=/usr/lib/postgresql/17/bin/pg_ctl reload -D /var/lib/postgresql/17/main -s
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

#### pg_auto_failover monitor

```ini
# /etc/systemd/system/pgaf-monitor.service
[Unit]
Description=pg_auto_failover monitor
After=postgresql.service

[Service]
User=postgres
ExecStart=/usr/bin/pg_autoctl run --pgdata /var/lib/postgresql/17/monitor
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

#### pg_auto_failover keeper (data nodes)

```ini
# /etc/systemd/system/pgaf-keeper.service
[Unit]
Description=pg_auto_failover keeper
After=postgresql.service network-online.target
Wants=network-online.target

[Service]
User=postgres
ExecStart=/usr/bin/pg_autoctl run --pgdata /var/lib/postgresql/17/main
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

#### PgBouncer

```ini
# /etc/systemd/system/pgbouncer.service
[Unit]
Description=PgBouncer
After=network-online.target
Wants=network-online.target

[Service]
User=pgbouncer
ExecStart=/usr/bin/pgbouncer -d /etc/pgbouncer/pgbouncer.ini
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

---

## 4. Operational playbooks

### Backup and recovery

- **Backup tooling:** pgBackRest with GCS repository.
- **Policy:** Prefer backups from standby to offload primary; if standby unhealthy, fallback to primary with throttling.
- **WAL archiving:** pgBackRest handles continuous archiving; enables PITR.

```ini
# /etc/pgbackrest/pgbackrest.conf
[global]
repo1-type=gcs
repo1-path=/pgbackrest
repo1-gcs-bucket=pg-backups-prod
repo1-gcs-key=/etc/pgbackrest/gcs-key.json
process-max=4
compress-type=zst

[cluster-01]
pg1-path=/var/lib/postgresql/17/main
```

```bash
# Scheduled via systemd timer or cron
pgbackrest --stanza=cluster-01 --type=full backup
pgbackrest --stanza=cluster-01 --type=diff backup
pgbackrest --stanza=cluster-01 info
```

- **PITR drill:**
  - Restore to a new node (or DR region) using `--delta` restore and `recovery_target_time` to validate zero data loss guarantees.

### Disaster recovery (cross-region)

- **Data:** GCS bucket with cross-region replication enabled.
- **Compute:** Cold standby templates in `us-east1`; Terraform workspace can instantiate DR nodes.
- **Process:** Bootstrap from pgBackRest + latest WAL; promote under pg_auto_failover monitor instance in DR region; switch DNS/LB if region-level failure.

### Monitoring and alerting (Cloud Monitoring)

- **Metrics:**
  - **Replication lag:** From `pg_stat_replication` (standby apply delay).
  - **Failover state:** pg_auto_failover monitor events.
  - **PgBouncer pool saturation:** client/server pool metrics.
  - **Disk latency:** pd-ssd IO, WAL fsync times.
- **Alerts:**
  - **RTO risk:** Primary not accepting writes > 10s.
  - **Lag breach:** > 100ms sustained for 30s.
  - **Split-brain guard:** Dual-active writes detected (from fencing audit).
- **Logs:**
  - Ship PostgreSQL csvlogs and keeper/monitor logs to Cloud Logging; enable audit logs for operation traceability.

### Maintenance and upgrades

- **Rolling upgrades:**
  - Upgrade standby first; rejoin quorum; switchover to upgraded standby; upgrade former primary; automatic failback preference retained via candidate priority.
- **Parameter changes:**
  - Apply via `ALTER SYSTEM` or config files; reload; enforce through Ansible/Terraform with drift detection.

---

## 5. Validation and testing framework

### Failure simulations

- **Node crash (primary):**
  - Kill PostgreSQL service or stop instance; measure time until standby promotion and PgBouncer reconnection; verify under 30 seconds.
- **Network partition:**
  - UFW drop between primary and monitor; ensure no split-brain: monitor removes unhealthy node from quorum; writes only on elected primary; fencing script blocks former primary writes on suspicion.
- **Disk failure (WAL disk):**
  - Unmount WAL; ensure keeper signals unhealthy, prevents unsafe promotion until state stabilized.

### Automation scripts (examples)

```bash
# Measure failover RTO and verify RPO 0 (transactionally)
start_ts=$(date +%s%3N)
# Begin a transaction, write, commit on primary
psql -c "BEGIN; INSERT INTO rto_test(ts) VALUES (CURRENT_TIMESTAMP); COMMIT;"
# Crash primary
sudo systemctl stop postgresql
# Poll until new primary accepts writes
while ! psql -h db.example.internal -c "select 1" >/dev/null 2>&1; do sleep 0.2; done
end_ts=$(date +%s%3N)
echo "Failover RTO ms: $((end_ts - start_ts))"
# Verify write exists on new primary
psql -c "SELECT count(*) FROM rto_test;"
```

```bash
# Replication lag under load (pgbench)
pgbench -S -c 200 -j 16 -T 60 -h db.example.internal
psql -c "SELECT now() - pg_last_xact_replay_timestamp() AS apply_lag;"
```

### Success criteria checks

- **Failover time:** Parse keeper/monitor logs timestamps; confirm < 30s.
- **Zero data loss:** Run commit-before-failover tests; inspect `pg_stat_wal_receiver`, `pg_stat_replication` and table contents post-failover to confirm no missing commits.
- **Automatic failback:** Bring original primary back; health/lag normalization; monitor elects original primary (higher candidate priority) safely; automation flips PgBouncer target accordingly—no manual commands.
- **Split-brain prevention:** Monitored partitions never allow dual writers; quorum removal and fencing validated.
- **Performance:** Replication lag consistently < 100ms under pgbench load; adjust WAL/compression/IO if needed.
- **Transparency:** Audit logs show role changes; Cloud Monitoring alerts trigger with clear, actionable context.

> Sources for pg_auto_failover capabilities and state machine behavior supporting multiple standbys and quorum management; Managed service HA model and failback symmetry used for trade-off reference and expectations; PostgreSQL 17 replication setup considerations.

---

## Design trade-offs and pitfalls

### Known pitfalls and edge cases

- **Synchronous replication stalls:** With strict RPO 0, any standby slowdown can stall commits. Mitigate with WAL-optimized disks, CPU sizing, and monitor-driven quorum control to temporarily remove unhealthy standbys.
- **PgBouncer stale routing:** If backend host flips and PgBouncer isn’t reloaded, clients may see transient errors. Use automation to HUP PgBouncer upon role change and ILB health gating.
- **Monitor locality and failure:** Place monitor in a distinct zone; harden and back it up. Though it’s not on the data path, an unavailable monitor complicates orchestration.
- **TLS everywhere complexity:** Certificate rotation must be automated and coordinated to avoid connection breaks; store only in Secret Manager, render at boot.
- **Disk contention:** Combining WAL and data IO hurts latency. Dedicated WAL SSD and `noatime` reduce jitter.
- **Cloud LB nuances:** Health check granularity and failover sensitivity must be tuned; too aggressive fails can flap.

### Critical design trade-offs

- **Cost vs. performance:** Synchronous replication + pd-ssd across zones increases cost but is necessary for RPO 0 and sub-30s failover. Managed services charge roughly double for HA; we mirror that rationale with similar resource duplication.
- **Security vs. simplicity:** End-to-end TLS, SCRAM, CIS hardening add operational overhead but deliver audit-grade compliance. Automate certificate lifecycle to reduce friction.
- **Operational transparency vs. minimalism:** Including detailed logging and alerts ensures accountability but requires disciplined log management and noise control; prefer csvlogs + structured alerts.

---

## Security and compliance controls

- **Encryption:** TLS on client, replication, and monitor connections; encrypted disks at rest.
- **Secrets:** GCP Secret Manager for all keys/passwords; nodes read at boot with least privilege.
- **Authentication:** SCRAM-SHA-256 for users; client certs for privileged roles; rotate regularly.
- **OS hardening:** CIS-aligned Ubuntu 24.04—UFW (default deny + allow specific ports), AppArmor profiles, auditd rules for Postgres and pg_auto_failover services, SSH hardening (no password, key-only, limited CIDRs).
- **Auditing:** Role transitions logged by monitor/keeper and Postgres; ship to Cloud Logging; alerts in Cloud Monitoring with incident routing.

> Sources: pg_auto_failover design details (quorum, synchronous safety); Cloud SQL HA overview informs cost/perf trade-offs and failback expectations.

---

## Tailored notes for your environment

- **Role detection via labels:** Your scripts should parse instance metadata (`computeMetadata/v1/instance/attributes`) to determine roles and candidate priority. Never parse instance names.
- **Color-coded logging:** Integrate your modular log functions (info, warn, error, debug, die, ask) in the cloud-init and role-change handlers to produce audit-grade traces with context (role, formation, cluster ID).


---
