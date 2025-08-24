#!/bin/bash
# Secure, idempotent Vault installer using Podman (rootless-aware, TLS-enabled)

set -euo pipefail

# -------- Configuration --------
VAULT_VERSION="${VAULT_VERSION:-latest}"
# Tunables
VAULT_API_ADDR="${VAULT_API_ADDR:-https://127.0.0.1:8200}"
VAULT_LISTEN_ADDR="${VAULT_LISTEN_ADDR:-0.0.0.0}"
VAULT_PORT="${VAULT_PORT:-8200}"
VAULT_CLUSTER_PORT="${VAULT_CLUSTER_PORT:-8201}"
HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
HEALTH_SLEEP="${HEALTH_SLEEP:-1}"
VAULT_START_TIMEOUT="${VAULT_START_TIMEOUT:-90}"
# Add runtime UID & permissive flag
VAULT_RUN_UID="${VAULT_RUN_UID:-100}"        # Default 'vault' user inside official image
PERMISSIVE_STORAGE="${PERMISSIVE_STORAGE:-0}" # Force permissive (1) skips restrictive attempt
FIREWALL_DISABLE="${FIREWALL_DISABLE:-0}"
ALLOW_ROOT="${ALLOW_ROOT:-0}"
BASE_DIR="${HOME}/vault-server"
CERT_DIR="${BASE_DIR}/data/certs"
STORAGE_DIR="${BASE_DIR}/data/storage"
CONFIG_DIR="${BASE_DIR}/config"
VAULT_IMAGE="docker.io/hashicorp/vault:${VAULT_VERSION}"

# Treat variables independently; auto-trust if ANY of TRUST_CERT or TRUST_VAULT_CERT is 1
TRUST_CERT="${TRUST_CERT:-0}"
TRUST_VAULT_CERT="${TRUST_VAULT_CERT:-0}"
# Accept either INSTALL_VAULT_CLI or INSTALL_CLI (alias)
INSTALL_CLI="${INSTALL_VAULT_CLI:-${INSTALL_CLI:-0}}"
CHECK_CONFIG="${CHECK_VAULT_CONFIG:-1}"

# -------- Logging (trim unused levels for production) --------
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

# Logging functions
log()  { echo -e "${GREEN}[$(ts)] [+]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(ts)] [!]${NC} $*" >&2; }
die()  { echo -e "${RED}[$(ts)] [x]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[$(ts)] [i]${NC} $*"; }
ask()  { echo -e "${CYAN}[$(ts)] [?]${NC} $*"; }

# -------- Error Trap --------
trap 'rc=$?; [ $rc -eq 0 ] || warn "Script aborted (rc=$rc) at line $LINENO"; exit $rc' EXIT

# -------- Pre-flight --------
preflight() {
  [ "$ALLOW_ROOT" = "1" ] || { [ "$(id -u)" -ne 0 ] || die "Run rootless or set ALLOW_ROOT=1 to continue as root"; }
  for bin in curl openssl ss; do
    command -v "$bin" >/dev/null 2>&1 || die "Required binary '$bin' not found"
  done
  [[ "$VAULT_API_ADDR" =~ ^https:// ]] || warn "VAULT_API_ADDR does not start with https:// (current: $VAULT_API_ADDR)"
}

# -------- Prerequisites --------
check_rootless() {
  if ! podman info --format '{{.Host.Security.Rootless}}' | grep -q true; then
    warn "Podman is not running in rootless mode. Consider switching for better isolation."
  else
    log "Podman is running in rootless mode."
  fi
}

install_podman() {
  if ! command -v podman &>/dev/null; then
    log "Installing Podman..."
    sudo dnf install -y podman
  else
    log "Podman already installed."
  fi
}

install_vault_cli() {
  # Already installed?
  if command -v vault >/dev/null 2>&1; then
    log "Vault CLI already installed: $(vault version | head -n1)"
    return
  fi

  # Auto-install if INSTALL_CLI=1
  if [[ "${INSTALL_CLI}" == "1" ]]; then
    DO_INSTALL="y"
  fi

  # Prompt only if not auto-install
  if [[ "${DO_INSTALL:-}" != "y" ]]; then
    ask "Vault CLI not found. Install now? [y/N]: "
    read -r DO_INSTALL
  fi

  case "${DO_INSTALL:-N}" in
    [Yy]*)
      # Resolve 'latest' robustly (HashiCorp checkpoint API first, fallback to scrape)
      if [[ "${VAULT_VERSION}" == "latest" ]]; then
        log "Resolving latest Vault version..."
        VAULT_VERSION="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/vault 2>/dev/null \
          | grep -Eo '"current_version":"[0-9]+\.[0-9]+\.[0-9]+"' \
          | head -1 | cut -d\" -f4 || true)"
        if [[ -z "${VAULT_VERSION}" ]]; then
          # Fallback scrape
            VAULT_VERSION="$(curl -fsSL https://releases.hashicorp.com/vault/ 2>/dev/null \
              | grep -Eo 'vault_[0-9]+\.[0-9]+\.[0-9]+' \
              | sed 's/vault_//' | head -1 || true)"
        fi
        [[ -n "${VAULT_VERSION}" ]] || die "Failed to resolve latest Vault version"
        log "Latest Vault version resolved to ${VAULT_VERSION}"
      fi

      local OS ARCH TMP_ZIP
      OS=$(uname | tr '[:upper:]' '[:lower:]')
      ARCH=$(case "$(uname -m)" in x86_64) echo "amd64";; aarch64|arm64) echo "arm64";; *) die "Unsupported arch";; esac)
      TMP_ZIP="/tmp/vault_${VAULT_VERSION}_${OS}_${ARCH}.zip"

      log "Installing Vault CLI version ${VAULT_VERSION}..."
      sudo dnf install -y unzip >/dev/null 2>&1 || true
      curl -fsSL -o "$TMP_ZIP" "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_${OS}_${ARCH}.zip" || die "Download failed"
      sudo unzip -o "$TMP_ZIP" -d /usr/local/bin >/dev/null || die "Unzip failed"
      sudo chmod 0755 /usr/local/bin/vault || warn "chmod failed"
      rm -f "$TMP_ZIP"
      log "Vault CLI installed: $(vault version | head -n1 || true)"
      ;;
    *)
      log "Skipping Vault CLI installation."
      ;;
  esac
}

check_ports() {
  for PORT in "$VAULT_PORT" "$VAULT_CLUSTER_PORT"; do
    if ss -tuln | grep -q ":$PORT "; then
      die "Port $PORT already in use"
    fi
  done
}

# -------- TLS Certificate --------
generate_tls_cert() {
  if [[ -f "${CERT_DIR}/private.key" && -f "${CERT_DIR}/public.crt" ]]; then
    log "TLS certs already exist. Skipping generation."
    return
  fi
  log "Generating self-signed TLS cert..."
  openssl req -new -newkey rsa:2048 -sha256 -days 3650 -nodes -x509 \
    -keyout "${CERT_DIR}/private.key" \
    -out "${CERT_DIR}/public.crt" \
    -subj "/C=SA/ST=Riyadh/L=Riyadh/O=Vault/OU=Prod/CN=localhost" \
    -addext "subjectAltName = DNS:localhost,IP:127.0.0.1" > /dev/null 2>&1 || die "Failed to generate cert"
  # Start with relaxed perms; will be tightened (or kept) in setup_permissions
  chmod 744 "${CERT_DIR}/private.key" 2>/dev/null || true
  chmod 744 "${CERT_DIR}/public.crt"  2>/dev/null || true
}

trust_cert() {
  # Already trusted
  if [[ -f /etc/pki/ca-trust/source/anchors/vault-local.crt ]]; then
    log "Vault certificate already trusted."
    return
  fi

  # Auto-trust if either flag is set
  if [[ "${TRUST_CERT}" == "1" || "${TRUST_VAULT_CERT}" == "1" ]]; then
    log "Trusting Vault certificate system-wide (env flag)."
    sudo cp "${CERT_DIR}/public.crt" /etc/pki/ca-trust/source/anchors/vault-local.crt && sudo update-ca-trust || warn "Failed to trust certificate"
    return
  fi

  # Prompt otherwise
  ask "Trust Vault certificate system-wide now? [y/N]: "
  read -r ans_trust
  if [[ "$ans_trust" =~ ^[Yy]$ ]]; then
    log "Trusting Vault certificate system-wide..."
    sudo cp "${CERT_DIR}/public.crt" /etc/pki/ca-trust/source/anchors/vault-local.crt && sudo update-ca-trust || warn "Failed to trust certificate"
  else
    info "Skipping system trust (export TRUST_CERT=1 for non-interactive)."
  fi
}

# -------- Directories --------
create_directories() {
  mkdir -p "$CERT_DIR" "$STORAGE_DIR" "$CONFIG_DIR"
}

# -------- Permissions --------
setup_permissions() {
  # Goal: give vault (UID inside container) access; prefer restrictive when possible.
  log "Configuring storage & certificate permissions (VAULT_RUN_UID=${VAULT_RUN_UID}, PERMISSIVE_STORAGE=${PERMISSIVE_STORAGE})"
  local restrictive_ok=0

  if [ "$PERMISSIVE_STORAGE" = "0" ]; then
    # Attempt restrictive path
    if chown "${VAULT_RUN_UID}:${VAULT_RUN_UID}" -R "${STORAGE_DIR}" "${CERT_DIR}" 2>/dev/null; then
      chmod 750 "${STORAGE_DIR}" 2>/dev/null || true
      chmod 640 "${CERT_DIR}/"*.key 2>/dev/null || true
      chmod 644 "${CERT_DIR}/"*.crt 2>/dev/null || true
      # Heuristic: ensure directory writable by that UID (rootless user namespace should allow)
      if runuser -u "$(id -un)" -- bash -c "touch '${STORAGE_DIR}/._perm_test' 2>/dev/null"; then
        rm -f "${STORAGE_DIR}/._perm_test" 2>/dev/null || true
        restrictive_ok=1
        log "Applied restrictive permissions (750 storage / 640 key / 644 cert)."
      else
        warn "Restrictive permission test failed; falling back to permissive."
      fi
    else
      warn "Could not chown to UID ${VAULT_RUN_UID}; falling back to permissive."
    fi
  else
    info "Permissive mode requested explicitly."
  fi

  if [ "$restrictive_ok" -ne 1 ]; then
    chmod 777 "${STORAGE_DIR}" 2>/dev/null || true
    chmod 744 "${CERT_DIR}/"*.key 2>/dev/null || true
    chmod 744 "${CERT_DIR}/"*.crt 2>/dev/null || true
    log "Using permissive permissions (777 storage / 744 key+crt)."
  fi
}

# -------- Vault Config --------
create_config() {
  log "Creating Vault config..."
  cat <<EOF > "${CONFIG_DIR}/config.hcl"
ui = true
api_addr = "${VAULT_API_ADDR}"
disable_mlock = true

storage "file" {
  path = "/data/storage"
}

listener "tcp" {
  address         = "${VAULT_LISTEN_ADDR}:${VAULT_PORT}"
  cluster_address = "${VAULT_LISTEN_ADDR}:${VAULT_CLUSTER_PORT}"
  tls_cert_file   = "/data/certs/public.crt"
  tls_key_file    = "/data/certs/private.key"
}
EOF
}

validate_config() {
  if [[ "$CHECK_CONFIG" != "1" ]]; then return; fi
  log "Validating Vault config..."
  if podman run --rm "$VAULT_IMAGE" vault server -h 2>&1 | grep -q -- "-check-config"; then
    podman run --rm \
      -v "${CONFIG_DIR}":/config:Z \
      "$VAULT_IMAGE" vault server -config=/config/config.hcl -check-config \
      && log "Vault config validated." \
      || die "Vault config validation failed."
  else
    warn "Vault image does not support -check-config. Performing basic static checks only."
    [[ -s "${CONFIG_DIR}/config.hcl" ]] || die "Config file empty/missing"
    grep -q 'listener "tcp"' "${CONFIG_DIR}/config.hcl" || die "Missing listener block"
    grep -q 'storage "file"' "${CONFIG_DIR}/config.hcl" || die "Missing storage file block"
    grep -q 'api_addr' "${CONFIG_DIR}/config.hcl" || warn "api_addr not found (may be acceptable)"
    log "Basic config checks passed (no full validation available)."
  fi
}

# -------- Firewall --------
configure_firewall() {
  [ "$FIREWALL_DISABLE" = "1" ] && { info "Firewall configuration disabled (FIREWALL_DISABLE=1)"; return; }
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    info "firewall-cmd not found; skipping firewall rule"
    return
  fi
  if ! sudo firewall-cmd --state >/dev/null 2>&1; then
    info "firewalld not running; skipping firewall rule"
    return
  fi
  for PORT in "$VAULT_PORT" "$VAULT_CLUSTER_PORT"; do
    if sudo firewall-cmd --query-port=${PORT}/tcp >/dev/null 2>&1; then
      log "firewalld already allows ${PORT}/tcp"
    else
      log "Adding firewalld rule for ${PORT}/tcp"
      sudo firewall-cmd --add-port=${PORT}/tcp --permanent
      sudo firewall-cmd --reload
    fi
  done
}

# -------- Container Setup --------
run_vault_container() {
  if podman image exists "$VAULT_IMAGE" &>/dev/null; then
    log "Vault image already present."
  else
    log "Pulling Vault image..."
    podman pull "$VAULT_IMAGE"
  fi

  log "Removing old Vault container (if any)..."
  podman rm -f vault &>/dev/null || true

  log "Starting Vault container..."
  podman run -d --name vault \
    -p "${VAULT_PORT}:${VAULT_PORT}" \
    -p "${VAULT_CLUSTER_PORT}:${VAULT_CLUSTER_PORT}" \
    --cap-add=IPC_LOCK \
    -v "${BASE_DIR}/data":/data:Z \
    -v "${CONFIG_DIR}":/config:Z \
    "$VAULT_IMAGE" server -config=/config/config.hcl
}

wait_for_vault() {
  log "Waiting for Vault to become responsive (timeout=${VAULT_START_TIMEOUT}s)..."
  local start_ts=$(date +%s)
  local attempt=0 http_code="" elapsed=0 sleep_int=$HEALTH_SLEEP
  local acceptable_codes="200 429 472 473 501 503"
  while true; do
    elapsed=$(( $(date +%s) - start_ts ))
    if [ "$elapsed" -ge "$VAULT_START_TIMEOUT" ]; then
      break
    fi
    # Try TCP connect quickly (bash /dev/tcp) to fail fast before curl
    if ( exec 3<>/dev/tcp/127.0.0.1/"$VAULT_PORT" ) 2>/dev/null; then
      # Retrieve HTTP status (no -f so non-200 doesn't fail); short timeout
      http_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 2 "${VAULT_API_ADDR}/v1/sys/health" || true)
      if [[ " $acceptable_codes " == *" $http_code "* ]]; then
        log "Vault reachable (health HTTP $http_code)."
        if [[ "$http_code" == "501" ]]; then info "Vault is uninitialized (HTTP 501). Initialize with: vault operator init"; fi
        if [[ "$http_code" == "503" ]]; then info "Vault is sealed (HTTP 503). Unseal after init."; fi
        return
      fi
      warn "Health endpoint returned unexpected status $http_code (attempt $attempt, elapsed ${elapsed}s)"
    else
      warn "Port ${VAULT_PORT} not open yet (attempt $attempt, elapsed ${elapsed}s)"
    fi
    attempt=$((attempt+1))
    sleep "$sleep_int"
    # Mild backoff after 10s
    if [ "$elapsed" -gt 10 ] && [ "$sleep_int" -lt 3 ]; then sleep_int=$((sleep_int+1)); fi
  done

  warn "Vault did not become responsive within ${VAULT_START_TIMEOUT}s"
  info "Recent container logs:"
  podman logs --tail 60 vault 2>&1 | sed 's/^/  | /'
  die "Startup timeout exceeded"
}

# -------- Diagnostics --------
show_status() {
  sleep 4 
  echo
  # Vault status exit codes:
  # 0=active, 1=standby, 2=sealed, 3=uninitialized, 4+=errors
  STATUS_OUTPUT="$(podman exec vault vault status -address=https://127.0.0.1:8200 -tls-skip-verify 2>&1)" || RC=$?
  RC=${RC:-0}
  if [ "$RC" -le 3 ]; then
    printf '%s\n' "$STATUS_OUTPUT"
    log "Vault status retrieved (rc=$RC)"
  else
    printf '%s\n' "$STATUS_OUTPUT" >&2
    warn "Vault status command failed (rc=$RC) (try: podman exec vault env VAULT_ADDR=https://127.0.0.1:8200 vault status -tls-skip-verify)"
  fi

  echo
  info "Summary:"
  info "  VAULT_ADDR       : ${VAULT_API_ADDR}"
  info "  Data Directory   : ${BASE_DIR}/data"
  info "  Config File      : ${CONFIG_DIR}/config.hcl"
  info "  Image            : ${VAULT_IMAGE}"
  info "  CLI Installed    : $(command -v vault >/dev/null 2>&1 && echo yes || echo no)"
  info "  Cert Trusted     : $( [ -f /etc/pki/ca-trust/source/anchors/vault-local.crt ] && echo yes || echo no )"
  info "  Firewall Managed : $( [ "$FIREWALL_DISABLE" = "1" ] && echo no || echo yes )"

  sleep 2
  podman ps -a --filter "name=vault"
  podman logs vault | head -n 20
}

# -------- Execution --------
main() {
  preflight
  install_podman
  check_rootless
  check_ports
  install_vault_cli
  create_directories
  generate_tls_cert
  trust_cert
  setup_permissions
  create_config
  validate_config
  configure_firewall
  run_vault_container
  wait_for_vault
  show_status
}

main "$@"
# -------- End of Script --------

