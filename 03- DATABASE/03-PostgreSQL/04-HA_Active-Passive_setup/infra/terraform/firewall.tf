locals {
  subnet_cidr = var.subnet_cidr
}

resource "google_compute_firewall" "allow_internal_pg" {
  name    = "allow-internal-postgres"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["5432", "5431", "6432"]
  }
  source_ranges = [local.subnet_cidr]
  target_tags   = ["pg-ha"]
}

resource "google_compute_firewall" "allow_health" {
  name    = "allow-internal-health"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = [tostring(var.health_port)]
  }
  source_ranges = [local.subnet_cidr]
  target_tags   = ["pg-ha"]
}

resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "allow-ssh-from-iap"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["pg-ha-admin"]
}
