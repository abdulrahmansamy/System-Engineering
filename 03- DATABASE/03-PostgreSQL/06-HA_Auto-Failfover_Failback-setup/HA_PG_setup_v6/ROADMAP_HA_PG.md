# HA PostgreSQL on GCP – Product Roadmap (Foundation Phase)

Status: Module 9 COMPLETE, Module 10 PENDING

## 1. Objectives Mapped to Success Criteria
- RPO 0: Synchronous replication + WAL archiving + pgBackRest + verification queries.
- RTO < 30s: Tight pg_auto_failover timeouts, minimized promotion work, pre-created replication slots, tuned checkpoints.
- Automatic Failback: Deterministic restoration of original primary via supervised Failback Controller (safety predicates + cooldown).
- Split-Brain Prevention: Single monitor authority + fencing logic (demote on isolation) + health-gated LB.
- Replication Lag <100ms: SSD separation (data/WAL), tuned WAL/compression, network optimization.
- Observability & Audit: Structured JSON events → Cloud Logging → log-based metrics + alert policies.

## 2. Key Design Enhancements vs Current State
| Area | Enhancement |
|------|-------------|
| Failback | Autonomous failback controller with JSON events & metrics. |
| Role Detection | Explicit metadata keys (pg_role, candidate_priority, cluster_id). |
| Secrets | Hash-based refresh from Secret Manager; TLS/certs centrally managed. |
| Load Balancing | Internal TCP LB fronting PgBouncer (upcoming Module 10). |
| PgBouncer | Transaction pooling with health, metrics, TLS optional. |
| Backups | Standby-based pgBackRest strategy (upcoming). |
| Monitoring | Custom metrics foundational components present. |
| Audit | JSON event logs for failback actions. |

## 3. Module Breakdown (Sequential)
1. Baseline Validation & Naming Alignment (DONE)
2. Metadata & Labels Standardization (DONE)
3. Disks & Filesystem Provisioning Logic (DONE)
4. Package & Repo Bootstrap (DONE)
5. Secrets & TLS Retrieval Layer (DONE)
6. PostgreSQL Configuration Generator (DONE)
7. pg_auto_failover Monitor + Nodes Init (DONE)
8. Failback Controller Service (DONE)
9. PgBouncer Deployment (DONE)
10. Internal Load Balancer & Health Check Integration (PENDING)
11. Backup & PITR (pgBackRest) (PENDING)
12. Monitoring & Alerting Stack (PENDING)
13. Logging & Auditing Framework (PENDING)
14. Test Harness & Fault Injection (PENDING)
15. Documentation & Runbooks (PENDING)
16. Hardening & Final Review (PENDING)

## 4. Automatic Failback Strategy (Detail)
- Predicates: cooldown, uptime >=180s, replication lag <=2s, sync markers present, formation stable.
- Action: `pg_autoctl perform switchover --candidate <orig>`.
- Observability: JSON events + Prometheus textfile metrics.

## 5. Trade-Offs (Delta)
| Trade-Off | Choice | Rationale |
|-----------|--------|-----------|
| PgBouncer TLS default | Disabled (opt-in) | Avoid premature complexity; enable when cert stable. |
| Metrics collection interval | 60s | Balance overhead vs freshness. |

## 6. Risks & Mitigations
| Risk | Mitigation |
|------|------------|
| LB health flaps on promotion | PgBouncer pooling masks brief DB restarts. |
| Stale user secrets in userlist | Diff-based regeneration on secret rotation. |

## 7. Current Gaps (Observed)
- ILB Terraform not yet implemented.
- pgBackRest config absent.
- Alert policies & dashboards absent.
- Comprehensive logging pipeline not wired.

## 8. Recent Module Progress Highlights
- Module 9: TLS optional toggle, pause/resume scripts, metrics exporter + timer, final markers.

## 9. Planned New Artifacts
- loadbalancers.tf (populate ILB)
- templates/pgbackrest.conf.tpl
- monitoring/alert_policies.tf
- README_HA_OPERATIONS.md

## 10. Idempotency Patterns
- PgBouncer diff rewrite, metrics timer, secret-driven userlist rebuild.

## 11. Metrics & Alerts (Initial Set)
- replication_lag_ms, failback_seconds_since_last, failback_replication_lag_seconds, pgbouncer_active_connections.

## 12. Acceptance Gates per Module
- Module 10: ILB targets PgBouncer ports; health check stable; only primary receives traffic.

## 13. Next Step
Begin Module 10: Internal Load Balancer & Health Check Integration.
