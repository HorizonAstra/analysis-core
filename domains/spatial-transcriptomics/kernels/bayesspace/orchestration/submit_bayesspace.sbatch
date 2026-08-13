#!/bin/bash
#SBATCH --job-name=bayesspace
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --output=logs/bayesspace_%j.out
#SBATCH --error=logs/bayesspace_%j.err

# SLURM Submission Script for BayesSpace
# Submit from repo root: sbatch workflows/bayesspace/orchestration/submit_bayesspace.sbatch
# To override SLURM resources: sbatch --mem=32G --time=08:00:00 workflows/bayesspace/orchestration/submit_bayesspace.sbatch

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Load HPC cluster profile (module names)
_HPC_PROFILE="${WORKSPACE_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE
hpc_module_load MODULE_SINGULARITY

# -- Configurable Parameters --
# Edit these values before submitting
DATAPATH=/path/to/visium/data
OUTDIR=/path/to/output
NPCS=15
Q=8
# Leave CONTAINER blank to use native mode (requires R/4.4.1 + BayesSpace on HPC)
# Set to containers/tumorspace_r.sif to use container mode
CONTAINER=containers/tumorspace_r.sif

# -- Run BayesSpace --
bash "${WORKSPACE_ROOT}/workflows/bayesspace/orchestration/run_bayesspace.sh" \
  --datapath "$DATAPATH" \
  --outdir "$OUTDIR" \
  --nPCs "$NPCS" \
  --q "$Q" \
  ${CONTAINER:+--container "$CONTAINER"}
