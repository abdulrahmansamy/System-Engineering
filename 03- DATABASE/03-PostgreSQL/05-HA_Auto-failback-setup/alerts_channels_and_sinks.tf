locals {
  channel_emails = var.notification_emails
}

# Create email notification channels (optional convenience)
resource "google_monitoring_notification_channel" "email" {
  for_each     = toset(local.channel_emails)
  display_name = "${each.value}"
  type         = "email"
  labels = {
    email_address = each.value
  }
  user_labels = local.app_labels
}

# Use provided channel IDs if set; otherwise default to created email channels
locals {
  alert_channel_ids = length(var.monitoring_notification_channels) > 0 ? var.monitoring_notification_channels : [for c in google_monitoring_notification_channel.email : c.id]
}


# Log sinks with retention for audit logs and ops-agent/system logs
resource "google_logging_project_bucket_config" "audit_logs" {
  project          = var.prod_db_project_id
  location         = "global"
  retention_days   = var.audit_logs_retention_days
  bucket_id        = "${local.name_prefix}-audit-logs"
  description      = "Audit logs bucket"
}

resource "google_logging_project_bucket_config" "ops_logs" {
  project          = var.prod_db_project_id
  location         = "global"
  retention_days   = var.ops_agent_logs_retention_days
  bucket_id        = "${local.name_prefix}-ops-logs"
  description      = "Ops agent and system logs bucket"
}

resource "google_logging_project_sink" "audit_logs_sink" {
  name        = "${local.name_prefix}-sink-audit-logs"
  destination = "logging.googleapis.com/projects/${var.prod_db_project_id}/locations/global/buckets/${google_logging_project_bucket_config.audit_logs.bucket_id}"
  filter      = "logName:(\"logs/cloudaudit.googleapis.com%2Factivity\" OR \"logs/cloudaudit.googleapis.com%2Fsystem_event\" OR \"logs/cloudaudit.googleapis.com%2Fdata_access\")"
  unique_writer_identity = true
}

resource "google_logging_project_sink" "ops_logs_sink" {
  name        = "${local.name_prefix}-sink-ops-logs"
  destination = "logging.googleapis.com/projects/${var.prod_db_project_id}/locations/global/buckets/${google_logging_project_bucket_config.ops_logs.bucket_id}"
  filter      = "resource.type=\"gce_instance\" AND (log_id(\"syslog\") OR logName:\"/logs/journal\" OR logName:\"/logs/postgresql_general\")"
  unique_writer_identity = true
}
