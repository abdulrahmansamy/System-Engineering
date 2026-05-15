#!/bin/bash
# -----------------------------------------------------------------------------
# sync_on_change - File and Directory Synchronization Tool
# Copyright (c) 2025 Abdulrahman Samy
#
# Licensed under the MIT License. See LICENSE file for details.
# Repository: https://github.com/abdulrahmansamy/system_engineering
# -----------------------------------------------------------------------------
# Script: sync_on_change_v1.8.3.sh
# Version: 1.8.3
#
# Purpose:
#   Watch a local file or directory for content changes and automatically sync
#   it to a remote host via scp/rsync, then set executable permissions remotely.
#
# How It Works:
#   - Computes a SHA-256 checksum each interval (default: 3s).
#   - On change: scp (file) or rsync/tar+scp (directory) -> remote chmod +x.
#   - Shows an animated progress (dots) while idle.
#   - Tracks consecutive failures and aborts after max_failures (default: 10).
#   - Supports external configuration files and reports the source of each setting.
#   - Supports self-installation, update, and removal via --install/--update/--uninstall.
#
# Usage:
#   ./sync_on_change <file|directory> [-c <config-file>] [-v] [-h]
#   ./sync_on_change --install
#   ./sync_on_change --update
#   ./sync_on_change --uninstall
#   ./sync_on_change --gen-config
#
# Examples:
#   ./sync_on_change scripts/deploy.sh
#   ./sync_on_change scripts/deploy.sh -c /path/custom.conf
#   ./sync_on_change --install
#   ./sync_on_change --gen-config
#
# Configuration Variables (overridable):
#   remote_user, remote_host, remote_path, interval, max_failures
#
# Configuration Precedence (first found wins):
#   1. -c <config-file> (explicit; required to exist)
#   2. $PWD/.sync_on_change.conf
#   3. <script_dir>/sync_on_change.conf
#   4. <watched_file_dir>/sync_on_change.conf
#   5. /etc/sync_on_change/sync_on_change.conf
#
# Notes:
#   - If -c is provided, NO fallback search occurs.
#   - On startup a summary lists each variable and whether it came from defaults
#     or which config file.
#   - Monitors only one file or directory; detects content (hash) changes, not metadata.
#   - For multi-file or bidirectional sync consider rsync or inotify-based tools.
#   - Safe to stop anytime with Ctrl+C.
#
# Changelog (v1.8.3):
#   - Replaced individual logging functions with a unified log() dispatcher
#   - Added: success(), error() levels; log <level> <msg> call style now supported
#   - Thin convenience wrappers (info/warn/die/debug/etc.) preserved for compat
#   - Fixed bare log() calls with no level (ssh_setup, initial_sync, check_deps)
#     that produced blank log lines — replaced with explicit info() calls
#   - Fixed SCRIPT_NAME derivation: now strips _v<version>.sh suffix dynamically
#     instead of a hardcoded string, making it reusable across version bumps
#   - Bumped version to 1.8.3
#
# Changelog (v1.8.2):
#   - Added check_deps(): detects OS package manager and installs missing prerequisites
#   - Added --check-deps flag to verify/install dependencies without starting a sync
#   - Bumped version to 1.8.2
#
# Changelog (v1.8.1):
#   - Fixed SCRIPT_NAME to always install as 'sync_on_change' (strips version suffix)
#   - Extracted print_watch_summary() function
#
# Changelog (v1.8.0):
#   - Clean release combining all fixes from v1.6 → v1.7.x
#   - Fixed ssh_setup: ssh-copy-id and mkdir -p failures now abort the script
#   - Added post-ssh-copy-id re-verification of key auth
#   - Added --gen-config flag: writes .sync_on_change.conf.example to $PWD and exits
#   - Extracted gen_example_config() as standalone reusable function
#   - Removed duplicate "no config" messaging (load_config warn + ensure prompt)
#   - Fixed $'...' quoting in read prompt (no command substitution in ANSI-C strings)
#   - Fixed [[ $? -eq 0 ]] anti-pattern in all _do_install/_do_update/_do_uninstall
#   - Removed unused local _rm_cmd variable in _do_uninstall
#   - Removed all dead commented-out code
#   - Updated Usage/Examples in header to match installed binary name
# -----------------------------------------------------------------------------

# ─── Version ─────────────────────────────────────────────────────────────────
VERSION="1.8.3"

# ─── Color Codes ─────────────────────────────────────────────────────────────
RED='\033[0;31m'       # Errors
GREEN='\033[0;32m'     # Success
YELLOW='\033[1;33m'    # Warnings
BLUE='\033[0;34m'      # Info
CYAN='\033[0;36m'      # Questions
MAGENTA='\033[0;35m'   # Debug
WHITE='\033[1;37m'     # Trace
GRAY='\033[0;37m'      # Silent
NC='\033[0m'           # No Color

# ─── Timestamp ───────────────────────────────────────────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# ─── Logging Functions ───────────────────────────────────────────────────────
# Unified dispatcher — accepts a level name as $1, message as remaining args.
# All convenience wrappers below delegate here for a single formatting path.
log() {
  local level="$1"; shift
  local msg="$*"
  case "$level" in
    success|+) echo -e "${GREEN}[$(ts)] [+]${NC} ${msg}" ;;
    info|i)    echo -e "${BLUE}[$(ts)] [i]${NC} ${msg}" ;;
    warn|!)    echo -e "${YELLOW}[$(ts)] [!]${NC} ${msg}" >&2 ;;
    error|x)   echo -e "${RED}[$(ts)] [x]${NC} ${msg}" >&2 ;;
    die)       echo -e "${RED}[$(ts)] [x]${NC} ${msg}" >&2; exit 1 ;;
    ask|'?')   echo -e "${CYAN}[$(ts)] [?]${NC} ${msg}" ;;
    debug|'*')  [ "$verbose" = true ] && echo -e "${MAGENTA}[$(ts)] [*]${NC} ${msg}" ;;
    trace|'>')  echo -en "\r${WHITE}[$(ts)] [>]${NC} ${msg}" ;;
    silent|-)  echo -e "${GRAY}[$(ts)] [-]${NC} ${msg}" ;;
    *)         echo -e "${NC}[$(ts)]${NC} ${msg}" ;;
  esac
}

# ── Convenience wrappers (preserve all existing call sites unchanged) ─────
success() { log success "$@"; }
info()    { log info    "$@"; }
warn()    { log warn    "$@"; }
error()   { log error   "$@"; }
die()     { log die     "$@"; }
ask()     { log ask     "$@"; }
debug()   { log debug   "$@"; }
trace()   { log trace   "$@"; }
silent()  { log silent  "$@"; }

# ─── Usage / Help ────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 <file|directory> [-c <config-file>] [-v] [-h]
       $0 --install | --update | --uninstall | --gen-config

Sync Modes:
  <file|directory>      Local file or directory to watch & sync on content change.

PATH Management:
  --install             Install this script into /usr/local/bin
  --update              Update the installed copy in /usr/local/bin
  --uninstall           Remove this script from /usr/local/bin

Configuration:
  --gen-config          Generate an example config file in the current directory
                        (writes .sync_on_change.conf.example) and exit
  --check-deps          Check for required tools and offer to install missing ones

Options:
  -c <config-file>      Explicit config file (must exist, disables fallback search)
  -v, --verbose         Enable verbose debug output
  --version             Print version and exit
  -h, --help            Show this help

Configuration Precedence (first found wins):
  1. -c <config-file> (explicit; required to exist)
  2. Current working directory (\$PWD/.sync_on_change.conf)
  3. Script directory ($(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.sync_on_change.conf)
  4. Directory of the watched file
  5. System-wide config (/etc/sync_on_change/sync_on_change.conf)
  6. Script's built-in defaults

Notes:
  - If -c is provided, NO fallback search occurs
  - On startup, a summary lists each variable and its source (default or config file)
  - Monitors content (hash) changes, not metadata
  - Directory sync uses rsync (with tar+scp fallback)
  - Safe to stop anytime with Ctrl+C
EOF
}

# ─── Argument Parsing ────────────────────────────────────────────────────────
parse_args() {
  target=""
  explicit_config=""
  verbose=false
  installer_mode=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --version)
        echo "sync_on_change: v${VERSION}"
        exit 0
        ;;
      --gen-config)
        gen_example_config
        exit 0
        ;;
      --check-deps)
        check_deps
        exit 0
        ;;
      -v|--verbose)
        verbose=true
        shift
        ;;
      -c)
        shift
        [ $# -gt 0 ] || die "-c requires a config file path"
        [ -z "$explicit_config" ] || die "Duplicate -c option"
        explicit_config="$1"
        shift
        ;;
      --install|--update|--uninstall)
        installer_mode="$1"
        shift
        ;;
      -*)
        die "Unknown option: $1 (use -h for help)"
        ;;
      *)
        if [ -z "$target" ]; then
          target="$1"
          shift
        else
          die "Unexpected extra argument: $1 (use -h for help)"
        fi
        ;;
    esac
  done

  # If an installer mode was requested, handle it and exit
  if [ -n "$installer_mode" ]; then
    universal_path_installer "$installer_mode"
    exit $?
  fi

  [ -n "$target" ] || { usage >&2; die "Missing <file|directory>"; }

  # Backward-compatibility alias
  file="$target"
}

# ─── Dependency Check & Install ─────────────────────────────────────────────────
check_deps() {
  local required=(ssh scp ssh-copy-id openssl rsync)
  local missing=()

  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    info "All prerequisites are satisfied."
    return 0
  fi

  warn "Missing prerequisites: ${missing[*]}"

  # Detect package manager
  local pkg_manager=""
  local install_cmd=""
  if command -v brew > /dev/null 2>&1; then
    pkg_manager="brew"
    install_cmd="brew install"
  elif command -v apt-get > /dev/null 2>&1; then
    pkg_manager="apt"
    install_cmd="sudo apt-get install -y"
  elif command -v dnf > /dev/null 2>&1; then
    pkg_manager="dnf"
    install_cmd="sudo dnf install -y"
  elif command -v yum > /dev/null 2>&1; then
    pkg_manager="yum"
    install_cmd="sudo yum install -y"
  elif command -v pacman > /dev/null 2>&1; then
    pkg_manager="pacman"
    install_cmd="sudo pacman -S --noconfirm"
  else
    die "No supported package manager found (brew/apt/dnf/yum/pacman). Install manually: ${missing[*]}"
  fi

  info "Detected package manager: $pkg_manager"

  # Map command names to package names where they differ
  local pkgs=()
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      ssh|scp|ssh-copy-id)
        # Only add openssh-client once
        if [[ ! " ${pkgs[*]} " =~ " openssh " ]] && [[ ! " ${pkgs[*]} " =~ " openssh-client " ]]; then
          case "$pkg_manager" in
            brew)   pkgs+=(openssh) ;;
            apt)    pkgs+=(openssh-client) ;;
            *)      pkgs+=(openssh-clients) ;;
          esac
        fi
        ;;
      openssl) pkgs+=(openssl) ;;
      rsync)   pkgs+=(rsync) ;;
      *)       pkgs+=("$cmd") ;;
    esac
  done

  echo
  local _answer
  read -t 15 -p "[$(ts)] [?] Install missing packages (${pkgs[*]}) using $pkg_manager? (y/N): " _answer
  echo

  if [[ "$_answer" =~ ^[Yy]$ ]]; then
    if $install_cmd "${pkgs[@]}"; then
      log "Prerequisites installed successfully."
    else
      die "Installation failed. Please install manually: ${pkgs[*]}"
    fi
  else
    die "Prerequisites not installed. Aborting. Missing: ${missing[*]}"
  fi
}

# ─── Generate Example Config ─────────────────────────────────────────────────
gen_example_config() {
  local DEST="$PWD/.sync_on_change.conf.example"
  cat > "$DEST" <<'EOF'
# sync_on_change configuration file
# Rename to .sync_on_change.conf and place in your working directory

# --- Remote Connection ---
remote_user="youruser"           # SSH username
remote_host="your.remote.host"  # SSH host or IP
remote_path="~/scripts/"        # Destination path on the remote host

# --- Behaviour ---
interval=3                       # Polling interval in seconds
max_failures=10                  # Abort after this many consecutive sync failures

# --- Advanced (optional) ---
# scp_opts="-C"                  # Extra options passed to scp
# ssh_opts="-o BatchMode=yes"    # Extra options passed to ssh
EOF
  echo -e "${GREEN}✔ Example config written to: ${BLUE}${DEST}${NC}"
  echo -e "  Rename it to ${BLUE}.sync_on_change.conf${NC} and fill in your remote details."
}

# ─── Defaults ────────────────────────────────────────────────────────────────
set_defaults() {
  remote_user="username"
  remote_host="xxx.xxx.xxx.xxx"
  remote_path="~/scripts/"
  interval=3
  max_failures=10
}

# ─── Config Loader ───────────────────────────────────────────────────────────
load_config() {
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  config_loaded=""

  if [ -n "$explicit_config" ]; then
    [ -f "$explicit_config" ] && [ -r "$explicit_config" ] \
      || die "Config file not found or not readable: $explicit_config"
    candidates=("$explicit_config")
  else
    candidates=(
      "$PWD/.sync_on_change.conf"
      "$script_dir/.sync_on_change.conf"
      "$(dirname "$file")/sync_on_change.conf"
      "/etc/sync_on_change/sync_on_change.conf"
    )
  fi

  for cand in "${candidates[@]}"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand" ] && [ -r "$cand" ]; then
      # shellcheck source=/dev/null
      source "$cand"
      config_loaded="$cand"
      break
    fi
  done

  if [ -n "$config_loaded" ]; then
    info "Configuration loaded from: $config_loaded"
  else
    warn "No configuration file found — using built-in defaults."
  fi
}

# ─── Config Validation ───────────────────────────────────────────────────────
validate_config() {
  : "${remote_user:?remote_user not set}"
  : "${remote_host:?remote_host not set}"
  : "${remote_path:?remote_path not set}"
  : "${interval:?interval not set}"
  : "${max_failures:?max_failures not set}"

  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval > 0 )) \
    || die "interval must be a positive integer (got: $interval)"
  [[ "$max_failures" =~ ^[0-9]+$ ]] && (( max_failures > 0 )) \
    || die "max_failures must be a positive integer (got: $max_failures)"
}

# ─── Config Source Report ────────────────────────────────────────────────────
print_config_sources() {
  local vars=(remote_user remote_host remote_path interval max_failures)
  echo
  info "Configuration sources:"
  for v in "${vars[@]}"; do
    local origin="default"
    if [ -n "$config_loaded" ] && grep -Eq "^[[:space:]]*${v}=" "$config_loaded"; then
      origin="$config_loaded"
    fi
    printf "  %-14s = %-25s (from: %s)\n" "$v" "${!v}" "$origin"
  done
  echo
}

# ─── SSH Setup ───────────────────────────────────────────────────────────────
ssh_setup() {
  echo
  info "Checking SSH connection to ${remote_user}@${remote_host}..."
  local ssh_check
  ssh_check=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_user}@${remote_host}" 'echo ok' 2>&1 || true)

  if [[ "$ssh_check" != "ok" ]]; then
    warn "SSH key authentication not set up for ${remote_user}@${remote_host}."
    debug "Running 'ssh-copy-id ${remote_user}@${remote_host}' to set up passwordless SSH."

    if ! ssh-copy-id "${remote_user}@${remote_host}"; then
      die "ssh-copy-id failed — cannot reach ${remote_user}@${remote_host}. Is the host up?"
    fi

    # Re-verify that key auth actually works after ssh-copy-id
    ssh_check=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_user}@${remote_host}" 'echo ok' 2>&1 || true)
    if [[ "$ssh_check" != "ok" ]]; then
      die "SSH key authentication still not working after ssh-copy-id. Aborting."
    fi
  else
    info "SSH key authentication is already set up for ${remote_user}@${remote_host}."
  fi

  info "Ensuring remote directory exists: $remote_path"
  if ! ssh "${remote_user}@${remote_host}" "mkdir -p $remote_path"; then
    die "Failed to create remote directory '${remote_path}' on ${remote_host}. Aborting."
  fi
}

# ─── Dots Animation ──────────────────────────────────────────────────────────
monitor_dots() {
  local max_dots=6
  local dot_count=1
  local elapsed=0
  local start_time
  start_time=$(date +%s)
  local target_name
  target_name="$(basename "$target")"

  while (( elapsed < interval )); do
    local current_time
    current_time=$(date +%s)
    elapsed=$(( current_time - start_time ))

    local dots
    dots=$(printf "%${dot_count}s" | tr ' ' '.')
    printf "\r\033[K${WHITE}[$(ts)] [>]${NC} Monitoring Changes on \"%s\" %s" "$target_name" "$dots"

    dot_count=$(( (dot_count % max_dots) + 1 ))
    sleep 0.5
  done
}

# ─── Spinner Animation ───────────────────────────────────────────────────────
monitor_spinner() {
  local spinner='|/-\\'
  local spin_index=0
  local elapsed=0
  local start_time
  start_time=$(date +%s)

  while (( elapsed < interval )); do
    local current_time
    current_time=$(date +%s)
    elapsed=$(( current_time - start_time ))

    printf "\r${WHITE}[$(ts)] [>]${NC} Monitoring Changes on %s ... %s" \
      "$(basename "$file")" "${spinner:$spin_index:1}"
    spin_index=$(( (spin_index + 1) % 4 ))
    sleep 0.1
  done
}

# ─── Directory Checksum ──────────────────────────────────────────────────────
calculate_directory_checksum() {
  local dir="$1"
  [ -d "$dir" ] || { echo ""; return; }

  find "$dir" -type f -exec openssl dgst -sha256 {} + 2>/dev/null \
    | sort \
    | openssl dgst -sha256 \
    | awk '{print $2}'
}

# ─── Checksum Dispatcher ─────────────────────────────────────────────────────
calculate_checksum() {
  local tgt="$1"
  if [ -f "$tgt" ]; then
    openssl dgst -sha256 "$tgt" | awk '{print $2}'
  elif [ -d "$tgt" ]; then
    calculate_directory_checksum "$tgt"
  else
    echo ""
  fi
}

# ─── Sync Target ─────────────────────────────────────────────────────────────
sync_target() {
  local tgt="$1"
  local r_user="$2"
  local r_host="$3"
  local r_path="$4"
  local current_checksum="$5"
  local last_checksum="$6"

  if [ -f "$tgt" ]; then
    # ── File sync via scp ──────────────────────────────────────────────────
    if scp "$tgt" "${r_user}@${r_host}:${r_path}" > /dev/null; then
      log success "✅ File synced successfully" >&2
      ssh "${r_user}@${r_host}" "chmod +x ${r_path}/$(basename "$tgt")" \
        && log success "🔐 Remote executable permission set successfully" >&2
      fail_count=0
      echo "$current_checksum"
    else
      (( fail_count++ )) || true
      warn "❌ File sync failed (failures: $fail_count)" >&2
      (( fail_count >= max_failures )) && die "Too many failures. Exiting."
      echo "$last_checksum"
    fi

  elif [ -d "$tgt" ]; then
    # ── Directory sync via rsync (with tar+scp fallback) ──────────────────
    if rsync -az --delete "$tgt/" "${r_user}@${r_host}:${r_path}/" > /dev/null 2>&1; then
      log success "✅ Directory synced successfully (rsync)" >&2
      ssh "${r_user}@${r_host}" "find ${r_path} -name '*.sh' -exec chmod +x {} +" \
        && log success "🔐 Remote executable permissions set for shell scripts" >&2
      fail_count=0
      echo "$current_checksum"
    else
      debug "rsync failed, trying tar+scp fallback" >&2
      local temp_archive="/tmp/sync_$(basename "$tgt")_$$.tar.gz"

      if tar -czf "$temp_archive" -C "$(dirname "$tgt")" "$(basename "$tgt")" 2>/dev/null \
         && scp "$temp_archive" "${r_user}@${r_host}:/tmp/" > /dev/null 2>&1; then

        if ssh "${r_user}@${r_host}" "
            set -e
            cd ${r_path}
            rm -rf $(basename "$tgt")
            tar -xzf /tmp/$(basename "$temp_archive")
            rm -f /tmp/$(basename "$temp_archive")
            find . -name '*.sh' -exec chmod +x {} +
          " > /dev/null 2>&1; then
          log success "✅ Directory synced successfully (tar+scp)" >&2
          log success "🔐 Remote executable permissions set for shell scripts" >&2
          rm -f "$temp_archive"
          fail_count=0
          echo "$current_checksum"
        else
          warn "❌ Directory extraction failed on remote" >&2
          rm -f "$temp_archive"
          (( fail_count++ )) || true
          echo "$last_checksum"
        fi
      else
        warn "❌ Archive creation or transfer failed" >&2
        rm -f "$temp_archive"
        (( fail_count++ )) || true
        echo "$last_checksum"
      fi

      (( fail_count >= max_failures )) && die "Too many failures. Exiting."
    fi

  else
    warn "Target is neither file nor directory: $tgt" >&2
    echo "$last_checksum"
  fi
}

# ─── System Config Dir & Example File ───────────────────────────────────────
ensure_system_config_dir_and_example() {
  local EXAMPLE_CWD="$PWD/.sync_on_change.conf.example"
  local _answer

  if [ -n "$config_loaded" ]; then
    # Config found — only mention example if it doesn't exist yet
    if [ ! -f "$EXAMPLE_CWD" ]; then
      info "Configuration is active from: $config_loaded — no example config file needed."
    fi
  else
    # No config found — offer to create an example
    echo
    read -t 15 -p "[$(ts)] [?] Would you like to generate an example config file to get started? (y/N): " _answer
    echo
    if [[ "$_answer" =~ ^[Yy]$ ]]; then
      gen_example_config
    else
      info "No example config created. Run with --gen-config anytime to create one."
    fi
  fi

  # If running as root, also maintain a system-wide reference copy
  if [ "$(id -u)" -eq 0 ]; then
    local EXAMPLE_ETC="/etc/sync_on_change/sync_on_change.conf.example"
    if [ ! -f "$EXAMPLE_ETC" ]; then
      info "Running as root — creating system-wide example config at $EXAMPLE_ETC"
      mkdir -p /etc/sync_on_change
      ( cd /etc/sync_on_change && gen_example_config )
    fi
  fi
}

# ─── Watch Summary ─────────────────────────────────────────────────────────
print_watch_summary() {
  local target_type="file"
  [ -d "$target" ] && target_type="directory"

  info "Watching:"
  printf "  ${BLUE}%-14s${NC}\t: %s\n" \
    "$target_type" "$target" \
    "Remote"        "${remote_user}@${remote_host}:${remote_path}" \
    "Interval"      "${interval}s" \
    "Max failures"  "${max_failures}"
}

# ─── Initial Sync ────────────────────────────────────────────────────────────
fail_count=0
last_checksum=""

initial_sync() {
  [ -e "$target" ] || die "Target not found for initial sync: $target"
  local current_checksum
  current_checksum=$(calculate_checksum "$target")
  if [ -f "$target" ]; then
    info "Performing initial file sync..."
  else
    info "Performing initial directory sync..."
  fi
  last_checksum=$(sync_target "$target" "$remote_user" "$remote_host" "$remote_path" \
                    "$current_checksum" "$last_checksum")
}

# ─── Main Loop ───────────────────────────────────────────────────────────────
main_loop() {
  local first_run=1
  local target_type="file"
  [ -d "$target" ] && target_type="directory"

  while true; do
    if [ ! -e "$target" ]; then
      warn "Target not found: $target"
      sleep "$interval"
      continue
    fi

    local current_checksum
    current_checksum=$(calculate_checksum "$target")

    if (( first_run )); then
      last_checksum="$current_checksum"
      first_run=0
      debug "Initial checksum for $target_type: $last_checksum"
      monitor_dots
    elif [[ "$current_checksum" != "$last_checksum" ]]; then
      echo
      debug "Checksum changed: $last_checksum -> $current_checksum"
      log "Change detected in $target_type. Syncing..."
      last_checksum=$(sync_target "$target" "$remote_user" "$remote_host" "$remote_path" \
                        "$current_checksum" "$last_checksum")
    else
      monitor_dots
    fi

    sleep "$interval"
  done
}

# ─── Universal PATH Installer ────────────────────────────────────────────────
universal_path_installer() {

  # --- Color Definitions ---
  local GREEN="\033[1;32m"
  local YELLOW="\033[1;33m"
  local BLUE="\033[1;34m"
  local RED="\033[1;31m"
  local RESET="\033[0m"

  # --- Resolve Script Path (cross-platform: realpath may not exist on macOS) ---
  local SCRIPT_PATH
  if command -v realpath > /dev/null 2>&1; then
    SCRIPT_PATH="$(realpath "$0")"
  else
    SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  fi
  local SCRIPT_NAME
  SCRIPT_NAME="$(basename "$SCRIPT_PATH")"   # e.g. sync_on_change_v1.8.3.sh
  SCRIPT_NAME="${SCRIPT_NAME%_v*.sh}"        # strip _v<version>.sh suffix → sync_on_change
  SCRIPT_NAME="${SCRIPT_NAME%.sh}"           # fallback: strip plain .sh if no version suffix
  local TARGET="/usr/local/bin/$SCRIPT_NAME"
  local TMP_TARGET="/tmp/${SCRIPT_NAME}.tmp.$$"

  # --- Parse Mode Flag ---
  local MODE="${1:-}"

  # ── Sub-functions ────────────────────────────────────────────────────────
  _do_install() {
    echo -e "${YELLOW}Installing ${SCRIPT_NAME} into /usr/local/bin ...${RESET}"
    if ! cp "$SCRIPT_PATH" "$TMP_TARGET"; then
      echo -e "${RED}✖ Failed to copy to temporary location.${RESET}"
      return 1
    fi
    chmod +x "$TMP_TARGET"
    local mv_cmd
    if [[ -w "/usr/local/bin" ]]; then
      mv_cmd="mv"
    else
      mv_cmd="sudo mv"
    fi
    if $mv_cmd "$TMP_TARGET" "$TARGET"; then
      echo -e "${GREEN}✔ Installed successfully. Run it using: ${BLUE}${SCRIPT_NAME}${RESET}"
    else
      echo -e "${RED}✖ Installation failed during final move.${RESET}"
      rm -f "$TMP_TARGET"
      return 1
    fi
  }

  _do_uninstall() {
    if [[ -f "$TARGET" ]]; then
      echo -e "${YELLOW}Removing ${SCRIPT_NAME} from /usr/local/bin ...${RESET}"
      local rm_cmd
      if [[ -w "/usr/local/bin" ]]; then
        rm_cmd="rm"
      else
        rm_cmd="sudo rm"
      fi
      if $rm_cmd -f "$TARGET"; then
        echo -e "${GREEN}✔ Uninstalled successfully.${RESET}"
      else
        echo -e "${RED}✖ Failed to uninstall.${RESET}"
        return 1
      fi
    else
      echo -e "${YELLOW}Nothing to uninstall. ${SCRIPT_NAME} is not in /usr/local/bin.${RESET}"
    fi
  }

  _do_update() {
    if [[ ! -f "$TARGET" ]]; then
      echo -e "${RED}✖ Cannot update: ${SCRIPT_NAME} is not installed. Run --install first.${RESET}"
      return 1
    fi
    echo -e "${YELLOW}Updating ${SCRIPT_NAME} ...${RESET}"
    if ! cp "$SCRIPT_PATH" "$TMP_TARGET"; then
      echo -e "${RED}✖ Failed to copy to temporary location.${RESET}"
      return 1
    fi
    chmod +x "$TMP_TARGET"
    local mv_cmd
    if [[ -w "/usr/local/bin" ]]; then
      mv_cmd="mv"
    else
      mv_cmd="sudo mv"
    fi
    if $mv_cmd "$TMP_TARGET" "$TARGET"; then
      echo -e "${GREEN}✔ Updated successfully.${RESET}"
    else
      echo -e "${RED}✖ Update failed during final move.${RESET}"
      rm -f "$TMP_TARGET"
      return 1
    fi
  }

  # ── Mode Dispatcher ──────────────────────────────────────────────────────
  case "$MODE" in
    --install)   _do_install;   return $? ;;
    --uninstall) _do_uninstall; return $? ;;
    --update)    _do_update;    return $? ;;
  esac

  # ── Default: Interactive Mode ────────────────────────────────────────────
  if [[ -f "$TARGET" ]]; then
    echo -e "${GREEN}✔ Already installed in PATH. Enjoy using ${BLUE}${SCRIPT_NAME}${RESET}"
    return 0
  fi

  echo
  echo -e "${BLUE}Do you like this tool?${RESET}"
  local answer
  read -t 30 -p "Add it to PATH so you can run it anywhere (y/N): " answer

  if [[ "$answer" =~ ^[Yy]$ ]]; then
    _do_install
  else
    echo -e "${YELLOW}Skipped PATH installation.${RESET}"
  fi
}

# ─── Script Entry ────────────────────────────────────────────────────────────

set_defaults
parse_args "$@"          # NOTE: --install/--update/--uninstall/--gen-config/--check-deps exit inside parse_args
check_deps               # Verify prerequisites; offer to install if missing
universal_path_installer # Interactive prompt (skipped when already in PATH)

load_config
ensure_system_config_dir_and_example  # Prompt after config state is known
validate_config
print_config_sources

ssh_setup
print_watch_summary

initial_sync
main_loop
