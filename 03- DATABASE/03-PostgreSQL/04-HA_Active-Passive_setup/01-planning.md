<!-- filepath: /Users/abdulrahmansamy/git-repos/system_engineering/03- DATABASE/03-PostgreSQL/04-HA_Active-Passive_setup/01-planning.md -->

# Planning: GCP PostgreSQL HA with pg_auto_failover

Research & analysis summary (concise):
- Target state: 3-node pg_auto_failover cluster (primary, secondary, dedicated monitor) across 3 GCP zones; synchronous replication for RPO=0; ILB + PgBouncer for connection continuity; automated backups to GCS; comprehensive hardening, monitoring, and automation.
- Zero data loss: synchronous_commit=remote_apply (or at least on) with number_sync_standbys=1; replication slots; WAL tuning; fast sync I/O; low-latency network; clock sync via NTP.
- Fast failover: tight health checks (5s), low debounce, TCP health endpoint reflecting “is_primary”; PgBouncer transaction pooling; connection retries; ILB probes integrated with role status.
- Automatic failback: policy-driven switchover when original primary is back, healthy, fully caught up (0 lag), and window-safe; use pg_autoctl switchover orchestrated by a systemd timer/agent on the monitor; enforce candidate-priority/preferred primary; only execute with RPO=0 conditions and no load risks.
- Split-brain prevention: single monitor state-machine authority; synchronous replication blocks writes on isolated primary; optional fencing via GCE API to stop isolated old primary; firewall isolation; health-check gating on ILB.
- Best practices: separate SSD for data and WAL; tuned FS and mount options; kernel/sysctl tuning for Pg; TLS everywhere (client, replication, monitor); SCRAM; Secrets in GCP Secret Manager; least-privilege SAs; UFW, fail2ban, AppArmor; journald/rsyslog; auditd; unattended-upgrades.
- Performance: shared_buffers, wal/compression/flush tuning, max_wal_size and checkpointer cadence, logical/physical I/O alignment, hugepages consideration, NUMA-friendly settings, network MTU; replication sender/receiver tuning; pgbouncer pool modes tuned for HA.
- Monitoring/alerting: postgres_exporter, pg_auto_failover metrics, system metrics; Cloud Monitoring + Alerting; event logging for role transitions; lag SLOs and RTO/RPO validation metrics.
- Backups/DR: pgBackRest to GCS; PITR; periodic backup validation restores; cross-region replication; snapshot schedules; runbooks for regional DR.
- Upgrades/maintenance: rolling minor upgrades; extension/version checks; throttle maintenance during failover; schema change guidance.
- Edge cases: monitor outage, network partitions, disk-full, WAL backlog, cert expiry, GCS outage, clock skew, excessive lag, long-running transactions blocking promotion, failback oscillation prevention (cooldown/backoff).

# [Product Roadmap: GCP PostgreSQL HA with pg_auto_failover]

## 1. Vision & Tech Stack
- Objective: Fully automated PostgreSQL HA with seamless failover and automatic safe failback to the original primary, achieving RPO=0 and RTO<30s.
- Infrastructure Summary: 2-node Postgres cluster with dedicated monitor across 3 GCP zones, ILB + PgBouncer for routing, Terraform + Bash provisioning, secure-by-default, with automated backups, monitoring, and compliance.
- Tech Stack: Terraform, Bash Scripting (for GCE provisioning).
- Directives Applied: No NodeJS; Terraform/Bash for provisioning; Safe-Edit Protocol; logging and hardening; GCE-first automation.

## 2. Core Requirements
- GCP: Shared VPC, single subnet, fixed internal IPs, ILB with custom health checks, Cloud DNS, service accounts with least-privilege, IAM bindings.
- Compute: 3 instances (primary, secondary, monitor) in us-central1-a/b/c; machine types sized for low-latency replication; separate SSD PDs for data and WAL.
- Disks/FS: Data and WAL on separate SSDs; tuned FS params; LVM for growth; auto filesystem expansion; SMART/disk health monitoring.
- PostgreSQL 17+: TLS, SCRAM, synchronous replication (RPO=0), replication slots, WAL archiving, tuned postgresql.conf for HA.
- pg_auto_failover: Dedicated monitor with TLS; formation configured with number_sync_standbys=1; candidate-priority to favor original primary; zero-manual orchestration for failover/failback.
- Connection layer: PgBouncer on both nodes; ILB routes only to current primary via health endpoint; optional read-only on standby via separate service.
- Security: CIS baseline, UFW restrictive policy, fail2ban, AppArmor, hardened SSH, unattended-upgrades, auditd, sysctl hardening, cert rotation via local CA; secrets in Secret Manager.
- Monitoring/Alerting: Postgres + system + pg_auto_failover metrics; Cloud Monitoring dashboards and alerting for RTO/RPO SLOs and state transitions.
- Backups/Recovery: pgBackRest to GCS; PITR; automated restore testing; snapshot scheduling.
- Automation: Systemd units/timers for bootstrap, cert rotation, pg_auto_failover switchover policy (automatic failback), log rotation, cleanup.
- Validation: Chaos tests for failover/failback; network partition simulations; transaction trackers to assert RPO=0 and RTO<30s.

## 3. Prioritized Functional Modules
| Priority | Module Name | Justification | Description of Resources |
|:---:|:---|:---|:---|
| 1 | Foundation: Terraform Project & Networking | Establish secure, deterministic infra baseline | VPC, subnet, routes, firewall (UFW baseline), service accounts, IAM, static IPs, DNS zones, ILB skeleton, health check placeholders |
| 2 | Compute & Disks | Ensure nodes and performance-critical storage exist and are attached | 3 GCE instances across zones; data/WAL SSDs; labels/tags; startup scripts wiring; LVM and fstab stubs |
| 3 | OS Hardening & Base Bootstrap | Security/compliance prerequisites | Bash provisioning: CIS, UFW, fail2ban, SSH hardening, unattended-upgrades, auditd, NTP, sysctl, journald/rsyslog, SMART, log dirs |
| 4 | TLS & Secrets | Secure-by-default transport and auth | Local CA creation, cert issuance, Secret Manager integration, systemd timer for rotation, secure permissions |
| 5 | PostgreSQL Install & Config | Core database layer tuned for HA | Install PG 17, directories (data/WAL), tuned postgresql.conf, pg_hba with TLS/SCRAM, replication slots, WAL archiving setup |
| 6 | pg_auto_failover Monitor | Control plane for safe orchestration | Install/initialize monitor with TLS; formation/group setup; parameters (number_sync_standbys=1, candidate-priority defaults) |
| 7 | Node Enrollment & Sync Replication | RPO=0 with sync | Enroll primary/secondary via pg_autoctl; ensure synchronous_commit and sync standby names; replication verification |
| 8 | PgBouncer & Health Agent | Seamless routing | PgBouncer config (tx pooling), auth, TLS; lightweight health HTTP/TCP endpoint exposing is_primary; integrate with ILB |
| 9 | ILB & DNS Plumbing | Client path resilience | ILB backends, health checks (primary-only), forwarding rules; optional DNS entry for reader endpoint |
| 10 | Automatic Failback Orchestrator | Zero-touch restoration of original primary | Systemd timer/agent on monitor: evaluate readiness (0 lag, steady state, cooldown), trigger pg_autoctl switchover safely |
| 11 | Backups: pgBackRest to GCS | Data protection & DR | Repo config, schedules, retention, GCS auth, periodic restore validation in sandbox |
| 12 | Monitoring & Alerting | SLO visibility and ops signals | postgres_exporter, node exporter, pg_auto_failover metrics, Cloud Monitoring dashboards/alerts, log-based alerts |
| 13 | Compliance & Logging | Audit and governance | Auditd rules, centralized logs, retention, immutability options, access reviews |
| 14 | Testing & Chaos Suite | Prove RTO/RPO and split-brain prevention | Automated failover/failback tests, network partition, disk-full, clock skew; success criteria enforcement |
| 15 | DR Enhancements | Business continuity | Cross-region backup replication, DR runbooks, regional failover automation hooks |
| 16 | Upgrades & Maintenance | Longevity without downtime | Rolling minor upgrades, extension checks, maintenance windows, throttling policies |
