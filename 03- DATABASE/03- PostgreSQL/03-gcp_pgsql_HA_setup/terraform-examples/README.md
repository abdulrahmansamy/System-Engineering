# Terraform Configuration for GCP PostgreSQL HA

This directory contains Terraform configuration files to deploy a complete PostgreSQL High Availability setup on Google Cloud Platform.

## What This Creates

### Infrastructure Components
- **2 Compute Engine instances** (primary and standby)
- **Service account** with required permissions
- **GCS bucket** for backups with lifecycle policies
- **Firewall rules** for PostgreSQL communication and health checks
- **HTTP Load Balancer** for health checks and monitoring
- **TCP Load Balancer** for database connections
- **Health checks** for both HTTP and TCP endpoints
- **Static IP addresses** for load balancers
- **Cloud DNS zone** (optional) with DNS records
- **Monitoring alerts** and uptime checks

### Security Features
- Dedicated service account with minimal required permissions
- Firewall rules restricting access to specific ports and source ranges
- GCS bucket with uniform bucket-level access and private access enforcement
- OS Login enabled for secure SSH access

## Prerequisites

1. **Google Cloud Project** with billing enabled
2. **Terraform** (>= 1.0) installed
3. **gcloud CLI** installed and authenticated
4. **Required APIs** enabled in your GCP project:
   ```bash
   gcloud services enable compute.googleapis.com
   gcloud services enable dns.googleapis.com
   gcloud services enable monitoring.googleapis.com
   gcloud services enable storage.googleapis.com
   ```

## Quick Start

### 1. Clone and Configure

```bash
# Navigate to terraform directory
cd terraform-examples/

# Copy example variables file
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your values
nano terraform.tfvars
```

### 2. Initialize and Deploy

```bash
# Initialize Terraform
terraform init

# Review the execution plan
terraform plan

# Apply the configuration
terraform apply
```

### 3. Verify Deployment

```bash
# Check instances are created
gcloud compute instances list --filter="name~postgresql"

# SSH to primary instance
terraform output ssh_commands

# Check cluster status
gcloud compute ssh postgresql-ha-primary --zone=us-central1-a
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show
```

## Configuration Options

### Instance Sizing

| Environment | Machine Type | vCPU | RAM | Use Case |
|-------------|-------------|------|-----|----------|
| Development | e2-standard-2 | 2 | 8GB | Testing, small workloads |
| Staging | n2-standard-2 | 2 | 8GB | Pre-production testing |
| Production | n2-standard-4 | 4 | 16GB | Standard production |
| High Performance | c2-standard-8 | 8 | 32GB | High-traffic production |

### Storage Options

```hcl
# Standard setup
boot_disk_size = 50
boot_disk_type = "pd-ssd"
data_disk_size = 0  # Use boot disk only

# Production setup with separate data disk
boot_disk_size = 50
boot_disk_type = "pd-ssd"
data_disk_size = 200
data_disk_type = "pd-ssd"

# High performance setup
data_disk_type = "pd-ssd"  # Better IOPS
```

## Load Balancer Configuration

### HTTP Load Balancer (Health/Monitoring)
- **Purpose**: Health checks, monitoring endpoints
- **Endpoints**:
  - `/health` - Health check endpoint
  - `/metrics` - Metrics endpoint (if implemented)
- **Port**: 80
- **Global**: Yes

### TCP Load Balancer (Database Connections)
- **Purpose**: Database connections with failover
- **Port**: 5432 (PostgreSQL)
- **Regional**: Yes
- **Failover**: Primary active, standby backup

## DNS Configuration

When `create_dns_zone = true`:

```hcl
# DNS records created
postgresql.example.com      -> TCP Load Balancer IP
postgresql-http.example.com -> HTTP Load Balancer IP
```

**Usage**:
```bash
# Database connection via DNS
psql -h postgresql.example.com -p 5432 -U username database

# Health check via DNS
curl http://postgresql-http.example.com/health
```

## Monitoring and Alerting

### Uptime Monitoring
- Checks HTTP endpoint every 60 seconds
- Alerts on failures via email
- Configurable notification channels

### Backup Monitoring
The instances include automated backup monitoring:
```bash
# View backup logs
sudo tail -f /var/log/postgresql/backup.log

# Check GCS backups
gsutil ls gs://PROJECT-postgresql-backups/
```

## Cost Optimization

### Resource Costs (us-central1, monthly estimates)
```
n2-standard-2 (2 vCPU, 8GB):  ~$50/month
n2-standard-4 (4 vCPU, 16GB): ~$100/month
pd-ssd 100GB:                 ~$17/month
GCS Standard storage 100GB:   ~$2/month
Load balancers:               ~$18/month
```

### Cost-Saving Tips
1. Use `e2-standard` instances for development
2. Use `pd-balanced` disks instead of `pd-ssd` for non-critical workloads
3. Set appropriate GCS lifecycle policies
4. Use preemptible instances for non-production (requires additional configuration)

## Customization Examples

### Development Environment

```hcl
# terraform.tfvars for dev
environment     = "dev"
machine_type    = "e2-standard-2"
data_disk_size  = 50
create_dns_zone = false
notification_emails = ["dev-team@example.com"]
```

### Production Environment

```hcl
# terraform.tfvars for prod
environment     = "prod"
machine_type    = "n2-standard-4"
data_disk_size  = 200
create_dns_zone = true
dns_domain      = "company.com"
notification_emails = ["dba@company.com", "ops@company.com"]
backup_retention_days = 90
```

## Maintenance Operations

### Scaling Up

```bash
# Update machine type
# Edit terraform.tfvars
machine_type = "n2-standard-8"

# Apply changes
terraform apply

# Restart PostgreSQL after resize
gcloud compute ssh postgresql-ha-primary
sudo systemctl restart postgresql
```

### Adding Monitoring

```bash
# Enable additional monitoring
enable_monitoring = true
notification_emails = ["admin@company.com"]

terraform apply
```

## Backup and Recovery

### Automated Backups
- **Base backups**: Daily at 2 AM via cron
- **WAL archiving**: Continuous to GCS
- **Lifecycle**: 7 days → Nearline → 30 days → Coldline → 90 days → Delete

### Manual Backup

```bash
# SSH to primary instance
gcloud compute ssh postgresql-ha-primary

# Run manual backup
sudo /var/backups/postgresql/scripts/pg_ha_gcs_backup.sh
```

### Disaster Recovery

```bash
# View backup files
gsutil ls gs://PROJECT-postgresql-backups/

# Restore from backup (on new instance)
gsutil cp gs://PROJECT-postgresql-backups/primary-instance/base/backup_YYYYMMDD.tar.gz .
# Follow PostgreSQL restoration procedures
```

## Security Best Practices

### Network Security
```hcl
# Restrict SSH access
ssh_source_ranges = [
  "10.0.0.0/8",           # Corporate network
  "203.0.113.100/32"      # Admin jump host
]
```

### IAM Security
- Service account uses minimal required permissions
- No default compute service account usage
- Storage access limited to backup bucket only

### Database Security
The setup scripts configure:
- `scram-sha-256` password encryption
- Connection logging
- SSL/TLS ready configuration
- Limited network access

## Troubleshooting

### Common Issues

1. **Instances not starting**
   ```bash
   # Check startup script logs
   gcloud compute ssh postgresql-ha-primary
   sudo tail -f /var/log/user-data.log
   ```

2. **Load balancer health checks failing**
   ```bash
   # Test health endpoint directly
   curl http://INSTANCE_IP:8080
   
   # Check firewall rules
   gcloud compute firewall-rules list --filter="name~postgresql"
   ```

3. **DNS not resolving**
   ```bash
   # Check DNS zone
   gcloud dns managed-zones list
   
   # Verify name servers
   dig NS postgresql.example.com
   ```

### Cleanup

```bash
# Destroy all resources
terraform destroy

# Confirm GCS bucket deletion (if needed)
gsutil rm -r gs://PROJECT-postgresql-backups
```

This Terraform configuration provides a production-ready PostgreSQL HA setup with comprehensive monitoring, security, and backup capabilities on Google Cloud Platform.
