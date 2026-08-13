#!/usr/bin/env python3
"""
KL_Compare_TumorSPACE_v1.py

Production-mode comparison of TumorSPACE outputs between a reference run
(from TumorSPACE/expected_outputs/{sample}/) and a new independent run.

Adapted from TumorSPACE_AWS/benchmarking/verify_fixed_seed_reproducibility.py.
Unlike the fixed-seed version, this uses correlation-based thresholds
appropriate for production runs (30 SVDs, no fixed seed).

Usage — single sample:
    python KL_Compare_TumorSPACE_v1.py \\
        --reference expected_outputs/1R \\
        --new-run /path/to/1R_container_prod_{timestamp}

Usage — all samples (batch mode):
    python KL_Compare_TumorSPACE_v1.py \\
        --reference-dir expected_outputs \\
        --new-run-dir /path/to/run_root \\
        --batch \\
        --report comparison_report.md

Five checks per sample:
    1. optimal_svd.txt         — NodeCor agreement (rtol <= 0.10)
    2. cor_dat_all.tsv         — top NodeCor + KNN agreement (rtol <= 0.10)
    3. predicted_spot_locations.tsv — Pearson R on Predicted_X/Y (>= 0.95)
    4. DA_significant.txt      — Jaccard gene overlap per SG pair (>= 0.30)
    5. SLAB_scores.txt         — Pearson R on SLAB column (>= 0.90)
"""

import os
import sys
import re
import glob
import argparse
from pathlib import Path
from datetime import datetime

import pandas as pd
import numpy as np
from scipy import stats


# ── Default thresholds ────────────────────────────────────────────────────────
DEFAULT_NODECOR_RTOL  = 0.10   # Check 1+2: NodeCor relative tolerance
DEFAULT_SPOT_R        = 0.95   # Check 3: min Pearson R for spot locations
DEFAULT_JACCARD       = 0.30   # Check 4: min median Jaccard for DA genes
DEFAULT_SLAB_R        = 0.90   # Check 5: min Pearson R for SLAB scores

SAMPLES_BATCH1 = ["1R", "2R", "4R", "6R", "1N", "7N", "13N", "14N"]
SAMPLES_BATCH2 = ["5R", "10R", "14R", "15R", "16R", "21N", "22N", "23N", "24N", "25N", "26N"]
ALL_SAMPLES    = SAMPLES_BATCH1 + SAMPLES_BATCH2


# ── Helpers ───────────────────────────────────────────────────────────────────

def parse_optimal_svd(path: Path) -> dict:
    """Parse optimal_svd.txt and return dict of key → value."""
    result = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#") or not line:
                continue
            if ":" in line:
                key, _, val = line.partition(":")
                result[key.strip()] = val.strip()
    return result


def find_svd_run_dir(job_dir: Path, svd_number: str) -> Path:
    """Locate svd_run_{N}/ within a job directory."""
    candidate = job_dir / f"svd_run_{svd_number}"
    if candidate.is_dir():
        return candidate
    # Fallback: search for any svd_run_* dir (in case number format differs)
    matches = sorted(job_dir.glob("svd_run_*"))
    if matches:
        return matches[0]
    return candidate  # Return non-existent path; caller handles missing


def pearson_r(a: np.ndarray, b: np.ndarray) -> float:
    """Return Pearson R, handling constant arrays."""
    if len(a) < 2:
        return float("nan")
    if np.std(a) == 0 or np.std(b) == 0:
        return 1.0 if np.allclose(a, b) else 0.0
    r, _ = stats.pearsonr(a, b)
    return float(r)


def jaccard(set_a: set, set_b: set) -> float:
    """Return Jaccard index between two sets."""
    if not set_a and not set_b:
        return 1.0
    union = set_a | set_b
    if not union:
        return 1.0
    return len(set_a & set_b) / len(union)


# ── Main comparison class ─────────────────────────────────────────────────────

class TumorSPACEComparison:
    """Compare one reference sample dir against one new-run job dir."""

    def __init__(self, reference_dir: Path, new_run_dir: Path,
                 nodecor_rtol: float = DEFAULT_NODECOR_RTOL,
                 min_spot_r: float = DEFAULT_SPOT_R,
                 min_jaccard: float = DEFAULT_JACCARD,
                 min_slab_r: float = DEFAULT_SLAB_R,
                 verbose: bool = False):
        self.ref      = Path(reference_dir)
        self.new      = Path(new_run_dir)
        self.nodecor_rtol = nodecor_rtol
        self.min_spot_r   = min_spot_r
        self.min_jaccard  = min_jaccard
        self.min_slab_r   = min_slab_r
        self.verbose      = verbose
        self.check_results = {}  # check_name -> (passed: bool, message: str)
        self.sample_name   = self.ref.name

    # ── Top-level ──────────────────────────────────────────────────────────────

    def run(self) -> bool:
        """Run all five checks. Returns True if all pass."""
        print("=" * 80)
        print(f"TumorSPACE Production-Mode Comparison: {self.sample_name}")
        print("=" * 80)

        if not self.ref.is_dir():
            print(f"ERROR: reference directory not found: {self.ref}")
            return False
        if not self.new.is_dir():
            print(f"ERROR: new-run directory not found: {self.new}")
            return False

        # Load optimal SVD info for both runs
        ref_svd_file = self.ref / "optimal_svd.txt"
        new_svd_file = self.new / "optimal_svd.txt"

        if not ref_svd_file.exists():
            print(f"ERROR: reference optimal_svd.txt not found: {ref_svd_file}")
            return False
        if not new_svd_file.exists():
            print(f"ERROR: new-run optimal_svd.txt not found: {new_svd_file}")
            return False

        ref_svd = parse_optimal_svd(ref_svd_file)
        new_svd = parse_optimal_svd(new_svd_file)

        ref_n = ref_svd.get("SVD_Number", "?")
        new_n = new_svd.get("SVD_Number", "?")
        ref_nc = ref_svd.get("NodeCor", "?")
        new_nc = new_svd.get("NodeCor", "?")

        print(f"Reference: {self.ref}  (SVD run {ref_n}, NodeCor={ref_nc})")
        print(f"New run:   {self.new}  (SVD run {new_n}, NodeCor={new_nc})")
        print()

        # Locate svd_run directories
        ref_svd_dir = find_svd_run_dir(self.ref, ref_n)
        new_svd_dir = find_svd_run_dir(self.new, new_n)

        self._check_nodecor(ref_svd, new_svd)
        self._check_hyperparams(ref_svd_dir, new_svd_dir)
        self._check_spot_locations(ref_svd_dir, new_svd_dir)
        self._check_da_jaccard()
        self._check_slab_correlation()

        return self._print_summary()

    # ── Check 1: NodeCor ──────────────────────────────────────────────────────

    def _check_nodecor(self, ref_svd: dict, new_svd: dict):
        print("[1/5] Optimal SVD parameters (optimal_svd.txt)...")
        try:
            ref_nc = float(ref_svd["NodeCor"])
            new_nc = float(new_svd["NodeCor"])
        except (KeyError, ValueError) as e:
            self._record("nodecor", False, f"Could not parse NodeCor: {e}")
            return

        diff_pct = abs(ref_nc - new_nc) / max(abs(ref_nc), 1e-12) * 100
        passed   = abs(ref_nc - new_nc) <= self.nodecor_rtol * abs(ref_nc)
        msg = (f"ref={ref_nc:.4f}, new={new_nc:.4f}, "
               f"diff={diff_pct:.1f}%  {'PASS' if passed else 'FAIL'}")
        print(f"      NodeCor: {msg}")

        if self.verbose:
            ref_knn = ref_svd.get("KNN", "?")
            new_knn = new_svd.get("KNN", "?")
            print(f"      KNN:     ref={ref_knn}, new={new_knn}")
            print(f"      SVD run: ref={ref_svd.get('SVD_Number','?')}, "
                  f"new={new_svd.get('SVD_Number','?')}")

        self._record("nodecor", passed, msg)

    # ── Check 2: Hyperparameter search top result ─────────────────────────────

    def _check_hyperparams(self, ref_svd_dir: Path, new_svd_dir: Path):
        print("[2/5] Hyperparameter search top result (cor_dat_all.tsv)...")
        ref_f = ref_svd_dir / "cor_dat_all.tsv"
        new_f = new_svd_dir / "cor_dat_all.tsv"

        if not ref_f.exists() or not new_f.exists():
            msg = f"cor_dat_all.tsv missing ({'ref' if not ref_f.exists() else 'new-run'})"
            print(f"      WARNING: {msg} — skipping")
            self._record("hyperparams", None, msg)
            return

        ref_df = pd.read_csv(ref_f, sep="\t")
        new_df = pd.read_csv(new_f, sep="\t")

        ref_top = ref_df.iloc[0]
        new_top = new_df.iloc[0]

        passed_nc  = True
        passed_knn = True
        msgs = []

        for col in ["NodeCor"]:
            if col in ref_top.index and col in new_top.index:
                rv, nv = float(ref_top[col]), float(new_top[col])
                diff_pct = abs(rv - nv) / max(abs(rv), 1e-12) * 100
                ok = abs(rv - nv) <= self.nodecor_rtol * abs(rv)
                passed_nc = ok
                status = "PASS" if ok else "FAIL"
                msg = f"ref={rv:.4f}, new={nv:.4f}, diff={diff_pct:.1f}%  {status}"
                print(f"      NodeCor (top): {msg}")
                msgs.append(f"NodeCor {msg}")

        if "KNN" in ref_top.index and "KNN" in new_top.index:
            rv, nv = int(ref_top["KNN"]), int(new_top["KNN"])
            ok = (rv == nv)
            passed_knn = ok
            status = "PASS" if ok else "NOTE"
            print(f"      KNN (top):     ref={rv}, new={nv}  {status}")
            msgs.append(f"KNN ref={rv} new={nv}")

        if self.verbose:
            print(f"      Rows in ref: {len(ref_df)}, in new: {len(new_df)}")

        # KNN mismatch is informational only; only NodeCor drives pass/fail
        self._record("hyperparams", passed_nc, "; ".join(msgs))

    # ── Check 3: Predicted spot locations ─────────────────────────────────────

    def _check_spot_locations(self, ref_svd_dir: Path, new_svd_dir: Path):
        print("[3/5] Predicted spot locations (predicted_spot_locations.tsv)...")
        ref_f = ref_svd_dir / "predicted_spot_locations.tsv"
        new_f = new_svd_dir / "predicted_spot_locations.tsv"

        if not ref_f.exists() or not new_f.exists():
            msg = ("predicted_spot_locations.tsv missing "
                   f"({'ref' if not ref_f.exists() else 'new-run'})")
            print(f"      WARNING: {msg} — skipping")
            self._record("spot_locations", None, msg)
            return

        ref_df = pd.read_csv(ref_f, sep="\t")
        new_df = pd.read_csv(new_f, sep="\t")

        # Align on barcode (rows may differ in order or count)
        ref_df = ref_df.set_index("Barcode_1")
        new_df = new_df.set_index("Barcode_1")
        common = ref_df.index.intersection(new_df.index)

        if len(common) == 0:
            self._record("spot_locations", False, "No shared barcodes between runs")
            print("      ERROR: no shared barcodes — check sample identity")
            return

        frac_common = len(common) / max(len(ref_df), len(new_df))
        if self.verbose:
            print(f"      Shared barcodes: {len(common)} "
                  f"({frac_common:.1%} of larger set)")

        msgs = []
        all_pass = True
        for col in ["Predicted_X", "Predicted_Y"]:
            if col not in ref_df.columns or col not in new_df.columns:
                continue
            r = pearson_r(ref_df.loc[common, col].values,
                          new_df.loc[common, col].values)
            ok = (not np.isnan(r)) and (r >= self.min_spot_r)
            all_pass = all_pass and ok
            status = "PASS" if ok else "FAIL"
            print(f"      Pearson R ({col}): {r:.4f}  {status}")
            msgs.append(f"{col} R={r:.4f}")

        self._record("spot_locations", all_pass, "; ".join(msgs))

    # ── Check 4: DA gene Jaccard ───────────────────────────────────────────────

    def _check_da_jaccard(self):
        print("[4/5] DA gene overlap per SG pair (DA_significant.txt)...")
        ref_f = self.ref / "optimal" / "gene" / "DA_significant.txt"
        new_f = self.new / "optimal" / "gene" / "DA_significant.txt"

        if not ref_f.exists() or not new_f.exists():
            msg = ("DA_significant.txt missing "
                   f"({'ref' if not ref_f.exists() else 'new-run'})")
            print(f"      WARNING: {msg} — skipping")
            self._record("da_jaccard", None, msg)
            return

        ref_df = pd.read_csv(ref_f, sep="\t")
        new_df = pd.read_csv(new_f, sep="\t")

        # Columns: DA_Object, Mean_Node, Mean_Sibling, P, Q, Node, Sibling
        # Build a per-SG-pair gene set using (Node, Sibling) as pair key.
        def pair_gene_sets(df: pd.DataFrame) -> dict:
            """Return dict: (node, sibling) -> frozenset of gene IDs."""
            sets = {}
            if "Node" not in df.columns or "Sibling" not in df.columns:
                # Fallback: treat entire file as one set
                gene_col = "DA_Object" if "DA_Object" in df.columns else df.columns[0]
                return {("all", "all"): frozenset(df[gene_col].dropna())}
            gene_col = "DA_Object" if "DA_Object" in df.columns else df.columns[0]
            for (node, sib), grp in df.groupby(["Node", "Sibling"]):
                pair = (str(node), str(sib))
                sets[pair] = frozenset(grp[gene_col].dropna())
            return sets

        ref_sets = pair_gene_sets(ref_df)
        new_sets = pair_gene_sets(new_df)
        all_pairs = set(ref_sets) | set(new_sets)

        jaccards = []
        for pair in all_pairs:
            r_set = ref_sets.get(pair, frozenset())
            n_set = new_sets.get(pair, frozenset())
            jaccards.append(jaccard(r_set, n_set))

        if not jaccards:
            self._record("da_jaccard", False, "No SG pairs found")
            print("      No SG pairs found")
            return

        med_j = float(np.median(jaccards))
        min_j = float(np.min(jaccards))
        passed = med_j >= self.min_jaccard

        print(f"      SG pairs evaluated: {len(jaccards)} "
              f"(ref: {len(ref_sets)}, new: {len(new_sets)})")
        print(f"      Median Jaccard: {med_j:.3f}  "
              f"{'PASS' if passed else 'FAIL'}  (threshold: {self.min_jaccard})")
        print(f"      Min Jaccard:    {min_j:.3f}")

        if self.verbose:
            sorted_pairs = sorted(zip(all_pairs, jaccards), key=lambda x: x[1])
            print("      Bottom 5 SG pairs by Jaccard:")
            for pair, j in sorted_pairs[:5]:
                print(f"        {pair[0]} vs {pair[1]}: {j:.3f}")

        self._record("da_jaccard", passed,
                     f"median_jaccard={med_j:.3f}, min={min_j:.3f}, pairs={len(jaccards)}")

    # ── Check 5: SLAB score correlation ───────────────────────────────────────

    def _check_slab_correlation(self):
        print("[5/5] SLAB score correlation (SLAB_scores.txt)...")
        ref_f = self.ref / "optimal" / "gene" / "SLAB_scores.txt"
        new_f = self.new / "optimal" / "gene" / "SLAB_scores.txt"

        if not ref_f.exists() or not new_f.exists():
            msg = ("SLAB_scores.txt missing "
                   f"({'ref' if not ref_f.exists() else 'new-run'})")
            print(f"      WARNING: {msg} — skipping")
            self._record("slab_r", None, msg)
            return

        ref_df = pd.read_csv(ref_f, sep="\t")
        new_df = pd.read_csv(new_f, sep="\t")

        # Columns: DA_Object, Dir, N, Spots, SLAB
        # Align on (DA_Object, Dir) key to match entries across runs
        score_col = "SLAB"
        key_cols  = ["DA_Object", "Dir"]

        if not all(c in ref_df.columns for c in key_cols + [score_col]):
            # Fallback: just correlate score columns in order
            ref_scores = ref_df.select_dtypes(include=[np.number]).iloc[:, -1].values
            new_scores = new_df.select_dtypes(include=[np.number]).iloc[:, -1].values
            n = min(len(ref_scores), len(new_scores))
            r = pearson_r(ref_scores[:n], new_scores[:n])
        else:
            ref_df = ref_df.set_index(key_cols)[score_col]
            new_df = new_df.set_index(key_cols)[score_col]
            common = ref_df.index.intersection(new_df.index)

            if len(common) == 0:
                self._record("slab_r", False, "No shared DA_Object/Dir entries")
                print("      ERROR: no shared SLAB entries between runs")
                return

            frac = len(common) / max(len(ref_df), len(new_df))
            if self.verbose:
                print(f"      Shared SLAB entries: {len(common)} "
                      f"({frac:.1%} of larger set)")

            r = pearson_r(ref_df.loc[common].values, new_df.loc[common].values)

        passed = (not np.isnan(r)) and (r >= self.min_slab_r)
        status = "PASS" if passed else "FAIL"
        print(f"      Pearson R (SLAB): {r:.4f}  {status}  "
              f"(threshold: {self.min_slab_r})")
        self._record("slab_r", passed, f"R={r:.4f}")

    # ── Summary ───────────────────────────────────────────────────────────────

    def _record(self, name: str, passed, message: str):
        self.check_results[name] = (passed, message)

    def _print_summary(self) -> bool:
        print()
        print("=" * 80)
        print("SUMMARY")
        print("=" * 80)

        check_labels = {
            "nodecor":       "1. NodeCor agreement",
            "hyperparams":   "2. Hyperparameter top result",
            "spot_locations":"3. Predicted spot locations",
            "da_jaccard":    "4. DA gene Jaccard overlap",
            "slab_r":        "5. SLAB score correlation",
        }

        n_pass = n_fail = n_skip = 0
        for key, label in check_labels.items():
            passed, msg = self.check_results.get(key, (None, "not run"))
            if passed is True:
                symbol = "PASS"
                n_pass += 1
            elif passed is False:
                symbol = "FAIL"
                n_fail += 1
            else:
                symbol = "SKIP"
                n_skip += 1
            print(f"  {symbol}  {label}")
            if passed is False:
                print(f"       → {msg}")

        print()
        if n_fail == 0 and n_pass > 0:
            print(f"  {n_pass}/{n_pass + n_skip} checks PASSED "
                  f"({n_skip} skipped due to missing files)")
        else:
            print(f"  {n_pass} passed / {n_fail} failed / {n_skip} skipped")

        print("=" * 80)
        return n_fail == 0


# ── Batch runner ──────────────────────────────────────────────────────────────

def find_new_run_dir(new_run_root: Path, sample: str, pattern: str) -> Path | None:
    """Locate the new-run job directory for a given sample."""
    glob_pattern = pattern.replace("{sample}", sample)
    matches = sorted(new_run_root.glob(glob_pattern))
    if not matches:
        return None
    return matches[-1]  # most recent if multiple


def run_batch(args) -> int:
    """Run comparisons for all 19 samples. Returns number of failures."""
    ref_root     = Path(args.reference_dir)
    new_run_root = Path(args.new_run_dir)
    pattern      = getattr(args, "new_run_pattern", "{sample}_container_prod_*")

    results = {}  # sample -> (n_fail, n_skip)
    for sample in ALL_SAMPLES:
        ref_dir = ref_root / sample
        if not ref_dir.is_dir():
            print(f"[{sample}] SKIP — reference dir not found: {ref_dir}")
            results[sample] = ("SKIP", "reference not found")
            continue

        new_dir = find_new_run_dir(new_run_root, sample, pattern)
        if new_dir is None:
            print(f"[{sample}] SKIP — new-run dir not found in {new_run_root} "
                  f"(pattern: {pattern.replace('{sample}', sample)})")
            results[sample] = ("SKIP", "new-run not found")
            continue

        print()
        comp = TumorSPACEComparison(
            reference_dir=ref_dir,
            new_run_dir=new_dir,
            nodecor_rtol=args.nodecor_rtol,
            min_spot_r=args.min_spot_r,
            min_jaccard=args.min_jaccard,
            min_slab_r=args.min_slab_r,
            verbose=args.verbose,
        )
        passed = comp.run()
        results[sample] = ("PASS" if passed else "FAIL", "")

    # Batch summary
    print()
    print("=" * 80)
    print("BATCH SUMMARY")
    print("=" * 80)
    n_pass = sum(1 for v in results.values() if v[0] == "PASS")
    n_fail = sum(1 for v in results.values() if v[0] == "FAIL")
    n_skip = sum(1 for v in results.values() if v[0] == "SKIP")
    print(f"  PASS: {n_pass}  FAIL: {n_fail}  SKIP: {n_skip}  Total: {len(results)}")
    print()
    for sample in ALL_SAMPLES:
        status, note = results.get(sample, ("?", ""))
        suffix = f"  ({note})" if note else ""
        batch  = "B1" if sample in SAMPLES_BATCH1 else "B2"
        print(f"  {status:4s}  [{batch}] {sample}{suffix}")
    print("=" * 80)

    # Optional markdown report
    if getattr(args, "report", None):
        _write_batch_report(args.report, results)

    return n_fail


def _write_batch_report(path: str, results: dict):
    lines = [
        "# TumorSPACE Comparison Report",
        f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        "",
        "| Sample | Batch | Status |",
        "|--------|-------|--------|",
    ]
    for sample in ALL_SAMPLES:
        status, note = results.get(sample, ("?", ""))
        batch = "1" if sample in SAMPLES_BATCH1 else "2"
        note_str = f" ({note})" if note else ""
        lines.append(f"| {sample} | {batch} | {status}{note_str} |")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Report written to: {path}")


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Production-mode TumorSPACE output comparison",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage")[1] if "Usage" in __doc__ else "",
    )

    # Single-sample mode
    single = parser.add_argument_group("single-sample mode")
    single.add_argument("--reference", metavar="DIR",
                        help="Reference sample directory (expected_outputs/{sample})")
    single.add_argument("--new-run", metavar="DIR",
                        help="New-run job directory for the same sample")

    # Batch mode
    batch = parser.add_argument_group("batch mode")
    batch.add_argument("--batch", action="store_true",
                       help="Compare all 19 samples")
    batch.add_argument("--reference-dir", metavar="DIR",
                       help="Root of reference dirs (expected_outputs/)")
    batch.add_argument("--new-run-dir", metavar="DIR",
                       help="Root containing new-run job dirs per sample")
    batch.add_argument("--new-run-pattern", metavar="GLOB",
                       default="{sample}_container_prod_*",
                       help="Glob pattern for locating new-run dirs "
                            "(default: '{sample}_container_prod_*')")
    batch.add_argument("--report", metavar="FILE",
                       help="Write batch summary to this markdown file")

    # Thresholds
    thresh = parser.add_argument_group("thresholds")
    thresh.add_argument("--nodecor-rtol", type=float, default=DEFAULT_NODECOR_RTOL,
                        metavar="FLOAT",
                        help=f"NodeCor relative tolerance (default: {DEFAULT_NODECOR_RTOL})")
    thresh.add_argument("--min-spot-r", type=float, default=DEFAULT_SPOT_R,
                        metavar="FLOAT",
                        help=f"Min Pearson R for spot locations (default: {DEFAULT_SPOT_R})")
    thresh.add_argument("--min-jaccard", type=float, default=DEFAULT_JACCARD,
                        metavar="FLOAT",
                        help=f"Min median Jaccard for DA genes (default: {DEFAULT_JACCARD})")
    thresh.add_argument("--min-slab-r", type=float, default=DEFAULT_SLAB_R,
                        metavar="FLOAT",
                        help=f"Min Pearson R for SLAB scores (default: {DEFAULT_SLAB_R})")

    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Verbose output with per-pair details")

    args = parser.parse_args()

    # ── Route to single or batch mode ─────────────────────────────────────────
    if args.batch:
        if not args.reference_dir or not args.new_run_dir:
            parser.error("--batch requires --reference-dir and --new-run-dir")
        n_fail = run_batch(args)
        sys.exit(0 if n_fail == 0 else 1)
    else:
        if not args.reference or not args.new_run:
            parser.error("Provide --reference and --new-run, or use --batch mode")
        comp = TumorSPACEComparison(
            reference_dir=Path(args.reference),
            new_run_dir=Path(args.new_run),
            nodecor_rtol=args.nodecor_rtol,
            min_spot_r=args.min_spot_r,
            min_jaccard=args.min_jaccard,
            min_slab_r=args.min_slab_r,
            verbose=args.verbose,
        )
        passed = comp.run()
        sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
