#!/bin/bash

# Alpine k3s Cluster Orchestrator
# Launches all nodes from qemu.yaml using socket networking
#
# Usage: ./test/launch-cluster.sh
#
# This script orchestrates qemu-test.sh to start all nodes:
# 1. Master starts first, waits 60s for k3s initialization
# 2. Workers start in parallel in background
# 3. All output logged to test/vm-multinode/{nodename}.log

set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
cd "$PROJECT_DIR"

# Configuration - always use qemu.yaml for socket networking cluster
# (Ignore inherited CONFIG_FILE from Makefile which defaults to k3s.yaml)
CONFIG_FILE="$PROJECT_DIR/qemu.yaml"
export CONFIG_FILE

# Source yaml parser
source lib/yaml-parser.sh

# Get nodes from config (format: name:ip:role)
NODES=()
while IFS=':' read -r name ip role; do
    [ -n "$name" ] && NODES+=("$name:$ip:$role")
done < <(yaml_get_nodes | grep -v '^$')

if [ ${#NODES[@]} -eq 0 ]; then
    echo "ERROR: No nodes found in $CONFIG_FILE"
    exit 1
fi

# Create log directory
VM_DIR="$TEST_DIR/qemu-cluster"
mkdir -p "$VM_DIR"

echo "============================================"
echo "Starting k3s cluster with ${#NODES[@]} node(s)"
echo "============================================"
echo "Config: $CONFIG_FILE"
echo "Logs: $VM_DIR/"
echo ""

# Validate apkovl files exist
for node in "${NODES[@]}"; do
    IFS=':' read -r name ip role <<< "$node"
    apkovl="$PROJECT_DIR/builds-qemu/${name}.apkovl.tar.gz"
    if [ ! -f "$apkovl" ]; then
        echo "ERROR: Overlay not found: $apkovl"
        echo "Run 'make build-test' first"
        exit 1
    fi
done

# Find and start master first
MASTER_STARTED=false
for node in "${NODES[@]}"; do
    IFS=':' read -r name ip role <<< "$node"
    if [ "$role" = "master" ]; then
        echo "Starting master: $name"
        "$TEST_DIR/qemu-test.sh" server > "$VM_DIR/${name}.log" 2>&1 &
        MASTER_PID=$!
        echo "  Master PID: $MASTER_PID"
        echo "  Log: $VM_DIR/${name}.log"
        echo ""
        MASTER_STARTED=true
        echo "Waiting 60 seconds for k3s to initialize..."
        sleep 60
        echo "Master initialization complete, starting workers..."
        echo ""
        break
    fi
done

if [ "$MASTER_STARTED" = false ]; then
    echo "ERROR: No master node found in config"
    exit 1
fi

# Start workers in parallel
WORKER_COUNT=0
for node in "${NODES[@]}"; do
    IFS=':' read -r name ip role <<< "$node"
    if [ "$role" != "master" ]; then
        echo "Starting worker: $name"
        "$TEST_DIR/qemu-test.sh" worker "$name" > "$VM_DIR/${name}.log" 2>&1 &
        WORKER_PID=$!
        echo "  Worker PID: $WORKER_PID"
        echo "  Log: $VM_DIR/${name}.log"
        WORKER_COUNT=$((WORKER_COUNT + 1))
    fi
done

echo ""
echo "============================================"
echo "Cluster started successfully"
echo "============================================"
echo "Master + $WORKER_COUNT worker(s) running in background"
echo ""
echo "Check status:  make qemu-cluster-status"
echo "View logs:     tail -f $VM_DIR/*.log"
echo "Stop cluster:  make qemu-cluster-stop"
echo ""
