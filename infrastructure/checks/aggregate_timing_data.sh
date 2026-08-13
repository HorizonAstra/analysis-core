#!/bin/bash
#
# aggregate_timing_data.sh
#
# Aggregate per-run timing data to centralized timing database
#
# Usage:
#   bash benchmarking/aggregate_timing_data.sh <timing_summary.tsv> <dataset> <mode> <svd_count>
#
# Arguments:
#   timing_summary.tsv   Path to per-run timing summary file
#   dataset              Dataset name (e.g., GSE213688_GSM6592057)
#   mode                 Run mode (native_test, native_prod, container_test, container_prod)
#   svd_count           Number of SVDs processed (e.g., 3 or 30)
#
# Output:
#   Appends data to benchmarks/timing_database.tsv with columns:
#   Dataset, Mode, Timestamp, Step, JobID, Runtime_sec, Memory_MB, Date, SVD_Count
#
# Example:
#   bash benchmarking/aggregate_timing_data.sh \
#       benchmarks/GSE213688_GSM6592057/runs/native_test_20260118_143527/timing_summary.tsv \
#       GSE213688_GSM6592057 native_test 3
#

set -e

if [ $# -ne 4 ]; then
    echo "Usage: bash $0 <timing_summary.tsv> <dataset> <mode> <svd_count>" >&2
    exit 1
fi

TIMING_FILE="$1"
DATASET="$2"
MODE="$3"
SVD_COUNT="$4"

# Workspace root
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
DATABASE="$WORKSPACE_ROOT/benchmarks/timing_database.tsv"

# Check if timing summary exists
if [ ! -f "$TIMING_FILE" ]; then
    echo "ERROR: Timing summary file not found: $TIMING_FILE" >&2
    exit 1
fi

# Extract timestamp from timing file path (assumes path contains mode_YYYYMMDD_HHMMSS)
TIMESTAMP=$(echo "$TIMING_FILE" | grep -oP '(?<=_)\d{8}_\d{6}(?=/)' || echo "unknown")

# Get current date
CURRENT_DATE=$(date +%Y-%m-%d)

# Create database with header if it doesn't exist
if [ ! -f "$DATABASE" ]; then
    echo -e "Dataset\tMode\tTimestamp\tStep\tJobID\tRuntime_sec\tMemory_MB\tDate\tSVD_Count" > "$DATABASE"
fi

# Read timing summary and append to database (skip header)
tail -n +2 "$TIMING_FILE" | while IFS=$'\t' read -r STEP JOBID RUNTIME MEMORY CPUTIME STATE; do
    # Convert memory from KB to MB (if present)
    if [ -n "$MEMORY" ] && [ "$MEMORY" != "N/A" ]; then
        MEMORY_MB=$(echo "$MEMORY" | awk '{print int($1/1024)}')
    else
        MEMORY_MB="N/A"
    fi
    
    # Convert runtime HH:MM:SS to seconds
    if [[ "$RUNTIME" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        HOURS="${BASH_REMATCH[1]}"
        MINS="${BASH_REMATCH[2]}"
        SECS="${BASH_REMATCH[3]}"
        RUNTIME_SEC=$((10#$HOURS * 3600 + 10#$MINS * 60 + 10#$SECS))
    else
        RUNTIME_SEC="$RUNTIME"
    fi
    
    # Append to database
    echo -e "${DATASET}\t${MODE}\t${TIMESTAMP}\t${STEP}\t${JOBID}\t${RUNTIME_SEC}\t${MEMORY_MB}\t${CURRENT_DATE}\t${SVD_COUNT}" >> "$DATABASE"
done

echo "Timing data aggregated to $DATABASE"
