resource "google_compute_instance_group" "primary_group" {
  name = "pg-primary-ig"
  zone = var.primary_zone
  instances = [google_compute_instance.primary.self_link]
  named_port {
    name = "pgbouncer"
    port = 6432
  }
}

resource "google_compute_instance_group" "secondary_group" {
  name = "pg-secondary-ig"
  zone = var.secondary_zone
  instances = [google_compute_instance.secondary.self_link]
  named_port {
    name = "pgbouncer"
    port = 6432
  }
}

resource "google_compute_health_check" "pg_health" {
  name               = "pg-ha-health"
  check_interval_sec = 2
  timeout_sec        = 1
  healthy_threshold  = 1
  unhealthy_threshold= 2
  tcp_health_check { port = var.health_port }
  log_config { enable = true }
}

resource "google_compute_region_backend_service" "pg_ilb_bes" {
  name                  = "pg-ilb-bes"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  protocol              = "TCP"
  health_checks         = [google_compute_health_check.pg_health.id]
  session_affinity      = "NONE"
  timeout_sec           = 10

  backend {
    group = google_compute_instance_group.primary_group.self_link
  }
  backend {
    group = google_compute_instance_group.secondary_group.self_link
  }
}

resource "google_compute_forwarding_rule" "pg_ilb" {
  name                  = "pg-ilb"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  ip_protocol           = "TCP"
  ports                 = ["6432"]
  subnetwork            = google_compute_subnetwork.subnet.id
  network               = google_compute_network.vpc.id
  backend_service       = google_compute_region_backend_service.pg_ilb_bes.id
  ip_address             = google_compute_address.vip.address
}
