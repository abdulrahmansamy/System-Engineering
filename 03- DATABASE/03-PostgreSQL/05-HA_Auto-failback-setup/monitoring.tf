locals {
  mon_labels = merge(local.app_labels, { module = "monitoring" })
}

# Log-based metric for TLS expiry warnings emitted by check_tls_expiry.sh via logger
resource "google_logging_metric" "tls_expiry_warning" {
  name        = "${local.name_prefix}-log-tls-expiry-warning"
  description = "TLS certificate expiry warnings from nodes"
  filter      = "resource.type=\"gce_instance\" AND textPayload:\"TLS_CERT_EXPIRY_WARNING\""
  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    display_name = "TLS expiry warning occurrences"
  }
}

# Replication data-delay alert (seconds)
resource "google_monitoring_alert_policy" "replication_delay" {
  display_name = "${local.name_prefix} PostgreSQL replication delay high"
  combiner     = "OR"
  notification_channels = local.alert_channel_ids
  conditions {
    display_name = "Replication data delay > threshold"
    condition_threshold {
      filter          = "metric.type=\"workload.googleapis.com/postgresql.replication.data_delay\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.replication_lag_threshold_seconds
      duration        = "120s"
      trigger { count = 1 }
    }
  }
  documentation { content = "Streaming replication delay exceeded threshold; RPO at risk." }
  enabled     = true
  user_labels = local.mon_labels
}

# WAL age alert (seconds)
resource "google_monitoring_alert_policy" "wal_age" {
  display_name = "${local.name_prefix} PostgreSQL WAL age high"
  combiner     = "OR"
  notification_channels = local.alert_channel_ids
  conditions {
    display_name = "WAL age > 12h"
    condition_threshold {
      filter          = "metric.type=\"workload.googleapis.com/postgresql.wal.age\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 43200
      duration        = "300s"
      trigger { count = 1 }
    }
  }
  documentation { content = "WAL age is high; check archiving and backups." }
  enabled     = true
  user_labels = local.mon_labels
}

# pg_auto_failover failover event via logs (journal). Create a log-based metric and alert on it.
resource "google_logging_metric" "pgaf_failover" {
  name        = "${local.name_prefix}-log-pgaf-failover"
  description = "pg_auto_failover role change occurrences"
  filter      = "resource.type=\"gce_instance\" AND (logName:\"/logs/journal\" OR log_id(\"syslog\")) AND textPayload:(\"demote\" OR \"promote\")"
  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    display_name = "pg_auto_failover role changes"
  }
}

resource "google_monitoring_alert_policy" "pgaf_failover_alert" {
  display_name = "${local.name_prefix} pg_auto_failover role change"
  combiner     = "OR"
  notification_channels = local.alert_channel_ids
  conditions {
    display_name = "Role changed"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${local.name_prefix}-log-pgaf-failover\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      trigger { count = 1 }
    }
  }
  documentation { content = "pg_auto_failover signaled a role change (promote/demote)." }
  enabled     = true
  user_labels = local.mon_labels
}

# pgBackRest failure alert via logs
resource "google_logging_metric" "pgbackrest_failure" {
  name        = "${local.name_prefix}-log-pgbackrest-failure"
  description = "pgBackRest error occurrences"
  filter      = "resource.type=\"gce_instance\" AND textPayload:\"pgbackrest\" AND (textPayload:\"ERROR\" OR textPayload:\"FATAL\")"
  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    display_name = "pgBackRest error occurrences"
  }
}

resource "google_monitoring_alert_policy" "pgbackrest_failure_alert" {
  display_name = "${local.name_prefix} pgBackRest errors"
  combiner     = "OR"
  notification_channels = local.alert_channel_ids
  conditions {
    display_name = "Errors > 0"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${local.name_prefix}-log-pgbackrest-failure\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      trigger { count = 1 }
    }
  }
  documentation { content = "pgBackRest logged an error; check backup status and storage." }
  enabled     = true
  user_labels = local.mon_labels
}

# TLS expiry warning alert using log-based metric
resource "google_monitoring_alert_policy" "tls_expiry_warning_alert" {
  display_name = "${local.name_prefix} TLS certificate expiring soon"
  combiner     = "OR"
  notification_channels = local.alert_channel_ids
  conditions {
    display_name = "Expiry warning present"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${local.name_prefix}-log-tls-expiry-warning\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      trigger { count = 1 }
    }
  }
  documentation { content = "Node reported TLS certificate expiring within 30 days." }
  enabled     = true
  user_labels = local.mon_labels
}

# Burn-rate style multi-window alert for replication delay (short + long window)
resource "google_monitoring_alert_policy" "replication_delay_burn" {
  display_name = "${local.name_prefix} PostgreSQL replication delay burn-rate"
  combiner     = "AND" # sustained breach across windows
  notification_channels = local.alert_channel_ids
  conditions {
    display_name = "Short window delay > threshold"
    condition_threshold {
      filter          = "metric.type=\"workload.googleapis.com/postgresql.replication.data_delay\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.replication_lag_threshold_seconds
      duration        = "120s"
      trigger { count = 1 }
    }
  }
  conditions {
    display_name = "Long window delay > threshold"
    condition_threshold {
      filter          = "metric.type=\"workload.googleapis.com/postgresql.replication.data_delay\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.replication_lag_threshold_seconds
      duration        = "1800s"
      trigger { count = 1 }
    }
  }
  documentation { content = "Sustained replication delay above threshold across short and long windows." }
  enabled     = true
  user_labels = local.mon_labels
}

# PgBouncer: Log-based metric for waiting clients from periodic pool emission
resource "google_logging_metric" "pgbouncer_waiting" {
  name        = "${local.name_prefix}-log-pgbouncer-waiting"
  description = "PgBouncer waiting clients (aggregated)"
  filter      = "resource.type=\"gce_instance\" AND textPayload:\"PGBOUNCER_POOLS\" AND textPayload:\"waiting=\""
  metric_descriptor {
    metric_kind  = "GAUGE"
    value_type   = "INT64"
    display_name = "pgbouncer waiting clients"
  }
  value_extractor = "REGEXP_EXTRACT(textPayload, 'waiting=(\\d+)')"
}

resource "google_monitoring_alert_policy" "pgbouncer_waiting_alert" {
  display_name = "${local.name_prefix} PgBouncer waiting clients > 0"
  combiner     = "OR"
  notification_channels = local.alert_channel_ids
  conditions {
    display_name = "Waiting clients present"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${local.name_prefix}-log-pgbouncer-waiting\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "120s"
      trigger { count = 1 }
    }
  }
  documentation { content = "PgBouncer reports waiting clients (pool saturation)." }
  enabled     = true
  user_labels = local.mon_labels
}
