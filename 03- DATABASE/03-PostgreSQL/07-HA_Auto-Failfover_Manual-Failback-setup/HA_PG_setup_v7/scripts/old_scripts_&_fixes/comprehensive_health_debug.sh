#!/bin/bash
# Comprehensive Health Endpoint Debugging Script
# Investigates the exact root cause of PgBouncer health failures

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
debug() { echo -e "${PURPLE}[DEBUG]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "🔍 COMPREHENSIVE HEALTH DEBUGGING"
echo "=================================="
echo "Goal: Find exact root cause of PgBouncer endpoint failures"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

# Get basic info
HOSTNAME=$(hostname)
SELF_IP=$(hostname -I | awk '{print $1}')
OTHER_NODE_IP=""

if [[ "$SELF_IP" == "192.168.14.21" ]]; then
    OTHER_NODE_IP="192.168.14.22"
    NODE_ROLE="primary"
else
    OTHER_NODE_IP="192.168.14.21"
    NODE_ROLE="standby"
fi

info "🖥️ System Information:"
echo "Hostname: $HOSTNAME"
echo "Self IP: $SELF_IP ($NODE_ROLE)"
echo "Other Node IP: $OTHER_NODE_IP"
echo

# === 1. PROCESS INVESTIGATION ===
info "📋 1. PROCESS INVESTIGATION"
echo "============================"

debug "Checking all health-related processes:"
ps aux | grep -E "(health|8001|8002|socat)" | grep -v grep || echo "No health processes found"
echo

debug "Checking processes listening on health ports:"
for port in 8001 8002; do
    echo "Port $port:"
    lsof -i:$port 2>/dev/null || echo "  No processes found"
    echo
done

debug "Checking socket listeners:"
ss -tuln | grep -E ":(8001|8002)" || echo "No health ports listening"
echo

# === 2. HEALTH SCRIPT ANALYSIS ===
info "📋 2. HEALTH SCRIPT ANALYSIS"
echo "============================="

debug "Checking health script files:"
for script in /usr/local/bin/*health*.sh; do
    if [[ -f "$script" ]]; then
        echo "Found: $script"
        echo "  Permissions: $(ls -la "$script" | awk '{print $1, $3, $4}')"
        echo "  Size: $(wc -l < "$script") lines"
    fi
done
echo

debug "Testing health script execution directly:"
echo "PostgreSQL health script test:"
if [[ -f "/usr/local/bin/pg-health-checker.sh" ]]; then
    timeout 5 /usr/local/bin/pg-health-checker.sh | tail -3 || echo "  Script execution failed"
else
    echo "  Script not found"
fi

echo
echo "PgBouncer health script test:"
if [[ -f "/usr/local/bin/pgbouncer-health-checker.sh" ]]; then
    timeout 5 /usr/local/bin/pgbouncer-health-checker.sh | tail -3 || echo "  Script execution failed"
else
    echo "  Script not found"
fi
echo

# === 3. SOCAT PROCESS DEBUGGING ===
info "📋 3. SOCAT PROCESS DEBUGGING"
echo "=============================="

debug "Checking socat processes in detail:"
pgrep -fl socat || echo "No socat processes found"
echo

debug "Checking for zombie or defunct processes:"
ps aux | grep -E "(defunct|zombie)" | grep -v grep || echo "No zombie processes found"
echo

debug "Testing direct socat connectivity:"
for port in 8001 8002; do
    echo "Testing port $port with nc:"
    timeout 2 nc -zv localhost $port 2>&1 || echo "  Port $port not reachable"
done
echo

# === 4. LOG ANALYSIS ===
info "📋 4. LOG ANALYSIS"
echo "==================="

debug "Checking recent health-related logs:"
for log in /var/log/*health*.log; do
    if [[ -f "$log" ]]; then
        echo "Log: $log"
        echo "  Last modified: $(stat -c %y "$log")"
        echo "  Size: $(wc -l < "$log") lines"
        echo "  Last 5 lines:"
        tail -5 "$log" | sed 's/^/    /'
        echo
    fi
done

debug "Checking system logs for health-related errors:"
journalctl --since "5 minutes ago" | grep -i -E "(health|8001|8002|socat|error|failed)" | tail -10 || echo "No recent health-related log entries"
echo

# === 5. NETWORK DEBUGGING ===
info "📋 5. NETWORK DEBUGGING"
echo "======================="

debug "Testing network connectivity:"
echo "Local loopback tests:"
for port in 8001 8002; do
    echo -n "  Port $port: "
    timeout 2 telnet localhost $port 2>/dev/null <<< "GET / HTTP/1.0" && echo "CONNECTED" || echo "FAILED"
done
echo

echo "Self-IP connectivity tests:"
for port in 8001 8002; do
    echo -n "  $SELF_IP:$port: "
    timeout 2 telnet $SELF_IP $port 2>/dev/null <<< "GET / HTTP/1.0" && echo "CONNECTED" || echo "FAILED"
done
echo

echo "Cross-node connectivity tests:"
for port in 8001 8002; do
    echo -n "  $OTHER_NODE_IP:$port: "
    timeout 3 telnet $OTHER_NODE_IP $port 2>/dev/null <<< "GET / HTTP/1.0" && echo "CONNECTED" || echo "TIMEOUT/FAILED"
done
echo

# === 6. DETAILED HTTP DEBUGGING ===
info "📋 6. DETAILED HTTP DEBUGGING"
echo "=============================="

debug "Testing HTTP endpoints with verbose curl:"
test_url_detailed() {
    local url="$1"
    local name="$2"
    
    echo "Testing $name ($url):"
    echo "  Basic connectivity:"
    timeout 5 curl -v --connect-timeout 3 "$url" 2>&1 | head -10 | sed 's/^/    /' || echo "    FAILED"
    echo
}

test_url_detailed "http://localhost:8001" "Local PostgreSQL"
test_url_detailed "http://localhost:8002" "Local PgBouncer"
test_url_detailed "http://$SELF_IP:8001" "Self PostgreSQL"  
test_url_detailed "http://$SELF_IP:8002" "Self PgBouncer"
test_url_detailed "http://$OTHER_NODE_IP:8001" "Other PostgreSQL"
test_url_detailed "http://$OTHER_NODE_IP:8002" "Other PgBouncer"

# === 7. PROCESS RACE CONDITION INVESTIGATION ===
info "📋 7. PROCESS RACE CONDITION INVESTIGATION"
echo "=========================================="

debug "Checking for process conflicts/race conditions:"
echo "Multiple socat processes on same port:"
for port in 8001 8002; do
    count=$(lsof -i:$port 2>/dev/null | wc -l)
    echo "  Port $port: $count processes"
    if [[ $count -gt 1 ]]; then
        warn "    Multiple processes detected on port $port!"
        lsof -i:$port 2>/dev/null | sed 's/^/      /'
    fi
done
echo

debug "Checking process start times:"
ps -eo pid,ppid,lstart,cmd | grep -E "(socat|health)" | grep -v grep | sed 's/^/  /' || echo "No health processes found"
echo

# === 8. RESOURCE INVESTIGATION ===
info "📋 8. RESOURCE INVESTIGATION"
echo "============================"

debug "System resources:"
echo "Load average: $(uptime | awk -F'load average:' '{print $2}')"
echo "Memory usage: $(free -h | grep Mem | awk '{print $3 "/" $2}')"
echo "Disk usage: $(df -h / | tail -1 | awk '{print $5}')"
echo

debug "File descriptor limits:"
echo "Current/Max FDs: $(lsof 2>/dev/null | wc -l)/$(ulimit -n)"
echo

# === 9. EXACT FAILURE REPRODUCTION ===
info "📋 9. EXACT FAILURE REPRODUCTION"
echo "================================="

debug "Reproducing the exact failing curl commands:"

reproduce_failure() {
    local url="$1"
    local name="$2"
    
    echo "Reproducing failure for $name:"
    echo "Command: curl --max-time 10 -s -w \"%{http_code}\" -o temp_response.json \"$url\""
    
    start_time=$(date +%s%3N)
    response=$(curl --max-time 10 -s -w "%{http_code}" -o temp_response.json "$url" 2>/dev/null || echo "000")
    end_time=$(date +%s%3N)
    duration=$((end_time - start_time))
    
    echo "  HTTP Code: $response"
    echo "  Duration: ${duration}ms"
    echo "  Response file exists: $(test -f temp_response.json && echo "YES" || echo "NO")"
    if [[ -f temp_response.json ]]; then
        echo "  Response size: $(wc -c < temp_response.json) bytes"
        echo "  Response content:"
        head -3 temp_response.json | sed 's/^/    /' 2>/dev/null || echo "    (Binary or invalid content)"
    fi
    echo
    rm -f temp_response.json
}

# Reproduce the specific failing endpoints
reproduce_failure "http://localhost:8002" "Local PgBouncer (should work)"
reproduce_failure "http://$OTHER_NODE_IP:8002" "Cross-node PgBouncer (failing)"
reproduce_failure "http://$SELF_IP:8002" "Self-IP PgBouncer (may fail)"

# === 10. SUMMARY AND RECOMMENDATIONS ===
info "📋 10. SUMMARY AND RECOMMENDATIONS"  
echo "=================================="

warn "🔍 INVESTIGATION COMPLETE"
echo
echo "Key findings to analyze:"
echo "1. Process conflicts on ports 8001/8002"
echo "2. Network connectivity between nodes"
echo "3. Socat process health and race conditions"
echo "4. HTTP response timing and connection issues"
echo "5. Resource constraints or file descriptor limits"
echo
echo "Next steps:"
echo "1. Check if multiple processes are competing for the same port"
echo "2. Verify network connectivity and firewall rules"
echo "3. Look for process zombies or defunct socat processes"
echo "4. Check system resource constraints"

success "🎯 Debugging investigation complete! Check the output above for patterns."