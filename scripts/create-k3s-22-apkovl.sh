#!/bin/bash

# Create apkovl for k3s-22

echo "Creating apkovl for k3s-22..."

cd apkovl-k3s-22

# Create the apkovl archive
tar -czf ../k3s-22.apkovl.tar.gz .

echo "Created k3s-22.apkovl.tar.gz"
echo "Copy this file to the boot partition of your SD card"
