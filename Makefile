# Makefile for Alpine Linux Diskless k3s Cluster Setup
#
# Usage:
#   make build                  - Build apkovl archives from YAML config
#   make test                   - Run diskless boot simulation
#   make setup-sd DEVICE=/dev/sdX NODE=k3s-21  - Setup SD card
#   make clean                  - Remove build artifacts

# Ensure Homebrew bin is in PATH (macOS)
export PATH := /opt/homebrew/bin:$(PATH)

# Configuration
CONFIG ?= k3s.yaml
SCRIPTS_DIR := scripts
TEST_DIR := test

# Export CONFIG_FILE for scripts (they check env var before arguments)
# Build directory is auto-detected by scripts based on config basename:
#   - builds/         for k3s.yaml, cluster-*.yaml
#   - builds-qemu/    for qemu.yaml, *-test.yaml, *-qemu.yaml
export CONFIG_FILE := $(CONFIG)

# Default node (first node in config)
NODE ?= k3s-21

# Detect OS for platform-specific commands
UNAME := $(shell uname)

# gomplate template engine (auto-downloaded, no manual install needed)
GOMPLATE_VERSION := v3.11.7
GOMPLATE_OS      := $(shell uname -s | tr '[:upper:]' '[:lower:]')
GOMPLATE_ARCH    := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
GOMPLATE_BIN     := $(CURDIR)/.local/bin/gomplate
GOMPLATE_URL     := https://github.com/hairyhenderson/gomplate/releases/download/$(GOMPLATE_VERSION)/gomplate_$(GOMPLATE_OS)-$(GOMPLATE_ARCH)
TEMPLATES_DIR    := $(CURDIR)/templates
export GOMPLATE_BIN
export TEMPLATES_DIR

.PHONY: help build validate clean clean-cache clean-test clean-all setup-sd test test-prod \
        test-server test-worker test-cluster-status test-cluster-stop \
        qemu-cluster test-qemu \
        build-test template list-apkovl list-apkovl-prod list-apkovl-test show-config cache-stats \
        lint format shellcheck-shfmt \
        install-deps install-hooks backup verify

# Default target
help:
	@echo "Alpine Linux Diskless k3s Cluster - Build System"
	@echo ""
	@echo "Build Targets:"
	@echo "  make build              Build all apkovl archives from YAML config (production)"
	@echo "  make build-test         Build test apkovl archives from qemu.yaml"
	@echo "  make template           Create partitioned disk template for QEMU testing"
	@echo "  make validate           Validate YAML configuration"
	@echo "  make clean              Remove production build artifacts"
	@echo "  make clean-cache        Remove download cache (.cache/)"
	@echo "  make clean-test         Remove test build artifacts"
	@echo "  make clean-all          Remove all artifacts (production + test + cache + vm dirs)"
	@echo "  make cache-stats        Show cache statistics"
	@echo "  make list-apkovl        List all apkovl archives (both)"
	@echo "  make list-apkovl-prod   List production apkovl archives"
	@echo "  make list-apkovl-test   List test apkovl archives"
	@echo ""
	@echo "Disk Targets:"
	@echo "  make setup-sd DEVICE=/dev/sdX NODE=k3s-21"
	@echo "                          Setup SD card for a specific node"
	@echo ""
	@echo "Test Targets (QEMU Testing):"
	@echo "  make test               Show qemu-test.sh usage"
	@echo "  make test-server        Start k3s server VM (run first, in terminal 1)"
	@echo "  make test-worker NODE=qemu-2"
	@echo "                          Start worker VM (run after server, in terminal 2)"
	@echo "  make test-cluster-status  Show running test VMs"
	@echo "  make test-cluster-stop    Stop all test VMs"
	@echo "  make test-qemu          Build + boot with qemu.yaml (single node)"
	@echo "  make test-prod          Boot test with production config (k3s.yaml)"
	@echo ""
	@echo "Configuration:"
	@echo "  CONFIG=<file>           YAML config file (default: k3s.yaml)"
	@echo "  NODE=<name>             Node name for SD card operations (default: k3s-21)"
	@echo "  DEVICE=<path>           Block device for SD card setup"
	@echo ""
	@echo "Examples:"
	@echo "  make build CONFIG=my-cluster.yaml"
	@echo "  make build-test          # Build QEMU test config"
	@echo "  make test-qemu           # Full QEMU test workflow"
	@echo "  make setup-sd DEVICE=/dev/disk4 NODE=k3s-21"
	@echo ""
	@echo "Lint Targets:"
	@echo "  make lint                Run shellcheck and check formatting"
	@echo "  make shellcheck-shfmt     Run shellcheck on all shell scripts"
	@echo "  make format              Format shell scripts with shfmt"
	@echo ""
	@echo "Template / Verification Targets:"
	@echo "  make install-deps        Download gomplate binary to .local/bin/"
	@echo "  make install-hooks       Install gitleaks pre-commit hook"
	@echo "  make backup              Snapshot current builds/ as reference baseline"
	@echo "  make verify              Diff new builds against reference (excludes machine-id, SSH keys)"

# =============================================================================
# Build Targets
# =============================================================================

# Build all apkovl archives from YAML configuration
build: validate | $(GOMPLATE_BIN)
	@echo "Building apkovl archives from $(CONFIG)..."
	./$(SCRIPTS_DIR)/build-from-yaml.sh $(CONFIG)

# Validate YAML configuration
validate:
	@echo "Validating configuration: $(CONFIG)..."
	./$(SCRIPTS_DIR)/validate-config.sh $(CONFIG)

# Individual build steps (for debugging)
build-apkovl:
	./$(SCRIPTS_DIR)/create-apkovl-yaml.sh $(CONFIG)

build-k3s:
	./$(SCRIPTS_DIR)/setup-k3s-yaml.sh $(CONFIG)

build-manifests:
	./$(SCRIPTS_DIR)/generate-manifests-yaml.sh $(CONFIG)

build-archives:
	./$(SCRIPTS_DIR)/create-apkovl-archives.sh $(CONFIG)

# Build test configuration (qemu.yaml)
build-test:
	@echo "Building test apkovl archives from qemu.yaml..."
	./$(SCRIPTS_DIR)/build-from-yaml.sh qemu.yaml

# Create partitioned disk template for QEMU testing
# This creates data-partitioned-template.qcow2 with pre-formatted partitions
template:
	@echo "Creating partitioned disk template for QEMU testing..."
	@./$(SCRIPTS_DIR)/create-qemu-template.sh

# =============================================================================
# Disk Targets
# =============================================================================

# Setup SD card - requires DEVICE variable
setup-sd:
ifndef DEVICE
	$(error DEVICE is required. Usage: make setup-sd DEVICE=/dev/sdX NODE=k3s-21)
endif
	@echo "Setting up SD card on $(DEVICE) for node $(NODE)..."
	@echo "WARNING: This will FORMAT $(DEVICE)!"
	sudo ./$(SCRIPTS_DIR)/setup-bootable-device.sh $(DEVICE) $(CONFIG) $(NODE)

# =============================================================================
# Test Targets
# =============================================================================
# Test Targets
# =============================================================================

# Show QEMU test usage (directs to qemu-test.sh)
test:
	@echo "QEMU Test Script"
	@echo "================="
	@echo ""
	@echo "Usage:"
	@echo "  ./test/qemu-test.sh server              # Boot master node"
	@echo "  ./test/qemu-test.sh worker <node-name>  # Boot worker node"
	@echo "  ./test/qemu-test.sh status              # Show running VMs"
	@echo "  ./test/qemu-test.sh stop [all]          # Stop VM(s)"
	@echo ""
	@echo "Make targets:"
	@echo "  make test-server              Boot server (master) VM"
	@echo "  make test-worker NODE=<name>   Boot worker VM"
	@echo "  make test-cluster-status       Show running VMs"
	@echo "  make test-cluster-stop         Stop all VMs"
	@echo ""

# Full QEMU test workflow - build and boot test config (single node for quick testing)
test-qemu: build-test
	@echo "Running single-node QEMU test..."
	CONFIG_FILE=qemu.yaml ./$(TEST_DIR)/qemu-test.sh server

# Boot test with production config (for RPi hardware testing)
test-prod:
	@echo "Running QEMU test with production config..."
	CONFIG_FILE=k3s.yaml ./$(TEST_DIR)/qemu-test.sh server

# -----------------------------------------------------------------------------
# Multi-Node Cluster Testing
# -----------------------------------------------------------------------------

# Start k3s server (master) VM - run this first in terminal 1
test-server:
	@echo "Starting k3s server VM..."
	@echo "Wait for k3s to initialize (~2-3 min) before starting workers."
	./$(TEST_DIR)/qemu-test.sh server

# Start a worker VM - run this after server is ready, in a separate terminal
test-worker:
	@echo "Starting k3s worker VM: $(NODE)..."
	./$(TEST_DIR)/qemu-test.sh worker $(NODE)

# Show status of running test VMs
test-cluster-status:
	@./$(TEST_DIR)/qemu-test.sh status

# Stop all test VMs
test-cluster-stop:
	@./$(TEST_DIR)/qemu-test.sh stop all

# QEMU Cluster - Start all nodes with socket networking (VM-to-VM communication)
# Uses launch-qemu-cluster.sh which orchestrates qemu-test.sh
qemu-cluster: build-test
	@echo "Starting full k3s cluster with QEMU socket networking..."
	@echo ""
	./$(TEST_DIR)/launch-qemu-cluster.sh

# =============================================================================
# Clean Targets
# =============================================================================

# Remove all build artifacts
clean:
	@echo "Cleaning production build directory..."
	rm -rf builds/*-apkovl
	rm -f builds/*.apkovl.tar.gz
	rm -rf builds/k3s-manifests
	rm -f builds/k3s-token.txt
	@echo "Production build artifacts cleaned."

# Remove test build artifacts only
clean-test:
	@echo "Cleaning test build directory..."
	rm -rf builds-qemu/*-apkovl
	rm -f builds-qemu/*.apkovl.tar.gz
	rm -rf builds-qemu/k3s-manifests
	rm -f builds-qemu/k3s-token.txt
	@echo "Test build artifacts cleaned."

# Deep clean - also removes qcow2 images and test artifacts
clean-all: clean clean-cache clean-test
	@echo "Removing qcow2 images and test artifacts..."
	rm -f builds/*.qcow2 builds/*.raw 2>/dev/null || true
	rm -f builds-qemu/*.qcow2 builds-qemu/*.raw 2>/dev/null || true
	rm -rf $(TEST_DIR)/qemu-cluster
	@echo "All artifacts cleaned."

# Clean cache directory
clean-cache:
	@echo "Cleaning cache directory..."
	@if [ -d ".cache" ]; then \
		rm -rf .cache; \
		echo "Cache cleared."; \
	else \
		echo "No cache to clean."; \
	fi

# Show cache statistics
cache-stats:
	@if [ -f "lib/cache.sh" ]; then \
		. ./lib/cache.sh && cache_stats; \
	else \
		echo "Cache library not found."; \
	fi

# =============================================================================
# Development Helpers
# =============================================================================

# Show current configuration
show-config:
	@echo "Current configuration:"
	@echo "  CONFIG: $(CONFIG)"
	@echo "  NODE: $(NODE)"
	@echo "  Build directory: auto-detected from config basename"
	@cat $(CONFIG)

# List available apkovl archives (both production and test)
list-apkovl:
	@echo "Production apkovl archives (builds/):"
	@ls -la builds/*.apkovl.tar.gz 2>/dev/null || echo "  No production archives found. Run 'make build' first."
	@echo ""
	@echo "Test apkovl archives (builds-qemu/):"
	@ls -la builds-qemu/*.apkovl.tar.gz 2>/dev/null || echo "  No test archives found. Run 'make build-test' first."

# List production apkovl archives only
list-apkovl-prod:
	@echo "Production apkovl archives (builds/):"
	@ls -la builds/*.apkovl.tar.gz 2>/dev/null || echo "  No production archives found. Run 'make build' first."

# List test apkovl archives only
list-apkovl-test:
	@echo "Test apkovl archives (builds-qemu/):"
	@ls -la builds-qemu/*.apkovl.tar.gz 2>/dev/null || echo "  No test archives found. Run 'make build-test' first."

# List nodes from config (requires yq or python)
list-nodes:
	@echo "Nodes defined in $(CONFIG):"
	@if command -v yq >/dev/null 2>&1; then \
		yq '.nodes[].name' $(CONFIG); \
	elif command -v python3 >/dev/null 2>&1; then \
		python3 -c "import yaml; [print('  ' + n['name']) for n in yaml.safe_load(open('$(CONFIG)'))['nodes']]"; \
	else \
		echo "  Install yq or python3 to list nodes"; \
	fi

# =============================================================================
# Lint and Format Targets
# =============================================================================

# Run shellcheck on all shell scripts
shellcheck-shfmt:
	@echo "Running ShellCheck..."
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh lib/*.sh || true; \
	else \
		echo "ShellCheck not installed. Install with: brew install shellcheck (macOS) or apt install shellcheck (Linux)"; \
	fi

# Format shell scripts with shfmt
format:
	@echo "Formatting shell scripts with shfmt..."
	@if command -v shfmt >/dev/null 2>&1; then \
		shfmt -w scripts/*.sh lib/*.sh; \
	else \
		echo "shfmt not installed. Install with: go install mvdan.cc/sh/v3/cmd/shfmt@latest"; \
	fi

# Install gitleaks pre-commit hook (configures git to use .githooks/)
install-hooks:
	@echo "Installing git hooks from .githooks/..."
	@git config core.hooksPath .githooks
	@echo "✓ Hooks configured. Running pre-commit check..."
	@if command -v gitleaks >/dev/null 2>&1; then \
		echo "  gitleaks is installed"; \
	else \
		echo "  Install gitleaks: brew install gitleaks (macOS) or go install github.com/gitleaks/gitleaks/v8/cmd/gitleaks@latest"; \
	fi
	@chmod +x .githooks/*

lint: shellcheck-shfmt
	@echo ""
	@echo "Checking script formatting..."
	@if command -v shfmt >/dev/null 2>&1; then \
		shfmt -d scripts/*.sh lib/*.sh; \
	else \
		echo "shfmt not installed for formatting check"; \
	fi

# =============================================================================
# Gomplate (template engine auto-download)
# =============================================================================

$(GOMPLATE_BIN):
	@mkdir -p .local/bin
	@echo "Downloading gomplate $(GOMPLATE_VERSION) for $(GOMPLATE_OS)/$(GOMPLATE_ARCH)..."
	@curl -fsSL "$(GOMPLATE_URL)" -o $@
	@chmod +x $@
	@echo "gomplate ready: $@"

install-deps: $(GOMPLATE_BIN)
	@echo "All dependencies installed."

# =============================================================================
# Backup and Verify Targets
# =============================================================================

# Snapshot current build outputs as a reference baseline before converting to templates.
# Run this once before starting template conversion, then use 'make verify' to check results.
backup:
	@echo "Creating reference backup of build outputs..."
	@if [ -d builds ] && [ "$$(ls -A builds/ 2>/dev/null)" ]; then \
		rm -rf builds-reference; \
		cp -a builds builds-reference; \
		echo "  ✓ builds/ → builds-reference/"; \
	else \
		echo "  No builds/ content to backup. Run 'make build' first."; \
	fi
	@if [ -d builds-qemu ] && [ "$$(ls -A builds-qemu/ 2>/dev/null)" ]; then \
		rm -rf builds-qemu-reference; \
		cp -a builds-qemu builds-qemu-reference; \
		echo "  ✓ builds-qemu/ → builds-qemu-reference/"; \
	fi
	@echo "Backup complete. Run 'make verify' after rebuilding to compare."

# Compare new build output against the reference backup.
# Excludes non-deterministic files: machine-id, cluster SSH keys, authorized_keys.
verify:
	@echo "Comparing new builds against reference..."
	@if [ ! -d builds-reference ]; then \
		echo "No reference backup found. Run 'make backup' first."; \
		exit 1; \
	fi
	@FAILED=0; \
	for ref_dir in builds-reference/*-apkovl; do \
		node_dir=$$(basename $$ref_dir); \
		new_dir="builds/$$node_dir"; \
		if [ ! -d "$$new_dir" ]; then \
			echo "  MISSING: $$new_dir"; \
			FAILED=1; \
			continue; \
		fi; \
		echo "  Checking $$node_dir/etc/ ..."; \
		if diff -rq \
			--exclude="machine-id" \
			--exclude="cluster_id_rsa*" \
			--exclude="authorized_keys" \
			--exclude="system-bootstrap" \
			"$$ref_dir/etc" "$$new_dir/etc" >/dev/null 2>&1; then \
			echo "    ✓ etc/ matches reference"; \
		else \
			echo "    ✗ etc/ DIFFERS from reference:"; \
			diff -r \
				--exclude="machine-id" \
				--exclude="cluster_id_rsa*" \
				--exclude="authorized_keys" \
				--exclude="system-bootstrap" \
				"$$ref_dir/etc" "$$new_dir/etc" 2>/dev/null || true; \
			FAILED=1; \
		fi; \
	done; \
	if [ "$$FAILED" -eq 0 ]; then \
		echo ""; \
		echo "✅ All comparable files match the reference!"; \
	else \
		echo ""; \
		echo "❌ Some files differ - review diffs above."; \
		exit 1; \
	fi
