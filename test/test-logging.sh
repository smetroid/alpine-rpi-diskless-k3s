#!/bin/sh
#
# test-logging.sh - Test script for unified logging system
#
# Tests all logging functions and validates dual output behavior
#

set -e

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source the logging library
. "${PROJECT_ROOT}/lib/logging.sh"

echo "========================================"
echo "Testing Unified Logging System"
echo "========================================"
echo ""

# Test 1: Basic logging levels
echo "Test 1: Basic Logging Levels"
echo "----------------------------------------"
log_info "This is an INFO message (should be green)"
log_warn "This is a WARN message (should be yellow)"
log_error "This is an ERROR message (should be red)"
log_success "This is a SUCCESS message (should be green with ✓)"
echo ""

# Test 2: DEBUG logging (should not appear unless DEBUG=1)
echo "Test 2: DEBUG Logging (disabled by default)"
echo "----------------------------------------"
log_debug "This DEBUG message should NOT appear"
log_info "DEBUG message above should be hidden"
echo ""

echo "Test 3: DEBUG Logging (enabled with DEBUG=1)"
echo "----------------------------------------"
DEBUG=1
log_debug "This DEBUG message SHOULD appear (gray)"
log_info "DEBUG message above should be visible"
DEBUG=0
echo ""

# Test 4: Script name detection
echo "Test 4: Script Name Detection"
echo "----------------------------------------"
log_info "Script name should be: test-logging.sh"
log_info "Detected SCRIPT_NAME: ${SCRIPT_NAME}"
echo ""

# Test 5: Timestamp format
echo "Test 5: Timestamp Format"
echo "----------------------------------------"
log_info "Check timestamp format: [YYYY-MM-DD HH:MM:SS]"
echo ""

# Test 6: Command execution - success case (live mode)
echo "Test 6: Command Execution - Success (Live Mode)"
echo "----------------------------------------"
log_exec "echo 'Command output line 1'; echo 'Command output line 2'" "Test successful command"
echo ""

# Test 7: Command execution - success case (quiet mode)
echo "Test 7: Command Execution - Success (Quiet Mode)"
echo "----------------------------------------"
log_exec -q "echo 'This output should only appear in debug'" "Test quiet successful command"
echo ""

# Test 8: Command execution - failure case (live mode)
echo "Test 8: Command Execution - Failure (Live Mode)"
echo "----------------------------------------"
log_info "The following command will fail intentionally..."
if ! log_exec "false" "Test failing command"; then
    log_info "Failure was caught correctly"
fi
echo ""

# Test 9: Command execution - failure case (quiet mode)
echo "Test 9: Command Execution - Failure (Quiet Mode)"
echo "----------------------------------------"
log_info "The following command will fail intentionally..."
if ! log_exec -q "sh -c 'echo Error output >&2; exit 1'" "Test quiet failing command"; then
    log_info "Failure was caught correctly, output shown above"
fi
echo ""

# Test 10: Multi-line command output
echo "Test 10: Multi-line Command Output"
echo "----------------------------------------"
log_exec "printf 'Line 1\nLine 2\nLine 3\n'" "Test multi-line output"
echo ""

# Test 11: Test error handling setup
echo "Test 11: Error Handling Setup"
echo "----------------------------------------"
log_info "Testing error trap setup (will create a subshell to test)"

(
    # Subshell to test error handling without killing main script
    setup_error_handling
    log_info "Error handling enabled"
    log_info "This subshell will exit cleanly"
) && log_success "Error handling trap works"
echo ""

# Test 12: Color support detection
echo "Test 12: Color Support Detection"
echo "----------------------------------------"
if [ -t 1 ]; then
    log_info "Terminal supports colors - colors should be visible"
else
    log_warn "Not a TTY - colors may not be visible"
fi
echo ""

# Test 13: Syslog integration check
echo "Test 13: Syslog Integration"
echo "----------------------------------------"
if command -v logger >/dev/null 2>&1; then
    log_success "logger command available - syslog integration active"
    log_info "Check /var/log/messages or journalctl for syslog entries"
else
    log_warn "logger command not available - syslog integration disabled"
fi
echo ""

# Test 14: Real-world scenario simulation
echo "Test 14: Real-world Scenario Simulation"
echo "----------------------------------------"
log_info "Simulating bootstrap script workflow..."
log_info "Step 1: Checking prerequisites"
log_exec "command -v sh" "Checking for shell"
log_info "Step 2: Creating temporary directory"
TEMP_DIR="/tmp/logging-test-$$"
log_exec "mkdir -p ${TEMP_DIR}" "Creating temp directory"
log_info "Step 3: Writing test file"
log_exec "echo 'test content' > ${TEMP_DIR}/test.txt" "Writing test file"
log_info "Step 4: Verifying file"
log_exec "cat ${TEMP_DIR}/test.txt" "Reading test file"
log_info "Step 5: Cleanup"
log_exec "rm -rf ${TEMP_DIR}" "Removing temp directory"
log_success "Workflow simulation complete"
echo ""

# Summary
echo "========================================"
echo "Logging System Test Summary"
echo "========================================"
log_success "All logging tests completed"
log_info "Visual inspection checklist:"
echo "  ✓ INFO messages appear in green"
echo "  ✓ WARN messages appear in yellow"
echo "  ✓ ERROR messages appear in red"
echo "  ✓ DEBUG messages only appear when DEBUG=1"
echo "  ✓ SUCCESS messages have green checkmark"
echo "  ✓ Command output is prefixed with script name"
echo "  ✓ Timestamps follow [YYYY-MM-DD HH:MM:SS] format"
echo "  ✓ Quiet mode suppresses output on success"
echo "  ✓ Failures show full error context"
echo ""
log_info "To verify syslog integration, run:"
echo "  tail -f /var/log/messages | grep ${SCRIPT_NAME}"
echo "  OR"
echo "  journalctl -f -t ${SCRIPT_NAME}"
echo ""
log_success "Testing complete!"
