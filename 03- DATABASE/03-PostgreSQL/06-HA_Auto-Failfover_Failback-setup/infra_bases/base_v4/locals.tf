locals {
  # Resolve environment from terraform workspace; fall back to var.ha_db_environment when workspace is default
  workspace_env = terraform.workspace == "default" ? var.ha_db_environment : terraform.workspace

  # Boolean used to select prod vs nonprod semantics
  is_production = contains(["prod", "production", "prd"], lower(terraform.workspace == "default" ? var.ha_db_environment : terraform.workspace))
}

locals {
  app_labels = {
    environment = local.workspace_env
    project     = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
    managed-by  = "terraform"
    stack       = "pg-ha-pg_auto_failover"
  }

  name_prefix = var.ha_db_instance_prefix
}

locals {
  # Map environment string to short code used in names
  env_code = contains(["prod", "production", "prd"], lower(local.workspace_env)) ? "prd" : (contains(["nonprod", "nprd"], lower(local.workspace_env)) ? "nprd" : lower(substr(local.workspace_env, 0, 4)))

  org_code = var.org_code

  # Base purpose names
  purpose = {
    monitor = "pg-monitor"
    primary = "pg-primary"
    standby = "pg-standby"
  }

  # Naming: [org]-[env]-[resource-type]-[purpose]-[instance]
  names = {
    monitor = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ha", local.purpose.monitor, 1)
    primary = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ha", local.purpose.primary, 1)
    standby = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ha", local.purpose.standby, 1)
  }


  # Disk names using the same convention with resource-type = disk
  disk_names = {
    primary_data = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-data", 1)
    primary_wal  = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-wal", 1)
    standby_data = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-data", 2)
    standby_wal  = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-wal", 2)
    monitor_data = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "disk", "pg-monitor", 1)
  }

  # Common tags
  network_tags = ["pg", "pg17", "cis-hardened", local.workspace_env]
}

locals {
  startup_script = file("${path.module}/scripts/ha_postgresql_setup.sh")
}


output "labels_common" {
  value       = local.app_labels
  description = "Common labels applied to resources"
}

output "name_prefix" {
  value       = local.name_prefix
  description = "Prefix used for resource names"
}

locals {
  # Extract network part (first 3 octets)
  prod_net    = join(".", slice(split(".", cidrhost(var.prod_db_subnet_cidr, 0)), 0, 3))
  nonprod_net = join(".", slice(split(".", cidrhost(var.nonprod_db_subnet_cidr, 0)), 0, 3))



  # Define IPs for prod
  prd_pg_ips = {
    primary = "${local.prod_net}.${var.db_host_ids.primary}"
    standby = "${local.prod_net}.${var.db_host_ids.standby}"
    monitor = "${local.prod_net}.${var.db_host_ids.monitor}"
    vip     = "${local.prod_net}.${var.db_host_ids.vip}"
  }

  # Define IPs for nonprod
  nprd_pg_ips = {
    primary = "${local.nonprod_net}.${var.db_host_ids.primary}"
    standby = "${local.nonprod_net}.${var.db_host_ids.standby}"
    monitor = "${local.nonprod_net}.${var.db_host_ids.monitor}"
    vip     = "${local.nonprod_net}.${var.db_host_ids.vip}"
  }

  # Select IPs based on environment
  # pg_ips = var.ha_db_environment == "prod" ? local.prd_pg_ips : local.nprd_pg_ips

  pg_ips = local.is_production ? local.prd_pg_ips : local.nprd_pg_ips

}

output "pg_primary_ip" {
  value = local.pg_ips["primary"]
}

output "pg_standby_ip" {
  value = local.pg_ips["standby"]
}

output "pg_monitor_ip" {
  value = local.pg_ips["monitor"]
}

output "pg_vip_ip" {
  value = local.pg_ips["vip"]
}

locals {
  selected_machine_type    = local.is_production ? var.ha_db_machine_type : var.ha_db_machine_type_nonprod
  selected_monitor_machine = local.is_production ? var.ha_db_monitor_machine_type : var.ha_db_monitor_machine_type_nonprod

  firewall_app_cidrs = local.is_production ? [var.prod_app_subnet_cidr] : [var.nonprod_app_subnet_cidr]
  firewall_db_cidrs  = local.is_production ? [var.prod_db_subnet_cidr] : [var.nonprod_db_subnet_cidr]

  selected_ssh_source_ranges = local.is_production ? var.prod_ssh_source_ranges : var.nonprod_ssh_source_ranges

}

locals {
  pg_cluster_id = format("%s-ha-cluster-01", contains(["prod", "production", "prd"], lower(local.workspace_env)) ? "prod" : "nonprod")
}

locals {
  # Validate CIDR strings and provide a safe fallback for any invalid entries
  firewall_app_cidrs_validated = [for c in local.firewall_app_cidrs : (can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", c)) ? c : "0.0.0.0/32")]
  firewall_db_cidrs_validated  = [for c in local.firewall_db_cidrs : (can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", c)) ? c : "0.0.0.0/32")]
}