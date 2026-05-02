#!/bin/bash

TIMEOUT=10
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# List of endpoints
endpoints=(
  "http://192.168.14.21:8001"
  "http://192.168.14.22:8001"
  "http://192.168.14.21:8002"
  "http://192.168.14.22:8002"
  "http://localhost:8001"
  "http://localhost:8002"
)

# Healthcheck loop with timeout and timing
for url in "${endpoints[@]}"; do
  touch healthcheck_failures.log
  echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] Checking $url ...${NC}"
  
  start=$(date +%s%3N)  # Start time in milliseconds
  response=$(curl --max-time $TIMEOUT -s -w "%{http_code}" -o temp_response.json "$url")
  end=$(date +%s%3N)    # End time in milliseconds
  duration=$((end - start))

  echo "⏱️ Response time: ${duration} ms"

  if [ "$response" -ge 200 ] && [ "$response" -lt 400 ] && jq . temp_response.json >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Valid response received from $url${NC}"
    jq . temp_response.json
  else
    echo -e "${RED}❌ No valid response from $url (HTTP $response or invalid JSON)${NC}"
    echo "$url failed at $(date) with HTTP $response and response time: ${duration} ms" >> healthcheck_failures.log
    cat temp_response.json | jq . >> healthcheck_failures.log
  fi

  echo "-----------------------------"
  rm -f temp_response.json
done

cat healthcheck_failures.log

# Cleanup
rm -fv temp_response.json
