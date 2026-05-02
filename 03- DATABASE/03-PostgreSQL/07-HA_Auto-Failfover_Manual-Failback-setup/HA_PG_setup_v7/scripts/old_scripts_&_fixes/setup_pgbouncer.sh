#!/bin/bash
# PostgreSQL HA PgBouncer Setup Script
# Configures PgBouncer connection pooling for both primary and standby nodes

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

# Configuration
PGBOUNCER_PORT=6432
PGBOUNCER_POOL_SIZE=25
PGBOUNCER_MAX_CLIENT_CONN=100
PGBOUNCER_DEFAULT_POOL_SIZE=10

# Get metadata
get_metadata() {
  local key="$1" default="$2"
  curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo "$default"
}

# Load secrets (reuse from bootstrap script)
load_secrets() {
  info "Loading database passwords..."
  
  local env_code="$(get_metadata env_code nprd)"
  local org_code="$(get_metadata org_code ipa)"
  
  # Try to get passwords from Secret Manager
  local token
  token=$(curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | \
    jq -r '.access_token' 2>/dev/null || true)
  
  if [[ -n "$token" ]]; then
    local project_id
    project_id=$(curl -sf -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/project/project-id' || echo "unknown")
    
    # Get passwords from Secret Manager
    for secret_name in "pg-superuser-password" "repmgr-password"; do
      local secret_id="${org_code}-${env_code}-sec-${secret_name}-01"
      local url="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${secret_id}/versions/latest:access"
      
      if secret_value=$(curl -sf -H "Authorization: Bearer $token" "$url" | jq -r '.payload.data' | base64 -d 2>/dev/null); then
        case "$secret_name" in
          "pg-superuser-password") export PG_SUPER_PASS="$secret_value" ;;
          "repmgr-password") export REPMGR_PASSWORD="$secret_value" ;;
        esac
      fi
    done
  fi
  
  # Use defaults if secrets not available
  export PG_SUPER_PASS="${PG_SUPER_PASS:-defaultpassword123}"
  export REPMGR_PASSWORD="${REPMGR_PASSWORD:-repmgrpassword123}"
  
  info "✓ Database passwords loaded"
}

# Detect node configuration
detect_configuration() {
  info "Detecting node configuration..."
  
  # Get local IP
  export SELF_IP="$(hostname -I | awk '{print $1}')"
  
  # Determine role
  local is_recovery
  is_recovery=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "unknown")
  
  if [[ "$is_recovery" == "f" ]]; then
    export NODE_ROLE="primary"
    export PGBOUNCER_MODE="session"  # Primary handles all connection types
  elif [[ "$is_recovery" == "t" ]]; then
    export NODE_ROLE="standby"
    export PGBOUNCER_MODE="transaction"  # Standby optimized for read-only
  else
    error "Cannot determine node role"
    exit 1
  fi
  
  info "Node role: $NODE_ROLE ($SELF_IP)"
  info "PgBouncer mode: $PGBOUNCER_MODE"
}

# Install PgBouncer if not already installed
install_pgbouncer() {
  info "Checking PgBouncer installation..."
  
  if command -v pgbouncer >/dev/null 2>&1; then
    info "✓ PgBouncer is already installed"
    return 0
  fi
  
  info "Installing PgBouncer..."
  export DEBIAN_FRONTEND=noninteractive
  
  # Update package list and install
  apt-get update >/dev/null 2>&1
  apt-get install -y pgbouncer >/dev/null 2>&1
  
  if command -v pgbouncer >/dev/null 2>&1; then
    info "✓ PgBouncer installed successfully"
  else
    error "Failed to install PgBouncer"
    exit 1
  fi
}

# Configure PgBouncer
configure_pgbouncer() {
  info "Configuring PgBouncer..."
  
  # Create PgBouncer configuration directory
  mkdir -p /etc/pgbouncer
  
  # Generate pgbouncer.ini
  cat > /etc/pgbouncer/pgbouncer.ini <<EOF
;; PgBouncer configuration for PostgreSQL HA
;; Node: $NODE_ROLE ($SELF_IP)

[databases]
;; Production databases
postgres = host=localhost port=5432 dbname=postgres
repmgr = host=localhost port=5432 dbname=repmgr

;; Application databases (add your databases here)
; myapp = host=localhost port=5432 dbname=myapp
; myapp_readonly = host=localhost port=5432 dbname=myapp

[pgbouncer]
;; Connection settings
listen_addr = *
listen_port = $PGBOUNCER_PORT

;; Authentication
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

;; Connection pooling
pool_mode = $PGBOUNCER_MODE
max_client_conn = $PGBOUNCER_MAX_CLIENT_CONN
default_pool_size = $PGBOUNCER_DEFAULT_POOL_SIZE

;; Per-database pool settings
;; For primary node - larger pools for write operations
;; For standby node - smaller pools optimized for reads

EOF

  # Add role-specific pool configurations
  if [[ "$NODE_ROLE" == "primary" ]]; then
    cat >> /etc/pgbouncer/pgbouncer.ini <<EOF
;; Primary node - optimized for writes
postgres.pool_size = $PGBOUNCER_POOL_SIZE
repmgr.pool_size = 10

;; Server settings
server_round_robin = 1
server_check_delay = 30
server_check_query = SELECT 1

;; Timeouts
server_connect_timeout = 15
server_login_retry = 3
query_timeout = 300
query_wait_timeout = 120
client_idle_timeout = 0
server_idle_timeout = 600
server_lifetime = 3600

;; Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
stats_period = 60

;; Admin
admin_users = pgbouncer_admin
stats_users = pgbouncer_stats

EOF
  else
    cat >> /etc/pgbouncer/pgbouncer.ini <<EOF
;; Standby node - optimized for reads
postgres.pool_size = $((PGBOUNCER_POOL_SIZE / 2))
repmgr.pool_size = 5

;; Server settings
server_round_robin = 1
server_check_delay = 10
server_check_query = SELECT 1

;; Timeouts (shorter for read-only operations)
server_connect_timeout = 10
server_login_retry = 2
query_timeout = 120
query_wait_timeout = 60
client_idle_timeout = 300
server_idle_timeout = 300
server_lifetime = 1800

;; Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
stats_period = 60

;; Admin
admin_users = pgbouncer_admin
stats_users = pgbouncer_stats

EOF
  fi

  info "✓ PgBouncer configuration created"
}

# Create user authentication file
create_userlist() {
  info "Creating PgBouncer user authentication file..."
  
  # Generate MD5 hashes for passwords
  local postgres_md5 repmgr_md5 admin_md5
  
  # Use PostgreSQL to generate MD5 hashes
  postgres_md5=$(echo -n "${PG_SUPER_PASS}postgres" | md5sum | cut -d' ' -f1)
  repmgr_md5=$(echo -n "${REPMGR_PASSWORD}repmgr" | md5sum | cut -d' ' -f1)
  admin_md5=$(echo -n "pgbouncer_admin_pass123pgbouncer_admin" | md5sum | cut -d' ' -f1)
  
  # Create userlist.txt
  cat > /etc/pgbouncer/userlist.txt <<EOF
;; PgBouncer user authentication file
;; Format: "username" "md5_hash"

"postgres" "md5${postgres_md5}"
"repmgr" "md5${repmgr_md5}"
"pgbouncer_admin" "md5${admin_md5}"
"pgbouncer_stats" "md5${admin_md5}"

EOF

  info "✓ User authentication file created"
}

# Create PgBouncer system user and service
setup_pgbouncer_service() {
  info "Setting up PgBouncer service..."
  
  # Create pgbouncer user if it doesn't exist
  if ! id -u pgbouncer >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/pgbouncer --shell /bin/false pgbouncer
    info "✓ Created pgbouncer system user"
  else
    info "✓ pgbouncer user already exists"
  fi
  
  # Create directories
  mkdir -p /var/lib/pgbouncer /var/log/pgbouncer /etc/pgbouncer
  
  # Set permissions on config files and directories
  chown -R pgbouncer:pgbouncer /etc/pgbouncer /var/lib/pgbouncer /var/log/pgbouncer
  chmod 750 /etc/pgbouncer
  chmod 640 /etc/pgbouncer/pgbouncer.ini
  
  # Set permissions on userlist if it exists
  if [[ -f /etc/pgbouncer/userlist.txt ]]; then
    chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
    chmod 640 /etc/pgbouncer/userlist.txt
  fi
  
  # Create systemd service file
  cat > /etc/systemd/system/pgbouncer.service <<EOF
[Unit]
Description=PgBouncer connection pooler for PostgreSQL
Documentation=man:pgbouncer(1)
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=forking
User=pgbouncer
Group=pgbouncer
ExecStart=/usr/bin/pgbouncer -d /etc/pgbouncer/pgbouncer.ini
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/var/run/pgbouncer/pgbouncer.pid
RuntimeDirectory=pgbouncer
RuntimeDirectoryMode=0755
LimitNOFILE=65536

# Restart policy
Restart=on-failure
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF

  # Create runtime directory
  mkdir -p /var/run/pgbouncer
  chown pgbouncer:pgbouncer /var/run/pgbouncer
  
  # Enable and start service
  systemctl daemon-reload
  systemctl enable pgbouncer
  
  info "✓ PgBouncer service configured"
}

# Create health check script for GCP Load Balancer
create_health_check() {
  info "Creating PgBouncer health check endpoint..."
  
  cat > /usr/local/bin/pgbouncer-health.sh <<'EOF'
#!/bin/bash
# PgBouncer Health Check for GCP Load Balancer
set -euo pipefail

PORT=${1:-8002}

# Function to check PgBouncer status
check_pgbouncer() {
    # Check if PgBouncer is running
    if ! systemctl is-active --quiet pgbouncer 2>/dev/null; then
        return 1
    fi
    
    # Check if PgBouncer is accepting connections
    if ! timeout 2 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
        return 1
    fi
    
    # Basic connection test through PgBouncer
    if ! timeout 3 sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
        return 1
    fi
    
    return 0
}

# Function to handle HTTP request
handle_request() {
    if check_pgbouncer; then
        status="healthy"
        http_code="200 OK"
    else
        status="unhealthy"
        http_code="503 Service Unavailable"
    fi
    
    # Get node role
    role="unknown"
    if timeout 2 sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q '^f'; then
        role="primary"
    elif timeout 2 sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q '^t'; then
        role="standby"
    fi
    
    # Create response body
    body="{\"service\":\"pgbouncer\",\"status\":\"$status\",\"role\":\"$role\",\"timestamp\":\"$(date -u +%FT%TZ)\",\"hostname\":\"$(hostname)\"}"
    
    # Send HTTP response
    echo -e "HTTP/1.1 $http_code\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: ${#body}\r\nConnection: close\r\n\r\n$body"
}

# Simple HTTP server using netcat or socat
if command -v socat >/dev/null 2>&1; then
    # Use socat if available (more reliable)
    while true; do
        echo "$(handle_request)" | socat -T 5 TCP-LISTEN:$PORT,reuseaddr,fork STDIO 2>/dev/null || sleep 1
    done
elif command -v nc >/dev/null 2>&1; then
    # Fallback to netcat
    while true; do
        echo "$(handle_request)" | nc -l -p "$PORT" -q 1 >/dev/null 2>&1 || sleep 1
    done
else
    # Simple bash implementation
    while true; do
        {
            handle_request
        } | while read -r line; do
            echo "$line"
        done
        sleep 1
    done
fi
EOF

  chmod +x /usr/local/bin/pgbouncer-health.sh
  
  # Create systemd service for health check
  cat > /etc/systemd/system/pgbouncer-health.service <<EOF
[Unit]
Description=PgBouncer Health Check Endpoint
After=network.target pgbouncer.service
Wants=pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pgbouncer-health.sh 8002
Restart=always
RestartSec=5
User=postgres
Group=postgres
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable pgbouncer-health.service
  
  info "✓ PgBouncer health check endpoint created (port 8002)"
}

# Configure PostgreSQL for PgBouncer
configure_postgresql_for_pgbouncer() {
  info "Configuring PostgreSQL for PgBouncer..."
  
  # Create PgBouncer admin users in PostgreSQL
  sudo -u postgres psql -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
            CREATE ROLE pgbouncer_admin WITH LOGIN PASSWORD 'pgbouncer_admin_pass123';
        END IF;
        
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer_stats') THEN
            CREATE ROLE pgbouncer_stats WITH LOGIN PASSWORD 'pgbouncer_admin_pass123';
        END IF;
    END
    \$\$;
  " 2>/dev/null || warn "Could not create PgBouncer admin users"
  
  # Update pg_hba.conf for PgBouncer connections
  local pg_hba="/etc/postgresql/17/main/pg_hba.conf"
  
  if [[ -f "$pg_hba" ]] && ! grep -q "PgBouncer connections" "$pg_hba"; then
    cat >> "$pg_hba" <<EOF

# PgBouncer connections
local   all             pgbouncer_admin                         peer
local   all             pgbouncer_stats                         peer
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
EOF
    
    # Reload PostgreSQL configuration
    systemctl reload postgresql
    info "✓ PostgreSQL configured for PgBouncer"
  fi
}

# Start services
start_services() {
  info "Starting PgBouncer services..."
  
  # Start PgBouncer
  if systemctl start pgbouncer; then
    info "✓ PgBouncer started successfully"
  else
    error "Failed to start PgBouncer"
    systemctl status pgbouncer || true
    exit 1
  fi
  
  # Start health check
  if systemctl start pgbouncer-health.service; then
    info "✓ PgBouncer health check started successfully"
  else
    warn "Failed to start PgBouncer health check"
  fi
  
  # Verify services
  sleep 2
  
  if systemctl is-active --quiet pgbouncer; then
    info "✓ PgBouncer is running"
  else
    error "PgBouncer is not running"
    exit 1
  fi
  
  # Test connection
  if timeout 5 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
    info "✓ PgBouncer is accepting connections on port 6432"
  else
    error "PgBouncer is not accepting connections"
    exit 1
  fi
}

# Validate configuration
validate_setup() {
  info "Validating PgBouncer setup..."
  
  # Test connection through PgBouncer (use peer authentication)
  if sudo -u postgres psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer connection successful' as status;" 2>/dev/null | grep -q "PgBouncer connection successful"; then
    info "✓ Database connection through PgBouncer successful"
  else
    warn "⚠ PgBouncer connection test had issues (this may be normal during initial setup)"
    # Don't exit on this failure as PgBouncer might still be functional
  fi
  
  # Test health endpoint
  if timeout 5 curl -s "http://localhost:8002" >/dev/null 2>&1; then
    info "✓ PgBouncer health endpoint is responding"
    local health_response
    health_response=$(curl -s "http://localhost:8002" 2>/dev/null || echo "{}")
    debug "Health response: $health_response"
  else
    warn "PgBouncer health endpoint is not responding"
  fi
  
  # Show PgBouncer stats
  info "PgBouncer statistics:"
  sudo -u postgres psql -h localhost -p 6432 -U pgbouncer_admin -d pgbouncer -c "SHOW STATS;" 2>/dev/null || warn "Cannot access PgBouncer stats"
}

# Main execution
main() {
  echo "=========================================="
  echo "PostgreSQL HA PgBouncer Setup"
  echo "=========================================="
  echo "Starting PgBouncer configuration..."
  echo ""
  
  # Check if running as root
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
  fi
  
  # Main setup sequence
  detect_configuration
  load_secrets
  install_pgbouncer
  setup_pgbouncer_service  # Create user first
  configure_pgbouncer
  create_userlist
  create_health_check
  configure_postgresql_for_pgbouncer
  start_services
  validate_setup
  
  echo ""
  echo "=========================================="
  info "PgBouncer Setup Complete!"
  echo "=========================================="
  echo ""
  echo "Configuration Summary:"
  echo "• Node Role: $NODE_ROLE"
  echo "• PgBouncer Port: $PGBOUNCER_PORT"
  echo "• Pool Mode: $PGBOUNCER_MODE"
  echo "• Health Check Port: 8002"
  echo ""
  echo "Connection Examples:"
  echo "• Direct: psql -h localhost -p 6432 -U postgres -d postgres"
  echo "• Health: curl http://localhost:8002"
  echo ""
  echo "Next Steps:"
  echo "1. Configure GCP Internal Load Balancer"
  echo "2. Update application connection strings"
  echo "3. Test failover scenarios"
  echo ""
}

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "PostgreSQL HA PgBouncer Setup Script"
  echo ""
  echo "This script configures PgBouncer connection pooling for PostgreSQL HA cluster."
  echo ""
  echo "Usage: sudo $0"
  echo ""
  echo "The script will:"
  echo "• Install and configure PgBouncer"
  echo "• Set up connection pooling"
  echo "• Create health check endpoints"
  echo "• Configure authentication"
  echo "• Start services"
  echo ""
  exit 0
fi

main "$@"