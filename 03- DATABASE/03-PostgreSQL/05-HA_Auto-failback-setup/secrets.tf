############################################################
# Module 3: Secret Manager integration (no secret versions)
############################################################

variable "create_secrets" {
  description = "Whether to create Secret Manager secrets in this environment"
  type        = bool
  default     = true
}

locals {
  secret_ids = {
    pg_superuser = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "pg-superuser-password", 1)
    pg_repl      = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "pg-replication-password", 1)
    pg_monitor   = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "pg-monitor-password", 1)
    pgbouncer    = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "pgbouncer-auth", 1)
    tls_ca       = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "tls-ca", 1)
    tls_crt      = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "tls-server-crt", 1)
    tls_key      = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "tls-server-key", 1)
  }
}

# Project-level roles for VM SA to emit logs/metrics
resource "google_project_iam_member" "sa_logging" {
  project = var.prod_db_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_project_iam_member" "sa_monitoring" {
  project = var.prod_db_project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret" "pg_superuser" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = local.secret_ids.pg_superuser
  replication {
    auto {}
  }
  labels = local.app_labels
}

resource "google_secret_manager_secret" "pg_repl" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = local.secret_ids.pg_repl
  replication {
    auto {}
  }
  labels = local.app_labels
}

resource "google_secret_manager_secret" "pg_monitor" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = local.secret_ids.pg_monitor
  replication {
    auto {}
  }
  labels = local.app_labels
}

resource "google_secret_manager_secret" "pgbouncer" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = local.secret_ids.pgbouncer
  replication {
    auto {}
  }
  labels = local.app_labels
}

resource "google_secret_manager_secret" "tls_ca" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = local.secret_ids.tls_ca
  replication {
    auto {}
  }
  labels = merge(local.app_labels, { usage = "tls" })
}

resource "google_secret_manager_secret" "tls_crt" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = local.secret_ids.tls_crt
  replication {
    auto {}
  }
  labels = merge(local.app_labels, { usage = "tls" })
}

resource "google_secret_manager_secret" "tls_key" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = local.secret_ids.tls_key
  replication {
    auto {}
  }
  labels = merge(local.app_labels, { usage = "tls" })
}

# Least-privilege secret access for the VM service account
resource "google_secret_manager_secret_iam_member" "pg_superuser_accessor" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = google_secret_manager_secret.pg_superuser[0].id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "pg_repl_accessor" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = google_secret_manager_secret.pg_repl[0].id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "pg_monitor_accessor" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = google_secret_manager_secret.pg_monitor[0].id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "pgbouncer_accessor" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = google_secret_manager_secret.pgbouncer[0].id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "tls_ca_accessor" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = google_secret_manager_secret.tls_ca[0].id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "tls_crt_accessor" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = google_secret_manager_secret.tls_crt[0].id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "tls_key_accessor" {
  count   = var.create_secrets ? 1 : 0
  project = var.prod_db_project_id
  secret_id = google_secret_manager_secret.tls_key[0].id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

output "secret_ids" {
  value = local.secret_ids
  description = "Secret IDs created in Secret Manager"
}

output "vm_service_account_email" {
  value       = google_service_account.pg_sa.email
  description = "Service account used by the PostgreSQL HA instances"
}
