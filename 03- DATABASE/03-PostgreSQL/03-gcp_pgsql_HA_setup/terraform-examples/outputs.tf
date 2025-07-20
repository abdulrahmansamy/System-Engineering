# Outputs for GCP PostgreSQL HA Terraform configuration

output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "zone" {
  description = "GCP zone"
  value       = var.zone
}

# Instance information
output "primary_instance_name" {
  description = "Name of the primary PostgreSQL instance"
  value       = google_compute_instance.postgresql_primary.name
}

output "standby_instance_name" {
  description = "Name of the standby PostgreSQL instance"
  value       = google_compute_instance.postgresql_standby.name
}

output "primary_internal_ip" {
  description = "Internal IP address of the primary instance"
  value       = google_compute_instance.postgresql_primary.network_interface[0].network_ip
}

output "standby_internal_ip" {
  description = "Internal IP address of the standby instance"
  value       = google_compute_instance.postgresql_standby.network_interface[0].network_ip
}

output "primary_external_ip" {
  description = "External IP address of the primary instance"
  value       = google_compute_instance.postgresql_primary.network_interface[0].access_config[0].nat_ip
}

output "standby_external_ip" {
  description = "External IP address of the standby instance"
  value       = google_compute_instance.postgresql_standby.network_interface[0].access_config[0].nat_ip
}

# Load balancer information
output "http_load_balancer_ip" {
  description = "External IP address of the HTTP load balancer"
  value       = google_compute_global_address.postgresql_http.address
}

output "tcp_load_balancer_ip" {
  description = "External IP address of the TCP load balancer"
  value       = google_compute_address.postgresql_tcp.address
}

output "http_load_balancer_url" {
  description = "URL of the HTTP load balancer"
  value       = "http://${google_compute_global_address.postgresql_http.address}"
}

# Database connection information
output "postgresql_connection_string" {
  description = "PostgreSQL connection string via load balancer"
  value       = "postgresql://username:password@${google_compute_address.postgresql_tcp.address}:5432/database"
}

output "pgbouncer_connection_string" {
  description = "PgBouncer connection string via load balancer"
  value       = "postgresql://username:password@${google_compute_address.postgresql_tcp.address}:6432/database"
}

output "direct_primary_connection" {
  description = "Direct connection to primary instance"
  value       = "postgresql://username:password@${google_compute_instance.postgresql_primary.network_interface[0].network_ip}:5432/database"
}

output "direct_standby_connection" {
  description = "Direct connection to standby instance (read-only)"
  value       = "postgresql://username:password@${google_compute_instance.postgresql_standby.network_interface[0].network_ip}:5432/database"
}

# Storage information
output "backup_bucket_name" {
  description = "Name of the GCS backup bucket"
  value       = google_storage_bucket.postgresql_backups.name
}

output "backup_bucket_url" {
  description = "URL of the GCS backup bucket"
  value       = google_storage_bucket.postgresql_backups.url
}

# DNS information (if enabled)
output "dns_zone_name" {
  description = "Name of the Cloud DNS zone"
  value       = var.create_dns_zone ? google_dns_managed_zone.postgresql[0].name : null
}

output "dns_zone_name_servers" {
  description = "Name servers for the DNS zone"
  value       = var.create_dns_zone ? google_dns_managed_zone.postgresql[0].name_servers : null
}

output "postgresql_dns_name" {
  description = "DNS name for PostgreSQL connection"
  value       = var.create_dns_zone ? "postgresql.${var.dns_domain}" : null
}

output "postgresql_http_dns_name" {
  description = "DNS name for HTTP monitoring endpoint"
  value       = var.create_dns_zone ? "postgresql-http.${var.dns_domain}" : null
}

# Service account information
output "service_account_email" {
  description = "Email of the PostgreSQL service account"
  value       = google_service_account.postgresql_sa.email
}

# Monitoring information
output "uptime_check_id" {
  description = "ID of the uptime check"
  value       = google_monitoring_uptime_check_config.postgresql_http.uptime_check_id
}

output "notification_channels" {
  description = "List of notification channel names"
  value       = google_monitoring_notification_channel.email[*].name
}

# Health check URLs
output "health_check_urls" {
  description = "Health check URLs for manual testing"
  value = {
    primary_health = "http://${google_compute_instance.postgresql_primary.network_interface[0].access_config[0].nat_ip}:8080"
    standby_health = "http://${google_compute_instance.postgresql_standby.network_interface[0].access_config[0].nat_ip}:8080"
    lb_health      = "http://${google_compute_global_address.postgresql_http.address}/health"
  }
}

# SSH connection commands
output "ssh_commands" {
  description = "SSH commands to connect to instances"
  value = {
    primary = "gcloud compute ssh ${google_compute_instance.postgresql_primary.name} --zone=${var.zone}"
    standby = "gcloud compute ssh ${google_compute_instance.postgresql_standby.name} --zone=${var.zone}"
  }
}

# Cluster status commands
output "cluster_status_commands" {
  description = "Commands to check cluster status"
  value = {
    cluster_show    = "sudo -u postgres repmgr -f /etc/repmgr.conf cluster show"
    replication_lag = "sudo -u postgres psql -c \"SELECT * FROM pg_stat_replication;\""
    pgbouncer_stats = "psql -p 6432 -U repmgr -d pgbouncer -c \"SHOW STATS;\""
  }
}

# Backup commands
output "backup_commands" {
  description = "Commands for backup operations"
  value = {
    manual_backup     = "/var/backups/postgresql/scripts/pg_ha_gcs_backup.sh"
    list_gcs_backups = "gsutil ls gs://${google_storage_bucket.postgresql_backups.name}/"
    backup_logs      = "sudo tail -f /var/log/postgresql/backup.log"
  }
}
