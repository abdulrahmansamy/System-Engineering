#!/bin/bash

# Validate arguments
if [ $# -ne 2 ]; then
  echo "❌ Usage: $0 [add|remove] [target_directory]"
  exit 1
fi

ACTION="$1"
TARGET_DIR="$2"

# Check if directory exists
if [ ! -d "$TARGET_DIR" ]; then
  echo "🚫 Directory not found: $TARGET_DIR"
  exit 1
fi

add_txt_extension() {
  echo "🔧 Adding .txt extension to .tf files in $TARGET_DIR..."
  for file in "$TARGET_DIR"/*.tf; do
    [ -e "$file" ] || continue
    mv "$file" "$file.txt"
    echo "Renamed: $(basename "$file") → $(basename "$file.txt")"
  done
}

remove_txt_extension() {
  echo "🧹 Removing .txt extension from .tf.txt files in $TARGET_DIR..."
  for file in "$TARGET_DIR"/*.tf.txt; do
    [ -e "$file" ] || continue
    new_name="${file%.txt}"
    mv "$file" "$new_name"
    echo "Renamed: $(basename "$file") → $(basename "$new_name")"
  done
}

# Execute based on action
case "$ACTION" in
  add)
    add_txt_extension
    ;;
  remove)
    remove_txt_extension
    ;;
  *)
    echo "❌ Invalid action: $ACTION. Use 'add' or 'remove'."
    exit 1
    ;;
esac
