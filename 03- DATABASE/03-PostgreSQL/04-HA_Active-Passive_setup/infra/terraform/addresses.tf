resource "google_compute_address" "primary" {
  name         = "pg-primary-ip"
  address_type = "INTERNAL"
  address      = var.primary_ip
  subnetwork   = google_compute_subnetwork.subnet.id
  region       = var.region
}

resource "google_compute_address" "secondary" {
  name         = "pg-secondary-ip"
  address_type = "INTERNAL"
  address      = var.secondary_ip
  subnetwork   = google_compute_subnetwork.subnet.id
  region       = var.region
}

resource "google_compute_address" "monitor" {
  name         = "pg-monitor-ip"
  address_type = "INTERNAL"
  address      = var.monitor_ip
  subnetwork   = google_compute_subnetwork.subnet.id
  region       = var.region
}

resource "google_compute_address" "vip" {
  name         = "pg-vip-ip"
  address_type = "INTERNAL"
  address      = var.vip_ip
  subnetwork   = google_compute_subnetwork.subnet.id
  region       = var.region
}
