#!/usr/bin/env bash
# Backward compatibility wrapper for legacy callers of podman-clean_v3.0.sh
# Delegates to the new modular CLI: podman-clean.sh
# Supports new 'completion' subcommand via delegation.
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/podman-clean.sh" "$@"
#   --tag TAG        Operate on images whose tag exactly matches TAG (all repositories)
#   --repo REPO      Operate on all images belonging to repository REPO
#   --silent         Enable silent mode (suppress output, only errors and warnings)
#   --verbose        Enable verbose mode (detailed output)
#   --log-file FILE  Log output to the specified file
# Notes:
#   If --tag value looks like a repository (contains '/' and no ':'), it is treated as --repo for convenience.
# Author: Abdul Rahman Samy
# Date: 2025-08-30

set -euo pipefail

DRY_RUN=false
TARGET_TAG=""
TARGET_REPO=""
CLI_LOG_LEVEL=""
LOG_FILE=""
SUBCOMMAND=""

# Exit codes:
#   0 success
#   1 no images found
#   2 user aborted
#   3 deletion failed

usage() {
    echo "Usage:"
    echo "  $0 repo <REPOSITORY>   [--dry-run] [--silent | --verbose] [--log-file FILE]"
    echo "  $0 tag <TAG>           [--dry-run] [--silent | --verbose] [--log-file FILE]"
    echo "  $0 dangling            [--dry-run] [--silent | --verbose] [--log-file FILE]"
    echo "  $0 [--repo REPOSITORY] [--tag TAG] (legacy flag mode, mutually exclusive)"
    echo "Exit codes: 0=success 1=no-images 2=user-aborted 3=deletion-failed"
    echo "Run '$0 --help' for full help."
}

# Pre-parse subcommand (if any)
if [[ $# -gt 0 ]]; then
    case "$1" in
        repo)
            SUBCOMMAND="repo"; shift
            if [[ $# -eq 0 || "$1" == --* ]]; then
                echo "[ERROR] Missing repository after 'repo' subcommand" >&2; usage >&2; exit 1
            fi
            TARGET_REPO="$1"; shift
            ;;
        tag)
            SUBCOMMAND="tag"; shift
            if [[ $# -eq 0 || "$1" == --* ]]; then
                echo "[ERROR] Missing tag after 'tag' subcommand" >&2; usage >&2; exit 1
            fi
            TARGET_TAG="$1"; shift
            ;;
        dangling)
            SUBCOMMAND="dangling"; shift ;;
        help|-h|--help)
            # Defer to later help for full details
            usage; exit 0 ;;
        *)
            # Not a subcommand; proceed with legacy flags
            :
            ;;
    esac
fi

# Updated flag parsing to support --tag / --repo plus new flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --tag)
            [[ -z "${2:-}" ]] && { echo "[ERROR] --tag requires an argument" >&2; exit 1; }
            TARGET_TAG="$2"; shift 2 ;;
        --tag=*) TARGET_TAG="${1#*=}"; shift ;;
        --repo)
            [[ -z "${2:-}" ]] && { echo "[ERROR] --repo requires an argument" >&2; exit 1; }
            TARGET_REPO="$2"; shift 2 ;;
        --repo=*) TARGET_REPO="${1#*=}"; shift ;;
        --silent)
            [[ -n "$CLI_LOG_LEVEL" ]] && { echo "[ERROR] Cannot combine --silent with another log verbosity flag" >&2; exit 1; }
            CLI_LOG_LEVEL="WARN"; shift ;;
        --verbose)
            [[ -n "$CLI_LOG_LEVEL" ]] && { echo "[ERROR] Cannot combine --verbose with another log verbosity flag" >&2; exit 1; }
            CLI_LOG_LEVEL="DEBUG"; shift ;;
        --log-file)
            [[ -z "${2:-}" ]] && { echo "[ERROR] --log-file requires a path" >&2; exit 1; }
            LOG_FILE="$2"; shift 2 ;;
        --log-file=*) LOG_FILE="${1#*=}"; shift ;;
        -h|--help)
            cat <<EOF
Usage:
  $0 repo <REPOSITORY>   [--dry-run] [--silent | --verbose] [--log-file FILE]
  $0 tag <TAG>           [--dry-run] [--silent | --verbose] [--log-file FILE]
  $0 dangling            [--dry-run] [--silent | --verbose] [--log-file FILE]
  $0 --repo REPOSITORY | --tag TAG (legacy flags)

Modes (precedence if mixing legacy flags):
  1. --repo / repo subcommand
  2. --tag  / tag subcommand
  3. dangling (default)

Logging:
  LOG_LEVEL env: ERROR,WARN,INFO,DEBUG (default INFO).
  --silent => WARN, --verbose => DEBUG.
  --log-file FILE collects all log lines (unfiltered).

Examples:
  $0 repo localhost/myapp
  $0 tag 1.4 --dry-run
  $0 dangling --silent
  $0 --repo localhost/myapp --dry-run
EOF
            exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Validate subcommand / flag conflicts
if [[ "$SUBCOMMAND" == "repo" && -n "$TARGET_TAG" ]]; then
    echo "[ERROR] Cannot specify tag options with 'repo' subcommand" >&2; exit 1
fi
if [[ "$SUBCOMMAND" == "tag" && -n "$TARGET_REPO" ]]; then
    echo "[ERROR] Cannot specify repo options with 'tag' subcommand" >&2; exit 1
fi

# Interpret --tag <repo> as repository filter when it resembles a repository
if [[ -n "$TARGET_TAG" && -z "$TARGET_REPO" && "$TARGET_TAG" == */* && "$TARGET_TAG" != *":"* ]]; then
    TARGET_REPO="$TARGET_TAG"
    TARGET_TAG=""
fi

# ----- Logging system -----
# Portable uppercase helper (avoids Bash 4+ ${var^^} feature for macOS / older bash)
safe_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Color setup (only if TTY and NO_COLOR not set)
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
    COLOR_INFO='\033[32m'
    COLOR_WARN='\033[33m'
    COLOR_ERROR='\033[31m'
    COLOR_DEBUG='\033[34m'
    COLOR_PROMPT='\033[36m'   # cyan for prompts
    COLOR_RESET='\033[0m'
else
    COLOR_INFO='' COLOR_WARN='' COLOR_ERROR='' COLOR_DEBUG='' COLOR_PROMPT='' COLOR_RESET=''
fi

level_to_num() {
    local u; u=$(safe_upper "$1")
    case "$u" in
        ERROR) echo 0 ;;
        WARN)  echo 1 ;;
        INFO)  echo 2 ;;
        DEBUG) echo 3 ;;
        *)     echo 2 ;;
    esac
}

# Determine effective log level
if [[ -n "$CLI_LOG_LEVEL" ]]; then
    EFFECTIVE_LOG_LEVEL="$(safe_upper "$CLI_LOG_LEVEL")"
else
    EFFECTIVE_LOG_LEVEL="$(safe_upper "${LOG_LEVEL:-INFO}")"
fi
LOG_LEVEL_NUM=$(level_to_num "$EFFECTIVE_LOG_LEVEL")

_log_emit() {
    local level="$1" lvl_num msg="$2"
    lvl_num=$(level_to_num "$level")
    # Always write to log file if set (uncolored)
    if [[ -n "$LOG_FILE" ]]; then
        { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true; echo "[$level] $msg" >> "$LOG_FILE"; } || true
    fi
    (( lvl_num <= LOG_LEVEL_NUM )) || return 0

    local color="$COLOR_DEBUG"
    case "$level" in
        ERROR) color="$COLOR_ERROR" ;;
        WARN)  color="$COLOR_WARN" ;;
        INFO)  color="$COLOR_INFO" ;;
        DEBUG) color="$COLOR_DEBUG" ;;
    esac

    local line="[$level] $msg"

    # Send all log lines to stderr to avoid polluting command substitution outputs (especially DEBUG during size calculations)
    if [[ -n "$color" ]]; then
        printf '%b%s%b\n' "$color" "$line" "$COLOR_RESET" >&2
    else
        printf '%s\n' "$line" >&2
    fi
}

log_error() { _log_emit ERROR "$1"; }
log_warn()  { _log_emit WARN  "$1"; }
log_info()  { _log_emit INFO  "$1"; }
log_debug() { _log_emit DEBUG "$1"; }

# Backward compatibility alias (not used further)
log() { log_info "$1"; }

# New: prompt helper (always shown, not filtered by log level)
log_ask() {
    local msg="$1"
    local label="[PROMPT]"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$label $msg" >> "$LOG_FILE"
    fi
    if [[ -n "$COLOR_PROMPT" ]]; then
        # Color entire prompt (label + message), reset before user input
        printf '%b%s %s%b' "$COLOR_PROMPT" "$label" "$msg" "$COLOR_RESET"
    else
        printf '%s %s' "$label" "$msg"
    fi
}

# Spinner (suppressed in WARN/ERROR-only mode)
SPINNER_PID=""
SPINNER_ACTIVE=0
start_spinner() {
    (( LOG_LEVEL_NUM < 2 )) && return 0  # hide in silent (WARN) mode
    local msg="$1"
    local frames='|/-\'
    local i=0
    SPINNER_ACTIVE=1
    printf "%s " "$msg"
    (
        while (( SPINNER_ACTIVE )); do
            printf "\r%s %s" "$msg" "${frames:i++%${#frames}:1}"
            sleep 0.15
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
    (( SPINNER_ACTIVE )) || return 0
    SPINNER_ACTIVE=0
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf '\r\033[K'  # clear line
}

# Ensure spinner stops on exit
trap 'stop_spinner' EXIT
# ----- End logging & spinner additions -----

# ----- Existing script logic -----

convert_to_bytes() {
    local num unit size="$1"
    num=$(echo "$size" | grep -oE '^[0-9.]+')
    unit=$(echo "$size" | grep -oE '[kMG]B$')

    case "$unit" in
        kB) awk "BEGIN {print $num * 1024}" ;;
        MB) awk "BEGIN {print $num * 1024 * 1024}" ;;
        GB) awk "BEGIN {print $num * 1024 * 1024 * 1024}" ;;
        *) echo 0 ;;
    esac
}

format_human_size() {
    local bytes="$1"
    if (( bytes < 1024 )); then
        echo "${bytes} B"
    elif (( bytes < 1024 * 1024 )); then
        awk "BEGIN {printf \"%.2f kB\", $bytes / 1024}"
    elif (( bytes < 1024 * 1024 * 1024 )); then
        awk "BEGIN {printf \"%.2f MB\", $bytes / (1024 * 1024)}"
    else
        awk "BEGIN {printf \"%.2f GB\", $bytes / (1024 * 1024 * 1024)}"
    fi
}

calculate_total_size() {
    local sizes total_bytes=0
    sizes=$(podman images -f "dangling=true" --format "{{.Size}}")

    if [[ -z "$sizes" ]]; then
        echo 0
        return
    fi

    while read -r size; do
        bytes=$(convert_to_bytes "$size")
        total_bytes=$(awk "BEGIN {print $total_bytes + $bytes}")
    done <<< "$sizes"

    log_debug "Summed dangling size bytes=$total_bytes"
    echo "${total_bytes%.*}"
}

list_dangling_images() {
    podman images -f "dangling=true" --format "{{.ID}} {{.Repository}}:{{.Tag}} {{.Size}}"
}

prune_exited_containers() {
    log_info "Checking for exited containers..."
    local exited_ids
    exited_ids=$(podman ps -a --filter "status=exited" -q)

    if [[ -z "$exited_ids" ]]; then
        log_info "No exited containers found."
        return
    fi

    log_info "Found $(echo "$exited_ids" | wc -l | xargs) exited container(s)."
    if $DRY_RUN; then
        log_info "Dry run: Would prune exited containers:"
        podman ps -a --filter "status=exited" --format "{{.ID}} {{.Image}} {{.Status}}"
    else
        log_ask "Prune exited containers before image cleanup? (y/N): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            podman container prune -f
            log_info "Exited containers pruned."
        else
            log_info "Container pruning skipped by user."
        fi
    fi
}

delete_dangling_images() {
    local ids
    ids=$(podman images -f "dangling=true" -q)

    if [[ -z "$ids" ]]; then
        log_info "No dangling images to delete."
        return
    fi

    log_info "Deleting $(echo "$ids" | wc -l | xargs) dangling image(s)..."
    start_spinner "Deleting dangling images"
    if ! echo "$ids" | xargs -r podman rmi; then
        stop_spinner
        log_warn "Some images could not be deleted. They may be in use by containers."
        return 3
    fi
    stop_spinner
    return 0
}

handle_containers_using_dangling_images() {
    log_info "Checking for containers using dangling images..."
    local dangling_ids used_containers

    dangling_ids=$(podman images -f "dangling=true" -q)

    if [[ -z "$dangling_ids" ]]; then
        log_info "No dangling image IDs found."
        return
    fi

    # Map container ID to image ID
    used_containers=""
    start_spinner "Inspecting containers"
    while read -r cid; do
        img_id=$(podman inspect --format '{{.ImageID}}' "$cid")
        if echo "$dangling_ids" | grep -q "$img_id"; then
            used_containers+="$cid $img_id"$'\n'
        fi
    done < <(podman ps -a -q)
    stop_spinner

    if [[ -z "$used_containers" ]]; then
        log_info "No containers are using dangling images."
        return
    fi

    log "Some containers are using dangling images:"
    echo "$used_containers" | while read -r cid img; do
        echo "  - Container ID: $cid | Image ID: $img"
    done

    if $DRY_RUN; then
        log_info "Dry run: Would remove these containers to unlock image deletion."
        return
    fi

    log_ask "Force remove these containers to unlock image deletion? (y/N): "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "$used_containers" | awk '{print $1}' | xargs -r podman rm -f
        log_info "Containers removed."
    else
        log_info "Container removal skipped by user."
    fi
}

# New unified images format (prevents splitting size "769 MB")
IMAGES_FORMAT='{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}'

# New: calculate total size for images in a repository (delimiter-safe)
calculate_total_size_by_repo() {
    local sizes total_bytes=0
    sizes=$(podman images --format "$IMAGES_FORMAT" | awk -F'|' -v r="$TARGET_REPO" '$1==r {print $4}')
    [[ -z "$sizes" ]] && { echo 0; return; }
    while read -r size; do
        bytes=$(convert_to_bytes "$size")
        total_bytes=$(awk "BEGIN {print $total_bytes + $bytes}")
    done <<< "$sizes"
    log_debug "Repo '$TARGET_REPO' total bytes=$total_bytes"
    echo "${total_bytes%.*}"
}

list_images_by_repo() {
    podman images --format "$IMAGES_FORMAT" | awk -F'|' -v r="$TARGET_REPO" '$1==r {printf "%s %s:%s %s\n",$3,$1,$2,$4}'
}

delete_images_by_repo() {
    local ids
    ids=$(podman images --format "$IMAGES_FORMAT" | awk -F'|' -v r="$TARGET_REPO" '$1==r {print $3}' | sort -u)
    [[ -z "$ids" ]] && { log "No images in repository '$TARGET_REPO' to delete."; return; }
    log_info "Deleting $(echo "$ids" | wc -l | xargs) image(s) in repository '$TARGET_REPO'..."
    start_spinner "Deleting repo images"
    if ! echo "$ids" | xargs -r podman rmi; then
        stop_spinner
        log_warn "Some repository images could not be deleted (possibly in use)."
        return 3
    fi
    stop_spinner
    return 0
}

# Revised: calculate total size for images matching a tag (across repositories) with delimiter
calculate_total_size_by_tag() {
    local sizes total_bytes=0
    sizes=$(podman images --format "$IMAGES_FORMAT" | awk -F'|' -v t="$TARGET_TAG" '$2==t {print $4}')
    [[ -z "$sizes" ]] && { echo 0; return; }
    while read -r size; do
        bytes=$(convert_to_bytes "$size")
        total_bytes=$(awk "BEGIN {print $total_bytes + $bytes}")
    done <<< "$sizes"
    log_debug "Tag '$TARGET_TAG' total bytes=$total_bytes"
    echo "${total_bytes%.*}"
}

list_images_by_tag() {
    podman images --format "$IMAGES_FORMAT" | awk -F'|' -v t="$TARGET_TAG" '$2==t {printf "%s %s:%s %s\n",$3,$1,$2,$4}'
}

delete_images_by_tag() {
    local ids
    ids=$(podman images --format "$IMAGES_FORMAT" | awk -F'|' -v t="$TARGET_TAG" '$2==t {print $3}' | sort -u)
    [[ -z "$ids" ]] && { log "No images with tag '$TARGET_TAG' to delete."; return; }
    log_info "Deleting $(echo "$ids" | wc -l | xargs) image(s) tagged '$TARGET_TAG'..."
    start_spinner "Deleting tagged images"
    if ! echo "$ids" | xargs -r podman rmi; then
        stop_spinner
        log_warn "Some tagged images could not be deleted (possibly in use)."
        return 3
    fi
    stop_spinner
    return 0
}

main() {
    # Repository mode
    if [[ -n "$TARGET_REPO" ]]; then
        log_info "Operating in repository mode for: '$TARGET_REPO'"
        total_bytes=$(calculate_total_size_by_repo)
        if (( total_bytes == 0 )); then
            log_info "No images found in repository '$TARGET_REPO'."
            exit 1
        fi
        human_size=$(format_human_size "$total_bytes")
        log_info "Total size of images in repository '$TARGET_REPO': $human_size"
        log_info "Images:"
        list_images_by_repo
        if $DRY_RUN; then
            log_info "Dry run: no deletions performed."
            exit 0
        fi
        log_ask "Delete all images in repository '$TARGET_REPO'? (y/N): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            if ! delete_images_by_repo; then
                exit 3
            fi
            exit 0
        else
            log_info "Deletion skipped by user."
            exit 2
        fi
    fi

    # Tag mode
    if [[ -n "$TARGET_TAG" ]]; then
        log_info "Operating in tag mode for tag: '$TARGET_TAG'"
        total_bytes=$(calculate_total_size_by_tag)
        if (( total_bytes == 0 )); then
            log_info "No images found with tag '$TARGET_TAG'."
            exit 1
        fi
        human_size=$(format_human_size "$total_bytes")
        log_info "Total size of images with tag '$TARGET_TAG': $human_size"
        log_info "Images:"
        list_images_by_tag
        if $DRY_RUN; then
            log_info "Dry run: no deletions performed."
            exit 0
        fi
        log_ask "Delete all images with tag '$TARGET_TAG'? (y/N): "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            if ! delete_images_by_tag; then
                exit 3
            fi
            exit 0
        else
            log_info "Deletion skipped by user."
            exit 2
        fi
    fi

    # Dangling mode
    log_info "Checking for dangling Podman images..."
    total_bytes=$(calculate_total_size)
    if (( total_bytes == 0 )); then
        log_info "No dangling images found."
        exit 1
    fi
    human_size=$(format_human_size "$total_bytes")
    log_info "Total size of dangling images: $human_size"
    log_info "Dangling images:"
    list_dangling_images

    prune_exited_containers

    handle_containers_using_dangling_images

    if $DRY_RUN; then
        log_info "Dry run enabled. No images will be deleted."
        exit 0
    fi
    log_ask "Do you want to delete dangling images? (y/N): "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if ! delete_dangling_images; then
            exit 3
        fi
        exit 0
    else
        log_info "Image cleanup skipped by user."
        exit 2
    fi
}
main
