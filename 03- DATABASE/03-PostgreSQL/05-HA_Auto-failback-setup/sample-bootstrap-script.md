
this sample bootstrap script to run when gce provisioning:

```bash
#!/bin/bash
set -euo pipefail

LOG="/var/log/bootstrap.log"

log() {
  local level="$1"
  local message="$2"
  echo -e "${level} $(date '+%Y-%m-%d %H:%M:%S') - ${message}" | tee -a "$LOG"
}

log "[INFO]" "Installing curl..."
apt-get update && apt-get install -y curl

log "[INFO]" "Fetching HA postgresql installation script URL from metadata..."
BOOTSTRAP_URL=$(curl -fsH 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/ha-pg-script-url || echo "")

if [[ -z "$BOOTSTRAP_URL" ]]; then
  log "[ERROR]" "Failed to retrieve ha-pg-script-url from metadata. Aborting."
  exit 1
fi

log "[INFO]" "Downloading and executing ha-pg-script script from: $BOOTSTRAP_URL"
if curl -fsSL "$BOOTSTRAP_URL" | bash; then
  log "[INFO]" "ha-pg-script script executed successfully."
else
  log "[ERROR]" "ha-pg-script script execution failed. Check logs for details."
  exit 1
fi
```

add this reference via metadata:

```hcl
metadata = {
  ha-pg-script-url = "https://raw.githubusercontent.com/abdulrahmansamy/System-Engineering/master/bootstrap_postgresql_ha.sh"
}
```