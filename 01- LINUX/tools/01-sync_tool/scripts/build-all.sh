#!/bin/bash
# Cross-platform build script for sync_on_change

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src/go"
BIN_DIR="$PROJECT_ROOT/bin"

echo "Building sync_on_change for multiple platforms..."

cd "$SRC_DIR"

# Ensure bin directory exists
mkdir -p "$BIN_DIR"

# Build for different platforms
echo "Building for Linux amd64..."
GOOS=linux GOARCH=amd64 go build -o "$BIN_DIR/sync_on_change-linux-amd64" .

echo "Building for Linux arm64..."
GOOS=linux GOARCH=arm64 go build -o "$BIN_DIR/sync_on_change-linux-arm64" .

echo "Building for macOS amd64..."
GOOS=darwin GOARCH=amd64 go build -o "$BIN_DIR/sync_on_change-darwin-amd64" .

echo "Building for macOS arm64 (Apple Silicon)..."
GOOS=darwin GOARCH=arm64 go build -o "$BIN_DIR/sync_on_change-darwin-arm64" .

echo "Building for Windows amd64..."
GOOS=windows GOARCH=amd64 go build -o "$BIN_DIR/sync_on_change-windows-amd64.exe" .

echo "Building for FreeBSD amd64..."
GOOS=freebsd GOARCH=amd64 go build -o "$BIN_DIR/sync_on_change-freebsd-amd64" .

echo ""
echo "✅ All builds completed successfully!"
echo ""
echo "Binaries created in $BIN_DIR:"
ls -la "$BIN_DIR"/sync_on_change-*

echo ""
echo "Platform detection script:"
echo "  Linux x64:     ./bin/sync_on_change-linux-amd64"
echo "  Linux ARM64:   ./bin/sync_on_change-linux-arm64"
echo "  macOS Intel:   ./bin/sync_on_change-darwin-amd64"
echo "  macOS Apple:   ./bin/sync_on_change-darwin-arm64"
echo "  Windows x64:   ./bin/sync_on_change-windows-amd64.exe"
echo "  FreeBSD x64:   ./bin/sync_on_change-freebsd-amd64"
