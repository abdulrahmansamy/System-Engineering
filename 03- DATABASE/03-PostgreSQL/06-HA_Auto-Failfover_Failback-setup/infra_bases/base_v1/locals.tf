locals {
  app_labels = {
    environment = var.ha_db_environment
    project     = var.prod_db_project_id
    managed-by  = "terraform"
    stack       = "pg-ha-pg_auto_failover"
  }

  name_prefix = var.ha_db_instance_prefix
}

locals {
  # Map environment string to short code used in names
  env_code = contains([lower(var.ha_db_environment)], "production") ? "prd" : (contains([lower(var.ha_db_environment)], "nonprod") ? "nprd" : lower(substr(var.ha_db_environment, 0, 4)))

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
  network_tags = ["pg", "pg17", "cis-hardened"]
}

locals {
  startup_script = file("${path.module}/scripts/pg_setup.sh")
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
    primary   = "${local.prod_net}.${var.db_host_ids.primary}"
    secondary = "${local.prod_net}.${var.db_host_ids.secondary}"
    monitor   = "${local.prod_net}.${var.db_host_ids.monitor}"
    vip       = "${local.prod_net}.${var.db_host_ids.vip}"
  }

  # Define IPs for nonprod
  nprd_pg_ips = {
    primary   = "${local.nonprod_net}.${var.db_host_ids.primary}"
    secondary = "${local.nonprod_net}.${var.db_host_ids.secondary}"
    monitor   = "${local.nonprod_net}.${var.db_host_ids.monitor}"
    vip       = "${local.nonprod_net}.${var.db_host_ids.vip}"
  }

  # Select IPs based on environment
  # pg_ips = var.ha_db_environment == "prod" ? local.prd_pg_ips : local.nprd_pg_ips

  pg_ips = contains(["prod", "production", "prd"], lower(var.ha_db_environment)) ? local.prd_pg_ips : local.nprd_pg_ips

}

output "pg_primary_ip" {
  value = local.pg_ips["primary"]
}

output "pg_secondary_ip" {
  value = local.pg_ips["secondary"]
}

output "pg_monitor_ip" {
  value = local.pg_ips["monitor"]
}

output "pg_vip_ip" {
  value = local.pg_ips["vip"]
}