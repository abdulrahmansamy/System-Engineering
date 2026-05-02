#############################################
# Module 10: Internal Load Balancer (PgBouncer)
#############################################

locals {
  ilb_name_base = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ilb", "pgbouncer", 1)
  ilb_labels    = merge(local.app_labels, { component = "ilb", layer = "pgbouncer" })
}

# Instance groups per zone (unmanaged) to register instances as ILB backends
resource "google_compute_instance_group" "pg_primary_group" {
  count       = var.ilb_enabled ? 1 : 0
  provider    = google.db_projects
  name        = "${local.ilb_name_base}-primary-group"
  zone        = var.ha_db_primary_zone
  instances   = [google_compute_instance.primary.self_link]
  network     = local.is_production ? data.google_compute_subnetwork.prod_db.network : data.google_compute_subnetwork.nonprod_db.network
  description = "Unmanaged instance group for primary PostgreSQL PgBouncer"
}

resource "google_compute_instance_group" "pg_standby_group" {
  count       = var.ilb_enabled ? 1 : 0
  provider    = google.db_projects
  name        = "${local.ilb_name_base}-standby-group"
  zone        = var.ha_db_secondary_zone
  instances   = [google_compute_instance.standby.self_link]
  network     = local.is_production ? data.google_compute_subnetwork.prod_db.network : data.google_compute_subnetwork.nonprod_db.network
  description = "Unmanaged instance group for standby PostgreSQL PgBouncer"
}

# TCP health check against PgBouncer port
resource "google_compute_health_check" "pgbouncer_tcp" {
  count               = var.ilb_enabled ? 1 : 0
  provider            = google.db_projects
  name                = "${local.ilb_name_base}-hc"
  timeout_sec         = var.ilb_health_check_timeout
  check_interval_sec  = var.ilb_health_check_interval
  healthy_threshold   = var.ilb_health_healthy_threshold
  unhealthy_threshold = var.ilb_health_unhealthy_threshold

  tcp_health_check {
    port = var.ilb_port
  }

  log_config {
    enable = false
  }
}

# Regional backend service (Internal passthrough ILB requires region backend service)
resource "google_compute_region_backend_service" "pgbouncer_backend" {
  count                  = var.ilb_enabled ? 1 : 0
  provider               = google.db_projects
  name                   = "${local.ilb_name_base}-bs"
  protocol               = "TCP"
  load_balancing_scheme  = "INTERNAL"
  region                 = var.region
  session_affinity       = "NONE"
  timeout_sec            = 30
  health_checks          = [google_compute_health_check.pgbouncer_tcp[0].self_link]

  backend {
    group = google_compute_instance_group.pg_primary_group[0].self_link
  }
  backend {
    group = google_compute_instance_group.pg_standby_group[0].self_link
  }

  lifecycle {
    ignore_changes = [backend]
  }
}

# Forwarding rule using pre-reserved VIP address
resource "google_compute_forwarding_rule" "pgbouncer_ilb" {
  count                 = var.ilb_enabled ? 1 : 0
  provider              = google.db_projects
  name                  = "${local.ilb_name_base}-fr"
  load_balancing_scheme = "INTERNAL"
  ip_protocol           = "TCP"
  ports                 = [tostring(var.ilb_port)]
  network               = local.is_production ? data.google_compute_subnetwork.prod_db.network : data.google_compute_subnetwork.nonprod_db.network
  subnetwork            = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
  backend_service       = google_compute_region_backend_service.pgbouncer_backend[0].self_link
  ip_address            = google_compute_address.pg_vip.address
  region                = var.region
}

output "ilb_pgbouncer_ip" {
  value       = var.ilb_enabled ? google_compute_forwarding_rule.pgbouncer_ilb[0].ip_address : null
  description = "Internal Load Balancer IP for PgBouncer"
}

output "ilb_pgbouncer_port" {
  value       = var.ilb_enabled ? var.ilb_port : null
  description = "Port exposed by the ILB for PgBouncer"
}

#############################################
# Optional Internal DNS Record
#############################################

variable "ilb_dns_record_name" {
  description = "Relative DNS record (without domain) for ILB PgBouncer endpoint"
  type        = string
  default     = "pg-ha"
}

variable "ilb_dns_zone_domain" {
  description = "DNS domain to use (must end with a dot) if creating zone/record"
  type        = string
  default     = "ha.internal."
}

variable "create_ilb_dns_zone" {
  description = "Whether to create a private DNS zone for the ILB"
  type        = bool
  default     = false
}

resource "google_dns_managed_zone" "ilb_internal" {
  count       = var.ilb_enabled && var.create_ilb_dns_zone ? 1 : 0
  name        = "${local.org_code}-${local.env_code}-ilb-pg"
  dns_name    = var.ilb_dns_zone_domain
  description = "Private zone for HA PgBouncer ILB"
  visibility  = "private"
  project     = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id

  private_visibility_config {
    networks {
      network_url = local.is_production ? data.google_compute_subnetwork.prod_db.network : data.google_compute_subnetwork.nonprod_db.network
    }
  }

  depends_on = [ google_project_service.dns ]
}

resource "google_dns_record_set" "ilb_pgbouncer_a" {
  count        = var.ilb_enabled && var.create_ilb_dns_zone ? 1 : 0
  managed_zone = google_dns_managed_zone.ilb_internal[0].name
  name         = "${var.ilb_dns_record_name}.${var.ilb_dns_zone_domain}"
  type         = "A"
  ttl          = 30
  rrdatas      = [google_compute_forwarding_rule.pgbouncer_ilb[0].ip_address]
  project      = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
}

output "ilb_pgbouncer_fqdn" {
  value       = (var.ilb_enabled && var.create_ilb_dns_zone) ? google_dns_record_set.ilb_pgbouncer_a[0].name : null
  description = "FQDN for PgBouncer ILB endpoint"
}

