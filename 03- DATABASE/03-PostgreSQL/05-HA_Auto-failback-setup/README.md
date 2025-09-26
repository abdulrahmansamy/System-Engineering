# PostgreSQL HA on GCP with pg_auto_failover – Terraform Foundation

This repository bootstraps the Terraform foundation for a production-grade PostgreSQL 17+ HA cluster on GCP.

Scope in this module:
- Providers and versions
- Data lookups for existing Shared VPC and subnets
- Common locals/labels and discovery outputs

Inputs are defined in `variables.tf` and can be provided via `terraform.tfvars` (already present).

Quick start (optional):

```bash
terraform init
terraform validate
terraform plan -var-file=terraform.tfvars
```

Next modules (high level): compute instances & metadata, Secret Manager wiring, OS hardening, PostgreSQL + pg_auto_failover, PgBouncer + ILB, backups, monitoring, and tests.

## Service Account least-privilege (documented)

VM service account (`pg_sa`) is granted only:
- roles/secretmanager.secretAccessor on specific secrets
- roles/logging.logWriter (project)
- roles/monitoring.metricWriter (project)

No broad editor/admin roles are used. Adjust in `secrets.tf` if needed.

## Module acceptances snapshot

- Terraform foundation: `terraform init/plan` passes; no destructive changes.
- Compute+metadata+disks: Instances carry metadata `ha-pg-script-url` and `timezone`; startup bootstrapper invoked.
- Secret Manager integration: Secrets for superuser, replication, monitor, PgBouncer auth, TLS (CA/server) with IAM bindings; HA script retrieves non-interactively and writes TLS with strict perms.
- OS hardening+NTP/timezone: Chrony configured to metadata.google.internal; UFW/AppArmor/auditd/SSH/sysctl applied; semantic logging to console+file.
