#!/usr/bin/env bash
# What this domain's pipeline toolchain reports about itself on the machine it
# is running on. It computes nothing. It exists so that the environment can be
# proven to activate before anything expensive is submitted into it.
set -euo pipefail
out="$1"
mkdir -p "$(dirname "$out")"
{
  echo "metaphlan: $(metaphlan --version 2>&1 | head -1)"
  echo "humann:    $(humann --version 2>&1 | head -1)"
  echo "kneaddata: $(kneaddata --version 2>&1 | head -1)"
  echo "workflows: $(biobakery_workflows --version 2>&1 | head -1)"
} > "$out"
cat "$out"
echo "TOOLCHAIN_OK"
