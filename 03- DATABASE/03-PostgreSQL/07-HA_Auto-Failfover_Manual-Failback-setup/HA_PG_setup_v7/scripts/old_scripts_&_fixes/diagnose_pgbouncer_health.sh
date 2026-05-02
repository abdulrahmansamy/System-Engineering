#!/bin/bash
# PgBouncer Health Diagnostic Script
# Diagnoses why port 8002 is timing out

set -euo pipefail

info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"; }

echo "==============================================="
echo "PgBouncer Health Endpoint Diagnostic Report"
echo "==============================================="
echo ""

# Check what's running on port 8002
info "Checking what's listening on port 8002..."
if ss -tuln | grep ":8002"; then
    echo "✓ Something is listening on port 8002"
else
    error "✗ Nothing is listening on port 8002"
fi

# Check processes using port 8002
info "Checking processes using port 8002..."
if lsof -i :8002 2>/dev/null; then
    echo "✓ Found processes using port 8002"
else
    error "✗ No processes found using port 8002"
fi

# Check systemd services related to health endpoints
info "Checking systemd services..."
for service in pgbouncer-ha-health pgbouncer-health-simple postgresql-ha-health; do
    if systemctl list-units --all | grep -q "$service"; then
        status=$(systemctl is-active "$service" 2>/dev/null || echo "not-found")
        if [[ "$status" == "active" ]]; then
            echo "✓ $service: $status"
        else
            error "✗ $service: $status"
        fi
    else
        warn "- $service: not installed"
    fi
done

# Check if PgBouncer itself is running
info "Checking PgBouncer service..."
if systemctl is-active --quiet pgbouncer; then
    echo "✓ PgBouncer service is active"
    
    # Check if PgBouncer is listening on 6432
    if ss -tuln | grep -q ":6432"; then
        echo "✓ PgBouncer is listening on port 6432"
    else
        error "✗ PgBouncer is not listening on port 6432"
    fi
else
    error "✗ PgBouncer service is not active"
fi

# Check recent logs for health services
info "Checking recent logs for health services..."
echo ""
echo "--- PgBouncer Health Service Logs (last 10 lines) ---"
journalctl -u pgbouncer-ha-health -n 10 --no-pager 2>/dev/null || echo "No logs found for pgbouncer-ha-health"

echo ""
echo "--- PgBouncer Service Logs (last 5 lines) ---"
journalctl -u pgbouncer -n 5 --no-pager 2>/dev/null || echo "No logs found for pgbouncer"

# Test local connectivity
info "Testing local connectivity..."
echo ""

# Test port 8002 with timeout
echo "Testing port 8002 connectivity (5 second timeout)..."
if timeout 5 bash -c '</dev/tcp/localhost/8002' 2>/dev/null; then
    echo "✓ Port 8002 is reachable via TCP"
else
    error "✗ Port 8002 is not reachable via TCP (timeout/refused)"
fi

# Test with curl
echo "Testing HTTP response on port 8002..."
if response=$(timeout 10 curl -s "http://localhost:8002" 2>/dev/null); then
    if [[ -n "$response" ]]; then
        echo "✓ Got HTTP response from port 8002"
        if echo "$response" | jq . >/dev/null 2>&1; then
            echo "✓ Response is valid JSON"
            echo "Response: $response"
        else
            warn "Response is not valid JSON: $response"
        fi
    else
        warn "Got empty response from port 8002"
    fi
else
    error "✗ No HTTP response from port 8002 (timeout/error)"
fi

# Check firewall/iptables
info "Checking firewall rules..."
echo ""
if command -v iptables >/dev/null 2>&1; then
    echo "Current iptables rules for port 8002:"
    iptables -L -n | grep 8002 || echo "No specific rules found for port 8002"
else
    echo "iptables not available"
fi

# Check if there are any blocking processes
info "Checking for potential blocking issues..."
echo ""

# Check system load
echo "System load: $(uptime)"

# Check memory usage
echo "Memory usage:"
free -h

# Check for any zombie processes
if ps aux | grep -E "(defunct|<zombie>)" | grep -v grep; then
    warn "Found zombie processes"
else
    echo "✓ No zombie processes found"
fi

echo ""
echo "==============================================="
echo "Diagnostic Summary"
echo "==============================================="

# Quick fix suggestions
echo ""
info "Quick fix suggestions:"
echo "1. Run the PgBouncer health fix script:"
echo "   sudo ./fix_pgbouncer_health_timeout.sh"
echo ""
echo "2. Manual restart of services:"
echo "   sudo systemctl restart pgbouncer"
echo "   sudo systemctl restart pgbouncer-ha-health"
echo ""
echo "3. Check if port is blocked:"
echo "   sudo netstat -tuln | grep 8002"
echo "   sudo ss -tuln | grep 8002"
echo ""
echo "4. Test connectivity:"
echo "   curl -v http://localhost:8002"
echo "   telnet localhost 8002"