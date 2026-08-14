#!/usr/bin/env bash
# Build (or rebuild) the biobakery_workflows conda env from a lock file, then
# apply all fixups. This encodes the hard-won rules so the rebuild is one command:
#
#   bash bin/build_env.sh            # newest envs/exports/*.lock
#   bash bin/build_env.sh <lock>     # explicit lock
#
# WHY the specifics:
#  - MUST run on a COMPUTE node (env builds are moderately heavy; keep them off the
#    shared login node -- same policy as the runner). We refuse login nodes.
#  - `--copy` makes the env's files INDEPENDENT of the shared pkg cache. Default
#    conda HARDLINKS from the cache (same FS), so our in-place patches would corrupt
#    the cache's copies (-> SafetyError on later rebuilds). --copy also makes the
#    env survive a repo-dir rename. Costs a few GB of disk; worth it.
#  - conda is sourced directly (not via activate.sh, which would try to activate an
#    env that doesn't exist yet).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# refuse login nodes (same guard as bin/submit_wmgx.sh)
case "$(hostname -s)" in
  cri22in*) [ "${ALLOW_LOGIN_NODE:-}" = 1 ] || {
    echo "ERROR: on login node $(hostname -s). Build on a compute node first:" >&2
    echo "       srun -p tier1q --account=dfi -t 02:00:00 --mem=16G -c 8 --pty bash" >&2
    echo "       (override at your own risk: ALLOW_LOGIN_NODE=1)" >&2
    exit 1; } ;;
esac

LOCK="${1:-$(ls -t "$ROOT"/envs/exports/*.lock 2>/dev/null | head -1)}"
[ -n "${LOCK:-}" ] && [ -r "$LOCK" ] || { echo "ERROR: no readable lock (envs/exports/*.lock or pass one as arg 1)" >&2; exit 1; }
PREFIX="$ROOT/envs/biobakery_workflows"

# initialize conda WITHOUT activating (env may not exist yet)
CONDA_BASE=/apps/software/gcc-12.1.0/miniconda3/24.9.2
if [ -r "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
  source "$CONDA_BASE/etc/profile.d/conda.sh"
else
  [ -r /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
  module load gcc/12.1.0 miniconda3/24.9.2
  source "$(conda info --base)/etc/profile.d/conda.sh"
fi
export CONDA_PKGS_DIRS="${CONDA_PKGS_DIRS:-/gpfs/data/dfi-cores/rijul/.conda/pkgs}"

echo "lock   : $LOCK"
echo "prefix : $PREFIX"
[ -e "$PREFIX" ] && { echo "removing existing env"; rm -rf "$PREFIX"; }

conda create -y --copy --prefix "$PREFIX" --file "$LOCK"

echo; echo "== env built; applying fixups (postinstall) =="
bash "$ROOT/bin/postinstall.sh"   # sub-scripts call the env python by absolute path; no activation needed
echo; echo "DONE. Activate with:  source $ROOT/config/activate.sh"
