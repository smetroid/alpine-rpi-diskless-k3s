# Makefile for Alpine Linux Diskless k3s Cluster Setup
#
# Usage:
#   make build                  - Build apkovl archives from YAML config
#   make test                   - Run diskless boot simulation
#   make setup-sd DEVICE=/dev/sdX NODE=k3s-21  - Setup SD card
#   make clean                  - Remove build artifacts

# Configuration
CONFIG ?= k3s.yaml
BUILD_DIR := builds
SCRIPTS_DIR := scripts
TEST_DIR := test

# Export CONFIG_FILE for scripts (they check env var before arguments)
export CONFIG_FILE := $(CONFIG)

# Default node (first node in config)
NODE ?= k3s-21

# Detect OS for platform-specific commands
UNAME := $(shell uname)

.PHONY: help build validate clean setup-sd test test-boot test-logging \
        test-server test-worker test-cluster-status test-cluster-stop

# Default target
help:
	@echo "Alpine Linux Diskless k3s Cluster - Build System"
	@echo ""
	@echo "Build Targets:"
	@echo "  make build              Build all apkovl archives from YAML config"
	@echo "  make validate           Validate YAML configuration"
	@echo "  make clean              Remove all build artifacts"
	@echo ""
	@echo "Disk Targets:"
	@echo "  make setup-sd DEVICE=/dev/sdX NODE=k3s-21"
	@echo "                          Setup SD card for a specific node"
	@echo ""
	@echo "Test Targets (Single Node):"
	@echo "  make test               Run single-node diskless boot simulation"
	@echo "  make test-boot          Alias for 'make test'"
	@echo "  make test-logging       Run logging tests"
	@echo ""
	@echo "Test Targets (Multi-Node Cluster):"
	@echo "  make test-server        Start k3s server VM (run first, in terminal 1)"
	@echo "  make test-worker NODE=k3s-22"
	@echo "                          Start worker VM (run after server, in terminal 2)"
	@echo "  make test-cluster-status  Show running test VMs"
	@echo "  make test-cluster-stop    Stop all test VMs"
	@echo ""
	@echo "Configuration:"
	@echo "  CONFIG=<file>           YAML config file (default: k3s.yaml)"
	@echo "  NODE=<name>             Node name for SD card operations (default: k3s-21)"
	@echo "  DEVICE=<path>           Block device for SD card setup"
	@echo ""
	@echo "Examples:"
	@echo "  make build CONFIG=my-cluster.yaml"
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

test-boot:
	@echo "Running Alpine diskless boot simulation..."
	./$(TEST_DIR)/test-alpine-diskless-boot.sh

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

# =============================================================================
# Clean Targets
# =============================================================================

# Remove all build artifacts
clean:
	@echo "Cleaning build directory..."
	rm -rf $(BUILD_DIR)/*-apkovl
	rm -f $(BUILD_DIR)/*.apkovl.tar.gz
	rm -rf $(BUILD_DIR)/k3s-manifests
	rm -f $(BUILD_DIR)/k3s-token.txt
	@echo "Build artifacts cleaned."

# Deep clean - also removes qcow2 images and test artifacts
clean-all: clean
	@echo "Removing qcow2 images and test artifacts..."
	rm -f $(BUILD_DIR)/*.qcow2
	rm -f $(BUILD_DIR)/*.raw
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
	@echo "  BUILD_DIR: $(BUILD_DIR)"
	@cat $(CONFIG)

# List available apkovl archives
list-apkovl:
	@echo "Available apkovl archives:"
	@ls -la $(BUILD_DIR)/*.apkovl.tar.gz 2>/dev/null || echo "  No archives found. Run 'make build' first."

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
