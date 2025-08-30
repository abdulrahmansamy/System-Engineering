#!/usr/bin/env bash
# Spinner library (depends on LOG_LEVEL_NUM)

SPINNER_PID=""
SPINNER_ACTIVE=0

spinner_init() {
  trap 'stop_spinner' EXIT
}

start_spinner() {
  (( LOG_LEVEL_NUM < 2 )) && return 0
  local msg="$1" frames='|/-\' i=0
  SPINNER_ACTIVE=1
  printf "%s " "$msg"
  (
    while (( SPINNER_ACTIVE )); do
      printf "\r%s %s" "$msg" "${frames:i++%${#frames}:1}"
      sleep 0.15
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  (( SPINNER_ACTIVE )) || return 0
  SPINNER_ACTIVE=0
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  printf '\r\033[K'
}
