#!/usr/bin/env bash

# Purpose: Cross-platform script to calculate and optionally delete dangling Podman images
# Flags:
#   --dry-run        Show what would be deleted without performing deletion
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

usage() {
    echo "Usage: $0 [--dry-run] [--repo REPOSITORY] [--tag TAG] [--silent | --verbose] [--log-file FILE]"
    echo "Run '$0 --help' for full help."
}

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
Usage: $0 [--dry-run] [--repo REPOSITORY] [--tag TAG] [--silent | --verbose] [--log-file FILE]

Modes (precedence):
  1. --repo REPOSITORY    Operate on images of a specific repository.
  2. --tag TAG            Operate on images whose tag equals TAG (all repositories).
  3. (default)            Operate on dangling images.

Logging:
  LOG_LEVEL env var accepted: ERROR,WARN,INFO,DEBUG (default INFO).
  --silent   => WARN level (errors & warnings only).
  --verbose  => DEBUG level (most detailed).
  --log-file FILE records all emitted log lines (unfiltered) for audit.

Convenience:
  If --tag VALUE contains '/' and no ':', it is treated as --repo VALUE.

Examples:
  $0 --repo localhost/myapp
  $0 --tag 1.4
  $0 --tag localhost/myapp   (interpreted as --repo localhost/myapp)
  $0 --dry-run --repo localhost/myapp
EOF
            exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

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
    echo "$ids" | xargs -r podman rmi || {
        stop_spinner
        log_warn "Some images could not be deleted. They may be in use by containers."
        return
    }
    stop_spinner
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
    echo "$ids" | xargs -r podman rmi || log_warn "Some repository images could not be deleted (possibly in use)."
    stop_spinner
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
    echo "$ids" | xargs -r podman rmi || log_warn "Some tagged images could not be deleted (possibly in use)."
    stop_spinner
}

main() {
    # Repository mode
    if [[ -n "$TARGET_REPO" ]]; then
        log_info "Operating in repository mode for: '$TARGET_REPO'"
        total_bytes=$(calculate_total_size_by_repo)
        if (( total_bytes == 0 )); then
            log_info "No images found in repository '$TARGET_REPO'."
            exit 0
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
            delete_images_by_repo
        else
            log_info "Deletion skipped by user."
        fi
        exit 0
    fi

    # Tag mode
    if [[ -n "$TARGET_TAG" ]]; then
        log_info "Operating in tag mode for tag: '$TARGET_TAG'"
        total_bytes=$(calculate_total_size_by_tag)
        if (( total_bytes == 0 )); then
            log_info "No images found with tag '$TARGET_TAG'."
            exit 0
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
            delete_images_by_tag
        else
            log_info "Deletion skipped by user."
        fi
        exit 0
    fi

    log_info "Checking for dangling Podman images..."
    total_bytes=$(calculate_total_size)

    if (( total_bytes == 0 )); then
        log_info "No dangling images found."
        exit 0
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
        delete_dangling_images
    else
        log_info "Image cleanup skipped by user."
    fi
}

main
    fi
}

main
