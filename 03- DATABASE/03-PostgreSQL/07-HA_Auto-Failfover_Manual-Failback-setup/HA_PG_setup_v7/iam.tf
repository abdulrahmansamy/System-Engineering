
# Grant compute instance service account permissions to modify load balancers
resource "google_project_iam_member" "vm_sa_compute_admin" {
  provider = google.db_projects
  project  = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  role     = "roles/compute.instanceAdmin.v1"
  member   = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_project_iam_member" "vm_sa_compute_loadbalancer_admin" {
  provider = google.db_projects
  project  = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  role     = "roles/compute.loadBalancerAdmin"
  member   = "serviceAccount:${google_service_account.pg_sa.email}"
}