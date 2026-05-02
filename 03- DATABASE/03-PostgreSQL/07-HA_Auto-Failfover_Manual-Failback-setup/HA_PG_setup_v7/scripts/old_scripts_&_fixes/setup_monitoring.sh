#!/bin/bash
# PostgreSQL HA Cluster Monitoring Setup Script
# Installs and configures monitoring agents and alerting
# Version: 1.0.0

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
info() { printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$*"; }
section() { printf "\n%b=== %s ===%b\n" "$BLUE" "$*" "$NC"; }

get_pg_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        echo "standby"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
        echo "primary"
    else
        echo "unknown"
    fi
}

install_google_cloud_ops_agent() {
    section "Installing Google Cloud Ops Agent"
    
    # Check if already installed
    if systemctl list-units --type=service --state=active | grep -q "google-cloud-ops-agent"; then
        success "Google Cloud Ops Agent is already running"
        return 0
    fi
    
    info "Installing Google Cloud Ops Agent..."
    
    # Download and install the agent
    if curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh; then
        sudo bash add-google-cloud-ops-agent-repo.sh --also-install
        rm -f add-google-cloud-ops-agent-repo.sh
        success "Google Cloud Ops Agent installed"
    else
        error "Failed to download Google Cloud Ops Agent installer"
        return 1
    fi
}

configure_ops_agent() {
    section "Configuring Google Cloud Ops Agent"
    
    local config_file="/etc/google-cloud-ops-agent/config.yaml"
    
    info "Creating Ops Agent configuration..."
    
    cat > "$config_file" << 'EOF'
# Google Cloud Ops Agent Configuration for PostgreSQL HA
logging:
  receivers:
    postgresql:
      type: postgresql
      include_paths:
        - /var/log/postgresql/*.log
      exclude_paths: []
    
    repmgr:
      type: files
      include_paths:
        - /var/log/repmgr/*.log
      exclude_paths: []
    
    pgbouncer:
      type: files
      include_paths:
        - /var/log/pgbouncer/*.log
      exclude_paths: []
    
    syslog:
      type: files
      include_paths:
        - /var/log/syslog
        - /var/log/messages
      exclude_paths: []

  processors:
    postgresql_parser:
      type: parse_json
    
    add_hostname:
      type: modify_fields
      fields:
        hostname:
          static_value: "${HOSTNAME}"

  exporters:
    google:
      type: google_cloud_logging

  service:
    pipelines:
      postgresql_pipeline:
        receivers: [postgresql]
        processors: [postgresql_parser, add_hostname]
        exporters: [google]
      
      repmgr_pipeline:
        receivers: [repmgr]
        processors: [add_hostname]
        exporters: [google]
      
      pgbouncer_pipeline:
        receivers: [pgbouncer]
        processors: [add_hostname]
        exporters: [google]
      
      system_pipeline:
        receivers: [syslog]
        processors: [add_hostname]
        exporters: [google]

metrics:
  receivers:
    postgresql:
      type: postgresql
      username: postgres
      password: ""
      database: postgres
      endpoint: localhost:5432
      collection_interval: 60s
    
    hostmetrics:
      type: hostmetrics
      collection_interval: 60s
      scrapers:
        cpu:
          metrics:
            system.cpu.utilization:
              enabled: true
        memory:
          metrics:
            system.memory.utilization:
              enabled: true
        disk:
          metrics:
            system.disk.io:
              enabled: true
        network:
          metrics:
            system.network.io:
              enabled: true
        load:
          metrics:
            system.cpu.load_average.1m:
              enabled: true
            system.cpu.load_average.5m:
              enabled: true
            system.cpu.load_average.15m:
              enabled: true

  processors:
    resourcedetection:
      type: resourcedetection
      detectors: [gcp, system]
    
    add_labels:
      type: modify_fields
      fields:
        cluster_role:
          static_value: "${PG_ROLE}"

  exporters:
    google:
      type: google_cloud_monitoring

  service:
    pipelines:
      postgresql_metrics:
        receivers: [postgresql]
        processors: [resourcedetection, add_labels]
        exporters: [google]
      
      system_metrics:
        receivers: [hostmetrics]
        processors: [resourcedetection, add_labels]
        exporters: [google]
EOF

    # Replace placeholders
    local role
    role=$(get_pg_role)
    sed -i "s/\${HOSTNAME}/$(hostname)/g" "$config_file"
    sed -i "s/\${PG_ROLE}/$role/g" "$config_file"
    
    success "Ops Agent configuration created"
    
    # Restart the service
    if systemctl restart google-cloud-ops-agent; then
        success "Google Cloud Ops Agent restarted with new configuration"
    else
        error "Failed to restart Google Cloud Ops Agent"
        return 1
    fi
}

setup_postgresql_logging() {
    section "Configuring PostgreSQL Logging"
    
    local pg_conf="/etc/postgresql/17/main/postgresql.conf"
    
    info "Updating PostgreSQL logging configuration..."
    
    # Backup original configuration
    cp "$pg_conf" "$pg_conf.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Update logging settings
    cat >> "$pg_conf" << 'EOF'

# Enhanced logging for monitoring
log_destination = 'stderr'
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
log_error_verbosity = default
log_statement = 'ddl'
EOF

    success "PostgreSQL logging configuration updated"
    
    # Restart PostgreSQL to apply changes
    if systemctl restart postgresql; then
        success "PostgreSQL restarted with new logging configuration"
    else
        error "Failed to restart PostgreSQL"
        return 1
    fi
}

create_custom_metrics_script() {
    section "Creating Custom Metrics Collection Script"
    
    local metrics_script="/usr/local/bin/pg-custom-metrics.sh"
    
    info "Creating custom metrics collection script..."
    
    cat > "$metrics_script" << 'EOF'
#!/bin/bash
# PostgreSQL HA Custom Metrics Collection Script
# Collects cluster-specific metrics for monitoring

set -euo pipefail

get_pg_role() {
    if sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^t'; then
        echo "standby"
    elif sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" postgres 2>/dev/null | grep -q '^f'; then
        echo "primary"
    else
        echo "unknown"
    fi
}

collect_replication_metrics() {
    local role
    role=$(get_pg_role)
    
    if [[ "$role" == "primary" ]]; then
        # Collect primary-specific metrics
        local standby_count
        standby_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_replication;" postgres 2>/dev/null || echo "0")
        echo "postgresql_ha_standby_count $standby_count"
        
        # WAL generation rate
        local wal_lsn
        wal_lsn=$(sudo -u postgres psql -Atqc "SELECT pg_current_wal_lsn();" postgres 2>/dev/null || echo "0/0")
        echo "postgresql_ha_current_wal_lsn_info{lsn=\"$wal_lsn\"} 1"
        
    elif [[ "$role" == "standby" ]]; then
        # Collect standby-specific metrics
        local replication_lag
        replication_lag=$(sudo -u postgres psql -Atqc "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" postgres 2>/dev/null || echo "-1")
        echo "postgresql_ha_replication_lag_seconds $replication_lag"
        
        # WAL receiver status
        local wal_receiver_status
        if sudo -u postgres psql -Atqc "SELECT pid FROM pg_stat_wal_receiver;" postgres 2>/dev/null | grep -q '[0-9]'; then
            wal_receiver_status=1
        else
            wal_receiver_status=0
        fi
        echo "postgresql_ha_wal_receiver_active $wal_receiver_status"
    fi
    
    # Common metrics
    echo "postgresql_ha_node_role_info{role=\"$role\"} 1"
    
    # Connection count
    local connection_count
    connection_count=$(sudo -u postgres psql -Atqc "SELECT count(*) FROM pg_stat_activity;" postgres 2>/dev/null || echo "0")
    echo "postgresql_ha_connection_count $connection_count"
    
    # Database size
    local db_size
    db_size=$(sudo -u postgres psql -Atqc "SELECT pg_database_size('postgres');" postgres 2>/dev/null || echo "0")
    echo "postgresql_ha_database_size_bytes $db_size"
}

collect_repmgr_metrics() {
    # Repmgr cluster status
    local cluster_nodes
    cluster_nodes=$(sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f /etc/repmgr/repmgr.conf cluster show 2>/dev/null | grep -c "running" || echo "0")
    echo "postgresql_ha_cluster_nodes_running $cluster_nodes"
    
    # Node check status
    if sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass repmgr -f /etc/repmgr/repmgr.conf node check >/dev/null 2>&1; then
        echo "postgresql_ha_node_check_status 1"
    else
        echo "postgresql_ha_node_check_status 0"
    fi
}

collect_pgbouncer_metrics() {
    # PgBouncer connection stats
    local active_clients
    active_clients=$(timeout 5 bash -c "echo 'SHOW CLIENTS;' | sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p 6432 -U postgres -d pgbouncer -t" 2>/dev/null | wc -l || echo "0")
    echo "postgresql_ha_pgbouncer_active_clients $active_clients"
    
    # PgBouncer pool stats
    local pool_stats
    if pool_stats=$(timeout 5 bash -c "echo 'SHOW POOLS;' | sudo -u postgres env PGPASSFILE=/var/lib/postgresql/.pgpass psql -h localhost -p 6432 -U postgres -d pgbouncer -t" 2>/dev/null); then
        echo "postgresql_ha_pgbouncer_pools_available 1"
    else
        echo "postgresql_ha_pgbouncer_pools_available 0"
    fi
}

main() {
    echo "# PostgreSQL HA Custom Metrics"
    echo "# Generated at $(date)"
    
    collect_replication_metrics
    collect_repmgr_metrics
    collect_pgbouncer_metrics
}

main
EOF

    chmod +x "$metrics_script"
    success "Custom metrics script created: $metrics_script"
    
    # Test the script
    info "Testing custom metrics collection..."
    if "$metrics_script" >/dev/null 2>&1; then
        success "Custom metrics collection test passed"
    else
        warn "Custom metrics collection test failed - check script manually"
    fi
}

setup_alerting_policies() {
    section "Setting up Basic Alerting Policies"
    
    info "Creating alerting policy configuration templates..."
    
    local alerts_dir="/etc/postgresql-ha-alerts"
    mkdir -p "$alerts_dir"
    
    # Create alert policy templates (to be applied via gcloud or Terraform)
    cat > "$alerts_dir/alerting-policies.yaml" << 'EOF'
# PostgreSQL HA Alerting Policies
# Apply these using gcloud or Terraform

alerting_policies:
  - displayName: "PostgreSQL HA - High Replication Lag"
    conditions:
      - displayName: "Replication lag > 60 seconds"
        conditionThreshold:
          filter: 'resource.type="gce_instance" AND metric.type="custom.googleapis.com/postgresql_ha_replication_lag_seconds"'
          comparison: COMPARISON_GREATER_THAN
          thresholdValue: 60
          duration: 300s
    
  - displayName: "PostgreSQL HA - Standby Node Down"
    conditions:
      - displayName: "No active standbys"
        conditionThreshold:
          filter: 'resource.type="gce_instance" AND metric.type="custom.googleapis.com/postgresql_ha_standby_count"'
          comparison: COMPARISON_LESS_THAN
          thresholdValue: 1
          duration: 60s
    
  - displayName: "PostgreSQL HA - WAL Receiver Inactive"
    conditions:
      - displayName: "WAL receiver not running"
        conditionThreshold:
          filter: 'resource.type="gce_instance" AND metric.type="custom.googleapis.com/postgresql_ha_wal_receiver_active"'
          comparison: COMPARISON_LESS_THAN
          thresholdValue: 1
          duration: 60s
    
  - displayName: "PostgreSQL HA - High Connection Count"
    conditions:
      - displayName: "Connection count > 150"
        conditionThreshold:
          filter: 'resource.type="gce_instance" AND metric.type="custom.googleapis.com/postgresql_ha_connection_count"'
          comparison: COMPARISON_GREATER_THAN
          thresholdValue: 150
          duration: 300s
    
  - displayName: "PostgreSQL HA - Node Check Failed"
    conditions:
      - displayName: "Repmgr node check failing"
        conditionThreshold:
          filter: 'resource.type="gce_instance" AND metric.type="custom.googleapis.com/postgresql_ha_node_check_status"'
          comparison: COMPARISON_LESS_THAN
          thresholdValue: 1
          duration: 120s
EOF

    success "Alerting policy templates created in: $alerts_dir"
    
    info "To apply these policies, use:"
    info "  gcloud alpha monitoring policies create --policy-from-file=$alerts_dir/alerting-policies.yaml"
    info "  Or apply via Terraform using the google_monitoring_alert_policy resource"
}

main() {
    printf "%b" "$BLUE"
    cat << "EOF"
╔══════════════════════════════════════════════════════╗
║       PostgreSQL HA Monitoring Setup                ║
╚══════════════════════════════════════════════════════╝
EOF
    printf "%b" "$NC"
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # Check if running on GCE
    if ! curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/project/project-id' >/dev/null 2>&1; then
        warn "Not running on Google Cloud Platform - some features may not work"
    fi
    
    info "Setting up monitoring for PostgreSQL HA cluster..."
    
    local role
    role=$(get_pg_role)
    info "Node role detected: $role"
    
    # Install and configure monitoring
    install_google_cloud_ops_agent
    configure_ops_agent
    setup_postgresql_logging
    create_custom_metrics_script
    setup_alerting_policies
    
    success "Monitoring setup completed successfully!"
    
    info "Monitoring configuration summary:"
    info "  • Google Cloud Ops Agent: Installed and configured"
    info "  • PostgreSQL logging: Enhanced for monitoring"
    info "  • Custom metrics: Available for cluster-specific monitoring"
    info "  • Alerting policies: Templates created for manual deployment"
    info ""
    info "Next steps:"
    info "  1. Verify metrics are appearing in Google Cloud Monitoring"
    info "  2. Apply alerting policies using gcloud or Terraform"
    info "  3. Set up notification channels for alerts"
    info "  4. Create custom dashboards for visualization"
}

main "$@"