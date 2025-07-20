# PostgreSQL HA Setup for Google Cloud Engine

This directory contains example scripts and configurations for deploying PostgreSQL HA clusters on Google Cloud Engine using user-data scripts during instance provisioning.

## GCE-Specific Features

### Automatic IP Detection
- Uses GCE metadata service to detect instance IPs
- Automatically discovers peer instances in the same zone
- Supports instance attributes for manual IP configuration

### Cloud Integration
- Automatic firewall rule creation
- Google Cloud Storage backup integration
- Health check endpoints for load balancers
- Instance metadata for status tracking

### Zero-Touch Deployment
- Runs during instance startup via user-data
- No manual intervention required
- Automatic peer discovery and configuration

## Deployment Methods

### Method 1: Terraform Deployment
```hcl
# terraform/main.tf
resource "google_compute_instance" "postgresql_primary" {
  name         = "postgresql-primary"
  machine_type = "n2-standard-2"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts"
      size  = 50
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    standby-ip = google_compute_instance.postgresql_standby.network_interface[0].network_ip
  }

  metadata_startup_script = file("../gce-user-data-examples/primary-user-data.sh")

  service_account {
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_instance" "postgresql_standby" {
  name         = "postgresql-standby"
  machine_type = "n2-standard-2"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts"
      size  = 50
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    primary-ip = google_compute_instance.postgresql_primary.network_interface[0].network_ip
  }

  metadata_startup_script = file("../gce-user-data-examples/standby-user-data.sh")

  service_account {
    scopes = ["cloud-platform"]
  }

  depends_on = [google_compute_instance.postgresql_primary]
}
```

### Method 2: gcloud CLI Deployment
```bash
# Create primary instance
gcloud compute instances create postgresql-primary \
  --zone=us-central1-a \
  --machine-type=n2-standard-2 \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --metadata-from-file startup-script=primary-user-data.sh \
  --metadata=standby-ip=10.128.0.11 \
  --scopes=cloud-platform

# Create standby instance
gcloud compute instances create postgresql-standby \
  --zone=us-central1-a \
  --machine-type=n2-standard-2 \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --metadata-from-file startup-script=standby-user-data.sh \
  --metadata=primary-ip=10.128.0.10 \
  --scopes=cloud-platform
```

### Method 3: Instance Templates (for Managed Instance Groups)
```bash
# Create instance template
gcloud compute instance-templates create postgresql-primary-template \
  --machine-type=n2-standard-2 \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --metadata-from-file startup-script=primary-user-data.sh \
  --scopes=cloud-platform
```

## Configuration Options

### Instance Metadata Keys
- `primary-ip`: IP address of the primary instance
- `standby-ip`: IP address of the standby instance  
- `backup-bucket`: GCS bucket name for backups
- `postgresql-primary-ready`: Set by primary when setup complete
- `postgresql-standby-ready`: Set by standby when setup complete

### Required IAM Permissions
```json
{
  "bindings": [
    {
      "role": "roles/compute.instanceAdmin.v1",
      "members": ["serviceAccount:SERVICE_ACCOUNT_EMAIL"]
    },
    {
      "role": "roles/storage.admin",
      "members": ["serviceAccount:SERVICE_ACCOUNT_EMAIL"]
    }
  ]
}
```

## Monitoring Setup

### Health Check Configuration
```bash
# Create health check
gcloud compute health-checks create http postgresql-health \
  --port=8080 \
  --request-path=/ \
  --check-interval=30s \
  --timeout=10s \
  --unhealthy-threshold=3 \
  --healthy-threshold=2
```

### Load Balancer Setup
```bash
# Create load balancer for read-only queries
gcloud compute backend-services create postgresql-backend \
  --protocol=TCP \
  --health-checks=postgresql-health \
  --global
```

## Backup Integration

### GCS Bucket Setup
```bash
# Create backup bucket
gsutil mb gs://PROJECT_ID-postgresql-backups

# Set lifecycle policy
gsutil lifecycle set backup-lifecycle.json gs://PROJECT_ID-postgresql-backups
```

### Backup Lifecycle Policy
```json
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

## Troubleshooting

### Check Setup Progress
```bash
# SSH to instance and check logs
gcloud compute ssh postgresql-primary --zone=us-central1-a
sudo tail -f /var/log/user-data.log
sudo tail -f /var/log/postgresql-setup-complete.log
```

### Verify Cluster Status
```bash
# On primary instance
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show

# Check health endpoints
curl http://INSTANCE_IP:8080
```

### Common Issues
1. **Firewall rules**: Ensure ports 5432 and 6432 are accessible between instances
2. **Service account permissions**: Verify compute and storage permissions
3. **Network connectivity**: Check VPC and subnet configuration
4. **Startup script execution**: Monitor /var/log/user-data.log for errors

This GCE-optimized setup provides a production-ready PostgreSQL HA cluster with automated deployment, cloud integration, and monitoring capabilities.
