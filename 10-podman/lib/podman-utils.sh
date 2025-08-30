#!/usr/bin/env bash
# Podman utility & action functions (require logging & spinner)

IMAGES_FORMAT='{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}'

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
  elif (( bytes < 1024*1024 )); then
    awk "BEGIN {printf \"%.2f kB\", $bytes/1024}"
  elif (( bytes < 1024*1024*1024 )); then
    awk "BEGIN {printf \"%.2f MB\", $bytes/(1024*1024)}"
  else
    awk "BEGIN {printf \"%.2f GB\", $bytes/(1024*1024*1024)}"
  fi
}

calculate_total_size() {
  local sizes total_bytes=0
  sizes=$(podman images -f dangling=true --format '{{.Size}}')
  [[ -z "$sizes" ]] && { echo 0; return; }
  while read -r s; do
    bytes=$(convert_to_bytes "$s")
    total_bytes=$(awk "BEGIN {print $total_bytes + $bytes}")
  done <<< "$sizes"
  log_debug "Summed dangling size bytes=$total_bytes"
  echo "${total_bytes%.*}"
}

calculate_total_size_by_repo() {
  local sizes total_bytes=0
  sizes=$(podman images --format "$IMAGES_FORMAT" | awk -F'|' -v r="$TARGET_REPO" '$1==r {print $4}')
  [[ -z "$sizes" ]] && { echo 0; return; }
  while read -r s; do
    bytes=$(convert_to_bytes "$s")
    total_bytes=$(awk "BEGIN {print $total_bytes + $bytes}")
  done <<< "$sizes"
  log_debug "Repo '$TARGET_REPO' total bytes=$total_bytes"
  echo "${total_bytes%.*}"
}

calculate_total_size_by_tag() {
  local sizes total_bytes=0
  sizes=$(podman images --format "$IMAGES_FORMAT" | awk -F'|' -v t="$TARGET_TAG" '$2==t {print $4}')
  [[ -z "$sizes" ]] && { echo 0; return; }
  while read -r s; do
    bytes=$(convert_to_bytes "$s")
    total_bytes=$(awk "BEGIN {print $total_bytes + $bytes}")
  done <<< "$sizes"
  log_debug "Tag '$TARGET_TAG' total bytes=$total_bytes"
  echo "${total_bytes%.*}"
}

list_dangling_images() {
  podman images -f dangling=true --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Size}}'
}

list_images_by_repo() {
  podman images --format "$IMAGES_FORMAT" | awk -F'|' -v r="$TARGET_REPO" '$1==r {printf "%s %s:%s %s\n",$3,$1,$2,$4}'
}

list_images_by_tag() {
  podman images --format "$IMAGES_FORMAT" | awk -F'|' -v t="$TARGET_TAG" '$2==t {printf "%s %s:%s %s\n",$3,$1,$2,$4}'
}

delete_dangling_images() {
  local ids
  ids=$(podman images -f dangling=true -q)
  [[ -z "$ids" ]] && { log_info "No dangling images to delete."; return 1; }
  log_info "Deleting $(echo "$ids" | wc -l | xargs) dangling image(s)..."
  start_spinner "Deleting dangling images"
  if ! echo "$ids" | xargs -r podman rmi; then
    stop_spinner
    log_warn "Some images could not be deleted. They may be in use."
    return 3
  fi
  stop_spinner
  return 0
}

delete_images_by_repo() {
  local ids
  ids=$(podman images --format "$IMAGES_FORMAT" | awk -F'|' -v r="$TARGET_REPO" '$1==r {print $3}' | sort -u)
  [[ -z "$ids" ]] && { log_info "No images in repository '$TARGET_REPO' to delete."; return 1; }
  log_info "Deleting $(echo "$ids" | wc -l | xargs) image(s) in repository '$TARGET_REPO'..."
  start_spinner "Deleting repo images"
  if ! echo "$ids" | xargs -r podman rmi; then
    stop_spinner
    log_warn "Some repository images could not be deleted."
    return 3
  fi
  stop_spinner
  return 0
}

delete_images_by_tag() {
  local ids
  ids=$(podman images --format "$IMAGES_FORMAT" | awk -F'|' -v t="$TARGET_TAG" '$2==t {print $3}' | sort -u)
  [[ -z "$ids" ]] && { log_info "No images with tag '$TARGET_TAG' to delete."; return 1; }
  log_info "Deleting $(echo "$ids" | wc -l | xargs) image(s) tagged '$TARGET_TAG'..."
  start_spinner "Deleting tagged images"
  if ! echo "$ids" | xargs -r podman rmi; then
    stop_spinner
    log_warn "Some tagged images could not be deleted."
    return 3
  fi
  stop_spinner
  return 0
}

prune_exited_containers() {
  log_info "Checking for exited containers..."
  local exited_ids
  exited_ids=$(podman ps -a --filter status=exited -q)
  [[ -z "$exited_ids" ]] && { log_info "No exited containers found."; return; }
  log_info "Found $(echo "$exited_ids" | wc -l | xargs) exited container(s)."
  if $DRY_RUN; then
    log_info "Dry run: Would prune exited containers:"
    podman ps -a --filter status=exited --format '{{.ID}} {{.Image}} {{.Status}}'
  else
    log_ask "Prune exited containers before image cleanup? (y/N): "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      podman container prune -f
      log_info "Exited containers pruned."
    else
      log_info "Container pruning skipped."
    fi
  fi
}

handle_containers_using_dangling_images() {
  log_info "Checking for containers using dangling images..."
  local dangling_ids used_containers cid img_id
  dangling_ids=$(podman images -f dangling=true -q)
  [[ -z "$dangling_ids" ]] && { log_info "No dangling image IDs found."; return; }
  used_containers=""
  start_spinner "Inspecting containers"
  while read -r cid; do
    img_id=$(podman inspect --format '{{.ImageID}}' "$cid")
    if echo "$dangling_ids" | grep -q "$img_id"; then
      used_containers+="$cid $img_id"$'\n'
    fi
  done < <(podman ps -a -q)
  stop_spinner
  [[ -z "$used_containers" ]] && { log_info "No containers are using dangling images."; return; }
  log_info "Some containers are using dangling images:"
  echo "$used_containers" | while read -r c i; do echo "  - Container: $c | Image: $i"; done
  if $DRY_RUN; then
    log_info "Dry run: Would remove these containers."
    return
  fi
  log_ask "Force remove these containers? (y/N): "
  read -r confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "$used_containers" | awk '{print $1}' | xargs -r podman rm -f
    log_info "Containers removed."
  else
    log_info "Container removal skipped."
  fi
}
