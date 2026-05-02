#############################################
# Module 2: Compute + Metadata + Disks
#############################################



# locals {
#   # Map environment string to short code used in names
#   env_code = contains([lower(var.ha_db_environment)], "production") ? "prd" : (contains([lower(var.ha_db_environment)], "nonprod") ? "nprd" : lower(substr(var.ha_db_environment, 0, 4)))

#   org_code = var.org_code

#   # Base purpose names
#   purpose = {
#     monitor = "pg-monitor"
#     primary = "pg-primary"
#     standby = "pg-standby"
#   }

#   # Naming: [org]-[env]-[resource-type]-[purpose]-[instance]
#   names = {
#     monitor = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ha", local.purpose.monitor, 1)
#     primary = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ha", local.purpose.primary, 1)
#     standby = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ha", local.purpose.standby, 1)
#   }

#   # Disk names using the same convention with resource-type = disk
#   disk_names = {
#     primary_data = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-data", 1)
#     primary_wal  = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-wal", 1)
#     standby_data = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-data", 2)
#     standby_wal  = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-wal", 2)
#     monitor_data = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-monitor", 1)
#   }

#   # Common tags
#   network_tags = ["pg", "pg17", "cis-hardened"]
# }

# Service account for DB instances
resource "google_service_account" "pg_sa" {
  provider     = google.db_projects
  account_id   = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sa", "pg-ha", 1)
  display_name = "PostgreSQL HA instances"
}

#############################################
# Disks
#############################################

resource "google_compute_disk" "primary_data" {
  provider = google.db_projects
  name     = local.disk_names.primary_data
  type     = var.ha_db_data_disk_type
  zone     = var.ha_db_primary_zone
  size     = local.is_production ? var.ha_db_data_disk_size : 500 # 10TB for prod
  labels   = merge(local.app_labels, { usage = "data", pg_role = "primary" })
}

resource "google_compute_disk" "primary_wal" {
  provider = google.db_projects
  name     = local.disk_names.primary_wal
  type     = var.ha_db_data_disk_type
  zone     = var.ha_db_primary_zone
  size     = local.is_production ? var.ha_db_wal_disk_size : 100 # 512GB for prod
  labels   = merge(local.app_labels, { usage = "wal", pg_role = "primary" })
}

resource "google_compute_disk" "standby_data" {
  provider = google.db_projects
  name     = local.disk_names.standby_data
  type     = var.ha_db_data_disk_type
  zone     = var.ha_db_secondary_zone
  size     = local.is_production ? var.ha_db_data_disk_size : 500 # 10TB for prod
  labels   = merge(local.app_labels, { usage = "data", pg_role = "standby" })
}

resource "google_compute_disk" "standby_wal" {
  provider = google.db_projects
  name     = local.disk_names.standby_wal
  type     = var.ha_db_data_disk_type
  zone     = var.ha_db_secondary_zone
  size     = local.is_production ? var.ha_db_wal_disk_size : 100 # 5120GB for prod
  labels   = merge(local.app_labels, { usage = "wal", pg_role = "standby" })
}

resource "google_compute_disk" "monitor_data" {
  provider = google.db_projects
  name     = local.disk_names.monitor_data
  type     = var.ha_db_data_disk_type
  zone     = var.ha_db_monitor_zone
  size     = local.is_production ? var.ha_db_monitor_data_disk_size : 50 # 200GB for prod
  labels   = merge(local.app_labels, { usage = "data", pg_role = "monitor" })
}


#############################################
# Instances
#############################################

resource "google_compute_instance" "monitor" {
  provider     = google.db_projects
  name         = local.names.monitor
  machine_type = local.is_production ? var.ha_db_monitor_machine_type : "n2-standard-2" # Smaller instance for non-prod
  zone         = var.ha_db_monitor_zone
  tags         = local.network_tags

  labels = merge(local.app_labels, { pg_role = "monitor" })

  boot_disk {
    initialize_params {
      image = var.ubuntu_minimal_2404_image
      type  = var.ha_db_boot_disk_type # pd-ssd
      size  = var.ha_db_boot_disk_size # 100GB
    }
  }

  attached_disk { source = google_compute_disk.monitor_data.id }

  metadata = {
    # "ha-pg-script-url" = var.ha_pg_script_url
    timezone      = var.timezone
    pg_role       = "monitor"
    formation     = "default"
    pg_cluster_id = local.pg_cluster_id
    environment   = local.workspace_env
  }

  metadata_startup_script = local.startup_script

  network_interface {
    subnetwork = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
    network_ip = google_compute_address.monitor_ip.address
    # Internal only; omit access_config to avoid external IP
  }

  service_account {
    email  = google_service_account.pg_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

resource "google_compute_instance" "primary" {
  provider     = google.db_projects
  name         = local.names.primary
  machine_type = local.is_production ? var.ha_db_machine_type : "n2-standard-6" # Smaller instance for non-prod
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

  attached_disk { source = google_compute_disk.primary_data.id }
  attached_disk { source = google_compute_disk.primary_wal.id }

  metadata = {
    # "ha-pg-script-url" = var.ha_pg_script_url
    timezone           = var.timezone
    role               = "primary"
    formation          = "default"
    pg_cluster_id      = local.pg_cluster_id
    candidate_priority = 100
    replication_quorum = true
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
}

resource "google_compute_instance" "standby" {
  provider     = google.db_projects
  name         = local.names.standby
  machine_type = local.is_production ? var.ha_db_machine_type : "n2-standard-6" # Smaller instance for non-prod
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

  attached_disk { source = google_compute_disk.standby_data.id }
  attached_disk { source = google_compute_disk.standby_wal.id }

  metadata = {
    # "ha-pg-script-url" = var.ha_pg_script_url
    timezone           = var.timezone
    role               = "standby"
    formation          = "default"
    pg_cluster_id      = local.pg_cluster_id
    candidate_priority = 50
    replication_quorum = true
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
}

output "monitor_instance_name" { value = google_compute_instance.monitor.name }
output "primary_instance_name" { value = google_compute_instance.primary.name }
output "standby_instance_name" { value = google_compute_instance.standby.name }

output "monitor_instance_specifications" {
  value     = google_compute_instance.monitor
  sensitive = true
}
output "primary_instance_specifications" {
  value     = google_compute_instance.primary
  sensitive = true
}
output "standby_instance_specifications" {
  value     = google_compute_instance.standby
  sensitive = true
}