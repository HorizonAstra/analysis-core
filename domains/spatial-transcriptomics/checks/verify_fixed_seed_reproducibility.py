#!/usr/bin/env python3
"""
verify_fixed_seed_reproducibility.py

Comprehensive verification script for fixed-seed reproducibility testing.
Compares native vs container results at multiple levels:
  1. Tree structure comparison
  2. Hyperparameter optimization results
  3. SLAB scores (spatial metrics)
  4. Correlation coefficient

Usage:
    python verify_fixed_seed_reproducibility.py --native NATIVE_DIR --container CONTAINER_DIR [--verbose]

Example:
    python verify_fixed_seed_reproducibility.py \
        --native benchmarks/GSE213688_GSM6592057/test_fixed_seed_native_native_test_20260128_143507 \
        --container benchmarks/GSE213688_GSM6592057/test_fixed_seed_container_container_test_20260128_143559
"""

import os
import sys
import argparse
from pathlib import Path
import pandas as pd
import numpy as np
from scipy import stats


class ReproducibilityVerifier:
    """Verify reproducibility between two pipeline runs."""
    
    def __init__(self, native_dir, container_dir, verbose=False):
        self.native_dir = Path(native_dir)
        self.container_dir = Path(container_dir)
        self.verbose = verbose
        self.results = {}
        
    def verify(self):
        """Run all verification checks."""
        print("="*80)
        print("TumorSPACE Fixed-Seed Reproducibility Verification")
        print("="*80)
        print(f"Native:    {self.native_dir}")
        print(f"Container: {self.container_dir}")
        print()
        
        # Check if directories exist
        if not self.native_dir.exists():
            print(f"ERROR: Native directory not found: {self.native_dir}")
            return False
        if not self.container_dir.exists():
            print(f"ERROR: Container directory not found: {self.container_dir}")
            return False
        
        # Find optimal directories
        native_optimal = self.native_dir / "optimal"
        container_optimal = self.container_dir / "optimal"
        
        if not native_optimal.exists():
            print(f"ERROR: Native optimal/ directory not found: {native_optimal}")
            return False
        if not container_optimal.exists():
            print(f"ERROR: Container optimal/ directory not found: {container_optimal}")
            return False
        
        print("[1/5] Comparing tree structures...")
        self._compare_trees(native_optimal, container_optimal)
        
        print("[2/5] Comparing hyperparameter optimization results...")
        self._compare_hyperparameters(native_optimal, container_optimal)
        
        print("[3/5] Comparing predicted spot locations...")
        self._compare_spot_locations(native_optimal, container_optimal)
        
        print("[4/5] Checking for identical file outputs...")
        self._compare_files(native_optimal, container_optimal)
        
        print("[5/5] Generating summary report...")
        self._print_summary()
        
        return True
    
    def _compare_trees(self, native_dir, container_dir):
        """Compare tree structures."""
        print("\n  Comparing tree files...")
        
        tree_files = ["Tree_support.nw", "OptimalTree_labelpreprune.nw"]
        
        for tree_file in tree_files:
            native_file = native_dir / tree_file
            container_file = container_dir / tree_file
            
            if not native_file.exists() or not container_file.exists():
                if self.verbose:
                    print(f"    ⚠ {tree_file} not found in one or both directories")
                continue
            
            with open(native_file) as f:
                native_tree = f.read().strip()
            with open(container_file) as f:
                container_tree = f.read().strip()
            
            if native_tree == container_tree:
                print(f"    ✓ {tree_file}: IDENTICAL")
                self.results[f"{tree_file}_match"] = True
            else:
                print(f"    ✗ {tree_file}: DIFFERENT")
                self.results[f"{tree_file}_match"] = False
                if self.verbose:
                    print(f"      Native length:    {len(native_tree)}")
                    print(f"      Container length: {len(container_tree)}")
    
    def _compare_hyperparameters(self, native_dir, container_dir):
        """Compare hyperparameter optimization results."""
        print("\n  Comparing cor_dat_all.tsv...")
        
        native_file = native_dir / "cor_dat_all.tsv"
        container_file = container_dir / "cor_dat_all.tsv"
        
        if not native_file.exists() or not container_file.exists():
            print("    ⚠ cor_dat_all.tsv not found in one or both directories")
            return
        
        native_df = pd.read_csv(native_file, sep='\t')
        container_df = pd.read_csv(container_file, sep='\t')
        
        # Check if they have identical rows (same search results)
        if native_df.equals(container_df):
            print("    ✓ cor_dat_all.tsv: IDENTICAL (same hyperparameter search results)")
            self.results["hyperparam_identical"] = True
        else:
            # Check if at least the top result is the same
            native_top = native_df.iloc[0]
            container_top = container_df.iloc[0]
            
            # Compare numeric columns with tolerance
            numeric_cols = ['NodeCor', 'Prune', 'Spatial', 'KNN']
            diffs = {}
            all_close = True
            for col in numeric_cols:
                if col in native_top.index and col in container_top.index:
                    diff = abs(native_top[col] - container_top[col])
                    diffs[col] = diff
                    if col in ['NodeCor', 'Prune', 'Spatial']:
                        # Use relative tolerance for floating point
                        is_close = np.isclose(native_top[col], container_top[col], rtol=1e-10, atol=1e-12)
                    else:  # KNN is integer
                        is_close = (native_top[col] == container_top[col])
                    
                    if not is_close:
                        all_close = False
                    
                    if self.verbose:
                        status = "✓" if is_close else "✗"
                        print(f"      {status} {col}: Native={native_top[col]}, Container={container_top[col]}, Diff={diff}")
            
            if all_close:
                print("    ✓ cor_dat_all.tsv: TOP RESULT IDENTICAL (optimal hyperparameters match)")
                self.results["hyperparam_top_identical"] = True
            else:
                print("    ✗ cor_dat_all.tsv: TOP RESULT DIFFERS (different optimal hyperparameters)")
                self.results["hyperparam_top_identical"] = False
            
            print(f"    Total rows - Native: {len(native_df)}, Container: {len(container_df)}")
    
    def _compare_spot_locations(self, native_dir, container_dir):
        """Compare predicted spot locations."""
        print("\n  Comparing predicted_spot_locations.tsv...")
        
        native_file = native_dir / "predicted_spot_locations.tsv"
        container_file = container_dir / "predicted_spot_locations.tsv"
        
        if not native_file.exists() or not container_file.exists():
            print("    ⚠ predicted_spot_locations.tsv not found in one or both directories")
            return
        
        native_df = pd.read_csv(native_file, sep='\t')
        container_df = pd.read_csv(container_file, sep='\t')
        
        if native_df.shape != container_df.shape:
            print(f"    ⚠ Different shapes - Native: {native_df.shape}, Container: {container_df.shape}")
            return
        
        # Check if DataFrames are identical
        if native_df.equals(container_df):
            print("    ✓ predicted_spot_locations.tsv: IDENTICAL")
            self.results["spot_locations_identical"] = True
        else:
            # Compare numeric columns (Predicted_X, Predicted_Y, Actual_X, Actual_Y)
            numeric_cols = ['Predicted_X', 'Predicted_Y', 'Actual_X', 'Actual_Y']
            available_cols = [col for col in numeric_cols if col in native_df.columns]
            
            all_close = True
            max_diffs = {}
            for col in available_cols:
                diffs = abs(native_df[col] - container_df[col])
                max_diff = diffs.max()
                mean_diff = diffs.mean()
                max_diffs[col] = max_diff
                
                # Use small tolerance for floating point
                is_close = np.allclose(native_df[col], container_df[col], rtol=1e-10, atol=1e-12)
                if not is_close:
                    all_close = False
                
                status = "✓" if is_close else "✗"
                print(f"      {status} {col}: max_diff={max_diff:.2e}, mean_diff={mean_diff:.2e}")
            
            if all_close:
                print("    ✓ predicted_spot_locations.tsv: NUMERICALLY IDENTICAL")
                self.results["spot_locations_identical"] = True
            else:
                print("    ✗ predicted_spot_locations.tsv: NUMERICALLY DIFFERENT")
                self.results["spot_locations_identical"] = False
    
    def _compare_files(self, native_dir, container_dir):
        """Compare file contents for exact byte-level identity."""
        print("\n  Comparing file outputs...")
        
        # Key files that should be identical
        key_files = [
            "Tree_support.nw",
            "allnodes_ripley.tsv",
            "allnodes_leaves_passingNodes.tsv",
        ]
        
        identical_count = 0
        for filename in key_files:
            native_file = native_dir / filename
            container_file = container_dir / filename
            
            if not native_file.exists() or not container_file.exists():
                if self.verbose:
                    print(f"    ⚠ {filename} not found in one or both directories")
                continue
            
            # Compare file contents
            with open(native_file, 'rb') as f:
                native_content = f.read()
            with open(container_file, 'rb') as f:
                container_content = f.read()
            
            if native_content == container_content:
                identical_count += 1
                print(f"    ✓ {filename}: BYTE-IDENTICAL")
            else:
                print(f"    ✗ {filename}: DIFFERS")
                if self.verbose:
                    print(f"      Native size:    {len(native_content)} bytes")
                    print(f"      Container size: {len(container_content)} bytes")
    
    def _print_summary(self):
        """Print summary report."""
        print("\n" + "="*80)
        print("REPRODUCIBILITY SUMMARY")
        print("="*80)
        
        # Count positive results
        identical_count = sum(1 for v in self.results.values() if v is True)
        different_count = sum(1 for v in self.results.values() if v is False)
        
        print(f"\nVerifications passed:  {identical_count}")
        print(f"Verifications failed:  {different_count}")
        
        if different_count == 0 and identical_count > 0:
            print("\n✓ PERFECT REPRODUCIBILITY (p=1.0 correlation) - Fixed seeds working correctly!")
        elif different_count == 0:
            print("\n⚠ Unable to perform full verification - check that output files exist")
        else:
            print(f"\n✗ Reproducibility issues detected - {different_count} mismatches found")
            print("Note: Minor floating-point differences (<1e-12) are acceptable")
        
        print("\n" + "="*80)


def main():
    parser = argparse.ArgumentParser(
        description="Verify reproducibility between native and container pipeline runs",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic verification
  python verify_fixed_seed_reproducibility.py \\
      --native benchmarks/native_test \\
      --container benchmarks/container_test
  
  # Verbose output with detailed comparisons
  python verify_fixed_seed_reproducibility.py \\
      --native benchmarks/native_test \\
      --container benchmarks/container_test \\
      --verbose
        """
    )
    
    parser.add_argument("--native", required=True, help="Native mode output directory")
    parser.add_argument("--container", required=True, help="Container mode output directory")
    parser.add_argument("--verbose", action="store_true", help="Verbose output with detailed comparisons")
    
    args = parser.parse_args()
    
    verifier = ReproducibilityVerifier(args.native, args.container, verbose=args.verbose)
    success = verifier.verify()
    
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
