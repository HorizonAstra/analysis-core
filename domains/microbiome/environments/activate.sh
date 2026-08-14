#!/usr/bin/env bash
# Activate the biobakery toolchain on Randi. SOURCE it (do not execute):
#   source /gpfs/data/dfi-cores/rijul/local-biobakery/config/activate.sh
#
# Written to work in non-interactive SLURM job shells too (where the `module`
# function may be undefined), so it sources conda directly from the pinned
# miniconda base and only falls back to Lmod if that path ever moves.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # repo root (local-biobakery/)
source "$ROOT/config/env.sh"

# conda base for the pinned module `gcc/12.1.0 + miniconda3/24.9.2` on Randi
CONDA_BASE=/apps/software/gcc-12.1.0/miniconda3/24.9.2
if [ -r "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
  source "$CONDA_BASE/etc/profile.d/conda.sh"
else
  # fallback: initialize Lmod, then load the module hierarchy
  [ -r /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
  module load gcc/12.1.0 miniconda3/24.9.2
  source "$(conda info --base)/etc/profile.d/conda.sh"
fi

conda activate "$ROOT/envs/biobakery_workflows"

# CRI's default LD_LIBRARY_PATH ships /apps/default/lib, whose Java-8 libjli breaks
# the conda env's newer java ("undefined symbol: JLI_StringDup"), which kills
# Trimmomatic inside KneadData. Strip it so java resolves its own libjli via RPATH.
# Grid jobs inherit this cleaned value through sbatch --export=ALL.
#
# `|| true` is load-bearing: when /apps/default/lib is the ONLY entry -- which is exactly
# the case in a NON-INTERACTIVE submit shell (LD_LIBRARY_PATH="/apps/default/lib:") -- grep
# strips everything and exits 1 (no lines matched). Under `set -euo pipefail` that would
# SILENTLY kill the whole run at activation. An empty result is correct here, not an error.
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  LD_LIBRARY_PATH="$(printf '%s' "$LD_LIBRARY_PATH" | tr ':' '\n' | grep -vxF '/apps/default/lib' | grep -v '^$' | paste -sd: - || true)"
  export LD_LIBRARY_PATH
fi
