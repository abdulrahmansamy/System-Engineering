#!/usr/bin/env bash
# Logging library

safe_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

level_to_num() {
  case "$(safe_upper "$1")" in
    ERROR) echo 0 ;;
    WARN)  echo 1 ;;
    INFO)  echo 2 ;;
    DEBUG) echo 3 ;;
    *)     echo 2 ;;
  esac
}

logging_init() {
  local cli_level="${1:-}"
  LOG_FILE="${2:-${LOG_FILE:-}}"

  if [[ -n "$cli_level" ]]; then
    EFFECTIVE_LOG_LEVEL="$(safe_upper "$cli_level")"
  else
    EFFECTIVE_LOG_LEVEL="$(safe_upper "${LOG_LEVEL:-INFO}")"
  fi
  LOG_LEVEL_NUM=$(level_to_num "$EFFECTIVE_LOG_LEVEL")

  if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    COLOR_INFO='\033[32m'
    COLOR_WARN='\033[33m'
    COLOR_ERROR='\033[31m'
    COLOR_DEBUG='\033[34m'
    COLOR_PROMPT='\033[36m'
    COLOR_RESET='\033[0m'
  else
    COLOR_INFO='' COLOR_WARN='' COLOR_ERROR='' COLOR_DEBUG='' COLOR_PROMPT='' COLOR_RESET=''
  fi
}

_log_emit() {
  local level="$1" msg="$2" lvl_num
  lvl_num=$(level_to_num "$level")
  if [[ -n "$LOG_FILE" ]]; then
    { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true; echo "[$level] $msg" >> "$LOG_FILE"; } || true
  fi
  (( lvl_num <= LOG_LEVEL_NUM )) || return 0
  local color=''
  case "$level" in
    ERROR) color="$COLOR_ERROR" ;;
    WARN)  color="$COLOR_WARN" ;;
    INFO)  color="$COLOR_INFO" ;;
    DEBUG) color="$COLOR_DEBUG" ;;
  esac
  local line="[$level] $msg"
  if [[ -n "$color" ]]; then
    printf '%b%s%b\n' "$color" "$line" "$COLOR_RESET" >&2
  else
    printf '%s\n' "$line" >&2
  fi
}

log_error(){ _log_emit ERROR "$1"; }
log_warn() { _log_emit WARN  "$1"; }
log_info() { _log_emit INFO  "$1"; }
log_debug(){ _log_emit DEBUG "$1"; }
log() { log_info "$1"; }

log_ask() {
  local msg="$1" label='[PROMPT]'
  [[ -n "$LOG_FILE" ]] && echo "$label $msg" >> "$LOG_FILE"
  if [[ -n "$COLOR_PROMPT" ]]; then
    printf '%b%s %s%b' "$COLOR_PROMPT" "$label" "$msg" "$COLOR_RESET"
  else
    printf '%s %s' "$label" "$msg"
  fi
}

print_detailed_help() {
cat <<'EOF'
Flags:
  --dry-run        Show actions without deleting
  --repo / --tag   Filter modes (exclusive)
  --silent         WARN level logs
  --verbose        DEBUG level logs
  --log-file FILE  Append all log lines to file

Subcommands:
  repo <REPO>      Operate on repository images
  tag <TAG>        Operate on images with a tag
  dangling         Operate on dangling images (default)

Exit Codes:
  0 success
  1 no images found
  2 user aborted
  3 deletion failed
EOF
}
