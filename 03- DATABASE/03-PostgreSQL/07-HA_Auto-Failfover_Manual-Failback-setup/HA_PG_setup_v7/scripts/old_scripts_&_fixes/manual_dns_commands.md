# PostgreSQL HA DNS Endpoint Manual Testing Commands
# Quick reference for testing pg-read and pg-write endpoints

## Prerequisites
### Set password (choose one method):
```
export PG_SUPER_PASS=$(gcloud secrets versions access latest --secret="ipa-nprd-sec-pg-superuser-password-01" --project="ipa-nprd-svc-db-01")
```
#### OR
```
export PG_SUPER_PASS='?=4-*HWWydY6rdhF34K!qD*%Q3gLc^dT'
```
### Then
```
export PGPASSWORD="$PG_SUPER_PASS"
```

## Basic Connectivity Tests

### Test READ endpoint
```
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SELECT current_timestamp, pg_is_in_recovery() as is_standby, inet_server_addr() as server_ip;"
```

### Test WRITE endpoint  
```
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SELECT current_timestamp, pg_is_in_recovery() as is_standby, inet_server_addr() as server_ip;"
```

## DNS Resolution Tests

### Check DNS resolution
```
dig +short pg-read.db.internal.nprd.ipa.edu.sa
dig +short pg-write.db.internal.nprd.ipa.edu.sa
```

### Test port connectivity
```
nc -zv pg-read.db.internal.nprd.ipa.edu.sa 6432
nc -zv pg-write.db.internal.nprd.ipa.edu.sa 6432
```

## READ Operations Test

### Basic read test
```
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "
SELECT 
    current_timestamp as test_time,
    current_user as connected_user,
    current_database() as database_name,
    version() as pg_version;
"
```

### System information
```
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "
SELECT 
    pg_is_in_recovery() as is_standby,
    pg_postmaster_start_time() as startup_time,
    count(*) as active_connections
FROM pg_stat_activity
WHERE state = 'active';
"
```

### Check replication status (if on primary)
```
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "
SELECT 
    client_addr,
    application_name,
    state,
    sync_state,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
"
```

## WRITE Operations Test

### Check if we're on primary
```
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "
SELECT 
    CASE WHEN pg_is_in_recovery() THEN 'STANDBY (READ-ONLY)' ELSE 'PRIMARY (WRITABLE)' END as node_status,
    inet_server_addr() as server_ip;
"
```

### Simple write test
```
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "
DROP TABLE IF EXISTS write_test_$(date +%s);
CREATE TABLE write_test_$(date +%s) (
    id SERIAL PRIMARY KEY,
    test_data TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO write_test_$(date +%s) (test_data) VALUES ('Manual test data');
SELECT * FROM write_test_$(date +%s);
DROP TABLE write_test_$(date +%s);
"
```

### Transaction test
```
PGPASSWORD="$PG_SUPER_PASS" psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "
BEGIN;
CREATE TABLE tx_test (id INT, data TEXT);
INSERT INTO tx_test VALUES (1, 'Transaction test');
SELECT count(*) FROM tx_test;
COMMIT;
DROP TABLE tx_test;
SELECT 'Transaction completed successfully' as result;
"
```

## Interactive Sessions

### Connect to READ endpoint
```
psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres
```

### Connect to WRITE endpoint
```
psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres
```

## Advanced Testing

### Test load balancing behavior
```
for i in {1..10}; do
    echo "Test $i:"
    psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -Atqc "SELECT inet_server_addr() as server_ip, pg_is_in_recovery() as is_standby;"
    sleep 1
done
```

### Test write endpoint consistency
```
for i in {1..5}; do
    echo "Write test $i:"
    psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -Atqc "SELECT inet_server_addr() as server_ip, CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END as role;"
    sleep 2
done
```

### Performance test
```
time psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SELECT count(*) FROM pg_stat_activity;"
time psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SELECT 1;"
```

## Troubleshooting Commands

### Check if PgBouncer is the issue
#### Test direct PostgreSQL connection (port 5432)
```
psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 5432 -U postgres -d postgres -c "SELECT 'Direct connection works';"
```

### Check connection pooling
```
psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SHOW pool_mode;" 2>/dev/null || echo "Not connected via PgBouncer"
```

### Test with specific IP addresses
```
psql -h 192.168.14.21 -p 6432 -U postgres -d postgres -c "SELECT inet_server_addr(), pg_is_in_recovery();"
psql -h 192.168.14.22 -p 6432 -U postgres -d postgres -c "SELECT inet_server_addr(), pg_is_in_recovery();"
```

## Expected Results

### READ endpoint should:
 - Connect to either PRIMARY or STANDBY
 - Allow all SELECT operations
 - Show consistent performance

### WRITE endpoint should:
 - Always connect to PRIMARY
 - Allow INSERT/UPDATE/DELETE operations  
 - Show is_standby = false

### Error Scenarios to Test

### What happens if primary is down?
- WRITE endpoint should fail or redirect to new primary
- READ endpoint should still work (connecting to standby)

### What happens if standby is down?
- READ endpoint should redirect to primary
- WRITE endpoint should continue working normally

## Load Balancer Health Checks

### Simulate health check queries
```
psql -h pg-write.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SELECT 1;" # Should always succeed on primary
psql -h pg-read.db.internal.nprd.ipa.edu.sa -p 6432 -U postgres -d postgres -c "SELECT 1;" # Should succeed on any healthy node
```