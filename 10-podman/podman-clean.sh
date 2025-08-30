#!/usr/bin/env bash
set -euo pipefail

# Exit codes:
# 0 success | 1 no images found | 2 user aborted | 3 deletion failed

DRY_RUN=false
TARGET_TAG=""
TARGET_REPO=""
CLI_LOG_LEVEL=""
LOG_FILE=""
SUBCOMMAND=""

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source libraries
# shellcheck source=lib/logging.sh
. "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=lib/spinner.sh
. "$SCRIPT_DIR/lib/spinner.sh"
# shellcheck source=lib/podman-utils.sh
. "$SCRIPT_DIR/lib/podman-utils.sh"

usage() {
  echo "Usage:"
  echo "  $0 repo <REPOSITORY>   [--dry-run] [--silent | --verbose] [--log-file FILE]"
  echo "  $0 tag <TAG>           [--dry-run] [--silent | --verbose] [--log-file FILE]"
  echo "  $0 dangling            [--dry-run] [--silent | --verbose] [--log-file FILE]"
  echo "  $0 completion [bash|zsh]   # print shell completion script"
  echo "  (legacy) $0 --repo REPOSITORY | --tag TAG [other flags]"
  echo "Exit codes: 0=success 1=no-images 2=user-aborted 3=deletion-failed"
}

# Pre-parse subcommand
if [[ $# -gt 0 ]]; then
  case "$1" in
    repo)
      SUBCOMMAND=repo; shift
      [[ $# -gt 0 && "$1" != --* ]] || { echo "[ERROR] Missing repository after 'repo'" >&2; usage >&2; exit 1; }
      TARGET_REPO="$1"; shift ;;
    tag)
      SUBCOMMAND=tag; shift
      [[ $# -gt 0 && "$1" != --* ]] || { echo "[ERROR] Missing tag after 'tag'" >&2; usage >&2; exit 1; }
      TARGET_TAG="$1"; shift ;;
    dangling)
      SUBCOMMAND=dangling; shift ;;
    help|-h|--help)
      usage; echo; print_detailed_help; exit 0 ;;
    completion)
      SUBCOMMAND=completion; shift ;;
    *) : ;;
  esac
fi

# Flag parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --tag) [[ -z "${2:-}" ]] && { echo "[ERROR] --tag requires value" >&2; exit 1; }; TARGET_TAG="$2"; shift 2 ;;
    --tag=*) TARGET_TAG="${1#*=}"; shift ;;
    --repo) [[ -z "${2:-}" ]] && { echo "[ERROR] --repo requires value" >&2; exit 1; }; TARGET_REPO="$2"; shift 2 ;;
    --repo=*) TARGET_REPO="${1#*=}"; shift ;;
    --silent) [[ -n "$CLI_LOG_LEVEL" ]] && { echo "[ERROR] Multiple verbosity flags" >&2; exit 1; }; CLI_LOG_LEVEL="WARN"; shift ;;
    --verbose) [[ -n "$CLI_LOG_LEVEL" ]] && { echo "[ERROR] Multiple verbosity flags" >&2; exit 1; }; CLI_LOG_LEVEL="DEBUG"; shift ;;
    --log-file) [[ -z "${2:-}" ]] && { echo "[ERROR] --log-file requires path" >&2; exit 1; }; LOG_FILE="$2"; shift 2 ;;
    --log-file=*) LOG_FILE="${1#*=}"; shift ;;
    -h|--help) usage; echo; print_detailed_help; exit 0 ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Conflict validation
if [[ "$SUBCOMMAND" == "repo" && -n "$TARGET_TAG" ]]; then echo "[ERROR] Cannot mix 'repo' subcommand with tag flags" >&2; exit 1; fi
if [[ "$SUBCOMMAND" == "tag" && -n "$TARGET_REPO" ]]; then echo "[ERROR] Cannot mix 'tag' subcommand with repo flags" >&2; exit 1; fi

# Interpret tag-as-repo heuristic
if [[ -n "$TARGET_TAG" && -z "$TARGET_REPO" && "$TARGET_TAG" == */* && "$TARGET_TAG" != *":"* ]]; then
  TARGET_REPO="$TARGET_TAG"; TARGET_TAG=""
fi

# Initialize logging & spinner
logging_init "$CLI_LOG_LEVEL" "$LOG_FILE"
spinner_init

# ---------------- Main workflow ----------------
# Completion subcommand
if [[ "$SUBCOMMAND" == "completion" ]]; then
  # Optional shell argument (defaults to bash style; works for zsh via bashcompinit)
  REQ_SHELL="${1:-bash}"
  cat <<'COMPLETE_EOF'
# podman-clean completion (bash/zsh via bashcompinit)
_podman_clean()
{
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  local subcommands="repo tag dangling completion help"
  local flags="--dry-run --silent --verbose --log-file --repo --tag --help -h"

  # First position: suggest subcommands & flags
  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "${subcommands} ${flags}" -- "$cur") )
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    repo)
      if (( COMP_CWORD == 2 )); then
        local repos
        repos=$(podman images --format '{{.Repository}}' 2>/dev/null | sort -u)
        COMPREPLY=( $(compgen -W "${repos}" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "${flags}" -- "$cur") )
      fi
      ;;
    tag)
      if (( COMP_CWORD == 2 )); then
        local tags
        tags=$(podman images --format '{{.Tag}}' 2>/dev/null | sort -u)
        COMPREPLY=( $(compgen -W "${tags}" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "${flags}" -- "$cur") )
      fi
      ;;
    dangling|completion|help)
      COMPREPLY=( $(compgen -W "${flags}" -- "$cur") )
      ;;
    *)
      COMPREPLY=( $(compgen -W "${subcommands} ${flags}" -- "$cur") )
      ;;
  esac
  return 0
}
complete -F _podman_clean podman-clean podman-clean.sh

# zsh support (enable bash completions)
if [[ -n "${ZSH_VERSION:-}" ]]; then
  autoload -Uz compinit bashcompinit 2>/dev/null || true
  compinit 2>/dev/null || true
  bashcompinit 2>/dev/null || true
fi
COMPLETE_EOF
  exit 0
fi

# Repo mode
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
    if ! delete_images_by_repo; then exit 3; fi
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
    if ! delete_images_by_tag; then exit 3; fi
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
  if ! delete_dangling_images; then exit 3; fi
  exit 0
else
  log_info "Image cleanup skipped by user."
  exit 2
fi
