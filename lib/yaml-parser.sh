#!/bin/bash

CONFIG_FILE="${CONFIG_FILE:-cluster-config.yaml}"

_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        echo "Error: yq is required. Install with: brew install yq" >&2
        return 1
    fi
    local expr="$1" file="${2:-$CONFIG_FILE}"
    if [ ! -f "$file" ]; then
        echo "Error: Configuration file $file not found" >&2
        return 1
    fi
    yq e "$expr // \"\"" "$file"
}

# Usage: yaml_get "section.key" [file]
yaml_get() {
    _yq ".${1}" "${2:-$CONFIG_FILE}"
}

# Usage: yaml_get_array ".path.to.array[]" [file]
yaml_get_array() {
    local file="${2:-$CONFIG_FILE}"
    if [ ! -f "$file" ]; then
        echo "Error: Configuration file $file not found" >&2
        return 1
    fi
    yq e "${1}" "$file" 2>/dev/null
}

# Outputs "name:ip:role" lines for each node
yaml_get_nodes() {
    local file="${1:-$CONFIG_FILE}"
    if ! command -v yq >/dev/null 2>&1; then
        echo "Error: yq is required. Install with: brew install yq" >&2
        return 1
    fi
    if [ ! -f "$file" ]; then
        echo "Error: Configuration file $file not found" >&2
        return 1
    fi
    yq e '.nodes[] | .name + ":" + .ip + ":" + .role' "$file"
}

get_cluster_name()    { yaml_get "cluster.name"; }
get_network_gateway() { yaml_get "network.gateway"; }
get_network_subnet()  { yaml_get "network.subnet"; }
get_dns_servers()     { yaml_get_array ".network.dns_servers[]"; }

get_metallb_start() { _yq '.network.loadbalancer_pool.start' "${1:-$CONFIG_FILE}"; }
get_metallb_end()   { _yq '.network.loadbalancer_pool.end'   "${1:-$CONFIG_FILE}"; }

get_service_enabled()  { _yq ".services.${1}.enabled"  "${2:-$CONFIG_FILE}"; }
get_service_version()  { _yq ".services.${1}.version"  "${2:-$CONFIG_FILE}"; }
get_service_replicas() { _yq ".services.${1}.replicas" "${2:-$CONFIG_FILE}"; }

get_k3s_cluster_cidr() { yaml_get "k3s.cluster_cidr"; }
get_k3s_service_cidr() { yaml_get "k3s.service_cidr"; }
get_alpine_packages()  { yaml_get_array ".alpine.packages[]"; }
get_alpine_timezone()  { yaml_get "alpine.timezone"; }

_get_datastore_value() { _yq ".k3s.datastore.${1}" "${CONFIG_FILE}"; }

get_datastore_type()     { _get_datastore_value "type"; }
get_datastore_host()     { _get_datastore_value "host"; }
get_datastore_port()     { _get_datastore_value "port"; }
get_datastore_database() { _get_datastore_value "database"; }
get_datastore_user()     { _get_datastore_value "user"; }
get_datastore_password() { _get_datastore_value "password"; }
get_datastore_sslmode()  { _get_datastore_value "sslmode"; }

get_datastore_endpoint() {
    local type; type=$(get_datastore_type)
    [ -z "$type" ] && return 1

    local host port database user password sslmode
    host=$(get_datastore_host)
    port=$(get_datastore_port); [ -z "$port" ] && port="5432"
    database=$(get_datastore_database)
    user=$(get_datastore_user)
    password=$(get_datastore_password)
    sslmode=$(get_datastore_sslmode); [ -z "$sslmode" ] && sslmode="disable"

    if [ "$type" = "postgres" ]; then
        echo "postgres://${user}:${password}@${host}:${port}/${database}?sslmode=${sslmode}"
    elif [ "$type" = "mysql" ]; then
        echo "mysql://${user}:${password}@tcp(${host}:${port})/${database}"
    else
        return 1
    fi
}

validate_config() {
    local errors=0
    echo "Validating cluster configuration..."

    if [ -z "$(get_cluster_name)" ]; then
        echo "Error: cluster.name is required" >&2
        errors=$((errors + 1))
    fi

    if [ -z "$(get_network_gateway)" ]; then
        echo "Error: network.gateway is required" >&2
        errors=$((errors + 1))
    fi

    local node_count
    node_count=$(yaml_get_nodes | wc -l)
    if [ "$node_count" -eq 0 ]; then
        echo "Error: At least one node must be defined" >&2
        errors=$((errors + 1))
    fi

    local master_count
    master_count=$(yaml_get_nodes | grep -c ":master" || true)
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
