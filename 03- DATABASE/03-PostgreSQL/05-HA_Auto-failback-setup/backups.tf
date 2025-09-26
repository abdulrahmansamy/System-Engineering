#############################################
# Module 7: Backups to GCS with pgBackRest
#############################################

locals {
  backup_bucket_name = lower(format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "bkt", "pgbackrest", 1))
  pgbackrest_secret_id = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "pgbackrest-gcs-key", 1)
}

resource "google_service_account" "pgbackrest_sa" {
  account_id   = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sa", "pgbackrest", 1)
  display_name = "pgBackRest backup service account"
  project      = var.prod_db_project_id
}

resource "google_storage_bucket" "pgbackrest" {
  name          = local.backup_bucket_name
  project       = var.prod_db_project_id
  location      = var.storage_bucket_location
  storage_class = "STANDARD"
  uniform_bucket_level_access = true
  versioning { enabled = true }
  labels = merge(local.app_labels, { usage = "backup" })
  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 120 }
  }
}

resource "google_storage_bucket_iam_member" "pgbackrest_writer" {
  bucket = google_storage_bucket.pgbackrest.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pgbackrest_sa.email}"
}

resource "google_service_account_key" "pgbackrest_key" {
  service_account_id = google_service_account.pgbackrest_sa.name
  keepers = {
    rotation = timestamp()
  }
}

resource "google_secret_manager_secret" "pgbackrest_gcs_key" {
  project   = var.prod_db_project_id
  secret_id = local.pgbackrest_secret_id
  replication {
    auto {}
  }
  labels = merge(local.app_labels, { usage = "backup" })
}

resource "google_secret_manager_secret_version" "pgbackrest_gcs_key_v" {
  secret      = google_secret_manager_secret.pgbackrest_gcs_key.id
  secret_data = base64decode(google_service_account_key.pgbackrest_key.private_key)
}

# Allow the VM SA to read the backup key secret
resource "google_secret_manager_secret_iam_member" "pgbackrest_key_accessor" {
  project  = var.prod_db_project_id
  secret_id = google_secret_manager_secret.pgbackrest_gcs_key.id
  role     = "roles/secretmanager.secretAccessor"
  member   = "serviceAccount:${google_service_account.pg_sa.email}"
}

output "pgbackrest_bucket_name" {
  description = "Name of the GCS bucket for pgBackRest"
  value       = google_storage_bucket.pgbackrest.name
}

output "pgbackrest_secret_id" {
  description = "Secret Manager ID for pgBackRest GCS key"
  value       = google_secret_manager_secret.pgbackrest_gcs_key.secret_id
}
