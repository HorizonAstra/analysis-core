#!/usr/bin/env bash
# Recreate runtime dirs that git does not carry (empty and/or gitignored).
# Run once after cloning on any machine:  ./bootstrap.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # repo root = biobakery/

mkdir -p "$HERE/references" "$HERE/envs/exports"
mkdir -p "$(dirname "$HERE")/studies"                  # sibling data home (outside the repo)
mkdir -p "/scratch/${USER}/biobakery" 2>/dev/null || true

echo "bootstrap complete:"
echo "  tool:    $HERE"
echo "  studies: $(dirname "$HERE")/studies"
echo "  scratch: /scratch/${USER}/biobakery"
