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
  name         = local.ip_names.primary
  address      = var.pg_primary_ip
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = data.google_compute_subnetwork.prod_db.self_link
  purpose      = "GCE_ENDPOINT"
  labels       = merge(local.app_labels, { role = "primary" })
}

resource "google_compute_address" "standby_ip" {
  name         = local.ip_names.standby
  address      = var.pg_standby_ip
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = data.google_compute_subnetwork.prod_db.self_link
  purpose      = "GCE_ENDPOINT"
  labels       = merge(local.app_labels, { role = "standby" })
}

resource "google_compute_address" "monitor_ip" {
  name         = local.ip_names.monitor
  address      = var.pg_monitor_ip
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = data.google_compute_subnetwork.prod_db.self_link
  purpose      = "GCE_ENDPOINT"
  labels       = merge(local.app_labels, { role = "monitor" })
}

# Reserved VIP for future Internal Load Balancer front-end
resource "google_compute_address" "pg_vip" {
  name         = local.ip_names.vip
  address      = var.pg_vip_ip
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = data.google_compute_subnetwork.prod_db.self_link
  purpose      = "SHARED_LOADBALANCER_VIP"
  labels       = merge(local.app_labels, { usage = "vip" })
}

output "primary_internal_ip" { value = google_compute_address.primary_ip.address }
output "standby_internal_ip" { value = google_compute_address.standby_ip.address }
output "monitor_internal_ip" { value = google_compute_address.monitor_ip.address }
output "pg_vip_internal_ip" { value = google_compute_address.pg_vip.address }
