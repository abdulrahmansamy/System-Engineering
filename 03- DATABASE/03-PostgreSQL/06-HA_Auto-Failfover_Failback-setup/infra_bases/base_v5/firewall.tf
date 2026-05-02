#############################################
# Module 4: Firewall rules
#############################################

locals {
  fw_name_prefix = format("%s-%s-fw", local.org_code, local.env_code)
}

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

resource "google_compute_firewall" "allow_pg_monitor" {
  name    = format("%s-allow-pg-monitor", local.fw_name_prefix)
  project = var.host_project_id
  network = data.google_compute_network.shared_vpc.self_link

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["5431"]
  }
  source_ranges = local.firewall_db_cidrs_validated

  target_tags = ["pg", local.workspace_env]
  description = "Allow pg_auto_failover monitor traffic"
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
