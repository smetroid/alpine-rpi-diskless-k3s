#!/bin/bash

# YAML Parser Library for Alpine diskless k3s setup
# Simple YAML parser using awk and sed

CONFIG_FILE="${CONFIG_FILE:-cluster-config.yaml}"

# Function to parse YAML and extract values
yaml_get() {
    local key="$1"
    local file="${2:-$CONFIG_FILE}"
    
    if [ ! -f "$file" ]; then
        echo "Error: Configuration file $file not found" >&2
        return 1
    fi
    
    # Handle nested keys (e.g., "network.gateway")
    local prefix=""
    local search_key="$key"
    
    if [[ "$key" == *.* ]]; then
        prefix=$(echo "$key" | cut -d. -f1)
        search_key=$(echo "$key" | cut -d. -f2-)
    fi
    
    # Parse YAML using awk
    awk -v prefix="$prefix" -v key="$search_key" '
    BEGIN { 
        in_section = (prefix == "")
        found = 0
    }
    
    # Skip comments and empty lines
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    
    # Section headers
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
        current_section = $1
        gsub(/:$/, "", current_section)
        in_section = (prefix == "" || current_section == prefix)
        next
    }
    
    # Key-value pairs
    in_section && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:/ {
        gsub(/^[[:space:]]+/, "")
        split($0, parts, ":")
        yaml_key = parts[1]
        yaml_value = parts[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", yaml_value)
        # Strip inline comments (everything after # outside of quotes)
        if (match(yaml_value, /^"[^"]*"( |#|$)/)) {
            # Value is quoted, remove quotes but preserve content
            gsub(/^"/, "", yaml_value)
            gsub(/".*$/, "", yaml_value)
        } else {
            # Value is not quoted, remove everything after first #
            gsub(/#.*$/, "", yaml_value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", yaml_value)
        }
        
        if (yaml_key == key) {
            print yaml_value
            found = 1
            exit
        }
    }
    
    END { if (!found && prefix == "" && key != "") exit 1 }
    ' "$file"
}

# Function to get array values from YAML
yaml_get_array() {
    local key="$1"
    local file="${2:-$CONFIG_FILE}"
    
    if [ ! -f "$file" ]; then
        echo "Error: Configuration file $file not found" >&2
        return 1
    fi
    
    # Handle nested keys
    local prefix=""
    local search_key="$key"
    
    if [[ "$key" == *.* ]]; then
        prefix=$(echo "$key" | cut -d. -f1)
        search_key=$(echo "$key" | cut -d. -f2-)
    fi
    
    awk -v prefix="$prefix" -v key="$search_key" '
    BEGIN { 
        in_section = (prefix == "")
        in_array = 0
    }
    
    # Skip comments and empty lines
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    
    # Section headers
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
        current_section = $1
        gsub(/:$/, "", current_section)
        in_section = (prefix == "" || current_section == prefix)
        in_array = 0
        next
    }
    
    # Array key
    in_section && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:/ {
        gsub(/^[[:space:]]+/, "")
        split($0, parts, ":")
        yaml_key = parts[1]
        
        if (yaml_key == key) {
            in_array = 1
        } else {
            in_array = 0
        }
        next
    }
    
    # Array items
    in_array && /^[[:space:]]*-/ {
        gsub(/^[[:space:]]*-[[:space:]]*/, "")
        # Handle quoted values with potential inline comments
        if (match($0, /^"[^"]*"/)) {
            # Extract just the content between quotes
            $0 = substr($0, 2, RLENGTH - 2)
        } else {
            # Unquoted value - strip inline comments
            gsub(/#.*$/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        }
        if (length($0) > 0) print $0
    }
    
    # Stop array on next key
    in_array && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:/ {
        in_array = 0
    }
    ' "$file"
}

# Function to get all nodes
yaml_get_nodes() {
    local file="${1:-$CONFIG_FILE}"
    
    # Simpler approach: extract nodes section and parse it
    awk '
    BEGIN { 
        in_nodes = 0
        current_node = ""
        current_ip = ""
        current_role = ""
    }
    
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    
    /^nodes:/ { in_nodes = 1; next }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
        if (in_nodes) {
            # Output current node before exiting nodes section
            if (current_node != "") {
                print current_node ":" current_ip ":" current_role
                current_node = ""
                current_ip = ""
                current_role = ""
            }
            in_nodes = 0
        }
        next
    }
    
    in_nodes && /^[[:space:]]*-[[:space:]]*name:/ {
        # Output previous node if any
        if (current_node != "") {
            print current_node ":" current_ip ":" current_role
        }
        # Start new node
        gsub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
        gsub(/^"/, ""); gsub(/"$/, "")
        current_node = $0
        current_ip = ""
        current_role = ""
        next
    }
    
    in_nodes && /^[[:space:]]+ip:/ {
        gsub(/^[[:space:]]+ip:[[:space:]]*/, "")
        gsub(/^"/, ""); gsub(/"$/, "")
        current_ip = $0
        next
    }
    
    in_nodes && /^[[:space:]]+role:/ {
        gsub(/^[[:space:]]+role:[[:space:]]*/, "")
        gsub(/^"/, ""); gsub(/"$/, "")
        current_role = $0
        next
    }
    
    END {
        # Output final node
        if (current_node != "") {
            print current_node ":" current_ip ":" current_role
        }
    }
    ' "$file"
}

# Helper functions for common config values
get_cluster_name() { yaml_get "cluster.name"; }
get_network_gateway() { yaml_get "network.gateway"; }
get_network_subnet() { yaml_get "network.subnet"; }
get_dns_servers() { yaml_get_array "network.dns_servers"; }
# LoadBalancer pool configuration helpers
get_metallb_start() {
    local file="${1:-$CONFIG_FILE}"
    
    # Parse network.loadbalancer_pool.start
    awk '
    BEGIN { in_network = 0; in_pool = 0 }
    /^network:/ { in_network = 1; next }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ { 
        if (in_network) in_network = 0
        next 
    }
    in_network && /^[[:space:]]+loadbalancer_pool:[[:space:]]*$/ {
        in_pool = 1
        next
    }
    in_network && in_pool && /^[[:space:]]+start:[[:space:]]*/ {
        gsub(/^[[:space:]]+start:[[:space:]]*/, "")
        gsub(/^"/, "")
        gsub(/"$/, "")
        print $0
        exit
    }
    in_network && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ {
        if (in_pool) in_pool = 0
    }
    ' "$file"
}

get_metallb_end() {
    local file="${1:-$CONFIG_FILE}"
    
    # Parse network.loadbalancer_pool.end
    awk '
    BEGIN { in_network = 0; in_pool = 0 }
    /^network:/ { in_network = 1; next }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ { 
        if (in_network) in_network = 0
        next 
    }
    in_network && /^[[:space:]]+loadbalancer_pool:[[:space:]]*$/ {
        in_pool = 1
        next
    }
    in_network && in_pool && /^[[:space:]]+end:[[:space:]]*/ {
        gsub(/^[[:space:]]+end:[[:space:]]*/, "")
        gsub(/^"/, "")
        gsub(/"$/, "")
        print $0
        exit
    }
    in_network && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ {
        if (in_pool) in_pool = 0
    }
    ' "$file"
}

# Service configuration helpers
get_service_enabled() {
    local service="$1"
    local file="${2:-$CONFIG_FILE}"
    
    # Parse services section for the specific service
    awk -v service="$service" '
    BEGIN { in_services = 0; in_service = 0 }
    /^services:/ { in_services = 1; next }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ { 
        if (in_services) in_services = 0
        next 
    }
    in_services && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ {
        gsub(/^[[:space:]]+/, "")
        gsub(/:$/, "")
        if ($1 == service) {
            in_service = 1
        } else {
            in_service = 0
        }
        next
    }
    in_service && /^[[:space:]]+enabled:[[:space:]]*/ {
        gsub(/^[[:space:]]+enabled:[[:space:]]*/, "")
        print $0
        exit
    }
    ' "$file"
}

get_service_version() {
    local service="$1"
    local file="${2:-$CONFIG_FILE}"
    
    # Parse services section for the specific service version
    awk -v service="$service" '
    BEGIN { in_services = 0; in_service = 0 }
    /^services:/ { in_services = 1; next }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ { 
        if (in_services) in_services = 0
        next 
    }
    in_services && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ {
        gsub(/^[[:space:]]+/, "")
        gsub(/:$/, "")
        if ($1 == service) {
            in_service = 1
        } else {
            in_service = 0
        }
        next
    }
    in_service && /^[[:space:]]+version:[[:space:]]*/ {
        gsub(/^[[:space:]]+version:[[:space:]]*/, "")
        gsub(/^"/, "")
        gsub(/"$/, "")
        print $0
        exit
    }
    ' "$file"
}

get_service_replicas() {
    local service="$1"
    local file="${2:-$CONFIG_FILE}"
    
    # Parse services section for the specific service replicas
    awk -v service="$service" '
    BEGIN { in_services = 0; in_service = 0 }
    /^services:/ { in_services = 1; next }
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ { 
        if (in_services) in_services = 0
        next 
    }
    in_services && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ {
        gsub(/^[[:space:]]+/, "")
        gsub(/:$/, "")
        if ($1 == service) {
            in_service = 1
        } else {
            in_service = 0
        }
        next
    }
    in_service && /^[[:space:]]+replicas:[[:space:]]*/ {
        gsub(/^[[:space:]]+replicas:[[:space:]]*/, "")
        print $0
        exit
    }
    ' "$file"
}
get_k3s_cluster_cidr() { yaml_get "k3s.cluster_cidr"; }
get_k3s_service_cidr() { yaml_get "k3s.service_cidr"; }
get_alpine_packages() { yaml_get_array "alpine.packages"; }
get_alpine_timezone() { yaml_get "alpine.timezone"; }

# Validation functions
validate_config() {
    local errors=0
    
    echo "Validating cluster configuration..."
    
    # Check required fields
    if [ -z "$(get_cluster_name)" ]; then
        echo "Error: cluster.name is required" >&2
        errors=$((errors + 1))
    fi
    
    if [ -z "$(get_network_gateway)" ]; then
        echo "Error: network.gateway is required" >&2
        errors=$((errors + 1))
    fi
    
    # Validate nodes
    local node_count=$(yaml_get_nodes | wc -l)
    if [ "$node_count" -eq 0 ]; then
        echo "Error: At least one node must be defined" >&2
        errors=$((errors + 1))
    fi
    
    # Check for master node
    local master_count=$(yaml_get_nodes | grep ":master" | wc -l)
    if [ "$master_count" -eq 0 ]; then
        echo "Error: At least one master node is required" >&2
        errors=$((errors + 1))
    fi
    
    if [ "$errors" -eq 0 ]; then
        echo "Configuration validation passed ✓"
        return 0
    else
        echo "Configuration validation failed with $errors error(s)"
        return 1
    fi
}