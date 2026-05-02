# IAM Permissions for Load Balancer Management
# Grants PostgreSQL VM service accounts permission to modify load balancers during failover

# Grant compute load balancer admin permissions to DB service account
resource "google_project_iam_member" "pg_sa_loadbalancer_admin" {
  provider = google.db_projects
  project  = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  role     = "roles/compute.loadBalancerAdmin"
  member   = "serviceAccount:${google_service_account.pg_sa.email}"
}

# Grant compute instance admin permissions (needed to read instance groups)
resource "google_project_iam_member" "pg_sa_instance_admin" {
  provider = google.db_projects
  project  = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  role     = "roles/compute.instanceAdmin.v1"
  member   = "serviceAccount:${google_service_account.pg_sa.email}"
}

# Grant compute network viewer (to read VPC and networking info)
resource "google_project_iam_member" "pg_sa_network_viewer" {
  provider = google.db_projects
  project  = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  role     = "roles/compute.networkViewer"
  member   = "serviceAccount:${google_service_account.pg_sa.email}"
}

# Output the service account email for reference
output "pg_service_account_email" {
  description = "Service account email used by PostgreSQL VMs"
  value       = google_service_account.pg_sa.email
}

output "pg_sa_iam_roles" {
  description = "IAM roles granted to PostgreSQL service account"
  value = [
    "roles/compute.loadBalancerAdmin",
    "roles/compute.instanceAdmin.v1",
    "roles/compute.networkViewer"
  ]
}
