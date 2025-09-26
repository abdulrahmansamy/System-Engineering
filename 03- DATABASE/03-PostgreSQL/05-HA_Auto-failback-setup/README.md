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
