Certainly. That's a critical requirement for ensuring time consistency across a distributed database cluster, which is essential for replication and logging.

I've added this time synchronization and localization requirement to the **Technical & Environmental Stack** section, as it's a core part of the base OS configuration.

Here is the fully updated prompt.

-----

### **Objective**

Design a complete, production-ready, and fully automated High Availability (HA) plan for a **PostgreSQL 17+ cluster** on Google Cloud Platform (GCP) using `pg_auto_failover`.

The central focus is achieving **seamless, zero-intervention failback**, where the original primary node is safely restored to its primary role after a failure event. The final system must operate with the reliability and transparency of a managed database service.

-----

### **Core System Requirements**

The final design must meet these non-negotiable criteria:

  * **Availability & Performance:**

      * **RPO:** 0 (zero data loss).
      * **RTO:** \< 30 seconds for automatic failover.
      * **Replication Lag:** \< 100ms under normal load.

  * **Automation & Operations:**

      * **Intervention:** Zero manual intervention required for any failover or failback sequence.
      * **Split-Brain:** Automatic prevention must be built-in and validated.
      * **State Management:** The cluster must maintain a consistent and predictable state across all failure scenarios.
      * **Role Identification:** Automation scripts **must not rely on GCE instance names** to determine roles. Instead, they must use **GCP metadata or labels** to identify an instance's role (e.g., primary, standby, monitor).

  * **Security & Compliance:**

      * **Encryption:** End-to-end TLS for all replication, client, and monitor connections. Data must be encrypted at rest.
      * **Credentials:** All secrets (passwords, keys) must be managed via **GCP Secret Manager**.
      * **Authentication:** Database users must authenticate via SSL certificates and SCRAM-SHA-256.
      * **OS Hardening:** All nodes must be hardened using CIS benchmarks, including configured firewalls (UFW), AppArmor, auditd, and hardened kernel/SSH parameters.
      * **Auditing:** All role transitions, failover events, and state changes must be logged for compliance and audit purposes.

  * **Backup & Disaster Recovery:**

      * **Backups:** **Back up the databases on all instances to GCS.** The process should be automated and validated, with **priority given to taking backups from a standby node** to minimize the primary node's load.
      * **DR:** The design must include a strategy for cross-region recovery and business continuity.

-----

### **Technical & Environmental Stack**

Base the design on the following established environment and technology stack:

  * **Cloud Environment:**

      * **Provider:** Google Cloud Platform (GCP).
      * **Networking:** A pre-existing Shared VPC with a `/22` subnet (e.g., `192.168.24.0/22`). Use data resources to reference existing network components.
      * **Regions:** Primary/secondary nodes in `us-central1-a` and `us-central1-b`; monitor node in `us-central1-c`.

  * **Compute & OS:**

      * **OS:** Ubuntu 24.04 LTS.
      * **Disk Strategy:**
          * **Data:** Separate, auto-resizing `pd-ssd` (min 1024GB) using LVM.
          * **WAL:** Dedicated `pd-ssd` (min 100GB) with `noatime` mount option.
      * **Time & Localization:**
          * **NTP:** All nodes must synchronize time using **Google's internal NTP servers** (`metadata.google.internal`).
          * **Timezone:** The system timezone must be dynamically configured at startup by fetching the value from the GCE metadata attribute `timezone`.

  * **Database & HA:**

      * **Database:** PostgreSQL 17+.
      * **Failover Manager:** `pg_auto_failover`.

  * **Network & Connection Layer:**

      * **Topology:** `[Client Apps] → [GCP Internal Load Balancer] → [PgBouncer Cluster] → [PostgreSQL Nodes]`
      * **Connection Pooling:** PgBouncer must be configured for high availability and seamless connection handling during failover.

-----

### **Scope of Deliverables**

Provide a comprehensive plan organized into the following sections:

**1. System Architecture Design**
* A complete system diagram showing the interaction between all components.
* A detailed data flow plan for client connections, replication, and monitoring.

**2. Infrastructure as Code (IaC) Plan (Terraform)**
* **Compute:** Configuration for GCE instances, including machine types, disks, and a startup script strategy.
* **Startup Script Strategy:** The startup script provided to GCE instances must be a lightweight bootstrapper. Its sole purpose is to fetch the main, version-controlled configuration script from a URL stored in instance metadata. This decouples configuration logic from the infrastructure definition.
* **For example:**
* The GCE instance metadata in Terraform would contain the URL:
``` hcl 
metadata = { 
    ha-pg-script-url = "https://raw.githubusercontent.com/abdulrahmansamy/System-Engineering/master/bootstrap_postgresql_ha.sh" 
    timezone         = "Asia/Riyadh" 
}  
```

* The `startup-script` itself would be a simple fetcher and executor:
```bash
#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/startup-script.log"
log() {
  echo "[$(date --rfc-3339=seconds)] - $1" | tee -a "$LOG_FILE"
}

log "Fetching configuration script URL from metadata..."
CONFIG_SCRIPT_URL=$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/ha-pg-script-url)

if [[ -z "$CONFIG_SCRIPT_URL" ]]; then
    log "FATAL: Metadata key 'ha-pg-script-url' not found. Aborting."
    exit 1
fi

log "Downloading and executing configuration script from $CONFIG_SCRIPT_URL"
if ! curl -sSL "$CONFIG_SCRIPT_URL" | bash &>> "$LOG_FILE"; then
    log "FATAL: Configuration script execution failed. See log for details."
    exit 1
fi
            
log "Configuration script completed successfully."
 ```
* **Networking:** Firewall rules, load balancer with health checks, and Cloud DNS configuration.
* **IAM & Security:** Service accounts with least-privilege permissions and Secret Manager setup.


**3. Configuration & Automation Plan**
* **PostgreSQL:** An optimized `postgresql.conf` for this HA workload.
* **`pg_auto_failover`:** A complete setup guide, including monitor configuration, formation setup, and tuning for automatic failback.
* **PgBouncer:** Configuration for connection pooling, HA, and integration with the load balancer.
* **Systemd:** Service units for all components to ensure proper startup, dependencies, and automatic restarts.

**4. Operational Playbooks**
* **Backup & Recovery:** Procedures for automated backups to GCS, PITR, and DR drills.
* **Monitoring & Alerting:** A plan for integrating with Google Cloud Monitoring to track key metrics (e.g., replication lag, cluster state) and trigger alerts.
* **Maintenance & Upgrades:** A strategy for performing rolling upgrades and maintenance without compromising availability.

**5. Validation & Testing Framework**
* A detailed test plan to simulate failures (node crash, network partition) and validate that the success criteria are met.
* Performance benchmarking scripts to measure replication lag and failover times.

-----

### **Success Criteria**

The final design will be considered successful upon demonstrating the following through the proposed testing framework:

1.  **Failover:** Automatic failover completes in under 30 seconds.
2.  **Data Integrity:** Zero data loss is verified after any failover event.
3.  **Failback:** The original primary node is automatically and safely restored to its role without manual intervention.
4.  **Resilience:** The system prevents split-brain during network partitions.
5.  **Performance:** Replication lag is consistently below 100ms under simulated load.
6.  **Transparency:** All state changes are captured in logs and trigger actionable alerts.