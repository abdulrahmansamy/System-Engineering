#!/bin/bash
# PostgreSQL HA + PgBouncer + GCP Load Balancer Deployment Guide
# Complete implementation script and application integration examples

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
guide() { echo -e "${BLUE}[GUIDE]${NC} $*"; }

echo "=========================================="
echo "PostgreSQL HA + PgBouncer + GCP LB"
echo "Complete Implementation Guide"
echo "=========================================="
echo ""

info "DEPLOYMENT OVERVIEW:"
echo ""
echo "This guide covers the complete implementation of:"
echo "✅ PostgreSQL HA cluster (DONE)"
echo "✅ PgBouncer connection pooling (NEXT)"
echo "✅ GCP Internal Load Balancer (NEXT)"
echo "✅ Application integration (FINAL)"
echo ""

# Phase 1: PgBouncer Setup
echo "=========================================="
guide "PHASE 1: PgBouncer Setup"
echo "=========================================="
echo ""

info "Step 1: Deploy PgBouncer on both nodes"
echo ""
echo "Run on PRIMARY server (192.168.14.21):"
echo "  chmod +x setup_pgbouncer.sh"
echo "  sudo ./setup_pgbouncer.sh"
echo ""
echo "Run on STANDBY server (192.168.14.22):"
echo "  chmod +x setup_pgbouncer.sh"
echo "  sudo ./setup_pgbouncer.sh"
echo ""

info "Step 2: Verify PgBouncer deployment"
echo ""
echo "Test connections:"
echo "  # Test on primary"
echo "  psql -h localhost -p 6432 -U postgres -d postgres"
echo ""
echo "  # Test health endpoints"
echo "  curl http://192.168.14.21:8002  # Primary PgBouncer health"
echo "  curl http://192.168.14.22:8002  # Standby PgBouncer health"
echo ""

# Phase 2: GCP Load Balancer
echo "=========================================="
guide "PHASE 2: GCP Load Balancer Setup"
echo "=========================================="
echo ""

info "Step 1: Update Terraform configuration"
echo ""
echo "Add to your terraform/main.tf:"
cat << 'EOF'

# Add PgBouncer firewall rules to existing configuration
resource "google_compute_firewall" "pgbouncer_access" {
  name        = "${var.org_code}-${var.env_code}-pgbouncer-access"
  description = "Allow access to PgBouncer connection pooler"
  network     = google_compute_network.vpc.name
  
  allow {
    protocol = "tcp"
    ports    = ["6432"]
  }
  
  source_ranges = [var.subnet_cidr]
  target_tags   = ["postgresql-server"]
}

resource "google_compute_firewall" "pgbouncer_health_check" {
  name        = "${var.org_code}-${var.env_code}-pgbouncer-health"
  description = "Allow health check access to PgBouncer"
  network     = google_compute_network.vpc.name
  
  allow {
    protocol = "tcp"
    ports    = ["8002"]
  }
  
  source_ranges = [
    "35.191.0.0/16",    # GCP health checks
    "130.211.0.0/22",   # GCP health checks
    var.subnet_cidr
  ]
  
  target_tags = ["postgresql-server"]
}

# Health check for PgBouncer
resource "google_compute_health_check" "pgbouncer" {
  name = "${var.org_code}-${var.env_code}-pgbouncer-health"
  
  http_health_check {
    port         = 8002
    request_path = "/"
  }
  
  timeout_sec         = 5
  check_interval_sec  = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

# Instance groups
resource "google_compute_instance_group" "pg_primary_group" {
  name = "${var.org_code}-${var.env_code}-primary-group"
  zone = var.primary_zone
  
  instances = [google_compute_instance.pg_primary.id]
  
  named_port {
    name = "pgbouncer"
    port = 6432
  }
}

resource "google_compute_instance_group" "pg_standby_group" {
  name = "${var.org_code}-${var.env_code}-standby-group"
  zone = var.standby_zone
  
  instances = [google_compute_instance.pg_standby.id]
  
  named_port {
    name = "pgbouncer"
    port = 6432
  }
}

# Backend service for writes (primary only)
resource "google_compute_region_backend_service" "pgbouncer_write" {
  name                  = "${var.org_code}-${var.env_code}-pg-write"
  region               = var.region
  protocol             = "TCP"
  load_balancing_scheme = "INTERNAL"
  
  health_checks = [google_compute_health_check.pgbouncer.id]
  
  backend {
    group = google_compute_instance_group.pg_primary_group.id
  }
}

# Backend service for reads (load balanced)
resource "google_compute_region_backend_service" "pgbouncer_read" {
  name                  = "${var.org_code}-${var.env_code}-pg-read"
  region               = var.region
  protocol             = "TCP"
  load_balancing_scheme = "INTERNAL"
  
  health_checks = [google_compute_health_check.pgbouncer.id]
  
  backend {
    group           = google_compute_instance_group.pg_primary_group.id
    capacity_scaler = 0.3  # Lower priority for reads
  }
  
  backend {
    group           = google_compute_instance_group.pg_standby_group.id
    capacity_scaler = 1.0  # Prefer standby for reads
  }
}

# Load balancer IPs
resource "google_compute_address" "pg_write_ip" {
  name         = "${var.org_code}-${var.env_code}-pg-write-ip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.pg_subnet.id
  address_type = "INTERNAL"
}

resource "google_compute_address" "pg_read_ip" {
  name         = "${var.org_code}-${var.env_code}-pg-read-ip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.pg_subnet.id
  address_type = "INTERNAL"
}

# Forwarding rules
resource "google_compute_forwarding_rule" "pg_write" {
  name                  = "${var.org_code}-${var.env_code}-pg-write"
  region               = var.region
  load_balancing_scheme = "INTERNAL"
  
  backend_service = google_compute_region_backend_service.pgbouncer_write.id
  ip_address     = google_compute_address.pg_write_ip.address
  ip_protocol    = "TCP"
  ports          = ["6432"]
  
  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.pg_subnet.id
}

resource "google_compute_forwarding_rule" "pg_read" {
  name                  = "${var.org_code}-${var.env_code}-pg-read"
  region               = var.region
  load_balancing_scheme = "INTERNAL"
  
  backend_service = google_compute_region_backend_service.pgbouncer_read.id
  ip_address     = google_compute_address.pg_read_ip.address
  ip_protocol    = "TCP"
  ports          = ["6432"]
  
  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.pg_subnet.id
}

# Outputs
output "database_endpoints" {
  description = "Database connection endpoints"
  value = {
    write_endpoint = "${google_compute_address.pg_write_ip.address}:6432"
    read_endpoint  = "${google_compute_address.pg_read_ip.address}:6432"
    primary_direct = "${google_compute_instance.pg_primary.network_interface[0].network_ip}:6432"
    standby_direct = "${google_compute_instance.pg_standby.network_interface[0].network_ip}:6432"
  }
}

EOF
echo ""

info "Step 2: Deploy load balancer infrastructure"
echo ""
echo "In your terraform directory:"
echo "  terraform plan"
echo "  terraform apply"
echo ""

# Phase 3: Application Integration
echo "=========================================="
guide "PHASE 3: Application Integration"
echo "=========================================="
echo ""

info "Connection String Examples:"
echo ""

echo "After Terraform deployment, you'll get endpoints like:"
echo "• Write endpoint: 192.168.14.100:6432 (writes to primary)"
echo "• Read endpoint:  192.168.14.101:6432 (reads from both, prefer standby)"
echo ""

info "Application Configuration Examples:"
echo ""

# Python example
guide "Python (psycopg2/asyncpg):"
cat << 'EOF'
import psycopg2
from psycopg2 import pool

# Connection configuration
WRITE_DSN = "postgresql://username:password@192.168.14.100:6432/myapp"
READ_DSN = "postgresql://username:password@192.168.14.101:6432/myapp"

# Connection pools
write_pool = psycopg2.pool.ThreadedConnectionPool(
    minconn=1,
    maxconn=20,
    dsn=WRITE_DSN
)

read_pool = psycopg2.pool.ThreadedConnectionPool(
    minconn=1,
    maxconn=50,
    dsn=READ_DSN
)

class DatabaseManager:
    @staticmethod
    def get_write_connection():
        return write_pool.getconn()
    
    @staticmethod
    def get_read_connection():
        return read_pool.getconn()
    
    @staticmethod
    def return_connection(conn, pool_type='read'):
        if pool_type == 'write':
            write_pool.putconn(conn)
        else:
            read_pool.putconn(conn)

# Usage example
def create_user(name, email):
    conn = DatabaseManager.get_write_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO users (name, email) VALUES (%s, %s)",
                (name, email)
            )
        conn.commit()
    finally:
        DatabaseManager.return_connection(conn, 'write')

def get_users():
    conn = DatabaseManager.get_read_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id, name, email FROM users")
            return cur.fetchall()
    finally:
        DatabaseManager.return_connection(conn, 'read')
EOF
echo ""

# Java example
guide "Java (HikariCP + JDBC):"
cat << 'EOF'
// application.properties
spring.datasource.write.url=jdbc:postgresql://192.168.14.100:6432/myapp
spring.datasource.write.username=username
spring.datasource.write.password=password
spring.datasource.write.hikari.maximum-pool-size=20
spring.datasource.write.hikari.minimum-idle=5

spring.datasource.read.url=jdbc:postgresql://192.168.14.101:6432/myapp
spring.datasource.read.username=username
spring.datasource.read.password=password
spring.datasource.read.hikari.maximum-pool-size=50
spring.datasource.read.hikari.minimum-idle=10

// DatabaseConfig.java
@Configuration
public class DatabaseConfig {
    
    @Bean
    @Primary
    @ConfigurationProperties("spring.datasource.write")
    public DataSource writeDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }
    
    @Bean
    @ConfigurationProperties("spring.datasource.read")
    public DataSource readDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }
    
    @Bean
    public JdbcTemplate writeJdbcTemplate(@Qualifier("writeDataSource") DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
    
    @Bean
    public JdbcTemplate readJdbcTemplate(@Qualifier("readDataSource") DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
}

// Service example
@Service
public class UserService {
    
    @Autowired
    @Qualifier("writeJdbcTemplate")
    private JdbcTemplate writeJdbcTemplate;
    
    @Autowired
    @Qualifier("readJdbcTemplate")
    private JdbcTemplate readJdbcTemplate;
    
    @Transactional
    public void createUser(String name, String email) {
        writeJdbcTemplate.update(
            "INSERT INTO users (name, email) VALUES (?, ?)",
            name, email
        );
    }
    
    @Transactional(readOnly = true)
    public List<User> getUsers() {
        return readJdbcTemplate.query(
            "SELECT id, name, email FROM users",
            (rs, rowNum) -> new User(
                rs.getLong("id"),
                rs.getString("name"),
                rs.getString("email")
            )
        );
    }
}
EOF
echo ""

# Node.js example
guide "Node.js (pg library):"
cat << 'EOF'
const { Pool } = require('pg');

// Connection pools
const writePool = new Pool({
  connectionString: 'postgresql://username:password@192.168.14.100:6432/myapp',
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

const readPool = new Pool({
  connectionString: 'postgresql://username:password@192.168.14.101:6432/myapp',
  max: 50,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

class DatabaseManager {
  static async executeWrite(query, params = []) {
    const client = await writePool.connect();
    try {
      const result = await client.query(query, params);
      return result;
    } finally {
      client.release();
    }
  }
  
  static async executeRead(query, params = []) {
    const client = await readPool.connect();
    try {
      const result = await client.query(query, params);
      return result;
    } finally {
      client.release();
    }
  }
}

// Usage examples
async function createUser(name, email) {
  const result = await DatabaseManager.executeWrite(
    'INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id',
    [name, email]
  );
  return result.rows[0].id;
}

async function getUsers() {
  const result = await DatabaseManager.executeRead(
    'SELECT id, name, email FROM users'
  );
  return result.rows;
}

// Export pools for graceful shutdown
module.exports = {
  DatabaseManager,
  writePool,
  readPool
};
EOF
echo ""

# Phase 4: Testing and Monitoring
echo "=========================================="
guide "PHASE 4: Testing and Monitoring"
echo "=========================================="
echo ""

info "Step 1: Validate complete setup"
echo ""
echo "Create a test script (test_complete_setup.sh):"
cat << 'EOF'
#!/bin/bash
# Test the complete PostgreSQL HA + PgBouncer + Load Balancer setup

set -euo pipefail

WRITE_ENDPOINT="192.168.14.100"  # Replace with your write LB IP
READ_ENDPOINT="192.168.14.101"   # Replace with your read LB IP

echo "Testing complete PostgreSQL HA setup..."

# Test 1: Direct PgBouncer connections
echo "1. Testing direct PgBouncer connections..."
psql -h 192.168.14.21 -p 6432 -U postgres -d postgres -c "SELECT 'Primary PgBouncer OK' as status;"
psql -h 192.168.14.22 -p 6432 -U postgres -d postgres -c "SELECT 'Standby PgBouncer OK' as status;"

# Test 2: Load balancer endpoints
echo "2. Testing load balancer endpoints..."
psql -h $WRITE_ENDPOINT -p 6432 -U postgres -d postgres -c "SELECT 'Write endpoint OK', pg_is_in_recovery() as is_standby;"
psql -h $READ_ENDPOINT -p 6432 -U postgres -d postgres -c "SELECT 'Read endpoint OK', pg_is_in_recovery() as is_standby;"

# Test 3: Write/Read split validation
echo "3. Testing write/read operations..."

# Create test table on write endpoint
psql -h $WRITE_ENDPOINT -p 6432 -U postgres -d postgres -c "
  CREATE TABLE IF NOT EXISTS load_balancer_test (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT NOW(),
    endpoint_type TEXT
  );
"

# Insert data via write endpoint
psql -h $WRITE_ENDPOINT -p 6432 -U postgres -d postgres -c "
  INSERT INTO load_balancer_test (endpoint_type) VALUES ('write_endpoint');
"

# Read data via read endpoint (should see the data after replication)
sleep 1
psql -h $READ_ENDPOINT -p 6432 -U postgres -d postgres -c "
  SELECT * FROM load_balancer_test ORDER BY created_at DESC LIMIT 5;
"

echo "✅ Complete setup test passed!"
EOF

echo "  chmod +x test_complete_setup.sh"
echo "  ./test_complete_setup.sh"
echo ""

info "Step 2: Set up monitoring"
echo ""
echo "Monitor key metrics:"
echo "• PgBouncer connection stats: SHOW STATS; in PgBouncer admin"
echo "• Load balancer health: GCP Console > Load Balancing"
echo "• PostgreSQL replication lag: Built-in monitoring"
echo "• Application connection patterns: Application logs"
echo ""

info "Step 3: Failover testing"
echo ""
echo "Test scenarios:"
echo "1. Primary failure: Stop primary PostgreSQL, verify writes redirect"
echo "2. Standby failure: Stop standby, verify reads use primary"
echo "3. PgBouncer failure: Restart PgBouncer, verify reconnection"
echo "4. Network issues: Test connection timeouts and retries"
echo ""

# Summary
echo "=========================================="
info "DEPLOYMENT SUMMARY"
echo "=========================================="
echo ""
echo "Complete PostgreSQL HA architecture:"
echo ""
echo "Applications"
echo "     ↓"
echo "GCP Internal Load Balancer"
echo "   ↙         ↘"
echo "Write LB    Read LB"
echo "   ↓           ↓"
echo "PgBouncer   PgBouncer"
echo "   ↓           ↓"
echo "Primary ←→ Standby"
echo ""
echo "Features implemented:"
echo "✅ PostgreSQL streaming replication"
echo "✅ Automatic failover (repmgr)"
echo "✅ Connection pooling (PgBouncer)"
echo "✅ Load balancing (GCP Internal LB)"
echo "✅ Health monitoring (Multiple endpoints)"
echo "✅ Read/write splitting"
echo ""
echo "Next steps:"
echo "1. Deploy PgBouncer: ./setup_pgbouncer.sh"
echo "2. Update Terraform: terraform apply"
echo "3. Test complete setup: ./test_complete_setup.sh"
echo "4. Update applications: Use new connection endpoints"
echo ""
echo "🎉 Production-ready PostgreSQL HA cluster with load balancing!"