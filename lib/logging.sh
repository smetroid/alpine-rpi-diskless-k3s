#!/bin/sh
#
# logging.sh - Unified logging library for Alpine diskless bootstrap scripts
#
# Provides consistent logging with dual output:
# - Color-coded output to screen (stdout/stderr)
# - Structured logs to /var/log/messages via syslog
#
# Usage:
#   source lib/logging.sh
#   setup_error_handling
#   log_info "Starting process"
#   log_exec "apk add kubectl" "Installing kubectl"
#

# Color constants for terminal output
if [ -t 1 ]; then
    # Terminal supports colors
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    GRAY='\033[0;90m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    # No color support
    RED=''
    YELLOW=''
    GREEN=''
    BLUE=''
    GRAY=''
    BOLD=''
    RESET=''
fi

# Auto-detect script name from calling script
SCRIPT_NAME="$(basename "$0" 2>/dev/null || echo "unknown")"

# Check if DEBUG mode is enabled
is_debug_enabled() {
    [ "${DEBUG:-0}" = "1" ] || [ "${DEBUG:-0}" = "true" ]
}

# Get current timestamp in consistent format
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Core logging function - handles dual output
# Args: $1=level, $2=color, $3=message
_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp="$(get_timestamp)"

    # Format: [TIMESTAMP] [SCRIPT_NAME] [LEVEL] Message
    local log_line="[${timestamp}] [${SCRIPT_NAME}] [${level}] ${message}"

    # Output to screen with color
    printf "${color}%s${RESET}\n" "${log_line}" >&2

    # Output to syslog (if logger is available)
    if command -v logger >/dev/null 2>&1; then
        # Map our levels to syslog priorities
        local priority
        case "${level}" in
            ERROR) priority="err" ;;
            WARN)  priority="warning" ;;
            INFO)  priority="info" ;;
            DEBUG) priority="debug" ;;
            *)     priority="notice" ;;
        esac

        logger -t "${SCRIPT_NAME}" -p "user.${priority}" "${log_line}"
    fi
}

# Log an error message (red)
log_error() {
    _log "ERROR" "${RED}" "$*"
}

# Log a warning message (yellow)
log_warn() {
    _log "WARN" "${YELLOW}" "$*"
}

# Log an info message (green)
log_info() {
    _log "INFO" "${GREEN}" "$*"
}

# Log a debug message (gray) - only if DEBUG=1
log_debug() {
    if is_debug_enabled; then
        _log "DEBUG" "${GRAY}" "$*"
    fi
}

# Log a success message (green with checkmark)
log_success() {
    _log "INFO" "${GREEN}${BOLD}" "✓ $*"
}

# Execute a command with logging
# Usage: log_exec [-q] <command> [description]
#   -q: Quiet mode - buffer output, only show on failure
#   Default: Live mode - show output as it happens
#
# Examples:
#   log_exec "apk add kubectl" "Installing kubectl"
#   log_exec -q "wget https://example.com/file" "Downloading file"
log_exec() {
    local quiet_mode=0
    local cmd=""
    local description=""

    # Parse arguments
    if [ "$1" = "-q" ]; then
        quiet_mode=1
        shift
    fi

    cmd="$1"
    description="${2:-$1}"

    log_info "Executing: ${description}"
    log_debug "Command: ${cmd}"

    local output
    local exit_code

    if [ ${quiet_mode} -eq 1 ]; then
        # Quiet mode: buffer output, only show on failure
        output=$(eval "${cmd}" 2>&1)
        exit_code=$?

        if [ ${exit_code} -ne 0 ]; then
            log_error "Command failed: ${description}"
            log_error "Exit code: ${exit_code}"
            log_error "Output:"
            echo "${output}" | while IFS= read -r line; do
                log_error "  | ${line}"
            done
        else
            log_success "${description}"
            log_debug "Output: ${output}"
        fi
    else
        # Live mode: show output as it happens
        # Use a temp file to capture exit code (POSIX-compliant, no PIPESTATUS)
        local tmpfile="/tmp/log_exec_$$"
        ( eval "${cmd}" 2>&1; echo $? > "${tmpfile}" ) | while IFS= read -r line; do
            # Prefix each line with script context
            printf "${BLUE}[%s]${RESET} %s\n" "${SCRIPT_NAME}" "${line}" >&2

            # Also send to syslog if available
            if command -v logger >/dev/null 2>&1; then
                logger -t "${SCRIPT_NAME}" -p "user.info" "${line}"
            fi
        done

        # Read exit code from temp file
        exit_code=$(cat "${tmpfile}" 2>/dev/null || echo 1)
        rm -f "${tmpfile}"

        if [ ${exit_code} -ne 0 ]; then
            log_error "Command failed: ${description} (exit code: ${exit_code})"
        else
            log_success "${description}"
        fi
    fi

    return ${exit_code}
}

# Set up error handling with automatic logging
# Call this at the start of scripts to enable auto-logging of errors
setup_error_handling() {
    set -e  # Exit on error

    # Trap ERR to log errors before exit
    trap '_handle_error $? ${LINENO} "${BASH_COMMAND:-unknown}"' ERR

    # Also trap EXIT for clean shutdown logging
    trap '_handle_exit $?' EXIT
}

# Internal: Handle errors
_handle_error() {
    local exit_code=$1
    local line_number=$2
    local command="$3"

    log_error "Script failed at line ${line_number}"
    log_error "Command: ${command}"
    log_error "Exit code: ${exit_code}"
}

# Internal: Handle script exit
_handle_exit() {
    local exit_code=$1

    if [ ${exit_code} -eq 0 ]; then
        log_info "Script completed successfully"
    else
        log_error "Script exited with code ${exit_code}"
    fi
}

# Note: export -f is bash-specific and not supported in ash/sh
# Functions are available in the current shell but not automatically in subshells
# If running scripts in subshells, source this library again in the subshell
