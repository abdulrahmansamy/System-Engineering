resource "google_service_account" "pg_nodes" {
  account_id   = "pg-node-sa"
  display_name = "PostgreSQL Nodes Service Account"
}

resource "google_service_account" "pg_monitor" {
  account_id   = "pg-monitor-sa"
  display_name = "pg_auto_failover Monitor Service Account"
}

locals {
  base_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/secretmanager.secretAccessor",
    "roles/storage.objectAdmin"
  ]
}

resource "google_project_iam_member" "pg_nodes_roles" {
  for_each = toset(local.base_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.pg_nodes.email}"
}

resource "google_project_iam_member" "pg_monitor_roles" {
  for_each = toset(local.base_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.pg_monitor.email}"
}
