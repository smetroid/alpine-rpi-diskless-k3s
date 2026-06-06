#!/bin/bash

# Cache library for Alpine k3s diskless build system
# Provides persistent caching for downloaded packages and binaries

# Detect project root (parent of lib/ directory)
# Use absolute path to ensure cache is always in the same location
CACHE_ROOT="${CACHE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.cache}"
export CACHE_ROOT

# Get the root cache directory
cache_root() {
    echo "$CACHE_ROOT"
}

# Get a specific cache subdirectory
cache_dir() {
    local subdir="$1"
    local root
    root=$(cache_root)
    local cache_path="${root}/${subdir}"

    # Create cache directory if it doesn't exist
    if [ ! -d "$cache_path" ]; then
        mkdir -p "$cache_path"
    fi

    echo "$cache_path"
}

# Check if a file exists in cache
# Returns 0 if found, 1 if not found
# Usage: cache_get subdir filename output_dest
cache_get() {
    local subdir="$1"
    local filename="$2"
    local dest="$3"

    local cache_path
    cache_path=$(cache_dir "$subdir")
    local cached_file="${cache_path}/${filename}"

    if [ -f "$cached_file" ]; then
        # Verify file is not empty (corrupted cache)
        if [ -s "$cached_file" ]; then
            echo "📦 Using cached: ${filename}"
            cp "$cached_file" "$dest"
            return 0
        else
            echo "⚠️  Cached file is empty, re-downloading: ${filename}"
            rm -f "$cached_file"
            return 1
        fi
    fi

    return 1
}

# Put a file into cache
# Usage: cache_put subdir filename source
cache_put() {
    local subdir="$1"
    local filename="$2"
    local source="$3"

    local cache_path
    cache_path=$(cache_dir "$subdir")
    local cached_file="${cache_path}/${filename}"

    # Create cache directory including nested subdirectories if needed
    local cached_dir
    cached_dir=$(dirname "$cached_file")
    mkdir -p "$cached_dir"

    # Copy to cache
    if cp "$source" "$cached_file" 2>/dev/null; then
        echo "💾 Cached: ${filename}"
        return 0
    else
        echo "⚠️  Failed to cache: ${filename}"
        return 1
    fi
}

# Clear all cache or a specific subdirectory
# Usage: cache_clear [subdir]
cache_clear() {
    local subdir="$1"

    local root
    root=$(cache_root)

    if [ -z "$subdir" ]; then
        # Clear entire cache
        if [ -d "$root" ]; then
            echo "🗑️  Clearing cache directory: ${root}"
            rm -rf "${root}"
            echo "✓ Cache cleared"
        else
            echo "No cache to clear"
        fi
    else
        # Clear specific subdirectory
        local cache_path="${root}/${subdir}"
        if [ -d "$cache_path" ]; then
            echo "🗑️  Clearing cache: ${subdir}"
            rm -rf "${cache_path}"
            echo "✓ Cache cleared: ${subdir}"
        else
            echo "No cache to clear for: ${subdir}"
        fi
    fi
}

# Show cache statistics
cache_stats() {
    local root
    root=$(cache_root)

    if [ ! -d "$root" ]; then
        echo "Cache is empty"
        return 0
    fi

    echo "📊 Cache Statistics: ${root}"
    echo ""

    # Total size
    local total_size
    total_size=$(du -sh "$root" 2>/dev/null | cut -f1)
    echo "Total size: ${total_size}"
    echo ""

    # Count files by type
    for subdir in apk k3s alpine-iso; do
        local cache_path="${root}/${subdir}"
        if [ -d "$cache_path" ]; then
            local count
            count=$(find "$cache_path" -type f | wc -l | tr -d ' ')
            local size
            size=$(du -sh "$cache_path" 2>/dev/null | cut -f1)
            echo "  ${subdir}: ${count} files, ${size}"
        fi
    done
}

# Generate cache key for APK packages
cache_key_apk() {
    local arch="$1"
    local pkg_name="$2"
    local version="$3"
    echo "${arch}/${pkg_name}-${version}.apk"
}

# Generate cache key for k3s binary
cache_key_k3s() {
    local version="$1"
    local arch="$2"
    echo "k3s-${version}-${arch}"
}

# Generate cache key for Alpine ISO
cache_key_alpine_iso() {
    local variant="$1"  # e.g., rpi, virt
    local version="$2"
    local arch="$3"
    local ext="${4:-tar.gz}"
    echo "alpine-${variant}-${version}-${arch}.${ext}"
}
