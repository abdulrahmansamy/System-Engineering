# Terraform configuration for GCP PostgreSQL HA setup
# This creates all required infrastructure including compute instances, load balancers, storage, and security

terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Data sources
data "google_compute_network" "default" {
  name = "default"
}

# Create service account for PostgreSQL instances
resource "google_service_account" "postgresql_sa" {
  account_id   = "postgresql-ha-sa"
  display_name = "PostgreSQL HA Service Account"
  description  = "Service account for PostgreSQL HA cluster instances"
}

# Grant necessary IAM roles to service account
resource "google_project_iam_member" "postgresql_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.postgresql_sa.email}"
}

resource "google_project_iam_member" "postgresql_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.postgresql_sa.email}"
}

resource "google_project_iam_member" "postgresql_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.postgresql_sa.email}"
}

# Create GCS bucket for backups
resource "google_storage_bucket" "postgresql_backups" {
  name          = "${var.project_id}-postgresql-backups"
  location      = var.region
  storage_class = "STANDARD"
  
  versioning {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
  
  uniform_bucket_level_access = true
  
  public_access_prevention = "enforced"
}

# Grant service account access to backup bucket
resource "google_storage_bucket_iam_member" "postgresql_backup_access" {
  bucket = google_storage_bucket.postgresql_backups.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.postgresql_sa.email}"
}

# Firewall rules for PostgreSQL HA cluster
resource "google_compute_firewall" "postgresql_internal" {
  name    = "postgresql-ha-internal"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["5432", "6432"]
  }

  source_tags = ["postgresql-ha"]
  target_tags = ["postgresql-ha"]
  
  description = "Allow PostgreSQL and PgBouncer communication between HA cluster nodes"
}

resource "google_compute_firewall" "postgresql_health_check" {
  name    = "postgresql-ha-health-check"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  # GCP health check source ranges
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["postgresql-ha"]
  
  description = "Allow GCP load balancer health checks"
}

resource "google_compute_firewall" "postgresql_ssh" {
  name    = "postgresql-ha-ssh"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = ["postgresql-ha"]
  
  description = "Allow SSH access to PostgreSQL instances"
}

# Primary PostgreSQL instance
resource "google_compute_instance" "postgresql_primary" {
  name         = "${var.instance_prefix}-primary"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts"
      size  = var.boot_disk_size
      type  = var.boot_disk_type
    }
  }

  # Optional additional disk for PostgreSQL data
  dynamic "attached_disk" {
    for_each = var.data_disk_size > 0 ? [1] : []
    content {
      source      = google_compute_disk.postgresql_primary_data[0].id
      device_name = "postgresql-data"
    }
  }

  network_interface {
    network = data.google_compute_network.default.name
    access_config {
      # Ephemeral external IP
    }
  }

  metadata = {
    startup-script = templatefile("${path.module}/../01-pgsql_setup-primary-gcp.sh", {
      standby_ip     = google_compute_instance.postgresql_standby.network_interface[0].network_ip
      backup_bucket  = google_storage_bucket.postgresql_backups.name
    })
    standby-ip    = google_compute_instance.postgresql_standby.network_interface[0].network_ip
    backup-bucket = google_storage_bucket.postgresql_backups.name
    enable-oslogin = "TRUE"
  }

  service_account {
    email  = google_service_account.postgresql_sa.email
    scopes = ["cloud-platform"]
  }

  tags = ["postgresql-ha", "postgresql-primary"]

  # Ensure standby instance is created first to get IP
  depends_on = [google_compute_instance.postgresql_standby]

  labels = {
    environment = var.environment
    role        = "primary"
    app         = "postgresql"
  }
}

# Standby PostgreSQL instance
resource "google_compute_instance" "postgresql_standby" {
  name         = "${var.instance_prefix}-standby"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts"
      size  = var.boot_disk_size
      type  = var.boot_disk_type
    }
  }

  # Optional additional disk for PostgreSQL data
  dynamic "attached_disk" {
    for_each = var.data_disk_size > 0 ? [1] : []
    content {
      source      = google_compute_disk.postgresql_standby_data[0].id
      device_name = "postgresql-data"
    }
  }

  network_interface {
    network = data.google_compute_network.default.name
    access_config {
      # Ephemeral external IP
    }
  }

  metadata = {
    startup-script = file("${path.module}/../02-pgsql_setup-standby-gcp.sh")
    primary-ip     = google_compute_instance.postgresql_primary.network_interface[0].network_ip
    enable-oslogin = "TRUE"
  }

  service_account {
    email  = google_service_account.postgresql_sa.email
    scopes = ["cloud-platform"]
  }

  tags = ["postgresql-ha", "postgresql-standby"]

  labels = {
    environment = var.environment
    role        = "standby"
    app         = "postgresql"
  }
}

# Optional data disks for PostgreSQL instances
resource "google_compute_disk" "postgresql_primary_data" {
  count = var.data_disk_size > 0 ? 1 : 0
  
  name = "${var.instance_prefix}-primary-data"
  type = var.data_disk_type
  zone = var.zone
  size = var.data_disk_size
  
  labels = {
    environment = var.environment
    instance    = "primary"
  }
}

resource "google_compute_disk" "postgresql_standby_data" {
  count = var.data_disk_size > 0 ? 1 : 0
  
  name = "${var.instance_prefix}-standby-data"
  type = var.data_disk_type
  zone = var.zone
  size = var.data_disk_size
  
  labels = {
    environment = var.environment
    instance    = "standby"
  }
}

# Health check for load balancers
resource "google_compute_health_check" "postgresql_http" {
  name                = "${var.instance_prefix}-health-check"
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/"
  }
}

# Health check for TCP load balancer
resource "google_compute_health_check" "postgresql_tcp" {
  name                = "${var.instance_prefix}-tcp-health-check"
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = 5432
  }
}

# Instance group for primary
resource "google_compute_instance_group" "postgresql_primary" {
  name        = "${var.instance_prefix}-primary-ig"
  description = "PostgreSQL primary instance group"
  zone        = var.zone

  instances = [google_compute_instance.postgresql_primary.id]

  named_port {
    name = "postgresql"
    port = 5432
  }
  
  named_port {
    name = "pgbouncer"
    port = 6432
  }
  
  named_port {
    name = "health"
    port = 8080
  }
}

# Instance group for standby
resource "google_compute_instance_group" "postgresql_standby" {
  name        = "${var.instance_prefix}-standby-ig"
  description = "PostgreSQL standby instance group"
  zone        = var.zone

  instances = [google_compute_instance.postgresql_standby.id]

  named_port {
    name = "postgresql"
    port = 5432
  }
  
  named_port {
    name = "pgbouncer"
    port = 6432
  }
  
  named_port {
    name = "health"
    port = 8080
  }
}

# Backend service for HTTP load balancer (health/monitoring)
resource "google_compute_backend_service" "postgresql_http" {
  name                  = "${var.instance_prefix}-http-backend"
  description           = "PostgreSQL HTTP backend for monitoring and health checks"
  protocol              = "HTTP"
  port_name             = "health"
  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 10
  health_checks         = [google_compute_health_check.postgresql_http.id]

  backend {
    group           = google_compute_instance_group.postgresql_primary.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  backend {
    group           = google_compute_instance_group.postgresql_standby.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 0.5
  }
}

# Regional backend service for TCP load balancer (database connections)
resource "google_compute_region_backend_service" "postgresql_tcp" {
  name                  = "${var.instance_prefix}-tcp-backend"
  description           = "PostgreSQL TCP backend for database connections"
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL"
  region                = var.region
  health_checks         = [google_compute_health_check.postgresql_tcp.id]
  
  # Failover configuration - primary is active, standby is backup
  backend {
    group          = google_compute_instance_group.postgresql_primary.id
    failover       = false
    balancing_mode = "CONNECTION"
  }
  
  backend {
    group          = google_compute_instance_group.postgresql_standby.id
    failover       = true
    balancing_mode = "CONNECTION"
  }
  
  # Connection draining settings
  connection_draining_timeout_sec = 60
}

# URL map for HTTP load balancer
resource "google_compute_url_map" "postgresql_http" {
  name            = "${var.instance_prefix}-http-lb"
  default_service = google_compute_backend_service.postgresql_http.id
  
  host_rule {
    hosts        = ["*"]
    path_matcher = "allpaths"
  }
  
  path_matcher {
    name            = "allpaths"
    default_service = google_compute_backend_service.postgresql_http.id
    
    path_rule {
      paths   = ["/health"]
      service = google_compute_backend_service.postgresql_http.id
    }
    
    path_rule {
      paths   = ["/metrics"]
      service = google_compute_backend_service.postgresql_http.id
    }
  }
}

# HTTP proxy for load balancer
resource "google_compute_target_http_proxy" "postgresql" {
  name    = "${var.instance_prefix}-http-proxy"
  url_map = google_compute_url_map.postgresql_http.id
}

# Global forwarding rule for HTTP load balancer
resource "google_compute_global_forwarding_rule" "postgresql_http" {
  name                  = "${var.instance_prefix}-http-forwarding-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.postgresql.id
  ip_address            = google_compute_global_address.postgresql_http.id
}

# Regional forwarding rule for TCP load balancer
resource "google_compute_forwarding_rule" "postgresql_tcp" {
  name                  = "${var.instance_prefix}-tcp-forwarding-rule"
  region                = var.region
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "5432"
  backend_service       = google_compute_region_backend_service.postgresql_tcp.id
  ip_address            = google_compute_address.postgresql_tcp.id
}

# Static IP addresses for load balancers
resource "google_compute_global_address" "postgresql_http" {
  name         = "${var.instance_prefix}-http-ip"
  address_type = "EXTERNAL"
}

resource "google_compute_address" "postgresql_tcp" {
  name         = "${var.instance_prefix}-tcp-ip"
  region       = var.region
  address_type = "EXTERNAL"
}

# Cloud DNS zone (optional)
resource "google_dns_managed_zone" "postgresql" {
  count       = var.create_dns_zone ? 1 : 0
  name        = "${var.instance_prefix}-zone"
  dns_name    = "${var.dns_domain}."
  description = "DNS zone for PostgreSQL HA cluster"
}

# DNS records for load balancers
resource "google_dns_record_set" "postgresql_http" {
  count        = var.create_dns_zone ? 1 : 0
  name         = "postgresql-http.${var.dns_domain}."
  managed_zone = google_dns_managed_zone.postgresql[0].name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.postgresql_http.address]
}

resource "google_dns_record_set" "postgresql_tcp" {
  count        = var.create_dns_zone ? 1 : 0
  name         = "postgresql.${var.dns_domain}."
  managed_zone = google_dns_managed_zone.postgresql[0].name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.postgresql_tcp.address]
}

# Monitoring notification channel (optional)
resource "google_monitoring_notification_channel" "email" {
  count        = length(var.notification_emails)
  display_name = "Email Notification ${count.index + 1}"
  type         = "email"
  
  labels = {
    email_address = var.notification_emails[count.index]
  }
}

# Uptime check for PostgreSQL HTTP endpoint
resource "google_monitoring_uptime_check_config" "postgresql_http" {
  display_name = "${var.instance_prefix} HTTP Health Check"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/health"
    port         = "80"
    use_ssl      = false
    request_method = "GET"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = google_compute_global_address.postgresql_http.address
    }
  }

  checker_type = "STATIC_IP_CHECKERS"
}

# Alert policy for PostgreSQL uptime
resource "google_monitoring_alert_policy" "postgresql_uptime" {
  count        = length(var.notification_emails) > 0 ? 1 : 0
  display_name = "${var.instance_prefix} Uptime Alert"
  combiner     = "OR"
  
  conditions {
    display_name = "PostgreSQL HTTP endpoint is down"
    
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" resource.type=\"uptime_url\""
      duration        = "300s"
      comparison      = "COMPARISON_EQUAL"
      threshold_value = 0
      
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_FRACTION_TRUE"
      }
    }
  }

  notification_channels = google_monitoring_notification_channel.email[*].name

  alert_strategy {
    auto_close = "1800s"
  }
}
