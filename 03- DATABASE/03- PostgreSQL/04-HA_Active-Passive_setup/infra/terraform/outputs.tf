output "network_id" { value = google_compute_network.vpc.id }
output "subnet_id"  { value = google_compute_subnetwork.subnet.id }

output "primary_ip"   { value = google_compute_address.primary.address }
output "secondary_ip" { value = google_compute_address.secondary.address }
output "monitor_ip"   { value = google_compute_address.monitor.address }
output "vip_ip"       { value = google_compute_address.vip.address }
output "ilb_ip"       { value = google_compute_address.vip.address }

output "pg_nodes_sa"  { value = google_service_account.pg_nodes.email }
output "pg_monitor_sa"{ value = google_service_account.pg_monitor.email }

output "dns_zone"     { value = google_dns_managed_zone.private.dns_name }

output "primary_instance" { value = google_compute_instance.primary.name }
output "secondary_instance" { value = google_compute_instance.secondary.name }
output "monitor_instance" { value = google_compute_instance.monitor.name }

output "primary_internal_ip"   { value = google_compute_address.primary.address }
output "secondary_internal_ip" { value = google_compute_address.secondary.address }
output "monitor_internal_ip"   { value = google_compute_address.monitor.address }

# TLS and Secrets outputs
output "tls_ca_secret" { value = google_secret_manager_secret.tls_ca_cert.secret_id }
output "tls_primary_key_secret" { value = google_secret_manager_secret.tls_pg_primary_key.secret_id }
output "tls_primary_cert_secret" { value = google_secret_manager_secret.tls_pg_primary_cert.secret_id }
output "tls_secondary_key_secret" { value = google_secret_manager_secret.tls_pg_secondary_key.secret_id }
output "tls_secondary_cert_secret" { value = google_secret_manager_secret.tls_pg_secondary_cert.secret_id }
output "tls_monitor_key_secret" { value = google_secret_manager_secret.tls_pg_monitor_key.secret_id }
output "tls_monitor_cert_secret" { value = google_secret_manager_secret.tls_pg_monitor_cert.secret_id }

output "pg_superuser_password_secret" { value = google_secret_manager_secret.pg_superuser_password.secret_id }
output "pg_repl_password_secret"     { value = google_secret_manager_secret.pg_repl_password.secret_id }
output "pgbouncer_auth_password_secret" { value = google_secret_manager_secret.pgbouncer_auth_password.secret_id }
output "pg_monitoring_password_secret" { value = google_secret_manager_secret.pg_monitoring_password.secret_id }

output "ilb_forwarding_rule" { value = google_compute_forwarding_rule.pg_ilb.name }
output "backup_bucket" { value = google_storage_bucket.pgbackrest.name }
