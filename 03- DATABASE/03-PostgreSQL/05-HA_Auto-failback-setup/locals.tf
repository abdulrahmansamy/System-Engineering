locals {
  app_labels = {
    environment = var.ha_db_environment
    project     = var.project_id
    managed-by  = "terraform"
    stack       = "pg-ha-pg_auto_failover"
  }

  name_prefix = var.ha_db_instance_prefix
}

output "labels_common" {
  value       = local.app_labels
  description = "Common labels applied to resources"
}

output "name_prefix" {
  value       = local.name_prefix
  description = "Prefix used for resource names"
}
