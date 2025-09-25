# TLS CA secret and version
resource "google_secret_manager_secret" "tls_ca_cert" {
  secret_id = "tls-ca-cert"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "tls_ca_cert_v1" {
  secret      = google_secret_manager_secret.tls_ca_cert.id
  secret_data = tls_self_signed_cert.ca_cert.cert_pem
}

# Per-node TLS key/cert secrets and versions
resource "google_secret_manager_secret" "tls_pg_primary_key" {
  secret_id = "tls-pg-primary-key"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret" "tls_pg_primary_cert" {
  secret_id = "tls-pg-primary-cert"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret_version" "tls_pg_primary_key_v1" {
  secret      = google_secret_manager_secret.tls_pg_primary_key.id
  secret_data = tls_private_key.primary_key.private_key_pem
}
resource "google_secret_manager_secret_version" "tls_pg_primary_cert_v1" {
  secret      = google_secret_manager_secret.tls_pg_primary_cert.id
  secret_data = tls_locally_signed_cert.primary_cert.cert_pem
}

resource "google_secret_manager_secret" "tls_pg_secondary_key" {
  secret_id = "tls-pg-secondary-key"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret" "tls_pg_secondary_cert" {
  secret_id = "tls-pg-secondary-cert"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret_version" "tls_pg_secondary_key_v1" {
  secret      = google_secret_manager_secret.tls_pg_secondary_key.id
  secret_data = tls_private_key.secondary_key.private_key_pem
}
resource "google_secret_manager_secret_version" "tls_pg_secondary_cert_v1" {
  secret      = google_secret_manager_secret.tls_pg_secondary_cert.id
  secret_data = tls_locally_signed_cert.secondary_cert.cert_pem
}

resource "google_secret_manager_secret" "tls_pg_monitor_key" {
  secret_id = "tls-pg-monitor-key"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret" "tls_pg_monitor_cert" {
  secret_id = "tls-pg-monitor-cert"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret_version" "tls_pg_monitor_key_v1" {
  secret      = google_secret_manager_secret.tls_pg_monitor_key.id
  secret_data = tls_private_key.monitor_key.private_key_pem
}
resource "google_secret_manager_secret_version" "tls_pg_monitor_cert_v1" {
  secret      = google_secret_manager_secret.tls_pg_monitor_cert.id
  secret_data = tls_locally_signed_cert.monitor_cert.cert_pem
}

# Database user passwords
resource "random_password" "pg_superuser" {
  length  = 24
  special = true
  override_special = "!@#%^*_-=+"
}

resource "random_password" "pg_repl" {
  length  = 24
  special = true
  override_special = "!@#%^*_-=+"
}

resource "random_password" "pgbouncer_auth" {
  length  = 24
  special = true
  override_special = "!@#%^*_-=+"
}

resource "google_secret_manager_secret" "pg_superuser_password" {
  secret_id = "pg-superuser-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret_version" "pg_superuser_password_v1" {
  secret      = google_secret_manager_secret.pg_superuser_password.id
  secret_data = random_password.pg_superuser.result
}

resource "google_secret_manager_secret" "pg_repl_password" {
  secret_id = "pg-repl-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret_version" "pg_repl_password_v1" {
  secret      = google_secret_manager_secret.pg_repl_password.id
  secret_data = random_password.pg_repl.result
}

resource "google_secret_manager_secret" "pgbouncer_auth_password" {
  secret_id = "pgbouncer-auth-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret_version" "pgbouncer_auth_password_v1" {
  secret      = google_secret_manager_secret.pgbouncer_auth_password.id
  secret_data = random_password.pgbouncer_auth.result
}

# Monitoring user password
resource "random_password" "pg_monitoring" {
  length  = 24
  special = true
  override_special = "!@#%^*_-=+"
}

resource "google_secret_manager_secret" "pg_monitoring_password" {
  secret_id = "pg-monitoring-password"
  replication {
    user_managed {
      replicas { location = var.region }
    }
  }
}
resource "google_secret_manager_secret_version" "pg_monitoring_password_v1" {
  secret      = google_secret_manager_secret.pg_monitoring_password.id
  secret_data = random_password.pg_monitoring.result
}
