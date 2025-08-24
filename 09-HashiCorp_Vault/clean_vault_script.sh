#!/bin/bash
set -euo pipefail

# Helpers (colored)
# Color codes
RED='\033[0;31m'       # Errors
GREEN='\033[0;32m'     # Success
YELLOW='\033[1;33m'    # Warnings
BLUE='\033[0;34m'      # Info
CYAN='\033[0;36m'      # Questions
MAGENTA='\033[0;35m'   # Debug
WHITE='\033[1;37m'     # Trace
GRAY='\033[0;37m'      # Silent
NC='\033[0m'           # No Color
# Timestamp
ts() { date '+%Y-%m-%d %H:%M:%S'; }

log(){ printf "%b\n" "${GREEN}[$(ts)] [+]${NC} $*"; }           # Success or progress
warn(){ printf "%b\n" "${YELLOW}[$(ts)] [!]${NC} $*" >&2; }     # Warning
die(){ printf "%b\n" "${RED}[$(ts)] [x]${NC} $*" >&2; exit 1; } # Fatal error
info(){ printf "%b\n" "${BLUE}[$(ts)] [i]${NC} $*"; }           # Informational hint
ask(){ printf "%b\n" "${CYAN}[$(ts)] [?]${NC} $*"; }            # Prompting a question
debug(){ printf "%b\n" "${MAGENTA}[$(ts)] [*]${NC} $*"; }       # Internal debug trace
trace(){ printf "%b\n" "${WHITE}[$(ts)] [>]${NC} $*"; }         # Step-by-step execution
silent(){ printf "%b\n" "${GRAY}[$(ts)] [-]${NC} $*"; }         # Low-priority or suppressed

VAULT_DIR="${VAULT_DIR:-$HOME/vault-server}"
VAULT_CONTAINER_NAME="${VAULT_CONTAINER_NAME:-vault}"
VAULT_IMAGE="${VAULT_IMAGE:-docker.io/hashicorp/vault:latest}"
TRUSTED_CERT="/etc/pki/ca-trust/source/anchors/vault-local.crt"
CLEAN_CLI="${CLEAN_CLI:-0}"
FORCE=0

usage(){
  cat <<USAGE
Usage: $0 [-f]
  -f    force (no prompts), delete all matching resources without confirmation
Env vars:
  VAULT_DIR (default: \$HOME/vault-server)
  CLEAN_IMAGE=1   also remove vault image
  CLEAN_CLI=1     also remove Vault CLI binary (/usr/local/bin/vault if present)
USAGE
}

while getopts ":fh" opt; do
  case "$opt" in
    f) FORCE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done || true

command -v podman >/dev/null 2>&1 || die "podman not found"

# Remove container if exists
if podman ps -a --format '{{.Names}}' | grep -qx "$VAULT_CONTAINER_NAME"; then
  log "Removing container: $VAULT_CONTAINER_NAME"
  podman rm -f "$VAULT_CONTAINER_NAME" >/dev/null || warn "Failed to remove container"
else
  log "Container $VAULT_CONTAINER_NAME not present"
fi

# Optionally remove image
if [ "${CLEAN_IMAGE:-0}" = "1" ]; then
  if podman image exists "$VAULT_IMAGE"; then
    log "Removing image $VAULT_IMAGE"
    podman rmi -f "$VAULT_IMAGE" >/dev/null || warn "Failed removing image"
  else
    log "Image $VAULT_IMAGE not present"
  fi
fi

# Optionally remove Vault CLI
if [ "${CLEAN_CLI}" = "1" ] || [ "$FORCE" -eq 1 ]; then
  log "Removing Vault CLI if present"
  if command -v vault >/dev/null 2>&1; then
    CLI_PATH="$(command -v vault)"
    if [ "$CLI_PATH" = "/usr/local/bin/vault" ]; then
      log "Removing Vault CLI at $CLI_PATH"
      sudo rm -f "$CLI_PATH" || warn "Failed to remove Vault CLI"
    else
      warn "Vault CLI located at $CLI_PATH (not /usr/local/bin/vault); skipping removal"
    fi
  else
    log "Vault CLI not found; nothing to remove"
  fi
else
  # Interactive removal
  if command -v vault >/dev/null 2>&1; then
    CLI_PATH="$(command -v vault)"
    if [ "$CLI_PATH" = "/usr/local/bin/vault" ]; then
      ask "Vault CLI found at $CLI_PATH. Remove it? [y/N]: "
      read -r ans_cli
      if [[ "$ans_cli" =~ ^[Yy]$ ]]; then
        log "Removing Vault CLI at $CLI_PATH"
        sudo rm -f "$CLI_PATH" || warn "Failed to remove Vault CLI"
      else
        log "Skipping Vault CLI removal"
      fi
    else
      warn "Vault CLI located at $CLI_PATH (not /usr/local/bin/vault); skipping removal"
    fi
  else
    log "Vault CLI not found; nothing to remove"
  fi
fi

# Remove only volumes that are dangling & (force) confirm before removing all
DANGLING_VOLUMES=$(podman volume ls -q --filter dangling=true || true)
if [ -n "$DANGLING_VOLUMES" ]; then
  if [ "$FORCE" -eq 1 ]; then
    log "Removing dangling podman volumes"
    echo "$DANGLING_VOLUMES" | xargs -r podman volume rm >/dev/null || warn "Volume removal issues"
  else
    warn "Dangling volumes detected:"
    echo "$DANGLING_VOLUMES"
    ask "Remove ALL listed volumes? [y/N]: "
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      log "Removing dangling volumes"
      echo "$DANGLING_VOLUMES" | xargs -r podman volume rm >/dev/null || warn "Volume removal issues"
    else
      log "Skipping volume removal"
    fi
  fi
else
  log "No dangling podman volumes to remove"
fi

# Remove trusted cert if present
if [ -f "$TRUSTED_CERT" ]; then
  log "Removing trusted cert $TRUSTED_CERT"
  sudo rm -f "$TRUSTED_CERT"
  if command -v update-ca-trust >/dev/null 2>&1; then
    sudo update-ca-trust >/dev/null 2>&1 || warn "update-ca-trust failed"
  fi
else
  log "Trusted cert not present"
fi

# Remove Vault data/config directory (with sudo fallback if some files root-owned)
remove_vault_dir() {
  local dir="$1"
  log "Removing directory $dir"
  if rm -rf "$dir" 2>/dev/null; then
    log "Removed $dir"
    return 0
  fi
  warn "Standard removal failed (likely permissions). Attempting sudo..."
  if command -v sudo >/dev/null 2>&1; then
    if sudo rm -rf "$dir"; then
      log "Removed $dir with sudo"
    else
      warn "sudo removal failed for $dir"
    fi
  else
    warn "sudo not available; cannot escalate to remove $dir"
  fi
}

# Remove Vault data/config directory
if [ -d "$VAULT_DIR" ]; then
  if [ "$FORCE" -eq 1 ]; then
    remove_vault_dir "$VAULT_DIR"
  else
    ask "VAULT_DIR found at $VAULT_DIR. Delete it? [y/N]: "
    read -r ans2
    if [[ "$ans2" =~ ^[Yy]$ ]]; then
      remove_vault_dir "$VAULT_DIR"
    else
      log "Skipping directory removal"
    fi
  fi
else
  log "VAULT_DIR $VAULT_DIR not found"
fi

# Remove firewall rules (8200 / 8201) if present
if command -v firewall-cmd >/dev/null 2>&1; then
  if sudo firewall-cmd --state >/dev/null 2>&1; then
    for p in 8200 8201; do
      if sudo firewall-cmd --query-port=${p}/tcp >/dev/null 2>&1; then
        log "Removing firewalld port ${p}/tcp"
        sudo firewall-cmd --remove-port=${p}/tcp --permanent >/dev/null 2>&1 || warn "Failed removing port ${p}"
        NEED_FW_RELOAD=1
      else
        log "Port ${p}/tcp not set in firewalld"
      fi
    done
    if [ "${NEED_FW_RELOAD:-0}" = "1" ]; then
      log "Reloading firewalld"
      sudo firewall-cmd --reload >/dev/null 2>&1 || warn "firewalld reload failed"
    fi
  else
    warn "firewalld not running; skipping firewall cleanup"
  fi
else
  log "firewall-cmd not found; skipping firewall cleanup"
fi

log "Cleanup complete."