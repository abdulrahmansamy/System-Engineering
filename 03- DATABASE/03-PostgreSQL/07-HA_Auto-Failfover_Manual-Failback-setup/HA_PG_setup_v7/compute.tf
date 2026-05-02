#############################################
# Module 2: Compute + Metadata + Disks
#############################################



# Service account for DB instances

resource "google_service_account" "pg_sa" {
  provider     = google.db_projects
  account_id   = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sa", "pg-ha", 1)
  display_name = "PostgreSQL HA instances service account"
}

#############################################
# Disks
#############################################

resource "google_compute_disk" "pg_primary_data" {
  provider = google.db_projects
  name     = local.disk_names.primary_data
  type     = var.ha_db_data_disk_type
  zone     = var.ha_db_primary_zone
  size     = local.is_production ? var.ha_db_data_disk_size : 500 # 10TB for prod
  labels   = merge(local.app_labels, { usage = "data", pg_role = "primary" })
}

# resource "google_compute_disk" "pg_primary_wal" {
#   provider = google.db_projects
#   name     = local.disk_names.primary_wal
#   type     = var.ha_db_data_disk_type
#   zone     = var.ha_db_primary_zone
#   size     = local.is_production ? var.ha_db_wal_disk_size : 100 # 512GB for prod
#   labels   = merge(local.app_labels, { usage = "wal", pg_role = "primary" })
# }

resource "google_compute_disk" "pg_standby_data" {
  provider = google.db_projects
  name     = local.disk_names.standby_data
  type     = var.ha_db_data_disk_type
  zone     = var.ha_db_secondary_zone
  size     = local.is_production ? var.ha_db_data_disk_size : 500 # 10TB for prod
  labels   = merge(local.app_labels, { usage = "data", pg_role = "standby" })
}

# resource "google_compute_disk" "pg_standby_wal" {
#   provider = google.db_projects
#   name     = local.disk_names.standby_wal
#   type     = var.ha_db_data_disk_type
#   zone     = var.ha_db_secondary_zone
#   size     = local.is_production ? var.ha_db_wal_disk_size : 100 # 5120GB for prod
#   labels   = merge(local.app_labels, { usage = "wal", pg_role = "standby" })
# }

resource "google_compute_disk" "pg_witness_data" {
  count    = var.enable_witness ? 1 : 0
  provider = google.db_projects
  name     = local.disk_names.witness_data
  type     = var.ha_db_data_disk_type
  zone     = var.ha_db_witness_zone
  size     = local.is_production ? var.ha_db_monitor_data_disk_size : 20 # witness minimal
  labels   = merge(local.app_labels, { usage = "data", pg_role = "witness" })
}


#############################################
# Instances
#############################################
# /*
resource "google_compute_instance" "pg_witness" {
  count        = var.enable_witness ? 1 : 0
  provider     = google.db_projects
  name         = local.names.witness
  machine_type = local.selected_monitor_machine
  zone         = var.ha_db_witness_zone
  tags         = local.network_tags

  labels = merge(local.app_labels, { pg_role = "witness" })

  boot_disk {
    initialize_params {
      image = var.ubuntu_minimal_2404_image
      type  = var.ha_db_boot_disk_type
      size  = var.ha_db_boot_disk_size
    }
  }

  attached_disk { source = google_compute_disk.pg_witness_data[0].id }

  metadata = {
    timezone               = var.timezone
    pg_role                = "witness"
    pg_cluster_id          = local.pg_cluster_id
    environment            = local.workspace_env
    replication_quorum     = "false"
    candidate_priority     = "0"
    pg_controller_cooldown = tostring(var.pg_failback_controller_cooldown_seconds)
    pg_health_port         = tostring(var.pg_health_port)
    # Streaming replication configuration for witness
    primary_host           = google_compute_address.primary_ip.address
    standby_host           = google_compute_address.standby_ip.address
    witness_host           = google_compute_address.witness_ip.address
    # Environmental codes for naming consistency
    org_code = local.org_code
    env_code = local.env_code
  }

  metadata_startup_script = local.startup_script

  network_interface {
    subnetwork = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
    network_ip = google_compute_address.witness_ip.address
  }

  service_account {
    email  = google_service_account.pg_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}
# */
resource "google_compute_instance" "pg_primary" {
  provider     = google.db_projects
  name         = local.names.primary
  machine_type = local.selected_machine_type
  zone         = var.ha_db_primary_zone
  tags         = local.network_tags

  labels = merge(local.app_labels, { pg_role = "primary" })

  boot_disk {
    initialize_params {
      image = var.ubuntu_minimal_2404_image
      type  = var.ha_db_boot_disk_type
      size  = var.ha_db_boot_disk_size
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  attached_disk { source = google_compute_disk.pg_primary_data.id }
  # attached_disk { source = google_compute_disk.pg_primary_wal.id }

  metadata = {
    # Standardized metadata keys for streaming replication HA
    timezone               = var.timezone
    pg_role                = "primary"
    pg_cluster_id          = local.pg_cluster_id
    environment            = local.workspace_env
    candidate_priority     = 100 # Preferred original primary
    replication_quorum     = true
    pg_failback_enabled    = true # Eligible for auto-failback preference
    pg_controller_cooldown = 600
    pg_health_port         = var.pg_health_port
    # Streaming replication configuration
    primary_host           = google_compute_address.primary_ip.address
    standby_host           = google_compute_address.standby_ip.address
    witness_host           = var.enable_witness ? google_compute_address.witness_ip.address : ""
    # Secret Manager secret IDs for the bootstrap script
    pg_superuser_secret_id   = local.secret_ids.pg_superuser
    pg_replication_secret_id = local.secret_ids.pg_replication
    pg_monitor_secret_id     = local.secret_ids.pg_monitor
    pg_appuser_secret_id     = local.secret_ids.pg_appuser
    pg_wso2user_secret_id    = local.secret_ids.pg_wso2user
    pg_tmsuser_secret_id     = local.secret_ids.pg_tmsuser
    pg_examuser_secret_id    = local.secret_ids.pg_examuser
    pg_helpdeskuser_secret_id = local.secret_ids.pg_helpdeskuser
    pg_konguser_secret_id    = local.secret_ids.pg_konguser
    pgbouncer_secret_id      = local.secret_ids.pgbouncer
    # Environmental codes for naming consistency
    org_code = local.org_code
    env_code = local.env_code
  }

  metadata_startup_script = local.startup_script

  network_interface {
    subnetwork = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
    network_ip = google_compute_address.primary_ip.address
  }

  service_account {
    email  = google_service_account.pg_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [
    google_secret_manager_secret.pg_superuser,
    google_secret_manager_secret.pg_replication,
    google_secret_manager_secret.pg_monitor,
    google_secret_manager_secret.pg_appuser,
    google_secret_manager_secret.pg_wso2user,
    google_secret_manager_secret.pg_tmsuser,
    google_secret_manager_secret.pg_examuser,
    google_secret_manager_secret.pg_helpdeskuser,
    google_secret_manager_secret.pg_konguser,
    google_secret_manager_secret.pgbouncer
  ]
}

resource "google_compute_instance" "pg_standby" {
  provider     = google.db_projects
  name         = local.names.standby
  machine_type = local.selected_machine_type
  zone         = var.ha_db_secondary_zone
  tags         = local.network_tags

  labels = merge(local.app_labels, { pg_role = "standby" })

  boot_disk {
    initialize_params {
      image = var.ubuntu_minimal_2404_image
      type  = var.ha_db_boot_disk_type
      size  = var.ha_db_boot_disk_size
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  attached_disk { source = google_compute_disk.pg_standby_data.id }
  # attached_disk { source = google_compute_disk.pg_standby_wal.id }

  metadata = {
    # Standardized metadata keys for streaming replication HA
    timezone               = var.timezone
    pg_role                = "standby"
    pg_cluster_id          = local.pg_cluster_id
    environment            = local.workspace_env
    candidate_priority     = 50   # Lower than original primary
    replication_quorum     = true # Required for sync commit
    pg_failback_enabled    = true # Participate in controller decisions (read-only)
    pg_controller_cooldown = 600
    pg_health_port         = var.pg_health_port
    # Streaming replication configuration
    primary_host           = google_compute_address.primary_ip.address
    standby_host           = google_compute_address.standby_ip.address
    witness_host           = var.enable_witness ? google_compute_address.witness_ip.address : ""
    # Secret Manager secret IDs for the bootstrap script
    pg_superuser_secret_id   = local.secret_ids.pg_superuser
    pg_replication_secret_id = local.secret_ids.pg_replication
    pg_monitor_secret_id     = local.secret_ids.pg_monitor
    pg_appuser_secret_id     = local.secret_ids.pg_appuser
    pg_wso2user_secret_id    = local.secret_ids.pg_wso2user
    pg_tmsuser_secret_id     = local.secret_ids.pg_tmsuser
    pg_examuser_secret_id    = local.secret_ids.pg_examuser
    pg_helpdeskuser_secret_id = local.secret_ids.pg_helpdeskuser
    pg_konguser_secret_id    = local.secret_ids.pg_konguser
    pgbouncer_secret_id      = local.secret_ids.pgbouncer
    # Environmental codes for naming consistency
    org_code = local.org_code
    env_code = local.env_code
  }

  metadata_startup_script = local.startup_script

  network_interface {
    subnetwork = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
    network_ip = google_compute_address.standby_ip.address
  }

  service_account {
    email  = google_service_account.pg_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [
    google_secret_manager_secret.pg_superuser,
    google_secret_manager_secret.pg_replication,
    google_secret_manager_secret.pg_monitor,
    google_secret_manager_secret.pg_appuser,
    google_secret_manager_secret.pg_wso2user,
    google_secret_manager_secret.pg_tmsuser,
    google_secret_manager_secret.pg_examuser,
    google_secret_manager_secret.pg_helpdeskuser,
    google_secret_manager_secret.pg_konguser,
    google_secret_manager_secret.pgbouncer,
    google_compute_instance.pg_primary # Wait for primary to be created first
  ]
}

# Duplicate section removed - IP addresses already exist below

output "witness_instance_name" { value = var.enable_witness ? google_compute_instance.pg_witness[0].name : null }
output "primary_instance_name" { value = google_compute_instance.pg_primary.name }
output "standby_instance_name" { value = google_compute_instance.pg_standby.name }

output "witness_instance_specifications" {
  value     = var.enable_witness ? google_compute_instance.pg_witness[0] : null
  sensitive = true
}
output "primary_instance_specifications" {
  value     = google_compute_instance.pg_primary
  sensitive = true
}
output "standby_instance_specifications" {
  value     = google_compute_instance.pg_standby
  sensitive = true
}