resource "google_project_service" "secretmanager" {
  provider = google.db_projects
#   project  = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  service  = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cert_manager" {
  provider = google.db_projects
  project  = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  service  = "certificatemanager.googleapis.com"
  disable_on_destroy = false
}
