#!/bin/bash

TIMEOUT=10
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

touch healthcheck_failures.log
> healthcheck_failures.log  # Clear previous log

# List of endpoints
endpoints=(
  "http://192.168.14.21:8001"
  "http://192.168.14.22:8001"
  "http://192.168.14.21:8002"
  "http://192.168.14.22:8002"
  "http://localhost:8001"
  "http://localhost:8002"
)

total=${#endpoints[@]}
working=0

# Healthcheck loop with timeout and timing
for url in "${endpoints[@]}"; do
  echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] Checking $url ...${NC}"
  
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
