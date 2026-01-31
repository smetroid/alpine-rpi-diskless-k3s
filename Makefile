# Makefile for Alpine Linux Diskless k3s Cluster Setup
#
# Usage:
#   make build                  - Build apkovl archives from YAML config
#   make test                   - Run diskless boot simulation
#   make setup-sd DEVICE=/dev/sdX NODE=k3s-21  - Setup SD card
#   make clean                  - Remove build artifacts

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

.PHONY: help build validate clean clean-test clean-all setup-sd test test-boot test-prod test-logging \
        test-server test-worker test-cluster-status test-cluster-stop \
        build-test build-qemu template list-apkovl list-apkovl-prod list-apkovl-test show-config

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
	@echo "  make clean-test         Remove test build artifacts"
	@echo "  make clean-all          Remove all artifacts (production + test vm dirs)"
	@echo "  make template           Create partitioned disk template (saved to test/)"
	@echo "  make list-apkovl        List all apkovl archives (both)"
	@echo "  make list-apkovl-prod   List production apkovl archives"
	@echo "  make list-apkovl-test   List test apkovl archives"
	@echo ""
	@echo "Disk Targets:"
	@echo "  make setup-sd DEVICE=/dev/sdX NODE=k3s-21"
	@echo "                          Setup SD card for a specific node"
	@echo ""
	@echo "Test Targets (Single Node):"
	@echo "  make test               Run QEMU boot test with qemu.yaml"
	@echo "  make test-boot          Same as 'make test'"
	@echo "  make test-qemu          Build + boot with qemu.yaml"
	@echo "  make test-prod          Boot test with production config (k3s.yaml)"
	@echo "  make test-logging       Run logging tests"
	@echo ""
	@echo "Test Targets (Multi-Node Cluster):"
	@echo "  make test-server        Start k3s server VM (run first, in terminal 1)"
	@echo "  make test-worker NODE=k3s-22"
	@echo "                          Start worker VM (run after server, in terminal 2)"
	@echo "  make test-cluster-status  Show running test VMs"
	@echo "  make test-cluster-stop    Stop all test VMs"
	@echo ""
	@echo "QEMU Cluster (Socket Networking):"
	@echo "  make qemu-cluster       Start all nodes in background (socket networking)"
	@echo "  make qemu-cluster-status  Show running cluster VMs"
	@echo "  make qemu-cluster-stop    Stop all cluster VMs"
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

# =============================================================================
# Build Targets
# =============================================================================

# Build all apkovl archives from YAML configuration
build: validate
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

# Run full diskless boot simulation with QEMU
test: test-boot

# Boot test - uses qemu.yaml by default for QEMU testing
test-boot:
	@echo "Running Alpine diskless boot simulation with qemu.yaml..."
	./$(TEST_DIR)/test-alpine-diskless-boot.sh qemu.yaml

# Full QEMU test workflow - build and boot test config
test-qemu: build-test
	@echo "Running QEMU test boot..."
	./$(TEST_DIR)/test-alpine-diskless-boot.sh qemu.yaml

# Boot test with production config (for RPi hardware testing)
test-prod:
	@echo "Running Alpine diskless boot simulation with k3s.yaml..."
	./$(TEST_DIR)/test-alpine-diskless-boot.sh k3s.yaml

# Run logging tests
test-logging:
	@echo "Running logging tests..."
	./$(TEST_DIR)/test-logging.sh

# -----------------------------------------------------------------------------
# Multi-Node Cluster Testing
# -----------------------------------------------------------------------------

# Start k3s server (master) VM - run this first in terminal 1
test-server:
	@echo "Starting k3s server VM..."
	@echo "Wait for k3s to initialize (~2-3 min) before starting workers."
	./$(TEST_DIR)/test-multinode.sh server

# Start a worker VM - run this after server is ready, in a separate terminal
test-worker:
	@echo "Starting k3s worker VM: $(NODE)..."
	./$(TEST_DIR)/test-multinode.sh worker $(NODE)

# Show status of running test VMs
test-cluster-status:
	@./$(TEST_DIR)/test-multinode.sh status

# Stop all test VMs
test-cluster-stop:
	@./$(TEST_DIR)/test-multinode.sh stop all

# QEMU Cluster - Start all nodes with socket networking (VM-to-VM communication)
# Uses launch-cluster.sh which orchestrates test-multinode.sh
qemu-cluster: build-test
	@echo "Starting full k3s cluster with QEMU socket networking..."
	@echo ""
	./$(TEST_DIR)/launch-cluster.sh

# QEMU Cluster - Start specific node by index (1-based)
qemu-node: build-test
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make qemu-node NODE=<index>"; \
		echo "Example: make qemu-node NODE=1  # Start first node"; \
		exit 1; \
	fi
	./$(TEST_DIR)/test-alpine-cluster.sh qemu.yaml $(NODE)

# QEMU Cluster - Stop all running cluster VMs
qemu-cluster-stop:
	@./$(TEST_DIR)/test-multinode.sh stop all

# QEMU Cluster - Show status of cluster VMs
qemu-cluster-status:
	@./$(TEST_DIR)/test-multinode.sh status

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
clean-all: clean clean-test
	@echo "Removing qcow2 images and test artifacts..."
	rm -f builds/*.qcow2 builds/*.raw 2>/dev/null || true
	rm -f builds-qemu/*.qcow2 builds-qemu/*.raw 2>/dev/null || true
	rm -rf $(TEST_DIR)/vm-diskless
	rm -rf $(TEST_DIR)/vm-multinode
	rm -f $(TEST_DIR)/setup.log
	@echo "All artifacts cleaned."

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
