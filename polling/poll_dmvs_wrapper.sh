#!/bin/bash
# Wrapper for poll_dmvs.py — always exits 0 so launchd keeps scheduling.
# Any errors are logged by the Python script itself.
#
# EDIT BEFORE USE: point PYTHON_BIN and SCRIPT_PATH at your local install.
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3}"
SCRIPT_PATH="${SCRIPT_PATH:-/path/to/poll_dmvs.py}"

"$PYTHON_BIN" "$SCRIPT_PATH" 2>&1
exit 0
