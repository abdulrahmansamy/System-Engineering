#!/usr/bin/env bash
# Docker installation/uninstallation script for Fedora (v1.4)
# Supports Fedora < 39 (dnf4) and Fedora 39+ (dnf5)
set -euo pipefail

# ─── Timestamp ────────────────────────────────────────────────────────────────
LOG_TS() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ─── Color Codes ───────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

# ─── Unified Logging Function ─────────────────────────────────────────────────
log() {
    local level="$1"
    shift
    local msg="$*"

    case "$level" in
        info)    echo -e "${BLUE}[$(LOG_TS)] [i]${NC} ${msg}" ;;
        success) echo -e "${GREEN}[$(LOG_TS)] [+]${NC} ${msg}" ;;
        warn)    echo -e "${YELLOW}[$(LOG_TS)] [!]${NC} ${msg}" >&2 ;;
        error)   echo -e "${RED}[$(LOG_TS)] [x]${NC} ${msg}" >&2 ;;
        debug)   echo -e "${MAGENTA}[$(LOG_TS)] [*]${NC} ${msg}" ;;
        trace)   echo -e "${WHITE}[$(LOG_TS)] [>]${NC} ${msg}" ;;
        silent)  echo -e "${GRAY}[$(LOG_TS)] [-]${NC} ${msg}" ;;
        *)       echo -e "${RED}[$(LOG_TS)] [x] Unknown log level: ${level}${NC}" >&2 ;;
    esac
}

# ─── JSON Logging (Optional) ──────────────────────────────────────────────────
log_json() {
  local level="$1"; shift
  local msg="$1"; shift || true
  local kv_pairs=("$@")

  printf '{"ts":"%s","level":"%s","msg":"%s"' "$(LOG_TS)" "$level" "$msg"
  for kv in "${kv_pairs[@]}"; do
    local key="${kv%%=*}"
    local val="${kv#*=}"
    printf ',"%s":"%s"' "$key" "$val"
  done
  printf '}\n'
}

# ─── Fatal Exit Helper ────────────────────────────────────────────────────────
fail() {
  log "error" "$*"
  exit 1
}

# ─── Globals ──────────────────────────────────────────────────────────────────
FEDORA_VERSION=0
PURGE=0          # set to 1 via --purge to also remove volumes/data dirs
ADD_USER=""      # set via --add-user <username> to add a user to the docker group

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Commands:
  install              Install Docker Engine (default if no command given)
  uninstall            Stop, disable, and remove Docker Engine

Options:
  --add-user <user>    Add <user> to the docker group after install
  --purge              (uninstall only) Also remove /var/lib/docker and /var/lib/containerd
  -h, --help           Show this help message

Examples:
  sudo ./$(basename "$0") install
  sudo ./$(basename "$0") install --add-user alice
  sudo ./$(basename "$0") uninstall
  sudo ./$(basename "$0") uninstall --purge
EOF
  exit 0
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────
COMMAND="install"

parse_args() {
  if [[ $# -eq 0 ]]; then
    return
  fi

  case "$1" in
    install|uninstall)
      COMMAND="$1"
      shift
      ;;
    -h|--help)
      usage
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --add-user)
        [[ -n "${2:-}" ]] || fail "--add-user requires a username argument."
        ADD_USER="$2"
        shift 2
        ;;
      --purge)
        PURGE=1
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        fail "Unknown option: $1. Run with --help for usage."
        ;;
    esac
  done
}

# ─── Root check ───────────────────────────────────────────────────────────────
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "Script must be run as root (use sudo)."
  fi
  log "info" "Running as root validated."
}

# ─── OS Validation ────────────────────────────────────────────────────────────
validate_fedora() {
  if [[ ! -f /etc/os-release ]]; then
    fail "/etc/os-release not found; cannot validate OS."
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" != "fedora" ]]; then
    fail "Unsupported OS. This script is intended for Fedora only."
  fi

  if [[ -z "${VERSION_ID:-}" ]]; then
    fail "Fedora VERSION_ID not found."
  fi

  FEDORA_VERSION="${VERSION_ID}"
  log "info" "Fedora OS validated." "id=${ID}" "version_id=${FEDORA_VERSION}"
}

# ─── DNF wrapper — uses dnf5 on Fedora 39+, dnf on older releases ─────────────
run_dnf() {
  local action="$1"; shift
  local pkgs=("$@")
  local dnf_cmd

  if [[ "${FEDORA_VERSION}" -ge 39 ]] && command -v dnf5 >/dev/null 2>&1; then
    dnf_cmd="dnf5"
  else
    dnf_cmd="dnf"
  fi

  log "info" "Running ${dnf_cmd}." "action=${action}" "packages=${pkgs[*]}"

  if ! "${dnf_cmd}" -y "$action" "${pkgs[@]}"; then
    fail "${dnf_cmd} ${action} failed."
  fi

  log "info" "${dnf_cmd} action validated." "action=${action}"
}

# ─── Prerequisites ────────────────────────────────────────────────────────────
setup_prereqs() {
  log "info" "Installing prerequisites (curl)."
  run_dnf install curl
}

# ─── Repo Configuration ───────────────────────────────────────────────────────
configure_docker_repo() {
  local repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
  local repo_file="/etc/yum.repos.d/docker-ce.repo"

  log "info" "Configuring Docker CE repository." "fedora_version=${FEDORA_VERSION}"

  if [[ -s "${repo_file}" ]]; then
    log "warn" "Docker CE repo file already exists; skipping download." "repo_file=${repo_file}"
  else
    log "info" "Downloading Docker CE repo file." "url=${repo_url}"
    if ! curl -fsSL "${repo_url}" -o "${repo_file}"; then
      fail "Failed to download Docker CE repo file from ${repo_url}"
    fi
  fi

  if [[ ! -s "${repo_file}" ]]; then
    fail "Docker CE repo file missing or empty after configuration: ${repo_file}"
  fi

  log "info" "Docker CE repository configuration validated." "repo_file=${repo_file}"
}

# ─── Docker Engine Install ────────────────────────────────────────────────────
install_docker() {
  log "info" "Installing Docker Engine packages."

  run_dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  local bins=(docker containerd)
  local missing=0

  for b in "${bins[@]}"; do
    if ! command -v "$b" >/dev/null 2>&1; then
      log "error" "Binary missing after installation." "binary=${b}"
      missing=1
    fi
  done

  [[ $missing -eq 0 ]] || fail "One or more Docker-related binaries are missing after installation."

  log "info" "Docker Engine installation validated."
}

# ─── Service Management ───────────────────────────────────────────────────────
enable_and_start_service() {
  log "info" "Enabling and starting docker.service."

  systemctl enable docker >/dev/null 2>&1 || fail "Failed to enable docker.service."
  systemctl start  docker >/dev/null 2>&1 || fail "Failed to start docker.service."

  if ! systemctl is-active --quiet docker; then
    fail "docker.service is not active after start."
  fi

  log "info" "docker.service enable/start validated."
}

# ─── Optional: add user to docker group ───────────────────────────────────────
add_user_to_docker_group() {
  if [[ -z "${ADD_USER}" ]]; then
    return
  fi

  if ! id "${ADD_USER}" >/dev/null 2>&1; then
    fail "User '${ADD_USER}' does not exist on this system."
  fi

  # Ensure the docker group exists (may be absent on minimal installs)
  if ! getent group docker >/dev/null 2>&1; then
    log "info" "docker group not found; creating it."
    groupadd docker || fail "Failed to create docker group."
    log "info" "docker group created."
  fi

  # Warn if the user is already a member — nothing to do
  if id -nG "${ADD_USER}" | grep -qw "docker"; then
    log "warn" "User '${ADD_USER}' is already in the docker group; skipping." "user=${ADD_USER}"
    return
  fi

  log "info" "Adding user to docker group." "user=${ADD_USER}"

  if ! usermod -aG docker "${ADD_USER}"; then
    fail "Failed to add user '${ADD_USER}' to docker group."
  fi

  log "success" "User '${ADD_USER}' added to docker group. Re-login required to apply."
}

# ─── Validation ───────────────────────────────────────────────────────────────
validate_docker_cli() {
  log "info" "Validating docker CLI."

  if ! docker --version >/dev/null 2>&1; then
    fail "docker CLI not responding correctly."
  fi

  log "info" "docker CLI validation passed."
}

validate_docker_engine() {
  log "info" "Validating Docker Engine with test container."

  if ! docker run --rm hello-world >/dev/null 2>&1; then
    fail "Failed to run hello-world container; Docker Engine validation failed."
  fi

  log "info" "Docker Engine runtime validation passed." "test_container=hello-world"
}

# ─── Uninstall ────────────────────────────────────────────────────────────────
uninstall_docker() {
  local repo_file="/etc/yum.repos.d/docker-ce.repo"
  local docker_pkgs=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
    docker-ce-rootless-extras
  )

  log "info" "Starting Docker uninstallation." "purge=${PURGE}"

  # Stop and disable service if running
  if systemctl is-active --quiet docker 2>/dev/null; then
    log "info" "Stopping docker.service."
    systemctl stop docker >/dev/null 2>&1 || log "warn" "Could not stop docker.service (may already be stopped)."
  fi

  if systemctl is-enabled --quiet docker 2>/dev/null; then
    log "info" "Disabling docker.service."
    systemctl disable docker >/dev/null 2>&1 || log "warn" "Could not disable docker.service."
  fi

  # Remove packages (ignore errors if packages are not installed)
  log "info" "Removing Docker packages."
  local dnf_cmd
  if [[ "${FEDORA_VERSION}" -ge 39 ]] && command -v dnf5 >/dev/null 2>&1; then
    dnf_cmd="dnf5"
  else
    dnf_cmd="dnf"
  fi

  "${dnf_cmd}" -y remove "${docker_pkgs[@]}" 2>/dev/null \
    && log "info" "Docker packages removed." \
    || log "warn" "Some packages were not found (may not have been installed)."

  # Remove repo file
  if [[ -f "${repo_file}" ]]; then
    rm -f "${repo_file}"
    log "info" "Docker CE repo file removed." "repo_file=${repo_file}"
  else
    log "warn" "Docker CE repo file not found; skipping." "repo_file=${repo_file}"
  fi

  # Reload systemd unit files
  systemctl daemon-reexec >/dev/null 2>&1 || true
  systemctl daemon-reload  >/dev/null 2>&1 || true

  # Purge data directories if requested
  if [[ "${PURGE}" -eq 1 ]]; then
    log "warn" "Purging Docker data directories (/var/lib/docker, /var/lib/containerd)."
    rm -rf /var/lib/docker /var/lib/containerd
    log "info" "Docker data directories purged."
  else
    log "silent" "Data directories /var/lib/docker and /var/lib/containerd were NOT removed."
    log "silent" "Run with --purge to also remove them."
  fi

  log "success" "Docker uninstallation completed." "purge=${PURGE}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  log "info" "Docker script started." "version=1.4" "command=${COMMAND}"

  require_root
  validate_fedora

  case "${COMMAND}" in
    install)
      setup_prereqs
      configure_docker_repo
      install_docker
      enable_and_start_service
      add_user_to_docker_group
      validate_docker_cli
      validate_docker_engine
      log "success" "Docker installation completed and fully validated." \
        "status=ok" "fedora_version=${FEDORA_VERSION}"
      ;;
    uninstall)
      uninstall_docker
      ;;
  esac
}

main "$@"
