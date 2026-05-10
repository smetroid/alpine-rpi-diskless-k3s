#!/bin/bash

# Template rendering library
# Provides render_template() for use by build scripts.
# Supports two modes:
#   *.tmpl  — rendered via gomplate (variable substitution via env vars)
#   *.sh    — copied verbatim (static files, no substitution needed)

# Resolve GOMPLATE_BIN and TEMPLATES_DIR relative to this file's location.
# This guards against stale relative values in the environment (e.g. from a
# prior invocation before the Makefile was updated to use $(CURDIR)).
_templates_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_templates_root="$(cd "$_templates_lib_dir/.." && pwd)"

GOMPLATE_BIN="${GOMPLATE_BIN:-${_templates_root}/.local/bin/gomplate}"
TEMPLATES_DIR="${TEMPLATES_DIR:-${_templates_root}/templates}"

# If env-provided paths are relative, replace them with absolute equivalents.
[[ "$GOMPLATE_BIN"  != /* ]] && GOMPLATE_BIN="${_templates_root}/.local/bin/gomplate"
[[ "$TEMPLATES_DIR" != /* ]] && TEMPLATES_DIR="${_templates_root}/templates"

render_template() {
    local template_path="$TEMPLATES_DIR/$1"
    local output="$2"

    if [ ! -f "$template_path" ]; then
        echo "Error: Template not found: $template_path" >&2
        return 1
    fi

    case "$template_path" in
        *.sh)
            cp "$template_path" "$output"
            ;;
        *.tmpl)
            if [ ! -x "$GOMPLATE_BIN" ]; then
                echo "Error: gomplate not found at $GOMPLATE_BIN" >&2
                echo "Run 'make install-deps' to download it." >&2
                return 1
            fi
            "$GOMPLATE_BIN" -f "$template_path" -o "$output"
            ;;
        *)
            echo "Error: Unknown template type for: $template_path" >&2
            return 1
            ;;
    esac
}
