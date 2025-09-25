# Terraform: Foundation (Networking & IAM)
 Usage:
 ```
  export TF_VAR_project_id="<your-gcp-project>"; terraform init && terraform apply
  ```
 Inputs set via TF vars: project_id, region (default us-central1)
 This module creates: VPC/subnet, firewall rules, reserved internal IPs, SAs, and private DNS zone.
# OS Hardening & Base Bootstrap:
  - Hardened bootstrap for all nodes with logging, UFW, fail2ban, unattended-upgrades, auditd, AppArmor, NTP, sysctl, journald.
  - Instances (primary, secondary, monitor) updated to use metadata_startup_script = file(${path.module}/scripts/bootstrap_os.sh).
 - TLS & Secrets: Generates a root CA and per-node certs, stores them and DB passwords in Secret Manager. Instances fetch TLS at boot via metadata token and install under /etc/ssl/pg.
 - Fixed tls.tf to use multi-line blocks for tls_private_key and added short hostname SANs.
 - Fixed Secret Manager resources to use user_managed replication in the selected region.
 - pg_auto_failover Monitor: firewall opens 5431 internally; monitor initialized with TLS via pg_autoctl; runs under systemd (pgautofailover-monitor.service). URI stored at /opt/pg-ha/monitor_uri.txt.
 - Node Enrollment & Sync Replication: Added private DNS A records for node hostnames. Data nodes enroll via pg_autoctl with TLS, candidate priorities; monitor formation enforces number-sync-standbys=1. Systemd units manage pg_autoctl on nodes and monitor.
 - PgBouncer & Health Agent: Installed PgBouncer with TLS, added DB user and config, enabled service on nodes. Added health agent exposing 8008 only on current primary using socat and systemd. Opened 6432 in firewall.
 - ILB & DNS: Added internal TCP Load Balancer on 6432 with TCP health check on 8008 and instance groups per zone; forwarding rule uses reserved VIP. Created pg-vip DNS A record.
 - Automatic Failback Orchestrator: Added monitor-resident agent and systemd timer to auto-switchover back to original primary when healthy, synchronous, and stable; configured synchronous_commit=remote_apply for RPO=0.
 - Backups: pgBackRest to GCS: Created GCS bucket with lifecycle and versioning; configured pgBackRest with posix repo mounted via gcsfuse; enabled WAL archiving; added systemd timers for daily incremental and weekly full backups on the standby node.
 - Monitoring & Alerting: Created 'monitoring' DB user (pg_monitor), installed Google Ops Agent for system metrics/logs everywhere and PostgreSQL metrics/logs on data nodes. Configured to read password from Secret Manager.