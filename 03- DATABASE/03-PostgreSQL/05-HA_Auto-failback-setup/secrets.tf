############################################################
# Module 3: Secret Manager integration (with secret versions)
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

# Generate strong passwords for DB roles and PgBouncer
resource "random_password" "pg_superuser" {
  length      = 32
  special     = true
  min_special = 4
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  override_special = "!@#%^*-_=+?"
}

resource "random_password" "pg_repl" {
  length      = 32
  special     = true
  min_special = 4
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  override_special = "!@#%^*-_=+?"
}

resource "random_password" "pg_monitor" {
  length      = 28
  special     = true
  min_special = 4
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  override_special = "!@#%^*-_=+?"
}

resource "random_password" "pgbouncer" {
  length      = 28
  special     = true
  min_special = 4
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  override_special = "!@#%^*-_=+?"
}

# Generate a self-signed TLS CA and server cert for initial bootstrap
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem
  subject { common_name = "ipa-internal-pg-ca" }
  is_ca_certificate = true
  validity_period_hours = 5 * 365 * 24
  allowed_uses = ["cert_signing", "crl_signing", "key_encipherment", "digital_signature"]
}

resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem
  subject { common_name = "pg-internal" }
  dns_names = [
    "localhost",
    google_compute_instance.primary.name,
    google_compute_instance.standby.name,
    google_compute_instance.monitor.name
  ]
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem   = tls_cert_request.server.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 3 * 365 * 24
  allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]
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

# Secret versions (payloads)
resource "google_secret_manager_secret_version" "pg_superuser" {
  count     = var.create_secrets ? 1 : 0
  secret    = google_secret_manager_secret.pg_superuser[0].id
  secret_data = random_password.pg_superuser.result
}

resource "google_secret_manager_secret_version" "pg_repl" {
  count     = var.create_secrets ? 1 : 0
  secret    = google_secret_manager_secret.pg_repl[0].id
  secret_data = random_password.pg_repl.result
}

resource "google_secret_manager_secret_version" "pg_monitor" {
  count     = var.create_secrets ? 1 : 0
  secret    = google_secret_manager_secret.pg_monitor[0].id
  secret_data = random_password.pg_monitor.result
}

resource "google_secret_manager_secret_version" "pgbouncer" {
  count     = var.create_secrets ? 1 : 0
  secret    = google_secret_manager_secret.pgbouncer[0].id
  secret_data = random_password.pgbouncer.result
}

resource "google_secret_manager_secret_version" "tls_ca" {
  count     = var.create_secrets ? 1 : 0
  secret    = google_secret_manager_secret.tls_ca[0].id
  secret_data = tls_self_signed_cert.ca.cert_pem
}

resource "google_secret_manager_secret_version" "tls_crt" {
  count     = var.create_secrets ? 1 : 0
  secret    = google_secret_manager_secret.tls_crt[0].id
  secret_data = tls_locally_signed_cert.server.cert_pem
}

resource "google_secret_manager_secret_version" "tls_key" {
  count     = var.create_secrets ? 1 : 0
  secret    = google_secret_manager_secret.tls_key[0].id
  secret_data = tls_private_key.server.private_key_pem
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
