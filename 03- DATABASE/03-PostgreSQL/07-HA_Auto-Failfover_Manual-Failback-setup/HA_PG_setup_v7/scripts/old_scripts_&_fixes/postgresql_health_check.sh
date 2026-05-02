#!/bin/bash
# PostgreSQL HA Health Check Endpoint
# This script provides a health check endpoint for load balancers
# Returns HTTP 200 if node should receive traffic, HTTP 503 if not
# Version: 1.0.0

set -euo pipefail

# Configuration
HEALTH_CHECK_PORT=${HEALTH_CHECK_PORT:-8001}
PG_PORT=${PG_PORT:-5432}
PG_HOST=${PG_HOST:-localhost}
PG_USER=${PG_USER:-postgres}
PG_DATABASE=${PG_DATABASE:-postgres}
CHECK_TYPE=${CHECK_TYPE:-"write"}  # "write" or "read"

# Health check logic
check_postgresql_health() {
    local check_type="$1"
    
    # Test basic PostgreSQL connectivity
    if ! timeout 3 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
        echo "HTTP/1.1 503 Service Unavailable"
        echo "Content-Type: text/plain"
        echo ""
        echo "PostgreSQL not responding"
        return 1
    fi
    
    # Check node role
    local is_in_recovery
    is_in_recovery=$(timeout 3 env PGPASSWORD="$PG_SUPER_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "true")
    
    if [[ "$check_type" == "write" ]]; then
        # For write health checks, only PRIMARY nodes should pass
        if [[ "$is_in_recovery" == "f" ]]; then
            echo "HTTP/1.1 200 OK"
            echo "Content-Type: application/json"
            echo ""
            echo '{"status":"healthy","role":"primary","can_write":true}'
            return 0
        else
            echo "HTTP/1.1 503 Service Unavailable"
            echo "Content-Type: application/json"
            echo ""
            echo '{"status":"unhealthy","role":"standby","can_write":false}'
            return 1
        fi
    else
        # For read health checks, both PRIMARY and STANDBY can pass
        local role
        if [[ "$is_in_recovery" == "f" ]]; then
            role="primary"
        else
            role="standby"
        fi
        
        echo "HTTP/1.1 200 OK"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"status\":\"healthy\",\"role\":\"$role\",\"can_read\":true}"
        return 0
    fi
}

# Simple HTTP server using netcat or socat
start_health_server() {
    local port="$1"
    local check_type="$2"
    
    echo "Starting PostgreSQL health check server on port $port (check_type: $check_type)"
    
    if command -v socat >/dev/null 2>&1; then
        # Use socat if available (more robust)
        while true; do
            echo "$(check_postgresql_health "$check_type")" | socat TCP-LISTEN:$port,reuseaddr,fork STDIO
        done
    elif command -v nc >/dev/null 2>&1; then
        # Fallback to netcat
        while true; do
            echo "$(check_postgresql_health "$check_type")" | nc -l -p "$port" -q 1
        done
    else
        echo "ERROR: Neither socat nor netcat (nc) is available"
        echo "Please install one of them to run the health check server"
        exit 1
    fi
}

# Systemd service mode
create_systemd_service() {
    local check_type="$1"
    local service_name="postgresql-health-check-${check_type}"
    
    cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=PostgreSQL HA Health Check Server (${check_type})
After=postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=postgres
Group=postgres
Environment=HEALTH_CHECK_PORT=${HEALTH_CHECK_PORT}
Environment=CHECK_TYPE=${check_type}
Environment=PG_HOST=${PG_HOST}
Environment=PG_PORT=${PG_PORT}
Environment=PG_USER=${PG_USER}
Environment=PG_DATABASE=${PG_DATABASE}
Environment=PGPASSFILE=/var/lib/postgresql/.pgpass
ExecStart=$0 server
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    echo "Systemd service created: /etc/systemd/system/${service_name}.service"
    echo "To start: sudo systemctl enable --now ${service_name}"
}

# Install dependencies
install_dependencies() {
    echo "Installing health check dependencies..."
    
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y socat netcat-openbsd
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y socat nc
    else
        echo "Please install socat or netcat manually"
        exit 1
    fi
}

# Main function
case "${1:-help}" in
    "server")
        start_health_server "$HEALTH_CHECK_PORT" "$CHECK_TYPE"
        ;;
    "check")
        check_postgresql_health "${2:-read}"
        ;;
    "install-service")
        create_systemd_service "${2:-write}"
        echo ""
        echo "Next steps:"
        echo "1. sudo systemctl daemon-reload"
        echo "2. sudo systemctl enable postgresql-health-check-${2:-write}"
        echo "3. sudo systemctl start postgresql-health-check-${2:-write}"
        ;;
    "install-deps")
        install_dependencies
        ;;
    "test")
        echo "Testing health check..."
        check_postgresql_health "${2:-read}"
        ;;
    *)
        echo "PostgreSQL HA Health Check Endpoint"
        echo "Usage: $0 {server|check|install-service|install-deps|test} [check_type]"
        echo ""
        echo "Commands:"
        echo "  server                  - Start health check HTTP server"
        echo "  check [write|read]      - Run single health check"
        echo "  install-service [type]  - Create systemd service (write or read)"
        echo "  install-deps            - Install required dependencies"
        echo "  test [write|read]       - Test health check functionality"
        echo ""
        echo "Environment Variables:"
        echo "  HEALTH_CHECK_PORT       - Port for health check server (default: 8001)"
        echo "  PG_HOST                 - PostgreSQL host (default: localhost)"
        echo "  PG_PORT                 - PostgreSQL port (default: 5432)"
        echo "  CHECK_TYPE              - Health check type: write or read (default: write)"
        echo ""
        echo "Examples:"
        echo "  # Install dependencies"
        echo "  $0 install-deps"
        echo ""
        echo "  # Create write health check service"
        echo "  $0 install-service write"
        echo ""
        echo "  # Create read health check service on different port"
        echo "  HEALTH_CHECK_PORT=8002 $0 install-service read"
        echo ""
        echo "  # Test health check manually"
        echo "  $0 test write"
        echo ""
        echo "  # Start server manually"
        echo "  CHECK_TYPE=write HEALTH_CHECK_PORT=8001 $0 server"
        exit 1
        ;;
esac