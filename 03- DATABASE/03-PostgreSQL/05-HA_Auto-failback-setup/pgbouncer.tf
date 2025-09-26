#############################################
# Module 6: PgBouncer + Internal TCP Load Balancer
#############################################

locals {
  pgb_name = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ha", "pgbouncer", 1)
}

resource "google_compute_instance_template" "pgb_template" {
  name_prefix  = "${local.pgb_name}-tmpl-"
  project      = var.prod_db_project_id
  machine_type = "e2-standard-4"
  tags         = ["pg", "pgbouncer", "pg17"]

  disk {
    source_image = var.ubuntu_minimal_2404_image
    auto_delete  = true
    boot         = true
    disk_type    = var.ha_db_boot_disk_type
    disk_size_gb = 30
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.prod_app.self_link
  }

  service_account {
    email  = google_service_account.pg_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    "startup-script" = file("${path.module}/scripts/pgbouncer_setup.sh")
    timezone          = var.timezone
  }
  labels = local.app_labels
}

resource "google_compute_health_check" "pgb_hc" {
  name    = format("%s-%s", local.pgb_name, "hc")
  project = var.prod_db_project_id
  tcp_health_check {
    port = 6432
  }
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
}

resource "google_compute_region_instance_group_manager" "pgb_rigm" {
  name               = format("%s-%s", local.pgb_name, "rigm")
  project            = var.prod_db_project_id
  base_instance_name = local.pgb_name
  region             = var.region
  version { instance_template = google_compute_instance_template.pgb_template.id }
  target_size        = 2
  distribution_policy_zones = [var.ha_db_primary_zone, var.ha_db_secondary_zone]
  update_policy {
    minimal_action    = "REPLACE"
    type              = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
  }
}

# Internal TCP LB (regional) using backend MIG
resource "google_compute_region_backend_service" "pgb_backend" {
  name                  = format("%s-%s", local.pgb_name, "bsvc")
  project               = var.prod_db_project_id
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  protocol              = "TCP"
  session_affinity      = "NONE"
  health_checks         = [google_compute_health_check.pgb_hc.id]
  backend {
    group = google_compute_region_instance_group_manager.pgb_rigm.instance_group
  }
}

resource "google_compute_forwarding_rule" "pgb_ilb" {
  name                  = format("%s-%s", local.pgb_name, "fr")
  project               = var.prod_db_project_id
  region                = var.region
  ip_address            = google_compute_address.pg_vip.id
  load_balancing_scheme = "INTERNAL"
  ports                 = ["6432"]
  network               = data.google_compute_network.shared_vpc.self_link
  subnetwork            = data.google_compute_subnetwork.prod_db.self_link
  backend_service       = google_compute_region_backend_service.pgb_backend.id
  ip_protocol           = "TCP"
}
