# GCP Internal Load Balancer Health Validation Guide

## Understanding the Issue

**❌ WRONG WAY (what was tested before):**
```bash
curl -s -o /dev/null -w "%{http_code}" http://192.168.14.20:6432
# This fails because:
# - Port 6432 is PostgreSQL/PgBouncer (database protocol)
# - HTTP requests to database ports return "000" (connection refused)
```

**✅ CORRECT WAY:**

### 1. Test GCP Health Check Endpoints (What GCP ILB Actually Uses)
```bash
# PostgreSQL Health Endpoints (used by GCP for backend health)
curl -s http://192.168.14.21:8001 | jq .  # Primary PostgreSQL health
curl -s http://192.168.14.22:8001 | jq .  # Standby PostgreSQL health

# PgBouncer Health Endpoints (used by GCP for backend health)  
curl -s http://192.168.14.21:8002 | jq .  # Primary PgBouncer health
curl -s http://192.168.14.22:8002 | jq .  # Standby PgBouncer health
```

### 2. Test Load Balancer TCP Connectivity
```bash
# Test if load balancer ports are accessible (TCP level)
timeout 5 bash -c "</dev/tcp/192.168.14.20/6432" && echo "Write LB Port: OPEN" || echo "Write LB Port: CLOSED"
timeout 5 bash -c "</dev/tcp/192.168.14.19/6432" && echo "Read LB Port: OPEN" || echo "Read LB Port: CLOSED"
```

### 3. Test Database Routing Through Load Balancers
```bash
# Test actual database connectivity through load balancers
export PG_SUPER_PASS='your_password'

# Write Load Balancer Test
PGPASSWORD="$PG_SUPER_PASS" psql -h 192.168.14.20 -p 6432 -U postgres -d postgres -c "SELECT 'Write LB Test' as result;"

# Read Load Balancer Test  
PGPASSWORD="$PG_SUPER_PASS" psql -h 192.168.14.19 -p 6432 -U postgres -d postgres -c "SELECT 'Read LB Test' as result;"
```

### 4. Test DNS Service Discovery
```bash
# Test DNS resolution
dig +short pg-write.db.internal.nprd.ipa.edu.sa  # Should return 192.168.14.20
dig +short pg-read.db.internal.nprd.ipa.edu.sa   # Should return 192.168.14.19

# Test database connectivity via DNS
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SELECT 'DNS Write Test';"
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SELECT 'DNS Read Test';"
```

## How GCP Internal Load Balancers Work

### Load Balancer Architecture:
```
Internet/Apps → DNS → Load Balancer VIP → Backend Health Check → Healthy Backends

Write Path: Apps → pg-write.db.internal.nprd.ipa.edu.sa (192.168.14.20:6432) → Primary (192.168.14.21:6432)
Read Path:  Apps → pg-read.db.internal.nprd.ipa.edu.sa (192.168.14.19:6432) → Standby (192.168.14.22:6432)
```

### Health Check Flow:
```
GCP ILB → Backend:8001 (PostgreSQL Health) → HTTP 200 = Healthy Backend
GCP ILB → Backend:8002 (PgBouncer Health) → HTTP 200 = Healthy Backend

If Backend Healthy: Route traffic to Backend:6432 (Database)
If Backend Unhealthy: Remove backend from rotation
```

## Expected Results for Healthy System:

### ✅ Health Endpoints Should Return:
```json
# Primary PostgreSQL Health (192.168.14.21:8001)
{"status": "healthy", "role": "primary", "timestamp": "..."}

# Standby PostgreSQL Health (192.168.14.22:8001)  
{"status": "healthy", "role": "standby", "timestamp": "..."}

# Primary PgBouncer Health (192.168.14.21:8002)
{"status": "healthy", "service": "pgbouncer", "timestamp": "..."}

# Standby PgBouncer Health (192.168.14.22:8002)
{"status": "healthy", "service": "pgbouncer", "timestamp": "..."}
```

### ✅ TCP Connectivity Should Show:
```
Write LB Port (192.168.14.20:6432): OPEN
Read LB Port (192.168.14.19:6432): OPEN
Write LB Port (192.168.14.20:5432): OPEN  
Read LB Port (192.168.14.19:5432): OPEN
```

### ✅ Database Connectivity Should Show:
```
Write LB Test: SUCCESS (can read/write)
Read LB Test: SUCCESS (can read)
DNS Write Test: SUCCESS
DNS Read Test: SUCCESS
```

## Troubleshooting Commands:

```bash
# Check if backends are healthy
curl -s http://192.168.14.21:8001 | jq .status  # Should be "healthy"
curl -s http://192.168.14.22:8001 | jq .status  # Should be "healthy"

# Check if services are running on backends
ssh user@192.168.14.21 "systemctl status final-pg-health final-pgbouncer-health postgresql pgbouncer"
ssh user@192.168.14.22 "systemctl status final-pg-health final-pgbouncer-health postgresql pgbouncer"

# Test direct backend connectivity (bypassing load balancer)
PGPASSWORD="$PG_SUPER_PASS" psql -h 192.168.14.21 -p 6432 -U postgres -c "SELECT 'Direct Primary Test';"
PGPASSWORD="$PG_SUPER_PASS" psql -h 192.168.14.22 -p 6432 -U postgres -c "SELECT 'Direct Standby Test';"
```

## Using the Comprehensive Validator:

```bash
# Make the script executable
chmod +x load_balancer_health_validator.sh

# Run with password for full testing
export PG_SUPER_PASS='your_password'
./load_balancer_health_validator.sh

# Run without password (limited testing)
./load_balancer_health_validator.sh
```

The validator will test:
1. ✅ DNS Resolution
2. ✅ Backend Health Endpoints  
3. ✅ Load Balancer TCP Connectivity
4. ✅ GCP Health Check Simulation
5. ✅ Database Routing (if password provided)
6. ✅ DNS-based Routing (if password provided)

This comprehensive approach tests exactly what GCP Internal Load Balancers need to work correctly in production!