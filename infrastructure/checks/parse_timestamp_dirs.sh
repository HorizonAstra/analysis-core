#!/bin/bash
#
# parse_timestamp_dirs.sh
#
# Utility to find latest pipeline run by mode from timestamp-based directories
#
# Usage:
#   bash benchmarking/parse_timestamp_dirs.sh <dataset> <mode>
#
# Arguments:
#   dataset    Dataset name (e.g., GSE213688_GSM6592057)
#   mode       Mode to search for: native_test, native_prod, container_test, container_prod
#
# Output:
#   Absolute path to the latest run directory matching the mode
#   Or empty string if no matching directory found
#
# Example:
#   LATEST_NATIVE=$(bash benchmarking/parse_timestamp_dirs.sh GSE213688_GSM6592057 native_test)
#   echo "Latest native test run: $LATEST_NATIVE"
#

set -e

if [ $# -ne 2 ]; then
    echo "Usage: bash $0 <dataset> <mode>" >&2
    echo "  mode: native_test, native_prod, container_test, container_prod" >&2
    exit 1
fi

DATASET="$1"
MODE="$2"

# Workspace root
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
BENCHMARK_DIR="$WORKSPACE_ROOT/benchmarks/$DATASET"

# Check if benchmark directory exists
if [ ! -d "$BENCHMARK_DIR" ]; then
    echo "" # Return empty string
    exit 0
fi

# Find all directories matching mode pattern with timestamps
# Pattern: {mode}_YYYYMMDD_HHMMSS
PATTERN="${MODE}_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]"

# Find matching directories, sort by timestamp (newest first), take first
LATEST=$(find "$BENCHMARK_DIR" -maxdepth 1 -type d -name "$PATTERN" 2>/dev/null | sort -r | head -1)

if [ -n "$LATEST" ]; then
    echo "$LATEST"
else
    echo "" # No matching directory found
fi
