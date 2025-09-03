#!/bin/bash

# Create apkovl for k3s-21

echo "Creating apkovl for k3s-21..."

cd apkovl-k3s-21

# Create the apkovl archive
tar -czf ../k3s-21.apkovl.tar.gz .

echo "Created k3s-21.apkovl.tar.gz"
echo "Copy this file to the boot partition of your SD card"
