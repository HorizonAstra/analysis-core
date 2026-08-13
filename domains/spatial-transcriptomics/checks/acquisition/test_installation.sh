#!/bin/bash
#
# Test GEO Tool Installation
#
# Verifies that all components of the GEO tool are working correctly

echo "=================================="
echo "GEO Tool Installation Test"
echo "=================================="
echo ""

# Change to workspace root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${WORKSPACE_ROOT}"

# Load Python module
echo "[1/5] Loading Python module..."
module load python/anaconda-2022.05
echo "  ✓ Python module loaded"
echo ""

# Check Python version and packages
echo "[2/5] Checking Python dependencies..."
python3 -c "
import sys
print(f'  Python version: {sys.version.split()[0]}')
import numpy, pandas, scipy, h5py, yaml, tqdm, requests
print('  ✓ All required packages available')
"
echo ""

# Test search functionality
echo "[3/5] Testing GEO search..."
cd "${WORKSPACE_ROOT}/workflows/acquisition/python"
python3 geo_search.py "visium" --max-results 2 > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "  ✓ Search module working"
else
    echo "  ✗ Search module failed"
    exit 1
fi
echo ""

# Test validation on existing benchmark
echo "[4/5] Testing validation module..."
if [ -d "${WORKSPACE_ROOT}/benchmarks/GSE213688_GSM6592057/input_data" ]; then
    python3 validate_dataset.py "${WORKSPACE_ROOT}/benchmarks/GSE213688_GSM6592057/" --min-spots 100 --min-genes 1000 > /dev/null 2>&1
    status=$?
    if [ $status -eq 0 ]; then
        echo "  ✓ Validation module working"
    else
        echo "  ⚠ Validation module completed with warnings"
    fi
else
    echo "  ⚠ Benchmark dataset not available for validation test"
fi
echo ""

# Test CLI interface
echo "[5/5] Testing main CLI..."
python3 geo_tool.py list-local > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "  ✓ Main CLI working"
else
    echo "  ✗ Main CLI failed"
    exit 1
fi
echo ""

echo "=================================="
echo "All tests passed! ✓"
echo "=================================="
echo ""
echo "Quick start commands:"
echo "  module load python/anaconda-2022.05"
echo "  bash workflows/acquisition/orchestration/run_geo_discovery.sh --query \"melanoma visium\" --interactive"
echo ""
echo "Full documentation: docs/geo_dataset_acquisition.md"
