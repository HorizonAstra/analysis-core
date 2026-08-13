#!/usr/bin/env bash
# Re-runnable. Copies everything the manifest places, and nothing it excludes.
# Rows marked rewrite/split/merge land at their destination unchanged; the edit happens after.
set -euo pipefail
# Refuse to overwrite anything that has been edited in the destination tree.
# The first run of this script populates the tree; every run after it is filling
# gaps. Silently restoring an original over a rewrite loses the work and, worse,
# looks like nothing happened. --force is for when that is genuinely wanted.
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$DEST_ROOT" in */analysis-core) :;; *) echo "refusing: destination is not analysis-core"; exit 1;; esac
repo_dir() { case "$1" in
  tumorspace) echo TumorSpace;;
  toolkit)    echo llm-analysis-toolkit;;
  biobakery)  echo local-biobakery;;
esac; }
copied=0; skipped=0
while IFS=$'\t' read -r repo src dest action note; do
  [[ "$repo" == \#* || -z "${repo:-}" || "$repo" == "-" ]] && continue
  case "$action" in exclude|superseded|rewritten) skipped=$((skipped+1)); continue;; esac
  [[ "$dest" == "-" ]] && { skipped=$((skipped+1)); continue; }
  for s in $src; do
    from="$SRC_ROOT/$(repo_dir "$repo")/$s"
    [[ -e "$from" ]] || { echo "missing: $from"; continue; }
    to="$DEST_ROOT/$dest"
    if [[ -d "$from" ]]; then
      mkdir -p "$to"
      if [ "$FORCE" -eq 0 ]; then
        edited=$(rsync -rin --exclude '__pycache__' --exclude '.DS_Store' --exclude '*.pyc' \
                   --exclude '.git' --exclude 'renv/library' --exclude '.venv' \
                   --exclude 'rlib' --exclude 'renv/staging' \
                   "$from" "$to" 2>/dev/null | grep -c '^>f\.' || true)
        if [ "${edited:-0}" -gt 0 ]; then
          echo "skip (edited here): $dest"; skipped=$((skipped+1)); continue
        fi
      fi
      rsync -a \
        --exclude '__pycache__' --exclude '.DS_Store' --exclude '*.pyc' \
        --exclude '.git' --exclude 'renv/library' --exclude '.venv' \
        --exclude 'rlib' --exclude 'renv/staging' \
        "$from" "$to"
    else
      case "$dest" in */) mkdir -p "$to"; target="$to/$(basename "$from")";; *) mkdir -p "$(dirname "$to")"; target="$to";; esac
      if [ "$FORCE" -eq 0 ] && [ -e "$target" ] && ! cmp -s "$from" "$target"; then
        echo "skip (edited here): $dest$(basename "$from")"; skipped=$((skipped+1)); continue
      fi
      rsync -a "$from" "$to"
    fi
    copied=$((copied+1))
  done
done < "$DEST_ROOT/_migration/manifest.tsv"
echo "copied $copied, skipped $skipped"
