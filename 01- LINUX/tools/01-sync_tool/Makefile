#!/usr/bin/env make

# Sync On Change - Cross-Platform Build System
.PHONY: help build build-all clean test install lint

# Default target
help:
	@echo "Sync On Change - Build System"
	@echo ""
	@echo "Targets:"
	@echo "  build      - Build for current platform"
	@echo "  build-all  - Build for all supported platforms"
	@echo "  clean      - Clean build artifacts"
	@echo "  test       - Test the Go binary"
	@echo "  install    - Install to /usr/local/bin (requires sudo)"
	@echo "  lint       - Run Go linting"
	@echo ""
	@echo "Implementations:"
	@echo "  make build-go     - Build Go version (recommended)"
	@echo "  make build-python - Build Python version"
	@echo ""

# Variables
PROJECT_ROOT := $(shell pwd)
SRC_GO := $(PROJECT_ROOT)/src/go
SRC_PYTHON := $(PROJECT_ROOT)/src/python
BIN_DIR := $(PROJECT_ROOT)/bin
CONFIG_DIR := $(PROJECT_ROOT)/config

# Go build targets
build: build-go
	@echo "✅ Build complete!"

build-go:
	@echo "Building Go version for current platform..."
	@cd $(SRC_GO) && go build -ldflags="-s -w" -o $(BIN_DIR)/sync_on_change .
	@chmod +x $(BIN_DIR)/sync_on_change

build-all:
	@echo "Building for all platforms..."
	@./scripts/build-all.sh

# Python build targets
build-python:
	@echo "Building Python version..."
	@cd $(SRC_PYTHON) && \
		source .venv/bin/activate && \
		pyinstaller --onefile --name sync_on_change sync_on_change.py && \
		mv dist/sync_on_change $(BIN_DIR)/sync_on_change-python

# Testing
test:
	@echo "Testing Go version..."
	@cd $(SRC_GO) && go test ./...
	@echo "Testing binary help..."
	@$(BIN_DIR)/sync_on_change -h

# Linting
lint:
	@echo "Running Go linting..."
	@cd $(SRC_GO) && go fmt ./...
	@cd $(SRC_GO) && go vet ./...

# Installation
install: build-go
	@echo "Installing to /usr/local/bin..."
	@sudo cp $(BIN_DIR)/sync_on_change /usr/local/bin/
	@sudo chmod +x /usr/local/bin/sync_on_change
	@echo "✅ Installed successfully!"
	@echo "Usage: sync_on_change -h"

# Clean up
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BIN_DIR)/sync_on_change*
	@rm -rf $(SRC_PYTHON)/build $(SRC_PYTHON)/dist $(SRC_PYTHON)/*.spec
	@echo "✅ Clean complete!"

# Development helpers
dev-setup:
	@echo "Setting up development environment..."
	@cd $(SRC_GO) && go mod tidy
	@echo "✅ Development setup complete!"

# Show binary sizes
size:
	@echo "Binary sizes:"
	@ls -lh $(BIN_DIR)/ | grep sync_on_change

# Package for distribution
package: build-all
	@echo "Creating distribution packages..."
	@mkdir -p dist
	@for binary in $(BIN_DIR)/sync_on_change-*; do \
		platform=$$(basename $$binary | sed 's/sync_on_change-//'); \
		echo "Packaging $$platform..."; \
		tar -czf dist/sync_on_change-$$platform.tar.gz \
			-C $(BIN_DIR) $$(basename $$binary) \
			-C $(CONFIG_DIR) sync_on_change.conf.example \
			-C $(PROJECT_ROOT) README.md LICENSE; \
	done
	@echo "✅ Distribution packages created in dist/"
