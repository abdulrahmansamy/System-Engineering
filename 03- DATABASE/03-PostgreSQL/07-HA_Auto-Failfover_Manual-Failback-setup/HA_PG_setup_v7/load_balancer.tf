# GCP Internal Load Balancer for PostgreSQL HA with PgBouncer
# private_zone_dns_name = "${var.internal_db_dns_zone}.${local.env_code}.${var.base_dns_domain}."
# This configuration creates health checks and load balancing for the PostgreSQL cluster

locals {
  # Naming: [org]-[env]-[resource-type]-[purpose]-[instance]
  load_balancer_names = {
    primary                = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "lb", "pg-primary", 1)
    standby                = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "lb", "pg-standby", 1)
    health_check           = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "hc", "pgbouncer-health", 1)
    backend_service_write  = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "bs", "pgbouncer-write", 1)
    backend_service_read   = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "bs", "pgbouncer-read", 1)
    instance_group_primary = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ig", "pg-primary-group", 1)
    instance_group_standby = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ig", "pg-standby-group", 1)
    forwarding_rule_write  = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "fr", "pgbouncer-write", 1)
    forwarding_rule_read   = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "fr", "pgbouncer-read", 1)
    pgbouncer_write_ip     = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ip", "pgbouncer-write", 1)
    pgbouncer_read_ip      = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "ip", "pgbouncer-read", 2)
  }
  # private_zone_dns_name = "${var.internal_db_dns_zone}.${local.env_code}.${var.base_dns_domain}"
}

# Health check for PgBouncer
resource "google_compute_health_check" "pgbouncer_health_check" {
  provider    = google.db_projects
  name        = local.load_balancer_names.health_check
  description = "Health check for PgBouncer connection pooler"

  timeout_sec         = var.ilb_health_check_timeout
  check_interval_sec  = var.ilb_health_check_interval
  healthy_threshold   = var.ilb_health_healthy_threshold
  unhealthy_threshold = var.ilb_health_unhealthy_threshold

  http_health_check {
    port               = 8002
    request_path       = "/"
    port_specification = "USE_FIXED_PORT"
  }

  log_config {
    enable = true
  }
}

# Backend service for write operations (primary only)
resource "google_compute_region_backend_service" "pgbouncer_write" {
  provider              = google.db_projects
  name                  = local.load_balancer_names.backend_service_write
  description           = "Backend service for PostgreSQL write operations"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"

  health_checks = [google_compute_health_check.pgbouncer_health_check.id]

  backend {
    group          = google_compute_instance_group.pg_primary_group.id
    balancing_mode = "CONNECTION"
  }

  session_affinity = "CLIENT_IP"

  connection_draining_timeout_sec = var.ilb_backend_connection_draining_timeout
}

# Backend service for read operations (both nodes with preference for standby)
resource "google_compute_region_backend_service" "pgbouncer_read" {
  provider              = google.db_projects
  name                  = local.load_balancer_names.backend_service_read
  description           = "Backend service for PostgreSQL read operations"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"

  health_checks = [google_compute_health_check.pgbouncer_health_check.id]

  # Standby backend (primary choice for reads)
  backend {
    group          = google_compute_instance_group.pg_standby_group.id
    balancing_mode = "CONNECTION"
  }

  # # Primary backend (fallback for reads)
  # backend {
  #   group          = google_compute_instance_group.pg_primary_group.id
  #   balancing_mode = "CONNECTION"
  # }

  session_affinity = "NONE" # Allow load balancing for reads

  connection_draining_timeout_sec = var.ilb_backend_connection_draining_timeout
}

# Instance groups for load balancer backends
resource "google_compute_instance_group" "pg_primary_group" {
  provider    = google.db_projects
  name        = local.load_balancer_names.instance_group_primary
  description = "Instance group for PostgreSQL primary node"
  zone        = var.ha_db_primary_zone

  instances = [google_compute_instance.pg_primary.id]

  named_port {
    name = "pgbouncer"
    port = 6432
  }

  named_port {
    name = "health"
    port = 8002
  }

  depends_on = [google_compute_instance.pg_primary]
}

resource "google_compute_instance_group" "pg_standby_group" {
  provider    = google.db_projects
  name        = local.load_balancer_names.instance_group_standby
  description = "Instance group for PostgreSQL standby node"
  zone        = var.ha_db_secondary_zone

  instances = [google_compute_instance.pg_standby.id]

  named_port {
    name = "pgbouncer"
    port = 6432
  }

  named_port {
    name = "health"
    port = 8002
  }

  depends_on = [google_compute_instance.pg_standby]
}

# Forwarding rule for write operations
resource "google_compute_forwarding_rule" "pgbouncer_write" {
  provider              = google.db_projects
  name                  = local.load_balancer_names.forwarding_rule_write
  description           = "Forwarding rule for PostgreSQL write operations"
  region                = var.region
  load_balancing_scheme = "INTERNAL"

  backend_service = google_compute_region_backend_service.pgbouncer_write.id

  ip_address  = google_compute_address.pgbouncer_write_ip.address
  ip_protocol = "TCP"
  ports       = ["6432"]

  network    = data.google_compute_network.shared_vpc.id
  subnetwork = local.is_production ? data.google_compute_subnetwork.prod_db.id : data.google_compute_subnetwork.nonprod_db.id
}

# Forwarding rule for read operations
resource "google_compute_forwarding_rule" "pgbouncer_read" {
  provider              = google.db_projects
  name                  = local.load_balancer_names.forwarding_rule_read
  description           = "Forwarding rule for PostgreSQL read operations"
  region                = var.region
  load_balancing_scheme = "INTERNAL"

  backend_service = google_compute_region_backend_service.pgbouncer_read.id

  ip_address  = google_compute_address.pgbouncer_read_ip.address
  ip_protocol = "TCP"
  ports       = ["6432"]

  network    = data.google_compute_network.shared_vpc.id
  subnetwork = local.is_production ? data.google_compute_subnetwork.prod_db.id : data.google_compute_subnetwork.nonprod_db.id
}

# Reserved IP addresses for load balancers
resource "google_compute_address" "pgbouncer_write_ip" {
  provider     = google.db_projects
  name         = local.load_balancer_names.pgbouncer_write_ip
  description  = "Internal IP for PostgreSQL write operations"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
  purpose      = "GCE_ENDPOINT"
  labels       = merge(local.app_labels, { pg_role = "write-lb" })
}

resource "google_compute_address" "pgbouncer_read_ip" {
  provider     = google.db_projects
  name         = local.load_balancer_names.pgbouncer_read_ip
  description  = "Internal IP for PostgreSQL read operations"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.is_production ? data.google_compute_subnetwork.prod_db.self_link : data.google_compute_subnetwork.nonprod_db.self_link
  purpose      = "GCE_ENDPOINT"
  labels       = merge(local.app_labels, { pg_role = "read-lb" })
}

# Firewall rules for PgBouncer and health checks
resource "google_compute_firewall" "pgbouncer_access" {
  name        = "${local.fw_name_prefix}-allow-pgbouncer-lb"
  description = "Allow access to PgBouncer connection pooler from load balancer"
  project     = var.host_project_id
  network     = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["6432"]
  }

  source_ranges = local.is_production ? [var.prod_db_subnet_cidr, var.prod_app_subnet_cidr] : [var.nonprod_db_subnet_cidr, var.nonprod_app_subnet_cidr]

  target_tags = ["pg", local.workspace_env]
}



# Create DNS private managed zone for db project for HA PostgreSQL
resource "google_dns_managed_zone" "private_zone" {
  count = var.create_dns_records ? 1 : 0

  provider = google.db_projects
  name     = "${local.org_code}-${local.env_code}-dns-zone-ha-pg"
  # dns_name = "${local.private_zone_dns_name}."
  dns_name = "${var.internal_db_dns_zone}.${local.env_code}.${var.base_dns_domain}." 

  description = "Private DNS zone for PostgreSQL HA cluster"

  visibility = "private"

  private_visibility_config {
    networks {
      network_url = data.google_compute_network.shared_vpc.id
    }
  }

  labels = merge(local.app_labels, { usage = "postgres-ha-dns" })

  depends_on = [google_project_service.dns]
}

# DNS records for load balancer endpoints
resource "google_dns_record_set" "pgbouncer_write" {
  provider = google.db_projects
  count    = var.create_dns_records ? 1 : 0

  name         = "pg-write.${google_dns_managed_zone.private_zone[0].dns_name}"
  managed_zone = google_dns_managed_zone.private_zone[0].name
  type         = "A"
  ttl          = 60

  rrdatas = [google_compute_address.pgbouncer_write_ip.address]
}

resource "google_dns_record_set" "pgbouncer_read" {
  provider = google.db_projects
  count    = var.create_dns_records ? 1 : 0

  name         = "pg-read.${google_dns_managed_zone.private_zone[0].dns_name}"
  managed_zone = google_dns_managed_zone.private_zone[0].name
  type         = "A"
  ttl          = 60

  rrdatas = [google_compute_address.pgbouncer_read_ip.address]
}

# Output the connection endpoints
output "pgbouncer_write_endpoint" {
  description = "PgBouncer write endpoint (primary only)"
  value = {
    ip_address = google_compute_address.pgbouncer_write_ip.address
    port       = 6432
    dns_name   = var.create_dns_records ? google_dns_record_set.pgbouncer_write[0].name : null
  }
}

output "pgbouncer_read_endpoint" {
  description = "PgBouncer read endpoint (load balanced)"
  value = {
    ip_address = google_compute_address.pgbouncer_read_ip.address
    port       = 6432
    dns_name   = var.create_dns_records ? google_dns_record_set.pgbouncer_read[0].name : null
  }
}

output "connection_examples" {
  description = "Example connection strings for applications"
  value = {
    write_connection = "postgresql://username:password@${google_compute_address.pgbouncer_write_ip.address}:6432/database_name"
    read_connection  = "postgresql://username:password@${google_compute_address.pgbouncer_read_ip.address}:6432/database_name"
    write_dns        = var.create_dns_records ? "postgresql://username:password@${trimsuffix(google_dns_record_set.pgbouncer_write[0].name, ".")}:6432/database_name" : null
    read_dns         = var.create_dns_records ? "postgresql://username:password@${trimsuffix(google_dns_record_set.pgbouncer_read[0].name, ".")}:6432/database_name" : null
  }
}

# Variables for load balancer configuration
# variable "create_dns_records" {
#   description = "Whether to create DNS records for load balancer endpoints"
#   type        = bool
#   default     = true
# }

variable "enable_connection_draining" {
  description = "Enable connection draining for backend services"
  type        = bool
  default     = true
}


/*
# Create DNS private managed zone for app projects for HA PostgreSQL
resource "google_dns_managed_zone" "private_zone_app_project" {
  count = var.create_dns_records ? 1 : 0

  provider = google.app_projects
  name     = "${local.org_code}-${local.env_code}-dns-zone-ha-pg"
  dns_name = "${local.private_zone_dns_name}."
  # dns_name = "${var.internal_db_dns_zone}${local.env_code}.${var.base_dns_domain}." --- IGNORE ---

  description = "Private DNS zone for PostgreSQL HA cluster"

  visibility = "private"

  private_visibility_config {
    networks {
      network_url = data.google_compute_network.shared_vpc.id
    }
  }

  labels = merge(local.app_labels, { usage = "postgres-ha-dns" })

  depends_on = [google_project_service.dns]
}



*/

locals {
  base_dns_domain       = "ipa.edu.sa"
  private_zone_dns_name = "internal.${local.base_dns_domain}"
  db_internal_dns       = "${var.db_subdomain}.${local.env_code}"
  db_internal_dns_fqdn  = "${local.db_internal_dns}.${local.private_zone_dns_name}"
  labels = {
    environment = local.workspace_env
    managed_by  = "terraform"
    project     = "ipa-nomination-platform-infrastructure"
    owner       = "infra-team"
  }
}

data "google_dns_managed_zone" "internal_dns_private_zone" {
  name     = "internal-private-dns-zone-01"
  project  = var.host_project_id
}

# DNS records for load balancer endpoints
resource "google_dns_record_set" "pgbouncer_write_internal_dns_zone" {
  provider = google.host 
  count    = var.create_dns_records ? 1 : 0

  name         = "pg-write.${local.db_internal_dns}.${data.google_dns_managed_zone.internal_dns_private_zone.dns_name}"
  managed_zone = data.google_dns_managed_zone.internal_dns_private_zone.name
  type         = "A"
  ttl          = 300

  rrdatas = [google_compute_address.pgbouncer_write_ip.address]
}

resource "google_dns_record_set" "pgbouncer_read_internal_dns_zone" {
  provider = google.host 
  count    = var.create_dns_records ? 1 : 0

  name         = "pg-read.${local.db_internal_dns}.${data.google_dns_managed_zone.internal_dns_private_zone.dns_name}"
  managed_zone = data.google_dns_managed_zone.internal_dns_private_zone.name
  type         = "A"
  ttl          = 300

  rrdatas = [google_compute_address.pgbouncer_read_ip.address]
}