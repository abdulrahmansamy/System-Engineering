# High-Availability PostgreSQL on GCP with pg_auto_failover: A Comprehensive Plan

This document outlines the design, implementation, and operational procedures for a production-ready, fully automated High Availability (HA) PostgreSQL 17+ cluster on Google Cloud Platform (GCP). The core of this design is `pg_auto_failover`, configured to achieve seamless, zero-intervention failover and, crucially, automated failback to the original primary node.

## Table of Contents
1.  [System Architecture Design](#1-system-architecture-design)
2.  [Infrastructure as Code (IaC) Plan (Terraform)](#2-infrastructure-as-code-iac-plan-terraform)
3.  [Configuration & Automation Plan (Bash)](#3-configuration--automation-plan-bash-script)
4.  [Operational Playbooks](#4-operational-playbooks)
5.  [Validation & Testing Framework](#5-validation--testing-framework)

---

## 1. System Architecture Design

This section details the overall architecture, component interaction, and data flow for the HA PostgreSQL cluster.

### 1.1. System Diagram

The architecture is designed for resilience, with components distributed across multiple zones to prevent a single point of failure.

```
                               +-------------------------------------------------+
                               |              Google Cloud Platform (GCP)          |
                               |                                                 |
                               |  +-----------------------+                      |
                               |  |   Client Applications |                      |
                               |  +-----------+-----------+                      |
                               |              |                                  |
                               |              | (TCP: 5432)                      |
                               |              |                                  |
                               |  +-----------v-----------+                      |
                               |  |  Internal TCP/UDP LB  |                      |
                               |  | (Forwarding Rule)     |                      |
                               |  +-----------+-----------+                      |
                               |              |                                  |
   +---------------------------+--------------+----------------------------------+
   |           |                              |                                  |
   |  +--------v--------+            +--------v--------+            +------------v----------+
   |  |    Zone A       |            |    Zone B       |            |       Zone C          |
   |  | +-------------+ |            | +-------------+ |            | +-------------------+ |
   |  | | GCE Instance| |            | | GCE Instance| |            | | GCE Instance      | |
   |  | |  (Primary)  | |<--Rep/Mon-->| |  (Standby)  | |<--Rep/Mon-->| |  (Monitor Node)   | |
   |  | +------+------+ |            | +------+------+ |            | +-------------------+ |
   |  |        |        |            |        |        |            |                     |
   |  | +------v------+ |            | +------v------+ |            |                     |
   |  | | PgBouncer   | |            | | PgBouncer   | |            |                     |
   |  | +------+------+ |            | +------+------+ |            |                     |
   |  |        |        |            |        |        |            |                     |
   |  | +------v------+ |            | +------v------+ |            |                     |
   |  | | PostgreSQL  | |            | | PostgreSQL  | |            |                     |
   |  | +-------------+ |            | +-------------+ |            |                     |
   +---------------------+            +-----------------+            +---------------------+
```

### 1.2. Component Overview

*   **Client Applications:** Connect to the database via a single, stable endpoint provided by the GCP Internal Load Balancer.
*   **GCP Internal Load Balancer (ILB):** Distributes TCP traffic on port 5432 to the available PgBouncer instances on the PostgreSQL nodes. Its health check probes PgBouncer to ensure it only forwards traffic to healthy, active nodes.
*   **GCE Instances:**
    *   **Primary Node (Zone A):** The active PostgreSQL instance handling read/write operations.
    *   **Standby Node (Zone B):** A hot standby, continuously replicating from the primary via synchronous streaming replication to ensure zero data loss (RPO=0). It's ready to take over immediately.
    *   **Monitor Node (Zone C):** Runs the `pg_auto_failover` monitor service. It acts as the orchestrator and source of truth for the cluster's state, preventing split-brain scenarios. Placing it in a third zone ensures it can arbitrate during a failure affecting the primary or standby.
*   **PgBouncer:** A lightweight connection pooler running on both the primary and standby nodes. It manages client connections, reducing the overhead on PostgreSQL. The ILB directs traffic to the PgBouncer on the *current* primary node.
*   **PostgreSQL 17+:** The core database.
*   **`pg_auto_failover`:** The HA management tool. It monitors the health of the PostgreSQL nodes, automates the failover process, and, critically, manages the automated failback.

### 1.3. Data Flow

*   **Client Connections:**
    1.  Clients connect to the ILB's IP address on port 5432.
    2.  The ILB, guided by its health check, forwards the connection to the PgBouncer instance on the *active primary* node.
    3.  PgBouncer pools the connection and forwards it to the local PostgreSQL instance.
*   **Replication Flow:**
    1.  The primary node streams Write-Ahead Log (WAL) records to the standby node using synchronous replication (`synchronous_commit = 'on'`, `synchronous_standby_names = '*'`).
    2.  The standby acknowledges receipt of the WAL records, ensuring a transaction is not considered complete on the primary until it is hardened on the standby. This guarantees an RPO of 0.
*   **Monitoring & Failover Flow:**
    1.  The `pg_auto_failover` monitor continuously checks the health of both the primary and standby nodes.
    2.  If the primary node fails, the monitor detects the failure.
    3.  The monitor promotes the standby node to the new primary.
    4.  The ILB health check fails for the old primary and succeeds for the new primary, automatically redirecting client traffic.
    5.  When the old primary comes back online, `pg_auto_failover` automatically re-integrates it into the cluster as a secondary. The design's key is that `pg_auto_failover` will then manage the process of failing back to this original primary when it is safe to do so, restoring the cluster's original configuration without intervention.

---

## 2. Infrastructure as Code (IaC) Plan (Terraform)

This section provides the Terraform configurations to provision the required GCP infrastructure. The code is organized into logical files, reflecting best practices.

### 2.1. `variables.tf`

Defines the input variables for the Terraform configuration, allowing for easy customization.

```hcl
variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "region" {
  description = "The GCP region for the resources."
  type        = string
  default     = "us-central1"
}

variable "network_name" {
  description = "The name of the Shared VPC network."
  type        = string
  default     = "default"
}

variable "subnetwork_name" {
  description = "The name of the subnetwork to deploy resources in."
  type        = string
}

variable "machine_type" {
  description = "The machine type for the GCE instances."
  type        = string
  default     = "e2-standard-4"
}

variable "instance_roles" {
  description = "A map defining the roles and zones for each instance."
  type = map(object({
    zone   = string
    is_db_node = bool
  }))
  default = {
    "pg-primary"  = { zone = "us-central1-a", is_db_node = true }
    "pg-standby"  = { zone = "us-central1-b", is_db_node = true }
    "pg-monitor"  = { zone = "us-central1-c", is_db_node = false }
  }
}
```

### 2.2. `compute.tf`

Provisions the GCE instances for the primary, standby, and monitor nodes.

```hcl
resource "google_compute_instance" "pg_nodes" {
  for_each = var.instance_roles

  project      = var.project_id
  zone         = each.value.zone
  name         = each.key
  machine_type = var.machine_type
  tags         = ["postgresql-ha"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts"
      size  = 50
      type  = "pd-standard"
    }
  }

  // Data disk for DB nodes
  attached_disk {
    source      = each.value.is_db_node ? google_compute_disk.data_disk[each.key].self_link : null
    device_name = "data-disk"
  }

  // WAL disk for DB nodes
  attached_disk {
    source      = each.value.is_db_node ? google_compute_disk.wal_disk[each.key].self_link : null
    device_name = "wal-disk"
  }

  network_interface {
    subnetwork = var.subnetwork_name
    network_ip = each.key == "pg-primary" ? "10.0.1.10" : (each.key == "pg-standby" ? "10.0.1.11" : "10.0.1.12")
  }

  metadata = {
    "role"                    = each.key
    "timezone"                = "Asia/Riyadh"
    "enable-oslogin"          = "TRUE"
    "metadata_startup_script" = file("${path.module}/scripts/ha_postgresql_setup.sh")
  }

  service_account {
    email  = google_service_account.pg_sa.email
    scopes = ["cloud-platform"]
  }

  allow_stopping_for_update = true
}

resource "google_compute_disk" "data_disk" {
  for_each = { for k, v in var.instance_roles : k => v if v.is_db_node }

  project  = var.project_id
  zone     = each.value.zone
  name     = "${each.key}-data-disk"
  type     = "pd-ssd"
  size     = 1024
}

resource "google_compute_disk" "wal_disk" {
  for_each = { for k, v in var.instance_roles : k => v if v.is_db_node }

  project  = var.project_id
  zone     = each.value.zone
  name     = "${each.key}-wal-disk"
  type     = "pd-ssd"
  size     = 100
}
```

### 2.3. `network.tf` & `firewall.tf`

Configures networking, including the ILB and firewall rules.

```hcl
# In firewall.tf
resource "google_compute_firewall" "allow_internal_postgres" {
  project = var.project_id
  name    = "allow-internal-postgres-ha"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["5432", "6432"] # PostgreSQL and PgBouncer
  }

  source_tags = ["postgresql-ha"]
  target_tags = ["postgresql-ha"]
}

resource "google_compute_firewall" "allow_lb_health_check" {
  project = var.project_id
  name    = "allow-lb-health-check"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["6432"] # Health check on PgBouncer
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"] # GCP Health Checker Ranges
  target_tags   = ["postgresql-ha"]
}

# In loadbalancers.tf
resource "google_compute_health_check" "pg_health_check" {
  project = var.project_id
  name    = "pgbouncer-health-check"
  
  tcp_health_check {
    port = "6432"
  }
}

resource "google_compute_region_backend_service" "pg_backend" {
  project               = var.project_id
  name                  = "pg-ha-backend-service"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  protocol              = "TCP"
  health_checks         = [google_compute_health_check.pg_health_check.id]
}

resource "google_compute_forwarding_rule" "pg_forwarding_rule" {
  project               = var.project_id
  name                  = "pg-ha-forwarding-rule"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.pg_backend.id
  all_ports             = true
  network               = var.network_name
  subnetwork            = var.subnetwork_name
}
```

### 2.4. `iam.tf` & `secrets.tf`

Manages service accounts and secrets.

```hcl
# In iam.tf
resource "google_service_account" "pg_sa" {
  project      = var.project_id
  account_id   = "postgresql-ha-sa"
  display_name = "Service Account for PostgreSQL HA Cluster"
}

resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

# In secrets.tf
resource "google_secret_manager_secret" "pg_password" {
  project   = var.project_id
  secret_id = "pg-auto-failover-password"

  replication {
    automatic = true
  }
}

resource "google_secret_manager_secret_version" "pg_password_version" {
  secret      = google_secret_manager_secret.pg_password.id
  secret_data = "a-very-strong-and-random-password"
}
```

---

## 3. Configuration & Automation Plan (Bash Script)

The `ha_postgresql_setup.sh` startup script is the heart of the automation. It will be responsible for configuring each node based on its role, which it determines from the GCE metadata.

### 3.1. `scripts/ha_postgresql_setup.sh`

This script will perform the following actions:

1.  **Identify Role:** Fetch the `role` from GCE metadata.
2.  **Install Packages:** Install PostgreSQL, `pg_auto_failover`, PgBouncer, and LVM tools.
3.  **Configure Disks (DB Nodes):** Set up LVM on the data and WAL disks.
4.  **Fetch Secrets:** Retrieve the PostgreSQL password from Secret Manager.
5.  **Configure PostgreSQL:** Apply a tuned `postgresql.conf`.
6.  **Configure `pg_auto_failover`:** Initialize the monitor, or create/join the formation.
7.  **Configure PgBouncer:** Set up connection pooling.
8.  **Set up Systemd Services:** Create and enable `systemd` units for all components.

A skeleton of the script:

```bash
#!/bin/bash
set -ex

# 1. Identify Role & Fetch Metadata
ROLE=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/role)
TIMEZONE=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/timezone)
(ALL_NODES_IPS) # Should not be Hardcoded, Must be discovered


# Set Timezone
timedatectl set-timezone "$TIMEZONE"

# 2. Install Packages
apt-get update
apt-get install -y postgresql-17 pg-auto-failover-cli pgbouncer lvm2

# ... more installation steps ...

# 3. Configure Disks (if DB node)
if [[ "$ROLE" == "pg-primary" || "$ROLE" == "pg-standby" ]]; then
  # LVM and filesystem setup for /dev/sdb (data) and /dev/sdc (wal)
  # ...
fi

# 4. Fetch Secrets
# Use gcloud to get the secret value
PG_PASSWORD=$(gcloud secrets versions access latest --secret="pg-auto-failover-password")
export PG_PASSWORD

# 5. Configure PostgreSQL
# Modify postgresql.conf and pg_hba.conf
# ...

# 6. Configure pg_auto_failover
case "$ROLE" in
  "pg-monitor")
    pg_autoctl create monitor --pgdata /var/lib/postgresql/17/monitor --auth trust --run
    ;;
  "pg-primary")
    # Wait for monitor to be ready
    pg_autoctl create postgres --pgdata /var/lib/postgresql/17/main --auth trust --ssl-self-signed --monitor "postgres://${MONITOR_I}:5432/pg_auto_failover" --formation default --name pg-primary --run
    ;;
  "pg-standby")
    # Wait for monitor and primary to be ready
    pg_autoctl create postgres --pgdata /var/lib/postgresql/17/main --auth trust --ssl-self-signed --monitor "postgres://${MONITOR_IP}:5432/pg_auto_failover" --formation default --name pg-standby --run
    ;;
esac

# ... and so on for PgBouncer and Systemd ...
```

### 3.2. `postgresql.conf` Highlights

Key settings for an HA workload:

```ini
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
hot_standby = on
synchronous_commit = on # For RPO=0
synchronous_standby_names = '*' # Let pg_auto_failover manage this
```

### 3.3. `pg_auto_failover` Configuration

The magic of automated failback lies in `pg_auto_failover`'s design. When the former primary comes back online, it is added as a secondary. `pg_auto_failover` has a concept of a "number of sync standbys" and will manage the roles to maintain the desired state. To encourage failback to the original primary, you can assign a higher `candidate_priority` to the `pg-primary` node during its creation.

```bash
# In the primary creation step
pg_autoctl create postgres ... --candidate-priority 100 ...

# In the standby creation step
pg_autoctl create postgres ... --candidate-priority 50 ...
```

A higher `candidate_priority` tells the monitor that this node is preferred for the primary role. When the original primary is healthy and caught up, the monitor can orchestrate a switchover to restore it to its primary role, achieving the automated failback requirement.

---

## 4. Operational Playbooks

### 4.1. Backup & Recovery

*   **Tool:** `pgBackRest` is an excellent choice for this.
*   **Strategy:**
    1.  Configure `pgBackRest` on all nodes.
    2.  Create a GCS bucket for backups.
    3.  Schedule a cron job on the **standby node** to perform regular full and incremental backups to the GCS bucket. This offloads the backup workload from the primary.
    4.  Enable WAL archiving from both primary and standby to the `pgBackRest` repository.

### 4.2. Monitoring & Alerting

*   **Tool:** Google Cloud Monitoring.
*   **Metrics to Track:**
    *   `pg_auto_failover` state changes (custom log-based metric).
    *   `pg_stat_replication.replay_lag`.
    *   CPU, Memory, and Disk I/O on all nodes.
*   **Alerting:** Create alerting policies in Cloud Monitoring to trigger notifications (e.g., to PagerDuty or Slack) for:
    *   Any failover event.
    *   Replication lag exceeding 100ms.
    *   High resource utilization.

---

## 5. Validation & Testing Framework

### 5.1. Test Plan

1.  **Primary Node Failure:**
    *   **Action:** Stop the `pg-primary` GCE instance.
    *   **Expected:** `pg_auto_failover` promotes `pg-standby` within 30 seconds. The ILB redirects traffic. No data loss.
2.  **Automated Failback Test:**
    *   **Action:** Start the `pg-primary` instance again.
    *   **Expected:** The node rejoins as a secondary, catches up, and `pg_auto_failover` automatically orchestrates a switchover to restore it as the primary due to its higher `candidate_priority`.
3.  **Network Partition (Split-Brain Test):**
    *   **Action:** Create a firewall rule to isolate the primary from the monitor and standby.
    *   **Expected:** The monitor demotes the isolated primary. The standby is promoted. The isolated primary steps down, preventing a split-brain scenario.

### 5.2. Performance Benchmarking

*   **Tool:** `pgbench`.
*   **Method:**
    1.  Run a sustained `pgbench` workload against the ILB.
    2.  While the load is active, monitor the `replay_lag` from `pg_stat_replication` on the primary.
    3.  Trigger a failover and measure the time from primary failure to the point where the new primary starts accepting write transactions.
