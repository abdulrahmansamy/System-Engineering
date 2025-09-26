resource "google_monitoring_dashboard" "pg_ha_overview" {
  dashboard_json = jsonencode({
    displayName = "${local.name_prefix} - PostgreSQL HA Overview"
    gridLayout = {
      widgets = [
        {
          title = "Replication delay (s)"
          xyChart = {
            dataSets = [
              {
                plotType   = "LINE"
                targetAxis = "Y1"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"workload.googleapis.com/postgresql.replication.data_delay\" resource.type=\"gce_instance\""
                  }
                }
              }
            ]
            yAxis = { label = "seconds", scale = "LINEAR" }
          }
        },
        {
          title = "WAL age (s)"
          xyChart = {
            dataSets = [
              {
                plotType   = "LINE"
                targetAxis = "Y1"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"workload.googleapis.com/postgresql.wal.age\" resource.type=\"gce_instance\""
                  }
                }
              }
            ]
            yAxis = { label = "seconds", scale = "LINEAR" }
          }
        },
        {
          title = "Active backends"
          xyChart = {
            dataSets = [
              {
                plotType   = "LINE"
                targetAxis = "Y1"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"workload.googleapis.com/postgresql.backends\" resource.type=\"gce_instance\""
                  }
                }
              }
            ]
            yAxis = { label = "count", scale = "LINEAR" }
          }
        },
        {
          title = "VM CPU utilization"
          xyChart = {
            dataSets = [
              {
                plotType   = "LINE"
                targetAxis = "Y1"
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\""
                  }
                }
              }
            ]
            yAxis = { label = "ratio", scale = "LINEAR" }
          }
        }
      ]
    }
  })
}
