#############################################
# Regional internal IP reservations
#############################################

locals {
  ip_names = {
    monitor = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ip", "pg-monitor", 1)
    primary = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ip", "pg-primary", 1)
    standby = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ip", "pg-standby", 1)
    vip     = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ip", "pg-vip", 1)
  }
}

resource "google_compute_address" "primary_ip" {
  provider     = google.db_projects
  name         = local.ip_names.primary
  address      = local.pg_ips["primary"]
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
  purpose      = "GCE_ENDPOINT"
  labels       = merge(local.app_labels, { pg_role = "primary" })
}

resource "google_compute_address" "standby_ip" {
  provider     = google.db_projects
  name         = local.ip_names.standby
  address      = local.pg_ips["standby"]
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
  purpose      = "GCE_ENDPOINT"
  labels       = merge(local.app_labels, { pg_role = "standby" })
}

resource "google_compute_address" "monitor_ip" {
  provider     = google.db_projects
  name         = local.ip_names.monitor
  address      = local.pg_ips["monitor"]
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
  purpose      = "GCE_ENDPOINT"
  labels       = merge(local.app_labels, { pg_role = "monitor" })
}

# Reserved VIP for future Internal Load Balancer front-end
resource "google_compute_address" "pg_vip" {
  provider     = google.db_projects
  name         = local.ip_names.vip
  address      = local.pg_ips["vip"]
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
  purpose      = "SHARED_LOADBALANCER_VIP"
  labels       = merge(local.app_labels, { usage = "vip", pg_role = "loadbalancer" })
}

output "primary_internal_ip" { value = google_compute_address.primary_ip.address }
output "standby_internal_ip" { value = google_compute_address.standby_ip.address }
output "monitor_internal_ip" { value = google_compute_address.monitor_ip.address }
output "pg_vip_internal_ip" { value = google_compute_address.pg_vip.address }
