#!/bin/bash
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
#   4. <script_dir>/.sync_on_change.conf
#   5. <watched_file_dir>/.sync_on_change.conf
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
debug()  { echo -e "${MAGENTA}[$(ts)] [*]${NC} $*"; }
trace()  { echo -en "\r${WHITE}[$(ts)] [>]${NC} $*"; }
silent() { echo -e "${GRAY}[$(ts)] [-]${NC} $*"; }

# ─── Usage / Help ─────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: sync_on_change_clean.sh <file> [-c <config-file>] [-h]

Required:
  <file>                Local file to watch & sync on content change.

Options:
  -c <config-file>      Explicit config file overriding defaults.
  -h, --help            Show this help.

Config search order (first found wins):
  1. -c <config-file> (if provided)
  2. <script_dir>/sync_on_change.conf
  3. $PWD/.sync_on_change.conf
  4. <script_dir>/.sync_on_change.conf
  5. <watched_file_dir>/.sync_on_change.conf
EOF
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────
file=""
explicit_config=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
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
      if [ -z "$file" ]; then
        file="$1"
        shift
      else
        die "Unexpected extra argument: $1 (use -h for help)"
      fi
      ;;
  esac
done

[ -n "$file" ] || { usage >&2; die "Missing <file>"; }

# ─── Configuration (defaults) ─────────────────────────────────────────────────
# (moved below parsing; removed old simple arg count check)
remote_user="username"              # SSH username
remote_host="172.00.00.00"          # SSH host or IP
remote_path="~/vault-scripts/"
interval=3
max_failures=10

# ─── Load External Configuration (first found) ───────────────────────────────
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_loaded=""

# If -c provided, require the file to exist & be readable; it overrides defaults exclusively.
if [ -n "$explicit_config" ]; then
  if [ ! -f "$explicit_config" ] || [ ! -r "$explicit_config" ]; then
    die "Config file not found or not readable: $explicit_config"
  fi
fi

# Build candidate list depending on explicit flag
if [ -n "$explicit_config" ]; then
  candidates=("$explicit_config")
else
  candidates=(
    "$script_dir/sync_on_change.conf"
    "$PWD/.sync_on_change.conf"
    "$script_dir/.sync_on_change.conf"
    "$(dirname "$file")/.sync_on_change.conf"
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
  info "Loaded configuration: $config_loaded"
else
  info "Using built-in defaults (no external config found)"
fi

# ─── Derived / Runtime Vars ───────────────────────────────────────────────────
fail_count=0
last_checksum=""

# Basic validation
: "${remote_user:?remote_user not set}"
: "${remote_host:?remote_host not set}"
: "${remote_path:?remote_path not set}"
: "${interval:?interval not set}"
: "${max_failures:?max_failures not set}"

# Ensure interval & max_failures are integers > 0
if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
  die "interval must be a positive integer (got: $interval)"
fi
if ! [[ "$max_failures" =~ ^[0-9]+$ ]] || [ "$max_failures" -le 0 ]; then
  die "max_failures must be a positive integer (got: $max_failures)"
fi

info "Watching: $file | Remote: ${remote_user}@${remote_host}:${remote_path} | Interval: ${interval}s | Max failures: ${max_failures}"

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
print_config_sources

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

  while (( elapsed < interval )); do
    local current_time=$(date +%s)
    local elapsed=$(( current_time - start_time ))

    local dots=$(printf "%${dot_count}s" | tr ' ' '.')
    # Clear line before printing
    printf "\r\033[K${WHITE}[$(ts)] [>]${NC} Monitoring Changes on \"%s\" %s" "$(basename "$file")" "$dots"

    dot_count=$(( (dot_count % max_dots) + 1 ))
    sleep 0.5
  done
}



# ─── Main Loop ────────────────────────────────────────────────────────────────
while true; do
  if [ ! -f "$file" ]; then
    warn "File not found: $file"
    sleep "$interval"
    continue
  fi

  current_checksum=$(openssl dgst -sha256 "$file" | awk '{print $2}')

  if [[ "$current_checksum" != "$last_checksum" ]]; then
    echo
    log "Change detected. Syncing..."

    if scp "$file" "$remote_user@$remote_host:$remote_path" > /dev/null; then
      log "✅ Synced successfully"

      ssh "$remote_user@$remote_host" "chmod +x $remote_path/$(basename "$file")" \
        && log "🔐 Remote executable permission set successfully" # set for \"$(basename "$file")\"

      fail_count=0
      last_checksum="$current_checksum"
    else
      ((fail_count++))
      warn "❌ Sync failed (failures: $fail_count)"
      if ((fail_count >= max_failures)); then
        die "Too many failures. Exiting."
      fi
    fi
  else
    # monitor_spinner
    monitor_dots
  fi
  sleep "$interval"
done
