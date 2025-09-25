# PostgreSQL HA (Active-Passive) on GCP — Terraform

A production-ready, opinionated HA PostgreSQL stack on GCP. It provisions networking, IAM, instances, disks, TLS, secrets, synchronous replication via pg_auto_failover, PgBouncer, an Internal TCP Load Balancer (ILB), backups to GCS, monitoring, and compliance hardening.

## What this deploys
- VPC and subnet with flow logs
- Private DNS zone and A records (pg-primary, pg-secondary, pg-monitor, pg-vip)
- Reserved internal IPs for nodes and VIP
- Service accounts and IAM for nodes and monitor
- Compute instances: primary, secondary (with data + WAL disks), and monitor
- Internal TCP Load Balancer on 6432 with health probe on 8008
- Secret Manager entries for TLS materials and passwords
- GCS bucket for pgBackRest backups (versioning + lifecycle)

## Prerequisites
- A GCP project with billing enabled
- Terraform and gcloud installed
- User/service permissions to create networking, instances, SA/IAM, DNS, Secret Manager, GCS, and load balancer resources

## Quick start
```bash
# Set variables (at minimum project and region)
export TF_VAR_project_id="<your-gcp-project>"
export TF_VAR_region="us-central1"
# Optional backups config
export TF_VAR_backup_bucket_name=""           # empty -> auto name
export TF_VAR_backup_location="us-central1"

terraform init
terraform apply -auto-approve
```

After apply, you can list outputs:
```bash
terraform output
```

## How it works (startup script overview)
Each VM runs metadata_startup_script -> scripts/bootstrap_os.sh which:
- Hardens the OS (UFW, fail2ban, unattended-upgrades, auditd, AppArmor, journald, sysctl, SSH, NTP)
- Retrieves TLS and secrets (CA, node cert/key, DB passwords) from Secret Manager
- On primary/secondary only: prepares/mounts data and WAL disks; installs PostgreSQL 17; enables TLS, HA settings, WAL compression, archive_mode, archive_command
- Configures pg_auto_failover: creates monitor and enrolls nodes with TLS; sets number-sync-standbys=1 and candidate priorities
- Installs PgBouncer (TLS) on nodes and a primary-only health endpoint on 8008
- ILB health check (8008) drives traffic to current primary on 6432
- Installs pgBackRest, mounts GCS repo via gcsfuse, enables archiving, and schedules backups (daily incremental, weekly full) on the standby
- Creates a monitoring user (pg_monitor) and installs Google Ops Agent for system/PG metrics and logs
- Adds compliance: log rotation, extra audit rules, permissions tightening, umask

## Operate
### Verify provisioning
```bash
# Instances
terraform output primary_instance secondary_instance monitor_instance

# Live bootstrap logs on any VM
sudo tail -f /var/log/pg-ha/bootstrap.log

# Key services
# Data nodes
systemctl status postgresql pgautofailover-node pgbouncer pgha-health
# Monitor
systemctl status pgautofailover-monitor pgha-failback.timer
```

### Connect your apps
Use the ILB VIP via DNS (recommended) on PgBouncer port 6432:
```bash
# Example psql
psql "host=pg-vip.<your-private-zone> port=6432 user=<dbuser> dbname=<db> sslmode=verify-full"
```
If clients verify TLS, install the CA cert stored in Secret Manager (tls-ca-cert).

### Failover/switchover
Manual switchover (on pg-monitor):
```bash
sudo -u postgres pg_autoctl perform switchover --formation default
```
Automatic failback runs on the monitor and promotes pg-primary back when it is healthy, secondary, synchronous, and stable.

### Backups
Optionally set a project metadata key so nodes know the backup bucket:
```bash
BUCKET=$(terraform output -raw backup_bucket)
gcloud compute project-info add-metadata --metadata backup-bucket=${BUCKET}
```
Verify pgBackRest:
```bash
sudo -u postgres pgbackrest --stanza=main check --log-level-console=info
```
Backups are run by timers; logs are in /var/log/pg-ha/pgbackrest-backup.log

### Monitoring
Google Ops Agent ships host metrics/logs from all nodes and PostgreSQL metrics/logs from data nodes (user: monitoring). Adjust /etc/google-cloud-ops-agent/config.yaml if needed.

### Health and ILB
- Primary-only health: returns PRIMARY on port 8008 of the active primary
```bash
curl http://<node-ip>:8008
```
- ILB forwards 6432 to the healthy primary based on the health probe

### Troubleshooting
- Bootstrap: /var/log/pg-ha/bootstrap.log
- Postgres: journalctl -u postgresql, and e.g. psql -c 'select * from pg_stat_wal_receiver;'
- Auto-failover: pg_autoctl show state; journalctl -u pgautofailover-*
- PgBouncer: /var/log/pg-ha/pgbouncer.log
- TLS files: /etc/ssl/pg
- Secrets: gcloud secrets versions access --secret=<name> latest

## Outputs to note
- ilb_ip, dns_zone, primary_ip, secondary_ip, monitor_ip, vip_ip
- backup_bucket
- Secret IDs for TLS and passwords (tls_ca_secret, pg_superuser_password_secret, etc.)
