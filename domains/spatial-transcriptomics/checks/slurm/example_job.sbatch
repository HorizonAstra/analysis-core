#!/bin/bash
#SBATCH --job-name=tumorspace_example
#SBATCH --account=pi-araman
#SBATCH --partition=caslake
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=06:00:00
#SBATCH --output=logs/tumorspace_example_%j.out
#SBATCH --error=logs/tumorspace_example_%j.err

# Example SLURM job script for running TumorSPACE_AWS analysis
# Author: Vivek Behera
# Usage: sbatch scripts/slurm/example_job.sbatch

# Print job information
echo "================================================"
echo "Job ID: $SLURM_JOB_ID"
echo "Job Name: $SLURM_JOB_NAME"
echo "Node: $SLURM_NODELIST"
echo "Start Time: $(date)"
echo "================================================"
echo ""

# Load required modules
module load singularity
module list

# Set working directory
cd $SLURM_SUBMIT_DIR
echo "Working directory: $(pwd)"
echo ""

# Define paths
CONTAINER="containers/tumorspace_aws.sif"
INPUT_DIR="benchmarks/data/GSE213688_GSM6592057"
OUTPUT_DIR="results/example_run_${SLURM_JOB_ID}"

# Create output directory
mkdir -p ${OUTPUT_DIR}

# Check container exists
if [ ! -f "${CONTAINER}" ]; then
    echo "ERROR: Container not found at ${CONTAINER}"
    echo "Please run ./setup.sh first to build the container"
    exit 1
fi

# Check input data exists
if [ ! -d "${INPUT_DIR}" ]; then
    echo "ERROR: Input directory not found at ${INPUT_DIR}"
    exit 1
fi

echo "Container: ${CONTAINER}"
echo "Input: ${INPUT_DIR}"
echo "Output: ${OUTPUT_DIR}"
echo ""

# Example: Run Julia command through container
echo "Running Julia version check..."
singularity exec ${CONTAINER} julia --version
echo ""

# Example: Run R command through container
echo "Running R version check..."
singularity exec ${CONTAINER} R --version
echo ""

# Example: Run Python command through container
echo "Running Python version check..."
singularity exec ${CONTAINER} python --version
echo ""

# ============================================
# PLACEHOLDER: Actual analysis workflow
# ============================================
# Replace the commands below with your actual analysis pipeline
# once workflows are implemented
# 
# Example structure:
# singularity exec ${CONTAINER} julia workflows/run_analysis.jl \
#   --input ${INPUT_DIR} \
#   --output ${OUTPUT_DIR} \
#   --threads ${SLURM_CPUS_PER_TASK}

echo "Workflow execution placeholder"
echo "Actual analysis commands to be added when workflows are implemented"
echo ""

# ============================================

# Print completion message
echo ""
echo "================================================"
echo "Job completed at: $(date)"
echo "Results saved to: ${OUTPUT_DIR}"
echo "================================================"

# Job statistics
sstat --format=JobID,MaxRSS,MaxVMSize,AveCPU -j ${SLURM_JOB_ID}
