# Sequential Execution Plan – HA PostgreSQL on GCP

This file is updated incrementally after each module per Protocol Code Shield-3.

## Legend
Status Codes: PENDING | IN_PROGRESS | DONE | BLOCKED

## Module Overview
| # | Module | Purpose | Status |
|---|--------|---------|--------|
| 1 | Baseline Validation & Naming Alignment | Confirm current infra & naming gaps | DONE |
| 2 | Metadata & Labels Standardization | Ensure required metadata keys applied | DONE |
| 3 | Disks & Filesystem Provisioning Logic | LVM + mount idempotent logic | DONE |
| 4 | Package & Repo Bootstrap | Install PG 17 + pg_auto_failover | DONE |
| 5 | Secrets & TLS Retrieval Layer | Secure secret pull & caching | DONE |
| 6 | PostgreSQL Configuration Generator | Templated config w/ diff logic | DONE |
| 7 | pg_auto_failover Monitor + Nodes Init | Cluster formation & sync tuning | DONE |
| 8 | Failback Controller Service | Auto restore preferred primary | DONE |
| 9 | PgBouncer Deployment | HA pooling + pause/resume | DONE |
|10 | Internal Load Balancer & Health Check | ILB + health gating | PENDING |
|11 | Backup & PITR (pgBackRest) | Full/incr + restore drills | PENDING |
|12 | Monitoring & Alerting Stack | Metrics + alerts Terraform | PENDING |
|13 | Logging & Auditing Framework | Structured events | PENDING |
|14 | Test Harness & Fault Injection | Validate SLAs | PENDING |
|15 | Documentation & Runbooks | Ops procedures | PENDING |
|16 | Hardening & Final Review | CIS / principle of least privilege | PENDING |

## Module 1: Baseline Validation & Naming Alignment
### Goals
- Inspect existing Terraform: ensure locals & outputs cover required roles (primary, standby, monitor, vip).
- Identify where compute instances are defined & confirm missing metadata keys.
- Confirm presence/absence of ILB resources.
- Capture actionable deltas for Module 2.

### Findings
- `compute.tf` uses placeholders (`{…}`) – actual resource content redacted/not present in context; cannot yet patch without reading full file.
- `loadbalancers.tf` is empty: ILB not yet implemented.
- IP reservations appear in `addresses.tf` but `ip_names` map only defines `monitor`; missing keys for `primary`, `standby`, `vip` (in snippet). Need to verify complete file contents to avoid duplication.
- Required metadata not visible: need keys `pg_role`, `cluster_id`, `candidate_priority`, `pg_failback_enabled`.
- Startup script variable name in locals: `startup_script` – currently only header in `scripts/ha_postgresql_setup.sh`.

### Action Items for Module 2
1. Populate missing reserved IP name locals if absent (primary, standby, vip).
2. Ensure compute instances reference reserved addresses explicitly.
3. Add metadata map additions per node.
4. Prepare additions for `loadbalancers.tf` (but implement in Module 10).
5. Extend startup script scaffold sections (deferred to later modules).

### Blockers
- Need full `compute.tf` & `addresses.tf` contents to apply precise edits (placeholders currently conceal code). Will read those before Module 2.

### Exit Criteria
- Inventory of required modifications documented (above) – DONE.
- No code changes performed (per protocol) – DONE.

Status: DONE. Proceeding with Module 2 edits applied (metadata normalization in `compute.tf`).

## Module 2 – Metadata & Labels Standardization
Status: DONE
Notes:
- Added variable `pg_failback_controller_cooldown_seconds` and integrated into instance metadata.
- All required metadata keys standardized; Terraform plan validation deferred until batching.

## Module 3 – Disks & Filesystem Provisioning Logic
Status: DONE
Additions this update:
- WAL relocation scaffolding (will execute post-initialization when PGDATA exists).
- Marker file `wal_relocate.done` logic.
Exit Criteria Met.

## Module 4 – Package & Repo Bootstrap
Status: DONE
Completion:
- Added version capture (`package_versions.env`).
- All required packages installed idempotently; services disabled awaiting config.

## Module 5 – Secrets & TLS Retrieval Layer
Status: DONE
Completion:
- Mandatory secret presence validation (soft-fail retry) for data nodes.
- Ephemeral self-signed cert fallback logic (flag file EPHEMERAL_CERT) when managed cert absent.
- Markers: `secrets.done`, `secrets_validation.done`.

## Module 6 – PostgreSQL Configuration Generator
Status: DONE
Completion Details:
- Dynamic sizing & baseline configs written idempotently.
- initdb with data checksums when absent.
- Role creation (postgres password, replicator, pgmonitor, pgbouncer) using secrets when present.
- WAL archive directory & symlink prepared; post-init WAL relocation executed if needed.
- Markers: pg_config.done, cluster_init.done, roles_configured.done.
Remaining Deferred Items (moved to later modules):
- Archive command integration with pgBackRest (Module 11).
- pg_hba network scope tightening (post network CIDR finalization).

## Module 7 – pg_auto_failover Monitor + Nodes Init
Status: DONE (unchanged from prior update)

## Module 8 – Failback Controller Service
Status: DONE
Completion Details:
- Controller script with predicates: cooldown, node uptime (>=180s), replication lag (<=2s), sync markers, formation stability.
- Preferred primary identification via candidate_priority >=100 marker file.
- Structured JSON event log appended (`failback_events.jsonl`) plus plain text log.
- Metrics exporter textfile (`failback_controller.prom`) providing seconds since last failback & current replication lag.
- Systemd service + timer already integrated (Module 8 earlier phase) using 1m cadence.
- Completion markers: failback_controller.done (integration), module8.complete (script), preferred_primary flag.
Deferred (Future Modules 12/13):
- Centralized log ingestion enhancements & metric registration in monitoring stack.
- Alert rule for repeated failback attempts.

## Module 9 – PgBouncer Deployment
Status: DONE
Completion Details (Final Update):
- Initial config & userlist generation with md5 hashing from secrets (diff-only updates).
- TLS optional enablement via instance metadata `pgbouncer_tls_enabled` (appends TLS parameters if true and certs present).
- Pause/Resume helper scripts installed (`pgbouncer_pause`, `pgbouncer_resume`).
- Healthcheck script (`pgbouncer_healthcheck`) verifying version and pool failure absence.
- Metrics exporter script (`pgbouncer_metrics`) + systemd timer (1m cadence) producing Prometheus textfile metrics (connections & pools).
- Systemd service enabled and restarted idempotently.
Markers: pgbouncer_config.done, pgbouncer_final.done.
Deferred (Later Modules 10/12/13):
- Integration of pause/resume during orchestrated failover events (hook into promotion scripts).
- Expanded metrics (latency, transaction rates) & alert policies.

## Next Module
Module 10 – Internal Load Balancer & Health Check Integration.
Planned Focus:
- Terraform ILB resources (forwarding rule, backend service, health check hitting PgBouncer health endpoint).
- Optional DNS record pointing to ILB VIP.
- Node tagging & firewall openings for health probes.

# HA PostgreSQL – Execution Plan (Operational)

## Module Status Table
| Module | Name | Status | Key Artifacts / Markers |
|--------|------|--------|-------------------------|
| 1 | Baseline Validation | DONE | N/A |
| 2 | Metadata & Labels | DONE | metadata applied |
| 3 | Disks & Filesystems | DONE | disk_setup.done, wal_relocate.done |
| 4 | Packages Bootstrap | DONE | packages.done, package_versions.env |
| 5 | Secrets & TLS Layer | DONE | secrets.done, secrets_validation.done |
| 6 | PG Config Generator | DONE | pg_config.done, cluster_init.done, roles_configured.done |
| 7 | pg_auto_failover Init | DONE | monitor_init.done, node_registered.done, monitor_unit.done, node_unit.done, sync_verified.done, timeouts_tuned.done, module7.complete |
| 8 | Failback Controller | DONE | failback_controller.done, module8.complete |
| 9 | PgBouncer Deployment | DONE | pgbouncer_config.done, pgbouncer_final.done |
| 10 | Internal Load Balancer | IN_PROGRESS | ilb_pgbouncer_ip output |
| 11 | Backups & PITR | PENDING | (future) |
| 12 | Monitoring & Alerting | PENDING | (future) |
| 13 | Logging & Auditing | PENDING | (future) |
| 14 | Test Harness & Fault Injection | PENDING | (future) |
| 15 | Runbooks & Docs | PENDING | (future) |
| 16 | Hardening & Final Review | PENDING | (future) |

---
## Completed Modules (1–9) Summary (Concise)
(omitted here for brevity – details retained in earlier revisions; focus shifts to Module 10 forward)

---
## Module 10 – Internal Load Balancer & Health Check Integration (PENDING)
Objective: Provide a stable virtual IP for writers routed through PgBouncer while ensuring only the active primary is in service, leveraging pg_auto_failover + PgBouncer health.

### Scope
- Terraform definition of regional Internal TCP Load Balancer (ILB) on port 6432.
- Backend service using instance group(s) containing database VMs.
- Health check referencing HTTP or TCP endpoint (strategy below) targeting PgBouncer health script.
- Optional DNS record (internal) pointing to ILB IP.
- Labels & annotations aligning with cluster_id.
- Ensure promotion events converge quickly (<30s) with health updates.
 - Runtime gating so only primary node runs PgBouncer (standby service stopped) to force single healthy backend.

### Design Decisions
- Health check method: TCP or HTTP? We will expose a lightweight HTTP health on 6432 via a small sidecar or reuse pgbouncer_healthcheck using a TCP connect. Simplicity first: use TCP health check to PgBouncer port (fast). Enhancement: later custom HTTP proxy if richer semantics needed.
- Only primary should pass health: PgBouncer config currently points to localhost Postgres. On a secondary, PgBouncer connects in hot-standby (read-only) – risk of unintended writes. Mitigation: implement a PgBouncer auth gate or scripted pause on non-primary nodes. Approach: Add metadata-driven script to pause PgBouncer automatically if node is NOT primary (future refinement). For Module 10 MVP we rely on synchronous routing changes + future Module 12 hooks.

### Terraform Tasks
1. Data lookups
   - data.google_compute_subnetwork (already present if network.tf defines) reuse.
2. Instance group
   - Create unmanaged instance group per zone: google_compute_instance_group.<cluster_id>-zoneX (attach existing instances by self_link).
3. Health check
   - google_compute_health_check.pgsql_pgbouncer (TCP, port 6432, check interval 5s, healthy_threshold 2, unhealthy_threshold 2, timeout 3s).
4. Backend service
   - google_compute_backend_service.pgsql_pgbouncer (protocol TCP, timeout 30s, connection_draining 5s) attach instance groups.
5. Forwarding rule
   - google_compute_forwarding_rule.pgsql_pgbouncer_ilb (load_balancing_scheme = INTERNAL, IP protocol TCP, port_range 6432, subnetwork reference).
6. (Optional) Reserve static internal address for consistency.
7. Output ILB IP and FQDN (if DNS created).

### Health Semantics Enhancement (Deferred)
- Script: on state change to secondary, auto run `pgbouncer_pause`. On primary promotion, run `pgbouncer_resume`.
- Potential integration: systemd unit triggered by pg_autoctl state file change in /var/lib/postgres/pg_autoctl.

### Acceptance Criteria
- A single internal IP (ILB) reachable from application VPC tier on port 6432.
- During switchover, ILB backend shifts traffic within <= 30s.
- Only one backend reported healthy at steady state (validate through gcloud backend-services get-health).
 - PgBouncer role gating script & timer present on data nodes with state transitions logged.

### Required Variables (extend variables.tf)
- ilb_enabled (bool, default true)
- ilb_subnet (string, optional if single subnet)
- ilb_internal_dns_zone (optional for record creation)
- ilb_dns_name (optional relative name)

### Terraform Validation Commands (post-implementation)
- terraform plan -target=module.ha_pg (scoped if modularized later)
- gcloud compute forwarding-rules describe <name>

### Risks
| Risk | Impact | Mitigation |
|------|--------|------------|
| All nodes healthy simultaneously | Writes may reach replica | Implement PgBouncer pause on replica (follow-up). |
| Health check too sensitive | Flapping | Tune thresholds (2/2) & short intervals balanced with stable startup grace. |

### Deliverables
- Updated `variables.tf`, `loadbalancers.tf` with ILB resources.
- Updated `outputs.tf` (if file exists / create) for ilb_ip, ilb_dns.
- Execution plan status change to IN_PROGRESS when edits start.

### Next Implementation Step
Create / update Terraform files to add ILB (start by extending `loadbalancers.tf`).

---
## Upcoming Module Stubs
(11–16 reserved; will expand upon entering each.)

