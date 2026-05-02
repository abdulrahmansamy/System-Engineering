#!/bin/bash
# Enhanced Health Check Test Script v1.3
# Tests all health endpoints with better analysis

TIMEOUT=10
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔍 Enhanced Health Check Test v1.3${NC}"
echo "======================================"
echo

touch healthcheck_failures.log
> healthcheck_failures.log  # Clear previous log

# List of endpoints with expected results
declare -A endpoints=(
  ["http://192.168.14.21:8001"]="PostgreSQL Primary"
  ["http://192.168.14.22:8001"]="PostgreSQL Standby"
  ["http://192.168.14.21:8002"]="PgBouncer Primary"  
  ["http://192.168.14.22:8002"]="PgBouncer Standby"
  ["http://localhost:8001"]="Local PostgreSQL"
  ["http://localhost:8002"]="Local PgBouncer"
)

total=${#endpoints[@]}
working=0

# Test direct health scripts first
echo -e "${YELLOW}📋 Testing direct health scripts first:${NC}"
echo "Primary PostgreSQL health script:"
if /usr/local/bin/pg-health-checker.sh 2>/dev/null | tail -1 | jq . >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Primary PostgreSQL health script works${NC}"
    /usr/local/bin/pg-health-checker.sh 2>/dev/null | tail -1 | jq . 2>/dev/null
else
    echo -e "${RED}❌ PostgreSQL health script not found or failing${NC}"
fi

echo "PgBouncer health script:"
if /usr/local/bin/pgbouncer-health-checker.sh 2>/dev/null | tail -1 | jq . >/dev/null 2>&1; then
    echo -e "${GREEN}✅ PgBouncer health script works${NC}"
    /usr/local/bin/pgbouncer-health-checker.sh 2>/dev/null | tail -1 | jq . 2>/dev/null
else
    echo -e "${RED}❌ PgBouncer health script not found or failing${NC}"
fi

echo
echo -e "${YELLOW}🌐 Testing HTTP endpoints:${NC}"

# Healthcheck loop with timeout and timing
for url in "${!endpoints[@]}"; do
  description="${endpoints[$url]}"
  echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] Checking $description ($url)...${NC}"
  
  start=$(date +%s%3N)  # Start time in milliseconds
  response=$(curl --max-time $TIMEOUT -s -w "%{http_code}" -o temp_response.json "$url")
  end=$(date +%s%3N)    # End time in milliseconds
  duration=$((end - start))

  echo "⏱️ Response time: ${duration} ms"

  if [[ -n "$response" ]] && [[ "$response" =~ ^[0-9]+$ ]] && [ "$response" -ge 200 ] && [ "$response" -lt 400 ] && jq . temp_response.json >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Valid response received from $url${NC}"
    jq . temp_response.json
    ((working++))
  else
    echo -e "${RED}❌ No valid response from $url (HTTP $response or invalid JSON)${NC}"
    echo "$url failed at $(date) with HTTP $response and response time: ${duration} ms" >> healthcheck_failures.log
    if [[ -f temp_response.json ]]; then
      cat temp_response.json | jq . >> healthcheck_failures.log 2>/dev/null || echo "Invalid JSON response" >> healthcheck_failures.log
    else
      echo "No response file created" >> healthcheck_failures.log
    fi
  fi

  echo "-----------------------------"
  rm -f temp_response.json
done

# Summary
echo -e "${YELLOW}========== Summary ==========${NC}"
echo -e "✅ Working endpoints: ${GREEN}${working}/${total}${NC}"
echo -e "❌ Failed endpoints: ${RED}$((total - working))/${total}${NC}"
echo -e "${YELLOW}=============================${NC}"

# Show failure log
echo -e "${YELLOW}Healthcheck Failures Log:${NC}"
cat healthcheck_failures.log

# Final cleanup
rm -fv temp_response.json
