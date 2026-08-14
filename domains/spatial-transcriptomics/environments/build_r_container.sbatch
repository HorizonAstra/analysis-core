#!/bin/bash
#SBATCH --job-name=build_r_container
#SBATCH --account=pi-araman
#SBATCH --partition=caslake
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=02:00:00
#SBATCH --output=logs/build_r_container_%j.out
#SBATCH --error=logs/build_r_container_%j.err

# Build tumorspace_r_base.sif and tumorspace_r.sif on a SLURM compute node.
#
# Run from the repo root:
#   sbatch containers/build_r_container.sbatch
#
# The job always rebuilds the base layer (equivalent to --force).
# On completion, check:
#   squeue -j <jobid>
#   tail logs/build_r_container_<jobid>.out
#   ls -lh containers/tumorspace_r_base.sif containers/tumorspace_r.sif

set -e

echo "Job ID:   $SLURM_JOB_ID"
echo "Node:     $SLURM_NODELIST"
echo "CPUs:     $SLURM_CPUS_PER_TASK"
echo "Start:    $(date)"
echo ""

cd "$SLURM_SUBMIT_DIR"
echo "Working directory: $(pwd)"
echo ""

module load singularity

bash containers/build_r_container.sh --force

echo ""
echo "Finished: $(date)"
