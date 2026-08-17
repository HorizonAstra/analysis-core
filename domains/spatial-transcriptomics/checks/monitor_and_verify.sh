#!/bin/bash
#
# monitor_and_verify.sh
#
# Monitor two pipeline jobs and verify reproducibility when both complete
#

set -e

NATIVE_JOB="$1"
CONTAINER_JOB="$2"
NATIVE_DIR="$3"
CONTAINER_DIR="$4"

if [ -z "$NATIVE_JOB" ] || [ -z "$CONTAINER_JOB" ]; then
    echo "Usage: monitor_and_verify.sh NATIVE_JOB CONTAINER_JOB NATIVE_DIR CONTAINER_DIR"
    exit 1
fi

echo "=================================="
echo "Monitoring fixed-seed test jobs"
echo "=================================="
echo "Native job:      $NATIVE_JOB"
echo "Container job:   $CONTAINER_JOB"
echo "Native dir:      $NATIVE_DIR"
echo "Container dir:   $CONTAINER_DIR"
echo ""

# Wait for jobs to complete
echo "Waiting for jobs to complete..."
echo ""

while true; do
    NATIVE_RUNNING=$(squeue -j "$NATIVE_JOB" 2>&1 | tail -1 | grep -c "caslake" || true)
    CONTAINER_RUNNING=$(squeue -j "$CONTAINER_JOB" 2>&1 | tail -1 | grep -c "caslake" || true)
    
    if [ $NATIVE_RUNNING -eq 0 ] && [ $CONTAINER_RUNNING -eq 0 ]; then
        echo "✓ Both jobs completed"
        break
    fi
    
    echo "[$(date)] Native: $([ $NATIVE_RUNNING -eq 1 ] && echo "RUNNING" || echo "DONE"), Container: $([ $CONTAINER_RUNNING -eq 1 ] && echo "RUNNING" || echo "DONE")"
    sleep 30
done

echo ""
echo "Checking job exit codes..."
sacct -j "$NATIVE_JOB" --format=JobID,State,ExitCode | tail -5
echo ""
sacct -j "$CONTAINER_JOB" --format=JobID,State,ExitCode | tail -5

echo ""
echo "=================================="
echo "Verifying reproducibility"
echo "=================================="
echo ""

# Run verification
python3 benchmarking/verify_fixed_seed_reproducibility.py \
    --native "$NATIVE_DIR" \
    --container "$CONTAINER_DIR" \
    --verbose

echo ""
echo "Done!"
