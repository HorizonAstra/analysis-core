#!/bin/bash
#
# GEO Dataset Discovery Tool - Bash Wrapper
#
# Convenient wrapper for the Python geo_tool.py script
# Supports both interactive and batch modes

set -e

# Get workspace root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Python module directory
PYTHON_DIR="${WORKSPACE_ROOT}/workflows/acquisition/python"

# Source capabilities if available
_CAPS="${WORKSPACE_ROOT}/config/capabilities.sh"
if [ -f "$_CAPS" ]; then
    # shellcheck disable=SC1090
    source "$_CAPS"
fi
unset _CAPS

# Check acquisition availability
if [ "${ACQUISITION_NATIVE_AVAILABLE:-}" = false ]; then
    echo "ERROR: acquisition is not available in this environment."
    echo "       python3 was not found or numpy/pandas are missing."
    echo "       Fix: Run 'bash setup.sh' for guided installation, or:"
    echo "            module load python/anaconda-2022.05"
    exit 1
fi

# Check if Python 3 is available (fast inline check as fallback when capabilities absent)
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 not found. Please install Python 3.8 or later."
    echo "       Fix: module load python/anaconda-2022.05  or run 'bash setup.sh'"
    exit 1
fi

# Function to display usage
usage() {
    cat << EOF
Usage: bash run_geo_discovery.sh [OPTIONS]

Options:
  --query QUERY          Search query (required for search mode)
  --interactive          Enable interactive selection after search
  --html-report          Generate HTML report of search results
  --download GEO_ID      Download and harmonize specific dataset
  --list                 List locally available datasets
  --show GEO_ID          Show details for specific dataset
  --max-results N        Maximum search results (default: 20)
  --organism ORGANISM    Filter by organism (Homo sapiens | Mus musculus)
  --refresh              Ignore cached results and re-fetch from NCBI
  --help                 Show this help message

Examples:
  # Search with interactive selection
  bash run_geo_discovery.sh --query "melanoma visium" --interactive
  
  # Generate HTML report
  bash run_geo_discovery.sh --query "breast cancer" --html-report
  
  # Download specific dataset
  bash run_geo_discovery.sh --download GSE213688_GSM6592057
  
  # List local datasets
  bash run_geo_discovery.sh --list
  
  # Show dataset details
  bash run_geo_discovery.sh --show GSE213688

EOF
}

# Parse arguments
QUERY=""
INTERACTIVE=false
HTML_REPORT=false
DOWNLOAD=""
LIST=false
SHOW=""
MAX_RESULTS=20
ORGANISM=""
REFRESH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --query)
            QUERY="$2"
            shift 2
            ;;
        --interactive)
            INTERACTIVE=true
            shift
            ;;
        --html-report)
            HTML_REPORT=true
            shift
            ;;
        --download)
            DOWNLOAD="$2"
            shift 2
            ;;
        --list)
            LIST=true
            shift
            ;;
        --show)
            SHOW="$2"
            shift 2
            ;;
        --max-results)
            MAX_RESULTS="$2"
            shift 2
            ;;
        --organism)
            ORGANISM="$2"
            shift 2
            ;;
        --refresh)
            REFRESH=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Change to Python directory so imports work
cd "${PYTHON_DIR}"

# Execute appropriate command
if [ "${LIST}" = true ]; then
    echo "Listing locally available datasets..."
    python3 geo_tool.py list-local

elif [ -n "${SHOW}" ]; then
    echo "Fetching details for ${SHOW}..."
    SHOW_ARGS=(show "${SHOW}")
    [ "${REFRESH}" = true ] && SHOW_ARGS+=(--refresh)
    python3 geo_tool.py "${SHOW_ARGS[@]}"

elif [ -n "${DOWNLOAD}" ]; then
    echo "Downloading and harmonizing ${DOWNLOAD}..."
    python3 geo_tool.py download "${DOWNLOAD}"

elif [ -n "${QUERY}" ]; then
    # Search mode — build args as an array to safely handle spaces and special chars
    SEARCH_CMD_ARGS=(search "${QUERY}" --max-results "${MAX_RESULTS}")

    if [ -n "${ORGANISM}" ]; then
        SEARCH_CMD_ARGS+=(--organism "${ORGANISM}")
    fi

    if [ "${INTERACTIVE}" = true ]; then
        SEARCH_CMD_ARGS+=(--interactive)
    fi

    if [ "${REFRESH}" = true ]; then
        SEARCH_CMD_ARGS+=(--refresh)
    fi

    echo "Searching GEO: ${QUERY}"
    python3 geo_tool.py "${SEARCH_CMD_ARGS[@]}"

    # Generate HTML report if requested
    if [ "${HTML_REPORT}" = true ]; then
        echo ""
        echo "Generating HTML report..."
        REPORT_CMD_ARGS=("${QUERY}" --max-results "${MAX_RESULTS}")

        if [ -n "${ORGANISM}" ]; then
            REPORT_CMD_ARGS+=(--organism "${ORGANISM}")
        fi

        python3 geo_report.py "${REPORT_CMD_ARGS[@]}"
    fi

else
    echo "ERROR: No action specified."
    echo ""
    usage
    exit 1
fi
