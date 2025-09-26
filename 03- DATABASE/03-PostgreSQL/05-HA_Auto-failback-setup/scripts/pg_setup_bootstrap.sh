#!/bin/bash
    set -euo pipefail
    LOG_FILE="/var/log/startup-script.log"
    echo "[$(date --rfc-3339=seconds)] - bootstrap starting" | tee -a "$LOG_FILE"
    apt-get update -y && apt-get install -y curl ca-certificates || true
    TZ_META=$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/timezone || echo "")
    if [ -n "$TZ_META" ]; then
      echo "[$(date --rfc-3339=seconds)] - setting timezone to $TZ_META" | tee -a "$LOG_FILE"
      timedatectl set-timezone "$TZ_META" || true
    fi
    CONFIG_SCRIPT_URL=$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/ha-pg-script-url || echo "")
    if [ -z "$CONFIG_SCRIPT_URL" ]; then
      echo "[$(date --rfc-3339=seconds)] - FATAL: ha-pg-script-url metadata not found" | tee -a "$LOG_FILE"
      exit 1
    fi
    echo "[$(date --rfc-3339=seconds)] - fetching config from $CONFIG_SCRIPT_URL" | tee -a "$LOG_FILE"
    if ! curl -sSL "$CONFIG_SCRIPT_URL" | bash &>> "$LOG_FILE"; then
      echo "[$(date --rfc-3339=seconds)] - FATAL: configuration script failed" | tee -a "$LOG_FILE"
      exit 1
    fi
    echo "[$(date --rfc-3339=seconds)] - bootstrap complete" | tee -a "$LOG_FILE"