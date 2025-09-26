#!/bin/bash
set -euo pipefail

LOG="/var/log/startup-script.log"

timestamp() {
  date --rfc-3339=seconds
}

log() {
  local level="$1"
  local message="$2"
  echo -e "${level} $(timestamp) - ${message}" | tee -a "$LOG"
}

log "[INFO]" "Bootstrap starting"

# Install prerequisites
if apt-get update -y && apt-get install -y curl ca-certificates; then
  log "[INFO]" "System packages installed successfully"
else
  log "[WARN]" "Package installation failed, continuing anyway"
fi

# Set timezone from metadata
TZ_META=$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/timezone || echo "")
if [[ -n "$TZ_META" ]]; then
  log "[INFO]" "Setting timezone to $TZ_META"
  timedatectl set-timezone "$TZ_META" || log "[WARN]" "Failed to set timezone"
fi

# Fetch configuration script URL
CONFIG_SCRIPT_URL=$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/ha-pg-script-url || echo "")
if [[ -z "$CONFIG_SCRIPT_URL" ]]; then
  log "[ERROR]" "ha-pg-script-url metadata not found"
  exit 1
fi

log "[INFO]" "Fetching and executing configuration script from: $CONFIG_SCRIPT_URL"
if curl -fsSL "$CONFIG_SCRIPT_URL" | bash &>> "$LOG"; then
  log "[INFO]" "Configuration script executed successfully"
else
  log "[ERROR]" "Configuration script execution failed"
  exit 1
fi

log "[INFO]" "Bootstrap complete"
