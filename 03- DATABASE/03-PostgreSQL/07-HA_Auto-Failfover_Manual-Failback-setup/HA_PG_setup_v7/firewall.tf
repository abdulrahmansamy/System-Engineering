#############################################
# Module 4: Firewall rules
#############################################

# locals {
#   fw_name_prefix = format("%s-%s-fw", local.org_code, local.env_code)
# }

resource "google_compute_firewall" "allow_ssh" {
  name    = format("%s-allow-ssh", local.fw_name_prefix)
  project = var.host_project_id
  network = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = concat(local.firewall_app_cidrs_validated, local.firewall_db_cidrs_validated)

  target_tags = ["pg", local.workspace_env]
  description = "Allow SSH to PG hosts from approved ranges"
}

resource "google_compute_firewall" "allow_pg" {
  name    = format("%s-allow-pg", local.fw_name_prefix)
  project = var.host_project_id
  network = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
  source_ranges = local.firewall_db_cidrs_validated

  target_tags = ["pg", local.workspace_env]
  description = "Allow Postgres traffic within DB subnet"
}

resource "google_compute_firewall" "allow_pg_health" {
  name    = format("%s-allow-pg-health", local.fw_name_prefix)
  project = var.host_project_id
  network = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = [tostring(var.pg_health_port)]
  }
  source_ranges = local.firewall_db_cidrs_validated

  target_tags = ["pg", local.workspace_env]
  description = "Allow role-aware primary health endpoint (repmgr-based)"
}

resource "google_compute_firewall" "allow_icmp_internal" {
  name    = format("%s-allow-icmp-internal", local.fw_name_prefix)
  project = var.host_project_id
  network = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow { protocol = "icmp" }
  source_ranges = concat(local.firewall_app_cidrs_validated, local.firewall_db_cidrs_validated)

  target_tags = ["pg", local.workspace_env]
  description = "Allow ICMP within DB subnet"
}

resource "google_compute_firewall" "allow_pgbouncer" {
  name    = format("%s-allow-pgbouncer", local.fw_name_prefix)
  project = var.host_project_id
  network = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["6432"]
  }
  source_ranges = local.firewall_db_cidrs_validated

  target_tags = ["pgbouncer"]
  description = "Allow PgBouncer traffic from app and db subnets"
}

# resource "google_compute_firewall" "allow_pgbouncer_health" {
#   name    = format("%s-allow-pgbouncer-health", local.fw_name_prefix)
#   project = var.host_project_id
#   network = data.google_compute_network.shared_vpc.self_link

#   direction = "INGRESS"
#   priority  = 1000

#   allow {
#     protocol = "tcp"
#     ports    = ["8002"]
#   }
#   source_ranges = concat(
#     local.firewall_db_cidrs_validated,
#     local.firewall_app_cidrs_validated,
#     [
#       "35.191.0.0/16",    # Google Cloud external load balancer health checks
#       "130.211.0.0/22",   # Google Cloud external load balancer health checks
#       "35.235.240.0/20"   # Google Cloud internal load balancer health checks
#     ]
#   )

#   target_tags = ["pg", local.workspace_env]
#   description = "Allow PgBouncer health endpoint access from subnets and GCP load balancer health checks"
# }


resource "google_compute_firewall" "pgbouncer_health_check" {
  name        = "${local.fw_name_prefix}-allow-pgbouncer-health"
  # description = "Allow health check access to PgBouncer"
  description = "Allow PgBouncer health endpoint access from subnets and GCP load balancer health checks"
  project     = var.host_project_id
  network     = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["8002"]
  }

  # Google Cloud health check source ranges
  source_ranges = concat(
    local.firewall_db_cidrs_validated,
    local.firewall_app_cidrs_validated,
    [
      "35.191.0.0/16",    # Google Cloud external load balancer health checks
      "130.211.0.0/22",   # Google Cloud external load balancer health checks
      "35.235.240.0/20"   # Google Cloud internal load balancer health checks
    ]
  )

  target_tags = ["pg", local.workspace_env]
}

resource "google_compute_firewall" "allow_bastion_to_pgbouncer_write" {
  name    = format("%s-allow-bastion-pgbouncer-write", local.fw_name_prefix)
  project = var.host_project_id
  network = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["6432"]
  }

  source_tags = ["bastion"]
  target_tags = ["pg", local.workspace_env]
  
  description = "Allow bastion host access to PgBouncer write VIP"
}

resource "google_compute_firewall" "allow_bastion_to_pgbouncer_read" {
  name    = format("%s-allow-bastion-pgbouncer-read", local.fw_name_prefix)
  project = var.host_project_id
  network = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["6432"]
  }

  source_tags = ["bastion"]
  target_tags = ["pg", local.workspace_env]
  
  description = "Allow bastion host access to PgBouncer read VIP"
}
