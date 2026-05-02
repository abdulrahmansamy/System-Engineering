#!/bin/bash

# Directory containing your Terraform files
TARGET_DIR="./terraform-configs"

# Function to add .txt extension to .tf files
add_txt_extension() {
  echo "🔧 Adding .txt extension to .tf files..."
  for file in "$TARGET_DIR"/*.tf; do
    [ -e "$file" ] || continue
    mv "$file" "$file.txt"
    echo "Renamed: $(basename "$file") → $(basename "$file.txt")"
  done
}

# Function to remove .txt extension from .tf.txt files
remove_txt_extension() {
  echo "🧹 Removing .txt extension from .tf.txt files..."
  for file in "$TARGET_DIR"/*.tf.txt; do
    [ -e "$file" ] || continue
    new_name="${file%.txt}"
    mv "$file" "$new_name"
    echo "Renamed: $(basename "$file") → $(basename "$new_name")"
  done
}

# Run the desired function
# Uncomment one of the following lines to execute

add_txt_extension
# remove_txt_extension
