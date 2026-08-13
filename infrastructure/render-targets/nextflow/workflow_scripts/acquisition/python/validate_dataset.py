#!/usr/bin/env python3
"""
Dataset Validation Module

Validate that downloaded and harmonized datasets meet TumorSPACE requirements.
"""

import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd


class DatasetValidator:
    """Validate TumorSPACE input datasets"""
    
    def __init__(self, dataset_dir: Path):
        """
        Initialize validator
        
        Args:
            dataset_dir: Directory containing input_data/ folder
        """
        self.dataset_dir = Path(dataset_dir)
        self.input_dir = self.dataset_dir / "input_data"
        
        self.required_files = {
            "M.txt": "Expression matrix",
            "barcodes.txt": "Spot barcodes",
            "features.txt": "Gene IDs",
            "barcodes_positions.txt": "Spatial positions"
        }
        
        self.validation_results = []
        self.errors = []
        self.warnings = []
        self.metadata = {}
    
    def validate(self, min_spots: int = 100, min_genes: int = 1000) -> bool:
        """
        Run full validation
        
        Args:
            min_spots: Minimum number of spots required
            min_genes: Minimum number of genes required
        
        Returns:
            True if validation passes, False otherwise
        """
        print(f"[Validation] Validating dataset at {self.dataset_dir}")
        
        # Check required files exist
        if not self._check_files_exist():
            self._write_report(success=False)
            return False
        
        # Load and validate each file
        try:
            matrix = self._validate_matrix()
            barcodes = self._validate_barcodes()
            features = self._validate_features()
            positions = self._validate_positions()
        except Exception as e:
            self.errors.append(f"Error loading files: {e}")
            self._write_report(success=False)
            return False
        
        # Check dimensions match
        if not self._check_dimensions(matrix, barcodes, features, positions):
            self._write_report(success=False)
            return False
        
        # Check thresholds
        n_spots, n_genes = matrix.shape
        self.metadata['n_spots'] = n_spots
        self.metadata['n_genes'] = n_genes
        
        if n_spots < min_spots:
            self.errors.append(f"Insufficient spots: {n_spots} < {min_spots}")
        if n_genes < min_genes:
            self.errors.append(f"Insufficient genes: {n_genes} < {min_genes}")
        
        # Check coordinate sanity
        self._check_coordinates(positions)
        
        # Compute summary statistics
        self._compute_statistics(matrix, positions)
        
        # Determine pass/fail
        success = len(self.errors) == 0
        self._write_report(success=success)
        
        return success
    
    def _check_files_exist(self) -> bool:
        """Check that all required files exist"""
        all_exist = True
        
        for filename, description in self.required_files.items():
            filepath = self.input_dir / filename
            if filepath.exists():
                self.validation_results.append(f"✓ {filename} exists")
            else:
                # Check for alternative names
                if filename == "features.txt" and (self.input_dir / "genes.txt").exists():
                    self.validation_results.append(f"✓ genes.txt exists (alternative to features.txt)")
                else:
                    self.errors.append(f"✗ {filename} not found ({description})")
                    all_exist = False
        
        return all_exist
    
    def _validate_matrix(self) -> np.ndarray:
        """Load and validate expression matrix"""
        matrix_path = self.input_dir / "M.txt"
        
        print(f"[Validation] Loading matrix: {matrix_path.name}")
        
        # Load matrix
        try:
            matrix = np.loadtxt(matrix_path, delimiter='\t')
        except Exception as e:
            raise ValueError(f"Could not load M.txt: {e}")
        
        # Check shape
        if matrix.ndim != 2:
            raise ValueError(f"Matrix must be 2D, got {matrix.ndim}D")
        
        n_spots, n_genes = matrix.shape
        self.validation_results.append(f"✓ Matrix shape: {n_spots} spots × {n_genes} genes")
        
        # Check for non-negative values (counts should be >= 0)
        if np.any(matrix < 0):
            self.warnings.append("Matrix contains negative values")
        
        # Check for all-zero rows/columns
        zero_spots = np.sum(matrix, axis=1) == 0
        zero_genes = np.sum(matrix, axis=0) == 0
        
        if np.any(zero_spots):
            n_zero_spots = np.sum(zero_spots)
            self.warnings.append(f"{n_zero_spots} spots have zero total counts")
        
        if np.any(zero_genes):
            n_zero_genes = np.sum(zero_genes)
            self.warnings.append(f"{n_zero_genes} genes have zero expression across all spots")
        
        return matrix
    
    def _validate_barcodes(self) -> List[str]:
        """Load and validate barcodes"""
        barcode_path = self.input_dir / "barcodes.txt"
        
        print(f"[Validation] Loading barcodes: {barcode_path.name}")
        
        with open(barcode_path, 'r') as f:
            lines = [line.strip() for line in f]
        
        # Check header
        if lines[0] != "barcode":
            self.warnings.append(f"Barcodes file header is '{lines[0]}', expected 'barcode'")
        
        barcodes = lines[1:]  # Skip header
        
        self.validation_results.append(f"✓ Loaded {len(barcodes)} barcodes")
        
        # Check for duplicates
        if len(barcodes) != len(set(barcodes)):
            self.errors.append("Duplicate barcodes found")
        
        # Check for empty barcodes
        if any(not bc for bc in barcodes):
            self.errors.append("Empty barcodes found")
        
        return barcodes
    
    def _validate_features(self) -> List[str]:
        """Load and validate features/genes"""
        # Try features.txt first, then genes.txt
        feature_path = self.input_dir / "features.txt"
        if not feature_path.exists():
            feature_path = self.input_dir / "genes.txt"
        
        print(f"[Validation] Loading features: {feature_path.name}")
        
        with open(feature_path, 'r') as f:
            lines = [line.strip() for line in f]
        
        # Check header
        header = lines[0]
        if header not in ["ensembl_gene_id", "gene_id", "feature_id"]:
            self.warnings.append(f"Features file header is '{header}', expected 'ensembl_gene_id' or 'gene_id'")
        
        features = lines[1:]  # Skip header
        
        self.validation_results.append(f"✓ Loaded {len(features)} features")
        
        # Check for duplicates
        if len(features) != len(set(features)):
            n_unique = len(set(features))
            self.warnings.append(f"Duplicate features found ({len(features)} total, {n_unique} unique)")
        
        # Check for empty features
        if any(not f for f in features):
            self.errors.append("Empty feature IDs found")
        
        return features
    
    def _validate_positions(self) -> pd.DataFrame:
        """Load and validate positions"""
        pos_path = self.input_dir / "barcodes_positions.txt"
        
        print(f"[Validation] Loading positions: {pos_path.name}")
        
        positions = pd.read_csv(pos_path, sep='\t')
        
        required_columns = [
            'barcode', 'in_tissue', 'array_row', 'array_col',
            'pxl_row_in_fullres', 'pxl_col_in_fullres',
            'pxl_row_in_mm', 'pxl_col_in_mm'
        ]
        
        # Check columns
        missing_cols = [col for col in required_columns if col not in positions.columns]
        if missing_cols:
            self.errors.append(f"Missing position columns: {', '.join(missing_cols)}")
        else:
            self.validation_results.append(f"✓ All 8 required position columns present")
        
        self.validation_results.append(f"✓ Loaded positions for {len(positions)} spots")
        
        return positions
    
    def _check_dimensions(self, matrix: np.ndarray, barcodes: List[str], 
                         features: List[str], positions: pd.DataFrame) -> bool:
        """Check that dimensions match across all files"""
        n_spots_matrix, n_genes_matrix = matrix.shape
        n_barcodes = len(barcodes)
        n_features = len(features)
        n_positions = len(positions)
        
        dim_match = True
        
        # Spots dimension
        if n_spots_matrix != n_barcodes:
            self.errors.append(f"Dimension mismatch: matrix has {n_spots_matrix} spots, barcodes has {n_barcodes}")
            dim_match = False
        
        if n_spots_matrix != n_positions:
            self.errors.append(f"Dimension mismatch: matrix has {n_spots_matrix} spots, positions has {n_positions}")
            dim_match = False
        
        # Genes dimension
        if n_genes_matrix != n_features:
            self.errors.append(f"Dimension mismatch: matrix has {n_genes_matrix} genes, features has {n_features}")
            dim_match = False
        
        if dim_match:
            self.validation_results.append(f"✓ Dimensions consistent across all files")
        
        return dim_match
    
    def _check_coordinates(self, positions: pd.DataFrame):
        """Check that spatial coordinates are reasonable"""
        if 'pxl_row_in_mm' not in positions.columns or 'pxl_col_in_mm' not in positions.columns:
            return
        
        # Check for negative coordinates
        if (positions['pxl_row_in_mm'] < 0).any() or (positions['pxl_col_in_mm'] < 0).any():
            self.warnings.append("Some spots have negative mm-scale coordinates")
        
        # Check for all-zero mm coordinates (indicates missing scale factors)
        if positions['pxl_row_in_mm'].sum() == 0 and positions['pxl_col_in_mm'].sum() == 0:
            self.warnings.append("All mm-scale coordinates are zero (scale factors may be missing)")
        
        # Check coordinate range (typical Visium slide is ~6.5mm × 6.5mm)
        max_row_mm = positions['pxl_row_in_mm'].max()
        max_col_mm = positions['pxl_col_in_mm'].max()
        
        if max_row_mm > 10 or max_col_mm > 10:
            self.warnings.append(f"Unusually large coordinates: max_row={max_row_mm:.1f}mm, max_col={max_col_mm:.1f}mm (expected <10mm)")
        
        self.metadata['spatial_extent_mm'] = f"{max_row_mm:.2f} × {max_col_mm:.2f}"
    
    def _compute_statistics(self, matrix: np.ndarray, positions: pd.DataFrame):
        """Compute dataset statistics"""
        # Expression statistics
        total_counts = matrix.sum()
        mean_counts_per_spot = matrix.sum(axis=1).mean()
        median_genes_per_spot = np.median((matrix > 0).sum(axis=1))
        
        self.metadata['total_counts'] = int(total_counts)
        self.metadata['mean_counts_per_spot'] = f"{mean_counts_per_spot:.1f}"
        self.metadata['median_genes_per_spot'] = int(median_genes_per_spot)
        
        # Spatial coverage
        if 'in_tissue' in positions.columns:
            n_in_tissue = (positions['in_tissue'] == 1).sum()
            self.metadata['spots_in_tissue'] = n_in_tissue
    
    def _write_report(self, success: bool):
        """Write validation report"""
        report_path = self.dataset_dir / "VALIDATION_REPORT.txt"
        
        with open(report_path, 'w') as f:
            f.write("=" * 60 + "\n")
            f.write("TumorSPACE Dataset Validation Report\n")
            f.write("=" * 60 + "\n\n")
            
            f.write(f"Dataset: {self.dataset_dir.name}\n")
            f.write(f"Status: {'PASS' if success else 'FAIL'}\n\n")
            
            if self.metadata:
                f.write("Metadata:\n")
                for key, value in self.metadata.items():
                    f.write(f"  {key}: {value}\n")
                f.write("\n")
            
            f.write("Validation Results:\n")
            for result in self.validation_results:
                f.write(f"  {result}\n")
            f.write("\n")
            
            if self.warnings:
                f.write("Warnings:\n")
                for warning in self.warnings:
                    f.write(f"  ⚠ {warning}\n")
                f.write("\n")
            
            if self.errors:
                f.write("Errors:\n")
                for error in self.errors:
                    f.write(f"  ✗ {error}\n")
                f.write("\n")
            
            f.write("=" * 60 + "\n")
        
        print(f"[Validation] Report written to {report_path}")
        
        # Also print summary to console
        print(f"\n{'='*60}")
        print(f"Validation {'PASSED' if success else 'FAILED'}")
        if self.metadata.get('n_spots') and self.metadata.get('n_genes'):
            print(f"  {self.metadata['n_spots']} spots × {self.metadata['n_genes']} genes")
        if self.errors:
            print(f"  {len(self.errors)} error(s)")
        if self.warnings:
            print(f"  {len(self.warnings)} warning(s)")
        print(f"{'='*60}\n")


def main():
    """Command-line interface"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Validate TumorSPACE dataset")
    parser.add_argument("dataset_dir", help="Dataset directory (contains input_data/)")
    parser.add_argument("--min-spots", type=int, default=100, help="Minimum spots required")
    parser.add_argument("--min-genes", type=int, default=1000, help="Minimum genes required")
    
    args = parser.parse_args()
    
    validator = DatasetValidator(Path(args.dataset_dir))
    success = validator.validate(min_spots=args.min_spots, min_genes=args.min_genes)
    
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
