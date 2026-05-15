#!/bin/bash
# -----------------------------------------------------------------------------
# sync_on_change - File and Directory Synchronization Tool
# Copyright (c) 2025 Abdulrahman Samy
# 
# Licensed under the MIT License. See LICENSE file for details.
# Repository: https://github.com/abdulrahmansamy/system_engineering
# -----------------------------------------------------------------------------
# Script: sync_on_change_clean.sh
# Purpose:
#   Watch a single local file for content changes and automatically sync it
#   to a remote host via scp, then set executable permission remotely.
#
# How It Works:
#   - Computes a SHA-256 checksum each interval (default: 3s).
#   - On change: scp -> remote chmod +x.
#   - Shows an animated progress (dots) while idle.
#   - Tracks consecutive failures and aborts after max_failures (default: 10).
#   - Supports external configuration files and reports the source of each setting.
#
# Usage:
#   ./sync_on_change_clean.sh <file> [-c <config-file>] [-h]
#
# Examples:
#   ./sync_on_change_clean.sh scripts/deploy.sh
#   ./sync_on_change_clean.sh scripts/deploy.sh -c /path/custom.conf
#
# Configuration Variables (overridable):
#   remote_user, remote_host, remote_path, interval, max_failures
#
# Configuration Precedence (first found wins):
#   1. -c <config-file> (explicit; required to exist)
#   2. <script_dir>/sync_on_change.conf
#   3. $PWD/.sync_on_change.conf
#   4. <watched_file_dir>/.sync_on_change.conf
#
# Notes:
#   - If -c is provided, NO fallback search occurs.
#   - On startup a summary lists each variable and whether it came from defaults
#     or which config file.
#   - Monitors only one file path; detects content (hash) changes, not metadata.
#   - For multi-file or bidirectional sync consider rsync or inotify-based tools.
#   - Safe to stop anytime with Ctrl+C.
# -----------------------------------------------------------------------------

# To sync code files built locally in VSCode to remote server where the script will be run on changes
# and set executable permissions remotely
# ─── Color Codes ───────────────────────────────────────────────────────────────
RED='\033[0;31m'       # Errors
GREEN='\033[0;32m'     # Success
YELLOW='\033[1;33m'    # Warnings
BLUE='\033[0;34m'      # Info
CYAN='\033[0;36m'      # Questions
MAGENTA='\033[0;35m'   # Debug
WHITE='\033[1;37m'     # Trace
GRAY='\033[0;37m'      # Silent
NC='\033[0m'           # No Color

# ─── Timestamp ────────────────────────────────────────────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# ─── Logging Functions ────────────────────────────────────────────────────────
log()    { echo -e "${GREEN}[$(ts)] [+]${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(ts)] [!]${NC} $*" >&2; }
die()    { echo -e "${RED}[$(ts)] [x]${NC} $*" >&2; exit 1; }
info()   { echo -e "${BLUE}[$(ts)] [i]${NC} $*"; }
ask()    { echo -e "${CYAN}[$(ts)] [?]${NC} $*"; }
debug()  { [ "$verbose" = true ] && echo -e "${MAGENTA}[$(ts)] [*]${NC} $*"; }
trace()  { echo -en "\r${WHITE}[$(ts)] [>]${NC} $*"; }
silent() { echo -e "${GRAY}[$(ts)] [-]${NC} $*"; }

# ─── Usage / Help ─────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 <file|directory> [-c <config-file>] [-v] [-h]

Required:
  <file|directory>      Local file or directory to watch & sync on content change.

Options:
  -c <config-file>      Explicit config file (must exist, disables fallback search)
  -v, --verbose         Enable verbose debug output
  -h, --help            Show this help

Configuration Precedence (first found wins):
  1. -c <config-file> (explicit; required to exist)
  2. Current working directory ($PWD/.sync_on_change.conf)
  3. Script directory ($script_dir/.sync_on_change.conf)
  4. Directory of the watched file ($(dirname "$target")/sync_on_change.conf)
  5. System-wide config (/etc/sync_on_change/sync_on_change.conf)
  6. Script's Defaults

Notes:
  - If -c is provided, NO fallback search occurs
  - On startup, /etc/sync_on_change/ is created if missing, and an example config file is placed there as reference
  - On startup, a summary lists each variable and its source (default or config file)
  - Monitors only one file or directory; detects content (hash) changes, not metadata
  - For multi-file or bidirectional sync, consider rsync or inotify-based tools
  - Safe to stop anytime with Ctrl+C
  - For files: Monitors content changes via SHA-256 checksum
  - For directories: Monitors all files recursively via find + checksums
  - Directory sync uses rsync for efficient transfer
EOF
}

parse_args() {
  # Argument Parsing
  target=""
  explicit_config=""
  verbose=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -v|--verbose)
        verbose=true
        shift
        ;;
      -c)
        shift
        [ $# -gt 0 ] || die "-c requires a config file path"
        if [ -n "$explicit_config" ]; then
          die "Duplicate -c option"
        fi
        explicit_config="$1"
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
  [ -n "$target" ] || { usage >&2; die "Missing <file|directory>"; }
  
  # Set file variable for backward compatibility
  file="$target"
}

set_defaults() {
  remote_user="username"
  remote_host="xxx.xxx.xxx.xxx"
  remote_path="~/scripts/"
  interval=3
  max_failures=10
}

load_config() {
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  config_loaded=""
  if [ -n "$explicit_config" ]; then
    if [ ! -f "$explicit_config" ] || [ ! -r "$explicit_config" ]; then
      die "Config file not found or not readable: $explicit_config"
    fi
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
      source "$cand"
      config_loaded="$cand"
      break
    fi
  done
  if [ -n "$config_loaded" ]; then
    info "Loaded configuration: $config_loaded"
  else
    info "Using built-in defaults (no external config found)"
  fi
}

validate_config() {
  : "${remote_user:?remote_user not set}"
  : "${remote_host:?remote_host not set}"
  : "${remote_path:?remote_path not set}"
  : "${interval:?interval not set}"
  : "${max_failures:?max_failures not set}"

  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
    die "interval must be a positive integer (got: $interval)"
  fi
  if ! [[ "$max_failures" =~ ^[0-9]+$ ]] || [ "$max_failures" -le 0 ]; then
    die "max_failures must be a positive integer (got: $max_failures)"
  fi
}

# ─── Config Source Report ─────────────────────────────────────────────────────
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

ssh_setup() {
  echo
  log "Checking SSH connection to $remote_user@$remote_host..."
  ssh_check=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_user@$remote_host" 'echo ok' 2>&1 || true)
  if [[ "$ssh_check" != "ok" ]]; then
    warn "SSH key authentication not set up for $remote_user@$remote_host."
    debug "Running 'ssh-copy-id $remote_user@$remote_host' to set up passwordless SSH and rerun this script."
    ssh-copy-id $remote_user@$remote_host
  else
    info "SSH key authentication is already set up for $remote_user@$remote_host."
  fi
  log "Ensuring remote directory exists: $remote_path"
  ssh "$remote_user@$remote_host" "mkdir -p $remote_path"
}

# ─── Spinner Animation ────────────────────────────────────────────────────────
monitor_spinner() {
  local spinner='|/-\\'
  local spin_index=0
  local start_time=$(date +%s)

  while (( elapsed < interval )); do
    local current_time=$(date +%s)
    local elapsed=$(( current_time - start_time ))
    # if (( elapsed >= interval )); then break; fi

    printf "\r${WHITE}[$(ts)] [>]${NC} Monitoring Changes on %s ... %s" "$(basename "$file")" "${spinner:$spin_index:1}"
    spin_index=$(( (spin_index + 1) % 4 ))
    sleep 0.1
  done
}

# ─── Dots Animation ────────────────────────────────────────────────────────

monitor_dots() {
  local max_dots=6
  local dot_count=1
  local start_time=$(date +%s)
  local target_name="$(basename "$target")"

  while (( elapsed < interval )); do
    local current_time=$(date +%s)
    local elapsed=$(( current_time - start_time ))

    local dots=$(printf "%${dot_count}s" | tr ' ' '.')
    # Clear line before printing
    printf "\r\033[K${WHITE}[$(ts)] [>]${NC} Monitoring Changes on \"%s\" %s" "$target_name" "$dots"

    dot_count=$(( (dot_count % max_dots) + 1 ))
    sleep 0.5
  done
}

# ─── Directory Checksum Calculation ──────────────────────────────────────────
calculate_directory_checksum() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo ""
    return
  fi
  
  # Find all files and calculate combined checksum
  find "$dir" -type f -exec openssl dgst -sha256 {} + 2>/dev/null | \
    sort | \
    openssl dgst -sha256 | \
    awk '{print $2}'
}

# ─── Enhanced Sync Function ──────────────────────────────────────────────────
sync_target() {
  local target="$1"
  local remote_user="$2"
  local remote_host="$3"
  local remote_path="$4"
  local current_checksum="$5"
  local last_checksum="$6"
  
  if [ -f "$target" ]; then
    # File sync using scp
    if scp "$target" "$remote_user@$remote_host:$remote_path" > /dev/null; then
      log "✅ File synced successfully" >&2
      ssh "$remote_user@$remote_host" "chmod +x $remote_path/$(basename "$target")" \
        && log "🔐 Remote executable permission set successfully" >&2
      fail_count=0
      echo "$current_checksum"
    else
      fail_count=$((fail_count + 1))
      warn "❌ File sync failed (failures: $fail_count)" >&2
      if ((fail_count >= max_failures)); then
        die "Too many failures. Exiting."
      fi
      echo "$last_checksum"
    fi
  elif [ -d "$target" ]; then
    # Directory sync - try rsync first, fallback to tar+scp
    if rsync -avz --delete "$target/" "$remote_user@$remote_host:$remote_path/" > /dev/null 2>&1; then
      log "✅ Directory synced successfully (rsync)" >&2
      ssh "$remote_user@$remote_host" "find $remote_path -name '*.sh' -exec chmod +x {} +" \
        && log "🔐 Remote executable permissions set for shell scripts" >&2
      fail_count=0
      echo "$current_checksum"
    else
      debug "rsync failed, trying tar+scp fallback" >&2
      # Fallback: tar + scp method
      local temp_archive="/tmp/sync_$(basename "$target")_$(date +%s).tar.gz"
      if tar -czf "$temp_archive" -C "$(dirname "$target")" "$(basename "$target")" 2>/dev/null; then
        if scp "$temp_archive" "$remote_user@$remote_host:/tmp/" > /dev/null 2>&1; then
          ssh "$remote_user@$remote_host" "
            cd $remote_path && 
            rm -rf $(basename "$target") && 
            tar -xzf /tmp/$(basename "$temp_archive") && 
            rm -f /tmp/$(basename "$temp_archive") &&
            find . -name '*.sh' -exec chmod +x {} +
          " > /dev/null 2>&1
          if [ $? -eq 0 ]; then
            log "✅ Directory synced successfully (tar+scp)" >&2
            log "🔐 Remote executable permissions set for shell scripts" >&2
            rm -f "$temp_archive"
            fail_count=0
            echo "$current_checksum"
          else
            warn "❌ Directory extraction failed on remote" >&2
            rm -f "$temp_archive"
            fail_count=$((fail_count + 1))
            echo "$last_checksum"
          fi
        else
          warn "❌ Archive transfer failed" >&2
          rm -f "$temp_archive"
          fail_count=$((fail_count + 1))
          echo "$last_checksum"
        fi
      else
        warn "❌ Archive creation failed" >&2
        fail_count=$((fail_count + 1))
        echo "$last_checksum"
      fi
      
      if ((fail_count >= max_failures)); then
        die "Too many failures. Exiting."
      fi
    fi
  else
    warn "Target is neither file nor directory: $target" >&2
    echo "$last_checksum"
  fi
}

# ─── Enhanced Checksum Calculation ───────────────────────────────────────────
calculate_checksum() {
  local target="$1"
  if [ -f "$target" ]; then
    openssl dgst -sha256 "$target" | awk '{print $2}'
  elif [ -d "$target" ]; then
    calculate_directory_checksum "$target"
  else
    echo ""
  fi
}

# ─── System Config Directory & Example File Module ───────────────────────────

ensure_system_config_dir_and_example() {
  # Create example config file in both /etc/sync_on_change/ and script dir if root, else only in script dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  EXAMPLE_CONTENT="# Example sync_on_change configuration file\n# Copy to sync_on_change.conf and edit as needed\n\n# --- Remote Connection ---\nremote_user=\"youruser\"           # SSH username\nremote_host=\"your.remote.host\"  # SSH host or IP\nremote_path=\"~/scripts/\"        # Destination directory\n\n# --- Behavior ---\ninterval=3                       # Poll interval (seconds)\nmax_failures=10                  # Abort after this many consecutive sync failures\n\n# --- Advanced (optional) ---\n# scp_opts=\"-C\"                  # Extra options for scp\n# ssh_opts=\"-o BatchMode=yes\"    # Extra options for ssh\n"

  # Always create in script directory
  EXAMPLE_CONF_SCRIPT="$script_dir/sync_on_change.conf.example"
  if [ ! -f "$EXAMPLE_CONF_SCRIPT" ]; then
    echo -e "$EXAMPLE_CONTENT" > "$EXAMPLE_CONF_SCRIPT"
  fi

  # If root, also create in /etc/sync_on_change/
  if [ "$(id -u)" -eq 0 ]; then
    if [ ! -d "/etc/sync_on_change" ]; then
      mkdir -p /etc/sync_on_change
    fi
    EXAMPLE_CONF_ETC="/etc/sync_on_change/sync_on_change.conf.example"
    if [ ! -f "$EXAMPLE_CONF_ETC" ]; then
      echo -e "$EXAMPLE_CONTENT" > "$EXAMPLE_CONF_ETC"
    fi
  fi
}

# ─── Main Loop ────────────────────────────────────────────────────────────────
fail_count=0
last_checksum=""

initial_sync() {
  if [ ! -e "$target" ]; then
    die "Target not found for initial sync: $target"
  fi
  current_checksum=$(calculate_checksum "$target")
  if [ -f "$target" ]; then
    log "Performing initial file sync..."
  else
    log "Performing initial directory sync..."
  fi
  last_checksum=$(sync_target "$target" "$remote_user" "$remote_host" "$remote_path" "$current_checksum" "$last_checksum")
}

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
      last_checksum=$(sync_target "$target" "$remote_user" "$remote_host" "$remote_path" "$current_checksum" "$last_checksum")
    else
      monitor_dots
    fi
    sleep "$interval"
  done
}


# ─── Script Entry ─────────────────────────────────────────────────────────────


# Call the module to ensure system config dir and example file
ensure_system_config_dir_and_example

set_defaults
parse_args "$@"
load_config
validate_config

# Determine target type for display
target_type="file"
[ -d "$target" ] && target_type="directory"

info "Watching $target_type: $target | Remote: ${remote_user}@${remote_host}:${remote_path} | Interval: ${interval}s | Max failures: ${max_failures}"
print_config_sources
ssh_setup
initial_sync
main_loop
