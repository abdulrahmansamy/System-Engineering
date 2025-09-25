# PostgreSQL HA Setup for Google Cloud Platform

This directory contains PostgreSQL High Availability setup scripts specifically optimized for Google Cloud Platform (GCP) Compute Engine instances. These scripts provide automated deployment with GCP-native integration.

## Key Features

### GCP-Native Integration
- **Automatic IP Detection**: Uses GCE metadata service to discover instance IPs
- **Instance Discovery**: Automatically finds peer instances in the same zone
- **Metadata Integration**: Supports instance attributes for configuration
- **Cloud Storage Backup**: Integrated with Google Cloud Storage
- **Firewall Automation**: Creates necessary firewall rules automatically
- **Health Checks**: Built-in endpoints for GCP Load Balancers

### Production-Ready Features
- **Auto-tuning**: Performance settings based on instance specifications
- **High Availability**: Primary-standby replication with automatic failover
- **Backup Integration**: GCS backup with lifecycle management
- **Monitoring Ready**: Health check endpoints and logging integration
- **Zero-Touch Deployment**: Runs via user-data during instance provisioning

## Directory Structure

```
03-gcp_pgsql_HA_setup/
├── 01-pgsql_setup-primary-gcp.sh      # GCP Primary setup script
├── 02-pgsql_setup-standby-gcp.sh      # GCP Standby setup script  
├── user-data-examples/                # User-data script examples
├── terraform-examples/                # Terraform deployment examples
└── README.md                          # This documentation
```

## Quick Start

### Method 1: Manual Execution

```bash
# On primary instance
sudo ./01-pgsql_setup-primary-gcp.sh 10.0.1.10 10.0.1.11

# On standby instance (after primary completes)
sudo ./02-pgsql_setup-standby-gcp.sh 10.0.1.10 10.0.1.11
```

### Method 2: Automated via Instance Metadata

```bash
# Set metadata on instances
gcloud compute instances add-metadata primary-instance \
  --metadata=standby-ip=10.0.1.11

gcloud compute instances add-metadata standby-instance \
  --metadata=primary-ip=10.0.1.10

# Scripts will auto-detect IPs
sudo ./01-pgsql_setup-primary-gcp.sh
sudo ./02-pgsql_setup-standby-gcp.sh
```

### Method 3: User-Data During Instance Creation

```bash
# Create primary instance with user-data
gcloud compute instances create postgresql-primary \
  --zone=us-central1-a \
  --machine-type=n2-standard-2 \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=user-data-primary.sh \
  --metadata=standby-ip=10.0.1.11 \
  --scopes=cloud-platform
```

## GCP-Specific Features

### Automatic IP Discovery
The scripts can automatically detect IP addresses through multiple methods:

1. **Instance Metadata**: Reading current instance's network interface
2. **Instance Attributes**: Custom metadata set on instances
3. **Zone Discovery**: Finding peer instances by name patterns
4. **Health Check Waiting**: Standby waits for primary to be ready

### Google Cloud Storage Integration

```bash
# Automatic GCS bucket creation
PROJECT_ID=$(curl -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)
BUCKET_NAME="${PROJECT_ID}-postgresql-backups"

# Lifecycle policy for cost optimization
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 30}
    },
    {
      "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
      "condition": {"age": 7}
    }
  ]
}
```

### Firewall Rules Automation
Scripts automatically create necessary firewall rules:

```bash
# PostgreSQL communication
gcloud compute firewall-rules create postgresql-ha-5432 \
  --allow tcp:5432 \
  --source-ranges="PRIMARY_IP/32,STANDBY_IP/32"

# PgBouncer communication  
gcloud compute firewall-rules create postgresql-ha-6432 \
  --allow tcp:6432 \
  --source-ranges="PRIMARY_IP/32,STANDBY_IP/32"

# Health check endpoint
gcloud compute firewall-rules create postgresql-health-8080 \
  --allow tcp:8080
```

### Health Check Endpoints
Built-in health check endpoints for GCP Load Balancers:

- **Port 8080**: HTTP health check endpoint
- **Primary**: Returns 200 if primary is healthy and accepting connections
- **Standby**: Returns 200 if standby is healthy and replicating

## Deployment Methods

### Method 1: Terraform Deployment (Recommended for Production)

The `terraform-examples/` directory contains complete Infrastructure as Code configuration:

```bash
cd terraform-examples/

# Configure your deployment
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars

# Deploy infrastructure
terraform init
terraform plan
terraform apply
```

**What Terraform Creates**:
- 2 Compute Engine instances with PostgreSQL HA setup
- Load balancers (HTTP for monitoring, TCP for database connections)
- GCS bucket with lifecycle policies for backups
- Firewall rules and security configurations
- Service accounts with minimal permissions
- Optional DNS zone and monitoring alerts

### Method 2: Manual gcloud Deployment

```bash
#!/bin/bash
# Complete GCP PostgreSQL HA deployment script

PROJECT_ID="your-project-id"
ZONE="us-central1-a"
PRIMARY_NAME="postgresql-primary"
STANDBY_NAME="postgresql-standby"

# Create GCS bucket for backups
gsutil mb -p "$PROJECT_ID" "gs://${PROJECT_ID}-postgresql-backups"

# Create primary instance
gcloud compute instances create $PRIMARY_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=n2-standard-2 \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=01-pgsql_setup-primary-gcp.sh \
  --metadata=backup-bucket="${PROJECT_ID}-postgresql-backups" \
  --scopes=cloud-platform \
  --tags=postgresql-ha

# Wait for primary to get IP
sleep 30
PRIMARY_IP=$(gcloud compute instances describe $PRIMARY_NAME \
  --zone=$ZONE --format="value(networkInterfaces[0].networkIP)")

# Update primary with standby IP metadata (will be updated after standby creation)
echo "Primary IP: $PRIMARY_IP"

# Create standby instance
gcloud compute instances create $STANDBY_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=n2-standard-2 \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=02-pgsql_setup-standby-gcp.sh \
  --metadata=primary-ip="$PRIMARY_IP" \
  --scopes=cloud-platform \
  --tags=postgresql-ha

# Get standby IP and update primary metadata
STANDBY_IP=$(gcloud compute instances describe $STANDBY_NAME \
  --zone=$ZONE --format="value(networkInterfaces[0].networkIP)")

gcloud compute instances add-metadata $PRIMARY_NAME \
  --zone=$ZONE --metadata=standby-ip="$STANDBY_IP"

echo "Deployment initiated:"
echo "Primary: $PRIMARY_IP"  
echo "Standby: $STANDBY_IP"
echo ""
echo "Monitor deployment:"
echo "gcloud compute ssh $PRIMARY_NAME --zone=$ZONE --command='tail -f /var/log/user-data.log'"
```

### Method 3: Individual Script Execution

```bash
# On primary instance
sudo ./01-pgsql_setup-primary-gcp.sh 10.0.1.10 10.0.1.11

# On standby instance (after primary completes)
sudo ./02-pgsql_setup-standby-gcp.sh 10.0.1.10 10.0.1.11
```

## GCP-Specific Features

### Automatic IP Discovery
The scripts can automatically detect IP addresses through multiple methods:

1. **Instance Metadata**: Reading current instance's network interface
2. **Instance Attributes**: Custom metadata set on instances
3. **Zone Discovery**: Finding peer instances by name patterns
4. **Health Check Waiting**: Standby waits for primary to be ready

### Google Cloud Storage Integration

```bash
# Automatic GCS bucket creation
PROJECT_ID=$(curl -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)
BUCKET_NAME="${PROJECT_ID}-postgresql-backups"

# Lifecycle policy for cost optimization
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 30}
    },
    {
      "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
      "condition": {"age": 7}
    }
  ]
}
```

### Firewall Rules Automation
Scripts automatically create necessary firewall rules:

```bash
# PostgreSQL communication
gcloud compute firewall-rules create postgresql-ha-5432 \
  --allow tcp:5432 \
  --source-ranges="PRIMARY_IP/32,STANDBY_IP/32"

# PgBouncer communication  
gcloud compute firewall-rules create postgresql-ha-6432 \
  --allow tcp:6432 \
  --source-ranges="PRIMARY_IP/32,STANDBY_IP/32"

# Health check endpoint
gcloud compute firewall-rules create postgresql-health-8080 \
  --allow tcp:8080
```

### Health Check Endpoints
Built-in health check endpoints for GCP Load Balancers:

- **Port 8080**: HTTP health check endpoint
- **Primary**: Returns 200 if primary is healthy and accepting connections
- **Standby**: Returns 200 if standby is healthy and replicating

## Deployment Methods

### Method 1: Terraform Deployment (Recommended for Production)

The `terraform-examples/` directory contains complete Infrastructure as Code configuration:

```bash
cd terraform-examples/

# Configure your deployment
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars

# Deploy infrastructure
terraform init
terraform plan
terraform apply
```

**What Terraform Creates**:
- 2 Compute Engine instances with PostgreSQL HA setup
- Load balancers (HTTP for monitoring, TCP for database connections)
- GCS bucket with lifecycle policies for backups
- Firewall rules and security configurations
- Service accounts with minimal permissions
- Optional DNS zone and monitoring alerts

### Method 2: Manual gcloud Deployment

```bash
#!/bin/bash
# Complete GCP PostgreSQL HA deployment script

PROJECT_ID="your-project-id"
ZONE="us-central1-a"
PRIMARY_NAME="postgresql-primary"
STANDBY_NAME="postgresql-standby"

# Create GCS bucket for backups
gsutil mb -p "$PROJECT_ID" "gs://${PROJECT_ID}-postgresql-backups"

# Create primary instance
gcloud compute instances create $PRIMARY_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=n2-standard-2 \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=01-pgsql_setup-primary-gcp.sh \
  --metadata=backup-bucket="${PROJECT_ID}-postgresql-backups" \
  --scopes=cloud-platform \
  --tags=postgresql-ha

# Wait for primary to get IP
sleep 30
PRIMARY_IP=$(gcloud compute instances describe $PRIMARY_NAME \
  --zone=$ZONE --format="value(networkInterfaces[0].networkIP)")

# Update primary with standby IP metadata (will be updated after standby creation)
echo "Primary IP: $PRIMARY_IP"

# Create standby instance
gcloud compute instances create $STANDBY_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=n2-standard-2 \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=02-pgsql_setup-standby-gcp.sh \
  --metadata=primary-ip="$PRIMARY_IP" \
  --scopes=cloud-platform \
  --tags=postgresql-ha

# Get standby IP and update primary metadata
STANDBY_IP=$(gcloud compute instances describe $STANDBY_NAME \
  --zone=$ZONE --format="value(networkInterfaces[0].networkIP)")

gcloud compute instances add-metadata $PRIMARY_NAME \
  --zone=$ZONE --metadata=standby-ip="$STANDBY_IP"

echo "Deployment initiated:"
echo "Primary: $PRIMARY_IP"  
echo "Standby: $STANDBY_IP"
echo ""
echo "Monitor deployment:"
echo "gcloud compute ssh $PRIMARY_NAME --zone=$ZONE --command='tail -f /var/log/user-data.log'"
```

### Method 3: Individual Script Execution

```bash
# On primary instance
sudo ./01-pgsql_setup-primary-gcp.sh 10.0.1.10 10.0.1.11

# On standby instance (after primary completes)
sudo ./02-pgsql_setup-standby-gcp.sh 10.0.1.10 10.0.1.11
```

## GCP-Specific Features

### Automatic IP Discovery
The scripts can automatically detect IP addresses through multiple methods:

1. **Instance Metadata**: Reading current instance's network interface
2. **Instance Attributes**: Custom metadata set on instances
3. **Zone Discovery**: Finding peer instances by name patterns
4. **Health Check Waiting**: Standby waits for primary to be ready

### Google Cloud Storage Integration

```bash
# Automatic GCS bucket creation
PROJECT_ID=$(curl -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)
BUCKET_NAME="${PROJECT_ID}-postgresql-backups"

# Lifecycle policy for cost optimization
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 30}
    },
    {
      "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
      "condition": {"age": 7}
    }
  ]
}
```

### Firewall Rules Automation
Scripts automatically create necessary firewall rules:

```bash
# PostgreSQL communication
gcloud compute firewall-rules create postgresql-ha-5432 \
  --allow tcp:5432 \
  --source-ranges="PRIMARY_IP/32,STANDBY_IP/32"

# PgBouncer communication  
gcloud compute firewall-rules create postgresql-ha-6432 \
  --allow tcp:6432 \
  --source-ranges="PRIMARY_IP/32,STANDBY_IP/32"

# Health check endpoint
gcloud compute firewall-rules create postgresql-health-8080 \
  --allow tcp:8080
```

### Health Check Endpoints
Built-in health check endpoints for GCP Load Balancers:

- **Port 8080**: HTTP health check endpoint
- **Primary**: Returns 200 if primary is healthy and accepting connections
- **Standby**: Returns 200 if standby is healthy and replicating

## Deployment Methods

### Method 1: Terraform Deployment (Recommended for Production)

The `terraform-examples/` directory contains complete Infrastructure as Code configuration:

```bash
cd terraform-examples/

# Configure your deployment
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars

# Deploy infrastructure
terraform init
terraform plan
terraform apply
```

**What Terraform Creates**:
- 2 Compute Engine instances with PostgreSQL HA setup
- Load balancers (HTTP for monitoring, TCP for database connections)
- GCS bucket with lifecycle policies for backups
- Firewall rules and security configurations
- Service accounts with minimal permissions
- Optional DNS zone and monitoring alerts

### Method 2: Manual gcloud Deployment

```bash
#!/bin/bash
# Complete GCP PostgreSQL HA deployment script

PROJECT_ID="your-project-id"
ZONE="us-central1-a"
PRIMARY_NAME="postgresql-primary"
STANDBY_NAME="postgresql-standby"

# Create GCS bucket for backups
gsutil mb -p "$PROJECT_ID" "gs://${PROJECT_ID}-postgresql-backups"

# Create primary instance
gcloud compute instances create $PRIMARY_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=n2-standard-2 \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=01-pgsql_setup-primary-gcp.sh \
  --metadata=backup-bucket="${PROJECT_ID}-postgresql-backups" \
  --scopes=cloud-platform \
  --tags=postgresql-ha

# Wait for primary to get IP
sleep 30
PRIMARY_IP=$(gcloud compute instances describe $PRIMARY_NAME \
  --zone=$ZONE --format="value(networkInterfaces[0].networkIP)")

# Update primary with standby IP metadata (will be updated after standby creation)
echo "Primary IP: $PRIMARY_IP"

# Create standby instance
gcloud compute instances create $STANDBY_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=n2-standard-2 \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=02-pgsql_setup-standby-gcp.sh \
  --metadata=primary-ip="$PRIMARY_IP" \
  --scopes=cloud-platform \
  --tags=postgresql-ha

# Get standby IP and update primary metadata
STANDBY_IP=$(gcloud compute instances describe $STANDBY_NAME \
  --zone=$ZONE --format="value(networkInterfaces[0].networkIP)")

gcloud compute instances add-metadata $PRIMARY_NAME \
  --zone=$ZONE --metadata=standby-ip="$STANDBY_IP"

echo "Deployment initiated:"
echo "Primary: $PRIMARY_IP"  
echo "Standby: $STANDBY_IP"
echo ""
echo "Monitor deployment:"
echo "gcloud compute ssh $PRIMARY_NAME --zone=$ZONE --command='tail -f /var/log/user-data.log'"
```

### Method 3: Individual Script Execution

```bash
# On primary instance
sudo ./01-pgsql_setup-primary-gcp.sh 10.0.1.10 10.0.1.11

# On standby instance (after primary completes)
sudo ./02-pgsql_setup-standby-gcp.sh 10.0.1.10 10.0.1.11
```

## GCP-Specific Features

### Automatic IP Discovery
The scripts can automatically detect IP addresses through multiple methods:

1. **Instance Metadata**: Reading current instance's network interface
2. **Instance Attributes**: Custom metadata set on instances
3. **Zone Discovery**: Finding peer instances by name patterns
4. **Health Check Waiting**: Standby waits for primary to be ready

### Google Cloud Storage Integration

```bash
# Automatic GCS bucket creation
PROJECT_ID=$(curl -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)
BUCKET_NAME="${PROJECT_ID}-postgresql-backups"

# Lifecycle policy for cost optimization
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 30}
    },
    {
      "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
      "condition": {"age": 7}
    }
  ]
}
```

### Firewall Rules Automation
Scripts automatically create necessary firewall rules:

```bash
# PostgreSQL communication
gcloud compute firewall-rules create postgresql-ha-5432 \
  --allow tcp:5432 \
  --source-ranges="PRIMARY_IP/32,STANDBY_IP/32"

# PgBouncer communication  
gcloud compute firewall-rules create postgresql-ha-6432 \
  --allow tcp:6432 \
  --source-ranges="PRIMARY_IP/32,STANDBY_IP/32"

# Health check endpoint
gcloud compute firewall-rules create postgresql-health-8080 \
  --allow tcp:8080
```

### Health Check Endpoints
Built-in health check endpoints for GCP Load Balancers:

- **Port 8080**: HTTP health check endpoint
- **Primary**: Returns 200 if primary is healthy and accepting connections
- **Standby**: Returns 200 if standby is healthy and replicating

## Deployment Methods

### Method 1: Terraform Deployment (Recommended for Production)

The `terraform-examples/` directory contains complete Infrastructure as Code configuration:

```bash
cd terraform-examples/

# Configure your deployment
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars

# Deploy infrastructure
terraform init
terraform plan
terraform apply
```

**What Terraform Creates**:
- 2 Compute Engine instances with PostgreSQL HA setup
- Load balancers (HTTP for monitoring, TCP for database connections)
- GCS bucket with lifecycle policies for backups
- Firewall rules and security configurations
- Service accounts with minimal permissions
- Optional DNS zone and monitoring alerts

### Method 2: Manual gcloud Deployment

```bash
#!/bin/bash
# Complete GCP PostgreSQL HA deployment script

PROJECT_ID="your-project-id"
ZONE="us-central1-a"
PRIMARY_NAME="postgresql-primary"
STANDBY_NAME="postgresql-standby"

# Create GCS bucket for backups
gsutil mb -p "$PROJECT_ID" "gs://${PROJECT_ID}-postgresql-backups"

# Create primary instance
gcloud compute instances create $PRIMARY_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=n2-standard-2 \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=01-pgsql_setup-primary-gcp.sh \
  --metadata=backup-bucket="${PROJECT_ID}-postgresql-backups" \
  --scopes=cloud-platform \
  --tags=postgresql-ha

# Wait for primary to get IP
sleep 30
PRIMARY_IP=$(gcloud compute instances describe $PRIMARY_NAME \
  --zone=$ZONE --format="value(networkInterfaces[0].networkIP)")

# Update primary with standby IP metadata (will be updated after standby creation)
echo "Primary IP: $PRIMARY_IP"

# Create standby instance
gcloud compute instances create $STANDBY_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --machine-type=n2-standard-2 \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --metadata-from-file startup-script=02-pgsql_setup-standby-gcp.sh \
  --metadata=primary-ip="$PRIMARY_IP" \
  --scopes=cloud-platform \
  --tags=postgresql-ha

# Get standby IP and update primary metadata
STANDBY_IP=$(gcloud compute instances describe $STANDBY_NAME \
  --zone=$ZONE --format="value(networkInterfaces[0].networkIP)")

gcloud compute instances add-metadata $PRIMARY_NAME \
  --zone=$ZONE --metadata=standby-ip="$STANDBY_IP"

echo "Deployment initiated:"
echo "Primary: $PRIMARY_IP"  
echo "Standby: $STANDBY_IP"
echo ""
echo "Monitor deployment:"
echo "gcloud compute ssh $PRIMARY_NAME --zone=$ZONE --command='tail -f /var/log/user-data.log'"
```

### Method 3: Individual Script Execution

```bash
# On primary instance
sudo ./01-pgsql_setup-primary-gcp.sh 10.0.1.10 10.0.1.11

# On standby instance (after primary completes)
sudo ./02-pgsql_setup-standby-gcp.sh 10.0.1.10 10.0.1.11
```

## Monitoring and Management

### Check Deployment Status

```bash
# SSH to instances and check logs
gcloud compute ssh postgresql-primary --zone=us-central1-a
sudo tail -f /var/log/user-data.log
sudo tail -f /var/log/postgresql-setup-complete.log

# Check health endpoints
curl http://PRIMARY_IP:8080
curl http://STANDBY_IP:8080
```

### Verify Cluster Status

```bash
# On either instance
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show

# Expected output:
# ID | Name    | Role    | Status    | Upstream | Location
#----+---------+---------+-----------+----------+---------
# 1  | primary | primary | * running |          | default
# 2  | standby | standby |   running | primary  | default
```

### Monitor Backups

```bash
# Check local backups
ls -la /var/backups/postgresql/base/
ls -la /var/backups/postgresql/logical/

# Check GCS backups
gsutil ls gs://PROJECT_ID-postgresql-backups/
```

## Load Balancer Setup

### Create HTTP(S) Load Balancer

```bash
# Create health check
gcloud compute health-checks create http postgresql-health \
  --port=8080 \
  --request-path=/ \
  --check-interval=30s \
  --timeout=10s

# Create backend service
gcloud compute backend-services create postgresql-backend \
  --protocol=HTTP \
  --health-checks=postgresql-health \
  --global

# Add instances to backend
gcloud compute backend-services add-backend postgresql-backend \
  --instance-group=postgresql-ig \
  --instance-group-zone=us-central1-a \
  --global
```

### Create TCP Load Balancer for Database Connections

```bash
# Create health check for TCP
gcloud compute health-checks create tcp postgresql-tcp-health \
  --port=5432

# Create backend service for TCP
gcloud compute backend-services create postgresql-tcp-backend \
  --protocol=TCP \
  --health-checks=postgresql-tcp-health \
  --region=us-central1

# Create forwarding rule
gcloud compute forwarding-rules create postgresql-tcp-lb \
  --region=us-central1 \
  --ports=5432 \
  --backend-service=postgresql-tcp-backend
```

## Security Configuration

### IAM Permissions Required

```json
{
  "bindings": [
    {
      "role": "roles/compute.instanceAdmin.v1",
      "members": ["serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com"]
    },
    {
      "role": "roles/storage.admin", 
      "members": ["serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com"]
    },
    {
      "role": "roles/compute.securityAdmin",
      "members": ["serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com"]
    }
  ]
}
```

### Network Security

```bash
# Restrict PostgreSQL access to specific networks
gcloud compute firewall-rules create postgresql-restricted \
  --allow tcp:5432 \
  --source-ranges="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" \
  --target-tags=postgresql-ha

# Allow health checks from GCP health check ranges
gcloud compute firewall-rules create allow-health-checks \
  --allow tcp:8080 \
  --source-ranges="35.191.0.0/16,130.211.0.0/22" \
  --target-tags=postgresql-ha
```

## Troubleshooting

### Common Issues

1. **Instance metadata not accessible**
   ```bash
   # Check metadata service
   curl -H "Metadata-Flavor: Google" \
     http://metadata.google.internal/computeMetadata/v1/instance/
   ```

2. **Firewall rules blocking connections**
   ```bash
   # List firewall rules
   gcloud compute firewall-rules list --filter="name~postgresql"
   ```

3. **GCS permissions issues**
   ```bash
   # Check service account permissions
   gcloud projects get-iam-policy PROJECT_ID
   ```

4. **Health check failures**
   ```bash
   # Test health endpoint locally
   curl http://localhost:8080
   
   # Check service status
   sudo systemctl status postgresql-health
   ```

### Logs and Monitoring

```bash
# PostgreSQL logs
sudo tail -f /var/log/postgresql/postgresql-17-main.log

# Repmgr logs  
sudo tail -f /var/log/postgresql/repmgrd.log

# Setup logs
sudo tail -f /var/log/user-data.log
sudo tail -f /var/log/postgresql-setup-complete.log

# Health check service logs
sudo journalctl -u postgresql-health -f
```

## Cost Optimization

### Instance Recommendations

- **Development**: e2-standard-2 (2 vCPU, 8GB RAM)
- **Production**: n2-standard-4 (4 vCPU, 16GB RAM) 
- **High Performance**: c2-standard-8 (8 vCPU, 32GB RAM)

### Storage Optimization

- **Boot Disk**: 20GB pd-standard (sufficient for OS and PostgreSQL)
- **Data Disk**: pd-ssd for better IOPS performance
- **Backup Storage**: Use GCS lifecycle policies to move to Coldline/Archive

### Backup Cost Management

```bash
# Set lifecycle policy on backup bucket
gsutil lifecycle set lifecycle-config.json gs://PROJECT-postgresql-backups

# lifecycle-config.json
{
  "rule": [
    {
      "action": {"type": "SetStorageClass", "storageClass": "NEARLINE"},
      "condition": {"age": 7}
    },
    {
      "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"}, 
      "condition": {"age": 30}
    },
    {
      "action": {"type": "Delete"},
      "condition": {"age": 90}
    }
  ]
}
```

This GCP-optimized PostgreSQL HA setup provides a production-ready, cloud-native database solution with automated deployment, integrated backups, and comprehensive monitoring capabilities.

## GCP Architecture & Data Flow

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           GCP PostgreSQL HA Architecture                           │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌─────────────────┐                                                               │
│  │   Applications  │                                                               │
│  │   & Clients     │                                                               │
│  └─────────┬───────┘                                                               │
│            │                                                                       │
│            ▼                                                                       │
│  ┌─────────────────┐           ┌─────────────────┐                                │
│  │ Cloud Load      │           │ Internal TCP    │                                │
│  │ Balancer (HTTP) │           │ Load Balancer   │                                │
│  │ Port: 80/443    │           │ Port: 5432/6432 │                                │
│  └─────────┬───────┘           └─────────┬───────┘                                │
│            │                             │                                       │
│            ▼                             ▼                                       │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                        Compute Engine Instances                             │ │
│  │                                                                             │ │
│  │  ┌─────────────────┐    Streaming     ┌─────────────────┐                  │ │
│  │  │   Primary VM    │   Replication    │   Standby VM    │                  │ │
│  │  │ 10.0.1.10       │ ───────────────► │ 10.0.1.11       │                  │ │
│  │  │                 │                  │                 │                  │ │
│  │  │ ┌─────────────┐ │                  │ ┌─────────────┐ │                  │ │
│  │  │ │PostgreSQL 17│ │                  │ │PostgreSQL 17│ │                  │ │
│  │  │ │Port: 5432   │ │                  │ │Port: 5432   │ │                  │ │
│  │  │ └─────────────┘ │                  │ └─────────────┘ │                  │ │
│  │  │ ┌─────────────┐ │                  │ ┌─────────────┐ │                  │ │
│  │  │ │ repmgrd     │ │◄─── Monitoring ──┤ │ repmgrd     │ │                  │ │
│  │  │ │(failover)   │ │                  │ │(monitoring) │ │                  │ │
│  │  │ └─────────────┘ │                  │ └─────────────┘ │                  │ │
│  │  │ ┌─────────────┐ │                  │ ┌─────────────┐ │                  │ │
│  │  │ │ PgBouncer   │ │                  │ │ PgBouncer   │ │                  │ │
│  │  │ │Port: 6432   │ │                  │ │Port: 6432   │ │                  │ │
│  │  │ └─────────────┘ │                  │ └─────────────┘ │                  │ │
│  │  │ ┌─────────────┐ │                  │ ┌─────────────┐ │                  │ │
│  │  │ │Health Check │ │                  │ │Health Check │ │                  │ │
│  │  │ │Port: 8080   │ │                  │ │Port: 8080   │ │                  │ │
│  │  │ └─────────────┘ │                  │ └─────────────┘ │                  │ │
│  │  └─────────────────┘                  └─────────────────┘                  │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
│                              │                                                   │
│                              ▼ WAL Archive & Backups                            │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                        Google Cloud Storage                                 │ │
│  │                     gs://PROJECT-postgresql-backups                        │ │
│  │                                                                             │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │ │
│  │  │Base Backups │  │Logical      │  │WAL Archive  │  │Automated    │       │ │
│  │  │(Physical)   │  │Backups      │  │Files        │  │Lifecycle    │       │ │
│  │  │Daily        │  │Every 6H     │  │Continuous   │  │Management   │       │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘       │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow Patterns

#### 1. Read-Write Operations (Primary Path)

```
┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ Application │────│ TCP Load         │────│ Primary VM      │────│ PostgreSQL      │
│             │    │ Balancer         │    │ 10.0.1.10       │    │ Port: 5432      │
│             │    │ Port: 5432       │    │                 │    │                 │
│             │◄───│                  │◄───│ PgBouncer       │◄───│ Write + Read    │
│             │    │                  │    │ Port: 6432      │    │ Operations      │
└─────────────┘    └──────────────────┘    └─────────────────┘    └─────────────────┘
                            │                        │
                            │                        ▼
                            │               ┌─────────────────┐
                            │               │ WAL Streaming   │
                            │               │ to Standby      │
                            │               └─────────┬───────┘
                            │                         │
                            ▼                         ▼
                   ┌──────────────────┐    ┌─────────────────┐
                   │ Health Check     │    │ Standby VM      │
                   │ Endpoint         │    │ 10.0.1.11       │
                   │ Port: 8080       │    │ (Replicating)   │
                   └──────────────────┘    └─────────────────┘
```

#### 2. Read-Only Operations (Standby Path - Optional)

```
┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ Read-Only   │────│ TCP Load         │────│ Standby VM      │────│ PostgreSQL      │
│ Application │    │ Balancer         │    │ 10.0.1.11       │    │ Port: 5432      │
│             │    │ Port: 5433       │    │                 │    │                 │
│             │◄───│ (Separate Port)  │◄───│ PgBouncer       │◄───│ Read Operations │
│             │    │                  │    │ Port: 6432      │    │ Only            │
└─────────────┘    └──────────────────┘    └─────────────────┘    └─────────────────┘
```

#### 3. Failover Scenario Data Flow

```
┌─────────────┐    ┌──────────────────┐    
│ Application │────│ TCP Load         │    ┌─────────────────┐
│             │    │ Balancer         │    │ Primary VM      │
│             │    │                  │    │ 10.0.1.10       │
│             │    │ (Health Check    │    │ ❌ FAILED       │
│             │    │  Detects Failure)│    └─────────────────┘
│             │    │                  │              │
│             │    │                  │              │ repmgr detects failure
│             │    │                  │              ▼
│             │    │                  │    ┌─────────────────┐
│             │    │                  │────│ Standby VM      │
│             │◄───│ Routes Traffic   │◄───│ 10.0.1.11       │
│             │    │ to New Primary   │    │ 🔄 PROMOTED     │
│             │    │                  │    │ TO PRIMARY      │
└─────────────┘    └──────────────────┘    └─────────────────┘
```

### GCP Load Balancer Integration

#### HTTP(S) Load Balancer (for Health Checks & Monitoring)

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           HTTP(S) Load Balancer                                    │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌─────────────────┐                                                               │
│  │   Frontend      │  External IP: 34.102.136.180                                 │
│  │   Service       │  Ports: 80, 443                                              │
│  │                 │  SSL Termination                                              │
│  └─────────┬───────┘                                                               │
│            │                                                                       │
│            ▼                                                                       │
│  ┌─────────────────┐                                                               │
│  │   URL Map &     │  /health → Health Check Backend                              │
│  │   Routing       │  /metrics → Monitoring Backend                               │
│  │                 │  /admin → Database Admin Tools                               │
│  └─────────┬───────┘                                                               │
│            │                                                                       │
│            ▼                                                                       │
│  ┌─────────────────┐           ┌─────────────────┐                                │
│  │   Backend       │           │   Health Check  │                                │
│  │   Service       │           │   Configuration │                                │
│  │                 │           │                 │                                │
│  │ • Health Check  │◄──────────┤ • Port: 8080    │                                │
│  │ • Load Balancing│           │ • Interval: 30s │                                │
│  │ • Session       │           │ • Timeout: 10s  │                                │
│  │   Affinity      │           │ • Path: /       │                                │
│  └─────────┬───────┘           └─────────────────┘                                │
│            │                                                                       │
│            ▼                                                                       │
│  ┌─────────────────┐           ┌─────────────────┐                                │
│  │   Instance      │           │   Instance      │                                │
│  │   Group         │           │   Group         │                                │
│  │   Primary Zone  │           │   Standby Zone  │                                │
│  │   us-central1-a │           │   us-central1-b │                                │
│  └─────────────────┘           └─────────────────┘                                │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

#### TCP Load Balancer (for Database Connections)

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                            TCP Load Balancer                                       │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌─────────────────┐                                                               │
│  │   Forwarding    │  Internal IP: 10.0.0.100                                     │
│  │   Rule          │  Port: 5432 (PostgreSQL)                                     │
│  │                 │  Port: 6432 (PgBouncer)                                      │
│  └─────────┬───────┘                                                               │
│            │                                                                       │
│            ▼                                                                       │
│  ┌─────────────────┐                                                               │
│  │   Regional      │  Load Balancing Algorithm:                                   │
│  │   Backend       │  • Connection-based                                          │
│  │   Service       │  • Session Affinity: CLIENT_IP                               │
│  │                 │  • Failover Policy: Active-Standby                          │
│  └─────────┬───────┘                                                               │
│            │                                                                       │
│            ▼                                                                       │
│  ┌─────────────────┐           ┌─────────────────┐                                │
│  │   Primary       │           │   Standby       │                                │
│  │   Backend       │           │   Backend       │                                │
│  │   (Active)      │           │   (Backup)      │                                │
│  │                 │           │                 │                                │
│  │ Priority: 100   │           │ Priority: 50    │                                │
│  │ Health: ✓       │           │ Health: ✓       │                                │
│  │ Status: HEALTHY │           │ Status: BACKUP  │                                │
│  └─────────┬───────┘           └─────────┬───────┘                                │
│            │                             │                                       │
│            ▼                             ▼                                       │
│  ┌─────────────────┐           ┌─────────────────┐                                │
│  │ Primary VM      │           │ Standby VM      │                                │
│  │ 10.0.1.10:5432  │           │ 10.0.1.11:5432  │                                │
│  │ 10.0.1.10:6432  │           │ 10.0.1.11:6432  │                                │
│  └─────────────────┘           └─────────────────┘                                │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Backup Data Flow to Google Cloud Storage

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                          Backup Data Flow Architecture                             │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌─────────────────┐           ┌─────────────────┐                                │
│  │   Primary VM    │           │   Standby VM    │                                │
│  │   10.0.1.10     │           │   10.0.1.11     │                                │
│  │                 │           │                 │                                │
│  │ ┌─────────────┐ │           │ ┌─────────────┐ │                                │
│  │ │ PostgreSQL  │ │           │ │ PostgreSQL  │ │                                │
│  │ │             │ │           │ │ (Read Only) │ │                                │
│  │ └─────┬───────┘ │           │ └─────┬───────┘ │                                │
│  │       │         │           │       │         │                                │
│  │       ▼         │           │       ▼         │                                │
│  │ ┌─────────────┐ │           │ ┌─────────────┐ │                                │
│  │ │WAL Archive  │ │           │ │Offload      │ │                                │
│  │ │Local Cache  │ │           │ │Backups      │ │                                │
│  │ │             │ │           │ │             │ │                                │
│  │ └─────┬───────┘ │           │ └─────┬───────┘ │                                │
│  │       │         │           │       │         │                                │
│  └───────┼─────────┘           └───────┼─────────┘                                │
│          │                             │                                         │
│          ▼                             ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                        Backup Orchestration                                 │ │
│  │                                                                             │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │ │
│  │  │ Base Backup │  │ Logical     │  │ WAL Archive │  │ GCS Sync    │       │ │
│  │  │ (Primary)   │  │ Backup      │  │ Continuous  │  │ Service     │       │ │
│  │  │             │  │ (Standby)   │  │ (Primary)   │  │ (Both)      │       │ │
│  │  │ Daily 2AM   │  │ Every 6H    │  │ Real-time   │  │ Every 15min │       │ │
│  │  └─────┬───────┘  └─────┬───────┘  └─────┬───────┘  └─────┬───────┘       │ │
│  └────────┼──────────────────┼──────────────────┼──────────────────┼─────────────┘ │
│           │                  │                  │                  │               │
│           ▼                  ▼                  ▼                  ▼               │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                    Google Cloud Storage Bucket                              │ │
│  │                  gs://PROJECT-postgresql-backups/                          │ │
│  │                                                                             │ │
│  │  📁 primary-instance/                  📁 standby-instance/                │ │
│  │  ├── base/                             ├── logical/                        │ │
│  │  │   ├── base_backup_20241201_020000/  │   ├── repmgr_20241201_060000.dump │ │
│  │  │   ├── roles_20241201_020000.sql     │   └── app_20241201_120000.dump    │ │
│  │  │   └── tablespaces_20241201.sql      └── base/                           │ │
│  │  ├── logical/                              └── offload_backup_20241201/    │ │
│  │  │   ├── repmgr_20241201_060000.dump                                       │ │
│  │  │   └── full_cluster_20241201.sql.gz                                      │ │
│  │  └── wal-archive/                                                          │ │
│  │      ├── 000000010000000000000001.gz                                       │ │
│  │      ├── 000000010000000000000002.gz                                       │ │
│  │      └── 000000010000000000000003.gz                                       │ │
│  │                                                                             │ │
│  │  🔄 Lifecycle Management:                                                   │ │
│  │  • 7 days: Standard → Nearline                                            │ │
│  │  • 30 days: Nearline → Coldline                                           │ │
│  │  • 90 days: Delete                                                         │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Network Security and Traffic Flow

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           Network Security Architecture                             │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  🌐 Internet                                                                        │
│      │                                                                             │
│      ▼                                                                             │
│  ┌─────────────────┐                                                               │
│  │   Cloud         │  Firewall Rules:                                             │
│  │   Firewall      │  • Allow 80,443 from 0.0.0.0/0                              │
│  │   & NAT         │  • Allow 8080 from GCP Health Check ranges                  │
│  │                 │    (35.191.0.0/16, 130.211.0.0/22)                         │
│  └─────────┬───────┘                                                               │
│            │                                                                       │
│            ▼                                                                       │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                            VPC Network                                       │ │
│  │                         (default: 10.128.0.0/9)                             │ │
│  │                                                                             │ │
│  │  ┌─────────────────┐                    ┌─────────────────┐                │ │
│  │  │   Subnet A      │                    │   Subnet B      │                │ │
│  │  │   us-central1-a │                    │   us-central1-b │                │ │
│  │  │   10.0.1.0/24   │                    │   10.0.2.0/24   │                │ │
│  │  │                 │                    │                 │                │ │
│  │  │ ┌─────────────┐ │                    │ ┌─────────────┐ │                │ │
│  │  │ │Primary VM   │ │                    │ │Standby VM   │ │                │ │
│  │  │ │10.0.1.10    │ │◄──── Replication ──┤ │10.0.2.11    │ │                │ │
│  │  │ │             │ │      Port: 5432    │ │             │ │                │ │
│  │  │ │Tags:        │ │                    │ │Tags:        │ │                │ │
│  │  │ │postgresql-ha│ │                    │ │postgresql-ha│ │                │ │
│  │  │ └─────────────┘ │                    │ └─────────────┘ │                │ │
│  │  └─────────────────┘                    └─────────────────┘                │ │
│  │                                                                             │ │
│  │  Firewall Rules Applied:                                                    │ │
│  │  • postgresql-ha-5432: Allow 5432 between postgresql-ha tagged instances   │ │
│  │  • postgresql-ha-6432: Allow 6432 between postgresql-ha tagged instances   │ │
│  │  • postgresql-health-8080: Allow 8080 for health checks                    │ │
│  │  • postgresql-restricted: Allow 5432 from private networks only            │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                   │
│            │                                                                     │
│            ▼                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                      Cloud Storage (Backup Egress)                          │ │
│  │                   Private Google Access Enabled                             │ │
│  │                                                                             │ │
│  │  • Backup traffic uses Google's private network                             │ │
│  │  • No external IP required for GCS access                                   │ │
│  │  • Encryption in transit (HTTPS/TLS)                                        │ │
│  │  • IAM-based access control                                                 │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
```

### Health Check and Monitoring Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        Health Check & Monitoring Flow                              │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌─────────────────┐                                                               │
│  │ GCP Load        │  Every 30 seconds:                                           │
│  │ Balancer        │  GET http://INSTANCE_IP:8080/                                │
│  │ Health Check    │                                                               │
│  └─────────┬───────┘                                                               │
│            │                                                                       │
│            ▼                                                                       │
│  ┌─────────────────┐           ┌─────────────────┐                                │
│  │   Primary VM    │           │   Standby VM    │                                │
│  │   Health Check  │           │   Health Check  │                                │
│  │   Service       │           │   Service       │                                │
│  │                 │           │                 │                                │
│  │ ┌─────────────┐ │           │ ┌─────────────┐ │                                │
│  │ │HTTP Server  │ │           │ │HTTP Server  │ │                                │
│  │ │Port: 8080   │ │           │ │Port: 8080   │ │                                │
│  │ │             │ │           │ │             │ │                                │
│  │ │ Check:      │ │           │ │ Check:      │ │                                │
│  │ │• PostgreSQL │ │           │ │• PostgreSQL │ │                                │
│  │ │• repmgr     │ │           │ │• Replication│ │                                │
│  │ │• Connections│ │           │ │• Lag Status │ │                                │
│  │ └─────┬───────┘ │           │ └─────┬───────┘ │                                │
│  └───────┼─────────┘           └───────┼─────────┘                                │
│          │                             │                                         │
│          ▼                             ▼                                         │
│  ┌──────────────────────────────────────────────────────────────────────────────┐ │
│  │                        Health Check Responses                                │ │
│  │                                                                              │ │
│  │  Primary Response:                 Standby Response:                        │ │
│  │  HTTP/1.1 200 OK                   HTTP/1.1 200 OK                          │ │
│  │  Content-Type: text/plain          Content-Type: text/plain                 │ │
│  │  PostgreSQL Primary: Healthy       PostgreSQL Standby: Healthy              │ │
│  │                                                                              │ │
│  │  Failure Scenarios:                Failure Scenarios:                       │ │
│  │  HTTP/1.1 503 Service Unavailable  HTTP/1.1 503 Service Unavailable        │ │
│  │  PostgreSQL Primary: Unhealthy     PostgreSQL Standby: Unhealthy            │ │
│  └──────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                   │
│            │                                                                     │
│            ▼                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                      Load Balancer Decision Engine                           │ │
│  │                                                                             │ │
│  │  Decision Matrix:                                                           │ │
│  │  • Primary Healthy + Standby Healthy → Route to Primary                    │ │
│  │  • Primary Unhealthy + Standby Healthy → Route to Standby (if promoted)    │ │
│  │  • Primary Healthy + Standby Unhealthy → Route to Primary                  │ │
│  │  • Both Unhealthy → Return 503 to clients                                  │ │
│  │                                                                             │ │
│  │  Failover Trigger:                                                          │ │
│  │  1. Health check detects primary failure                                   │ │
│  │  2. repmgr promotes standby to primary                                     │ │
│  │  3. Load balancer updates routing based on new health check results        │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────┘
```
