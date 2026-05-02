#!/bin/bash
# One-Line Health Endpoint Fix
# Run this command on BOTH nodes to immediately fix all health endpoints

# Clean up existing processes
pkill -f ":8001" 2>/dev/null || true
pkill -f ":8002" 2>/dev/null || true
sleep 2

# Configure firewall
iptables -I INPUT -p tcp --dport 8001 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 8002 -j ACCEPT 2>/dev/null || true

# Create PostgreSQL health script
cat > /tmp/pg_health_8001.sh << 'EOF'
#!/bin/bash
while true; do
  if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
    role=$(sudo -u postgres psql -Atqc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;" 2>/dev/null || echo "unknown")
    response="{\"status\":\"healthy\",\"service\":\"postgresql-ha\",\"role\":\"$role\",\"message\":\"PostgreSQL operational\",\"timestamp\":\"$(date -Iseconds)\",\"node_ip\":\"$(hostname -I | awk '{print $1}')\"}"
    status_line="HTTP/1.1 200 OK"
  else
    response="{\"status\":\"unhealthy\",\"service\":\"postgresql-ha\",\"role\":\"unknown\",\"message\":\"PostgreSQL not accessible\",\"timestamp\":\"$(date -Iseconds)\",\"node_ip\":\"$(hostname -I | awk '{print $1}')\"}"
    status_line="HTTP/1.1 503 Service Unavailable"
  fi
  content_length=${#response}
  printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s" "$status_line" "$content_length" "$response" | nc -l -s 0.0.0.0 -p 8001 -q 1 2>/dev/null || sleep 1
done
EOF

chmod +x /tmp/pg_health_8001.sh
nohup /tmp/pg_health_8001.sh >/dev/null 2>&1 &

# Create PgBouncer health script
cat > /tmp/pgbouncer_health_8002.sh << 'EOF'
#!/bin/bash
while true; do
  if pgrep -f pgbouncer >/dev/null 2>&1 && timeout 3 bash -c "</dev/tcp/localhost/6432" 2>/dev/null; then
    response="{\"service\":\"pgbouncer\",\"status\":\"healthy\",\"message\":\"PgBouncer operational\",\"timestamp\":\"$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"$(hostname -I | awk '{print $1}')\"}"
    status_line="HTTP/1.1 200 OK"
  else
    response="{\"service\":\"pgbouncer\",\"status\":\"unhealthy\",\"message\":\"PgBouncer not accessible\",\"timestamp\":\"$(date -Iseconds)\",\"port\":6432,\"node_ip\":\"$(hostname -I | awk '{print $1}')\"}"
    status_line="HTTP/1.1 503 Service Unavailable"
  fi
  content_length=${#response}
  printf "%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s" "$status_line" "$content_length" "$response" | nc -l -s 0.0.0.0 -p 8002 -q 1 2>/dev/null || sleep 1
done
EOF

chmod +x /tmp/pgbouncer_health_8002.sh
nohup /tmp/pgbouncer_health_8002.sh >/dev/null 2>&1 &

sleep 5

echo "✅ Health endpoints started!"
echo "Testing endpoints..."

# Test local endpoints
for port in 8001 8002; do
  if timeout 10 curl -s "http://localhost:$port" >/dev/null 2>&1; then
    echo "✅ Port $port: WORKING"
  else
    echo "❌ Port $port: FAILED"
  fi
done

echo "🎯 Run this script on BOTH nodes, then test with: sudo ./test_health_checks_v1.1.sh"