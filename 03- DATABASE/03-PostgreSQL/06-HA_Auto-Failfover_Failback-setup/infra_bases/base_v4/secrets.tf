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
    tls_ca_cert  = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "tls-ca-cert", 1)
    tls_key      = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "sec", "tls-private-key", 1)
  }
  cert_names = {

    app_db_ilb = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "cert", "app-db-ilb", 1)
    pg_servers = format("%s-%s-%s-%s-%02d", local.org_code, local.env_code, "cert", "pg-servers", 1)
  }

}



# Generate strong passwords for DB roles and PgBouncer
resource "random_password" "pg_superuser" {
  length           = 32
  special          = true
  min_special      = 4
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  override_special = "!@#%^*-_=+?"
}

resource "random_password" "pg_repl" {
  length           = 32
  special          = true
  min_special      = 4
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  override_special = "!@#%^*-_=+?"
}

resource "random_password" "pg_monitor" {
  length           = 28
  special          = true
  min_special      = 4
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  override_special = "!@#%^*-_=+?"
}

resource "random_password" "pgbouncer" {
  length           = 28
  special          = true
  min_special      = 4
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  override_special = "!@#%^*-_=+?"
}

output "pg_superuser_password" {
  value       = random_password.pg_superuser.result
  description = "Generated password for the 'postgres' superuser"
  sensitive   = true
}

output "pg_repl_password" {
  value       = random_password.pg_repl.result
  description = "Generated password for the 'repl' replication user"
  sensitive   = true
}

output "pg_monitor_password" {
  value       = random_password.pg_monitor.result
  description = "Generated password for the 'pgmon' monitoring user"
  sensitive   = true
}

output "pgbouncer_password" {
  value       = random_password.pgbouncer.result
  description = "Generated password for the 'pgbouncer' user"
  sensitive   = true
}

# Generate a self-signed TLS CA and server cert for initial bootstrap
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca_cert" {
  private_key_pem = tls_private_key.ca.private_key_pem
  subject { common_name = "ipa-internal-pg-ca" }
  is_ca_certificate     = true
  validity_period_hours = 5 * 365 * 24
  allowed_uses          = ["cert_signing", "crl_signing", "key_encipherment", "digital_signature"]
}

resource "tls_private_key" "tls_private_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "pg_servers" {
  private_key_pem = tls_private_key.tls_private_key.private_key_pem
  subject { common_name = "pg-internal" }
  dns_names = [
    "localhost",
    google_compute_instance.primary.name,
    google_compute_instance.standby.name,
    google_compute_instance.monitor.name,
    "*.internal"
  ]
}

resource "tls_locally_signed_cert" "pg_servers" {
  cert_request_pem      = tls_cert_request.pg_servers.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours = 3 * 365 * 24
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "tls_cert_request" "app_db_ilb" {
  private_key_pem = tls_private_key.tls_private_key.private_key_pem
  subject { common_name = "pg-ha-vip" }
  dns_names = [
    var.ha_db_dns_domain, var.internal_dns_domain,
    "${"*."}${var.ha_db_dns_domain}",
    "${"*."}${var.internal_dns_domain}"
  ]
  # description = "Certificate request for PostgreSQL HA cluster internal load balancer"
}

resource "tls_locally_signed_cert" "app_db_ilb" {
  cert_request_pem      = tls_cert_request.app_db_ilb.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours = 3 * 365 * 24
  allowed_uses          = ["server_auth", "key_encipherment", "digital_signature"]
  # description = "Locally signed certificate for PostgreSQL HA cluster internal load balancer"
}

output "signed_pg_servers_cert_details" {
  value = {
    cert_pem       = tls_locally_signed_cert.pg_servers.cert_pem
    validity_start = tls_locally_signed_cert.pg_servers.validity_start_time
    validity_end   = tls_locally_signed_cert.pg_servers.validity_end_time
    # serial_number       = tls_locally_signed_cert.pg_servers.serial_number
    allowed_uses        = tls_locally_signed_cert.pg_servers.allowed_uses
    dns_names           = tls_cert_request.pg_servers.dns_names
    issuer_common_name  = tls_self_signed_cert.ca_cert.subject[0].common_name
    subject_common_name = tls_cert_request.pg_servers.subject[0].common_name
  }
  sensitive   = true
  description = "Full details of the signed TLS certificate for PostgreSQL HA cluster servers internal communications"
}

output "signed_app_db_ilb_cert_details" {
  value = {
    cert_pem       = tls_locally_signed_cert.app_db_ilb.cert_pem
    validity_start = tls_locally_signed_cert.app_db_ilb.validity_start_time
    validity_end   = tls_locally_signed_cert.app_db_ilb.validity_end_time
    # serial_number       = tls_locally_signed_cert.app_db_ilb.serial_number
    allowed_uses        = tls_locally_signed_cert.app_db_ilb.allowed_uses
    dns_names           = tls_cert_request.app_db_ilb.dns_names
    issuer_common_name  = tls_self_signed_cert.ca_cert.subject[0].common_name
    subject_common_name = tls_cert_request.app_db_ilb.subject[0].common_name
  }
  sensitive   = true
  description = "Full details of the signed TLS certificate for application to PostgreSQL HA cluster internal load balancer communications"
}

resource "google_certificate_manager_dns_authorization" "pg_servers_dns_auth" {
  provider    = google.db_projects
  count       = var.create_secrets ? 1 : 0
  name        = "${local.cert_names.pg_servers}-dns-auth"
  description = "DNS authorization for internal PG servers"
  domain      = "pg-internal.ipa.edu.sa"
  labels      = merge(local.app_labels, { usage = "pg_servers_dns_auth" })
  depends_on  = [google_project_service.cert_manager]
}

resource "google_certificate_manager_dns_authorization" "app_db_ilb_dns_auth" {
  provider    = google.db_projects
  count       = var.create_secrets ? 1 : 0
  name        = "${local.cert_names.app_db_ilb}-dns-auth"
  description = "DNS authorization for the application-to-DB ILB"
  domain      = var.ha_db_dns_domain
  labels      = merge(local.app_labels, { usage = "app_db_ilb_dns_auth" })
  depends_on  = [google_project_service.cert_manager]
}

resource "google_certificate_manager_dns_authorization" "internal_domain_dns_auth" {
  provider    = google.db_projects
  count       = var.create_secrets ? 1 : 0
  name        = "internal-domain-dns-auth"
  description = "DNS authorization for the internal domain"
  domain      = var.internal_dns_domain
  labels      = merge(local.app_labels, { usage = "internal_domain_dns_auth" })
  depends_on  = [google_project_service.cert_manager]
}

# Project-level roles for VM SA to emit logs/metrics
resource "google_project_iam_member" "sa_logging" {
  project = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_project_iam_member" "sa_monitoring" {
  project = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.pg_sa.email}"
}

# Secret Manager secrets (without versions)
resource "google_secret_manager_secret" "pg_superuser" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = local.secret_ids.pg_superuser
  replication {
    auto {}
  }
  labels     = merge(local.app_labels, { usage = "pg_superuser_password" })
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "pg_repl" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = local.secret_ids.pg_repl
  replication {
    auto {}
  }
  labels     = merge(local.app_labels, { usage = "pg_replication_password" })
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "pg_monitor" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = local.secret_ids.pg_monitor
  replication {
    auto {}
  }
  labels     = merge(local.app_labels, { usage = "pg_monitor_password" })
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "pgbouncer" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = local.secret_ids.pgbouncer
  replication {
    auto {}
  }
  labels     = merge(local.app_labels, { usage = "pgbouncer_password" })
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "tls_ca" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = local.secret_ids.tls_ca
  replication {
    auto {}
  }
  labels = merge(local.app_labels, { usage = "tls_ca" })
}

resource "google_secret_manager_secret" "tls_ca_cert" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = local.secret_ids.tls_ca_cert
  replication {
    auto {}
  }
  labels     = merge(local.app_labels, { usage = "tls_ca_cert" })
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "tls_key" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = local.secret_ids.tls_key
  replication {
    auto {}
  }
  labels     = merge(local.app_labels, { usage = "tls_key" })
  depends_on = [ google_project_service.secretmanager ]
}

# use resource "google_certificate_manager_certificate" instead
resource "google_certificate_manager_certificate" "pg_servers_cert" {
  provider    = google.db_projects
  count       = var.create_secrets ? 1 : 0
  name        = local.cert_names.pg_servers
  description = "Managed certificate for internal PG server communication"
  scope       = "DEFAULT"
  managed {
    domains = ["pg-internal.ipa.edu.sa"]
    dns_authorizations = [google_certificate_manager_dns_authorization.pg_servers_dns_auth[0].id]
  }
  labels = merge(local.app_labels, { usage = "pg_servers_cert" })
  depends_on = [ google_project_service.cert_manager ]
}

resource "google_certificate_manager_certificate" "app_db_ilb_cert" {
  provider    = google.db_projects
  count       = var.create_secrets ? 1 : 0
  name        = local.cert_names.app_db_ilb
  description = "Managed certificate for the application-to-DB ILB"
  scope       = "DEFAULT"
  managed {
    domains = [var.ha_db_dns_domain, var.internal_dns_domain]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.app_db_ilb_dns_auth[0].id,
      google_certificate_manager_dns_authorization.internal_domain_dns_auth[0].id
    ]
  }
  labels = merge(local.app_labels, { usage = "app_db_ilb_cert" })
  depends_on = [ google_project_service.cert_manager ]
}

# Secret versions (payloads)
resource "google_secret_manager_secret_version" "pg_superuser" {
  count       = var.create_secrets ? 1 : 0
  secret      = google_secret_manager_secret.pg_superuser[0].id
  secret_data = random_password.pg_superuser.result
  depends_on  = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "pg_repl" {
  count       = var.create_secrets ? 1 : 0
  secret      = google_secret_manager_secret.pg_repl[0].id
  secret_data = random_password.pg_repl.result
  depends_on  = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "pg_monitor" {
  count       = var.create_secrets ? 1 : 0
  secret      = google_secret_manager_secret.pg_monitor[0].id
  secret_data = random_password.pg_monitor.result
  depends_on  = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "pgbouncer" {
  count       = var.create_secrets ? 1 : 0
  secret      = google_secret_manager_secret.pgbouncer[0].id
  secret_data = random_password.pgbouncer.result
  depends_on  = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "tls_ca" {
  count       = var.create_secrets ? 1 : 0
  secret      = google_secret_manager_secret.tls_ca[0].id
  secret_data = tls_private_key.ca.private_key_pem
  depends_on  = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "tls_ca_cert" {
  count       = var.create_secrets ? 1 : 0
  secret      = google_secret_manager_secret.tls_ca_cert[0].id
  secret_data = tls_self_signed_cert.ca_cert.cert_pem
  depends_on  = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "tls_key" {
  count       = var.create_secrets ? 1 : 0
  secret      = google_secret_manager_secret.tls_key[0].id
  secret_data = tls_private_key.tls_private_key.private_key_pem
  depends_on  = [google_project_service.secretmanager]
}

# Least-privilege secret access for the VM service account
resource "google_secret_manager_secret_iam_member" "pg_superuser_accessor" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = google_secret_manager_secret.pg_superuser[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "pg_repl_accessor" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = google_secret_manager_secret.pg_repl[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "pg_monitor_accessor" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = google_secret_manager_secret.pg_monitor[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "pgbouncer_accessor" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = google_secret_manager_secret.pgbouncer[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "tls_ca_accessor" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = google_secret_manager_secret.tls_ca[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pg_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "tls_key_accessor" {
  count     = var.create_secrets ? 1 : 0
  project   = local.is_production ? var.prod_db_project_id : var.nonprod_db_project_id
  secret_id = google_secret_manager_secret.tls_key[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pg_sa.email}"
}

output "secret_ids" {
  value       = local.secret_ids
  description = "Secret IDs created in Secret Manager"
}

output "vm_service_account_email" {
  value       = google_service_account.pg_sa.email
  description = "Service account used by the PostgreSQL HA instances"
}
