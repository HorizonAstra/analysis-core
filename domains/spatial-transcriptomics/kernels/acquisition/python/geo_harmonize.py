#!/usr/bin/env python3
"""
GEO Harmonization Module

Convert various 10x Visium formats from GEO to TumorSPACE standard format:
- M.txt (dense matrix, spots × genes, tab-delimited, no headers)
- barcodes.txt (header: "barcode", one per line)
- features.txt (header: "ensembl_gene_id" or "gene_id", one per line)
- barcodes_positions.txt (8 columns with headers)
"""

import gzip
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd

try:
    import h5py
except ImportError:
    print("WARNING: h5py not installed. H5 format support disabled.", file=sys.stderr)
    h5py = None

try:
    from scipy.io import mmread
    from scipy.sparse import issparse
except ImportError:
    print("WARNING: scipy not installed. MTX format support disabled.", file=sys.stderr)
    issparse = lambda x: False
    mmread = None


class GEOHarmonizer:
    """Convert GEO data to TumorSPACE format"""
    
    def __init__(self, input_dir: Path, output_dir: Path):
        """
        Initialize harmonizer
        
        Args:
            input_dir: Directory containing downloaded GEO files
            output_dir: Directory to write harmonized files (should end with /input_data/)
        """
        self.input_dir = Path(input_dir)
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        self.detected_format = None
        self.file_map = {}
    
    def harmonize(self) -> bool:
        """
        Main harmonization workflow
        
        Returns:
            True if successful, False otherwise
        """
        print(f"[GEOHarmonize] Harmonizing data from {self.input_dir}")
        
        # Step 1: Detect format and find required files
        if not self._detect_format():
            print("[GEOHarmonize] ERROR: Could not detect data format", file=sys.stderr)
            return False
        
        print(f"[GEOHarmonize] Detected format: {self.detected_format}")
        
        # Step 2: Load matrix, barcodes, features
        try:
            matrix, barcodes, features = self._load_expression_data()
        except Exception as e:
            print(f"[GEOHarmonize] ERROR loading expression data: {e}", file=sys.stderr)
            return False
        
        print(f"[GEOHarmonize] Loaded matrix: {matrix.shape[0]} spots × {matrix.shape[1]} genes")
        
        # Step 3: Load spatial positions
        try:
            positions_df = self._load_positions()
        except Exception as e:
            print(f"[GEOHarmonize] ERROR loading positions: {e}", file=sys.stderr)
            return False
        
        print(f"[GEOHarmonize] Loaded positions for {len(positions_df)} spots")
        
        # Step 4: Filter to in-tissue spots and align
        try:
            matrix_filtered, barcodes_filtered, positions_filtered = self._filter_and_align(
                matrix, barcodes, positions_df
            )
        except Exception as e:
            print(f"[GEOHarmonize] ERROR during filtering: {e}", file=sys.stderr)
            return False
        
        print(f"[GEOHarmonize] After filtering: {len(barcodes_filtered)} in-tissue spots")
        
        # Step 5: Write standardized output files
        try:
            self._write_matrix(matrix_filtered, self.output_dir / "M.txt")
            self._write_barcodes(barcodes_filtered, self.output_dir / "barcodes.txt")
            self._write_features(features, self.output_dir / "features.txt")
            self._write_positions(positions_filtered, self.output_dir / "barcodes_positions.txt")
        except Exception as e:
            print(f"[GEOHarmonize] ERROR writing output files: {e}", file=sys.stderr)
            return False
        
        print(f"[GEOHarmonize] Harmonization complete! Files written to {self.output_dir}")
        return True
    
    def _detect_format(self) -> bool:
        """Detect data format and locate required files"""
        all_files = list(self.input_dir.rglob("*"))
        all_files = [f for f in all_files if f.is_file()]
        
        # Look for H5 format
        h5_files = [f for f in all_files if f.name.endswith('.h5') and 'feature_bc_matrix' in f.name]
        if h5_files and h5py is not None:
            self.detected_format = "H5"
            self.file_map['matrix'] = h5_files[0]
            # H5 contains barcodes and features internally
            return True
        
        # Look for MTX format
        mtx_files = [f for f in all_files if f.name.endswith('.mtx') or f.name.endswith('.mtx.gz')]
        if mtx_files and mmread is not None:
            self.detected_format = "MTX"
            self.file_map['matrix'] = mtx_files[0]
            
            # Find barcodes
            barcode_files = [f for f in all_files if 'barcode' in f.name.lower() and 
                           (f.name.endswith('.tsv') or f.name.endswith('.tsv.gz') or 
                            f.name.endswith('.txt') or f.name.endswith('.txt.gz'))]
            if not barcode_files:
                return False
            self.file_map['barcodes'] = barcode_files[0]
            
            # Find features
            feature_files = [f for f in all_files if ('feature' in f.name.lower() or 'gene' in f.name.lower()) and 
                           (f.name.endswith('.tsv') or f.name.endswith('.tsv.gz') or 
                            f.name.endswith('.txt') or f.name.endswith('.txt.gz'))]
            if not feature_files:
                return False
            self.file_map['features'] = feature_files[0]
            
            return True
        
        # Look for CSV format
        csv_files = [f for f in all_files if 'count' in f.name.lower() and f.name.endswith('.csv')]
        if csv_files:
            self.detected_format = "CSV"
            self.file_map['matrix'] = csv_files[0]
            # CSV format may have barcodes as first column, features as header
            return True
        
        return False
    
    def _load_expression_data(self) -> Tuple[np.ndarray, List[str], List[str]]:
        """Load expression matrix, barcodes, and features"""
        if self.detected_format == "H5":
            return self._load_h5()
        elif self.detected_format == "MTX":
            return self._load_mtx()
        elif self.detected_format == "CSV":
            return self._load_csv()
        else:
            raise ValueError(f"Unknown format: {self.detected_format}")
    
    def _load_h5(self) -> Tuple[np.ndarray, List[str], List[str]]:
        """Load from H5 file"""
        h5_path = self.file_map['matrix']
        print(f"[GEOHarmonize] Loading H5: {h5_path.name}")
        
        with h5py.File(h5_path, 'r') as f:
            # Standard 10x H5 structure
            matrix_group = f['matrix']
            
            # Load sparse matrix components
            data = matrix_group['data'][:]
            indices = matrix_group['indices'][:]
            indptr = matrix_group['indptr'][:]
            shape = matrix_group['shape'][:]
            
            # Reconstruct sparse matrix
            from scipy.sparse import csc_matrix
            sparse_matrix = csc_matrix((data, indices, indptr), shape=shape)
            
            # Convert to dense (spots × genes)
            # Note: 10x H5 is genes × spots, need to transpose
            matrix = sparse_matrix.toarray().T
            
            # Load barcodes
            barcodes_data = matrix_group['barcodes'][:]
            barcodes = [bc.decode('utf-8') if isinstance(bc, bytes) else str(bc) for bc in barcodes_data]
            
            # Load features (gene IDs)
            features_group = matrix_group['features']
            if 'id' in features_group:
                features_data = features_group['id'][:]
            elif 'name' in features_group:
                features_data = features_group['name'][:]
            else:
                raise ValueError("Could not find gene IDs in H5 file")
            
            features = [f.decode('utf-8') if isinstance(f, bytes) else str(f) for f in features_data]
        
        return matrix, barcodes, features
    
    def _load_mtx(self) -> Tuple[np.ndarray, List[str], List[str]]:
        """Load from MTX + TSV files"""
        mtx_path = self.file_map['matrix']
        barcode_path = self.file_map['barcodes']
        feature_path = self.file_map['features']
        
        print(f"[GEOHarmonize] Loading MTX: {mtx_path.name}")
        
        # Load sparse matrix
        sparse_matrix = mmread(mtx_path)
        
        # Convert to dense (genes × spots in MTX format)
        matrix = sparse_matrix.toarray()
        
        # Transpose to spots × genes
        matrix = matrix.T
        
        # Load barcodes
        print(f"[GEOHarmonize] Loading barcodes: {barcode_path.name}")
        if barcode_path.name.endswith('.gz'):
            with gzip.open(barcode_path, 'rt') as f:
                barcodes = [line.strip().split('\t')[0] for line in f]
        else:
            with open(barcode_path, 'r') as f:
                barcodes = [line.strip().split('\t')[0] for line in f]
        
        # Load features
        print(f"[GEOHarmonize] Loading features: {feature_path.name}")
        if feature_path.name.endswith('.gz'):
            with gzip.open(feature_path, 'rt') as f:
                features = [line.strip().split('\t')[0] for line in f]
        else:
            with open(feature_path, 'r') as f:
                features = [line.strip().split('\t')[0] for line in f]
        
        return matrix, barcodes, features
    
    def _load_csv(self) -> Tuple[np.ndarray, List[str], List[str]]:
        """Load from CSV file"""
        csv_path = self.file_map['matrix']
        print(f"[GEOHarmonize] Loading CSV: {csv_path.name}")
        
        df = pd.read_csv(csv_path, index_col=0)
        
        # Assume rows are spots, columns are genes
        matrix = df.values
        barcodes = df.index.tolist()
        features = df.columns.tolist()
        
        return matrix, barcodes, features
    
    def _load_positions(self) -> pd.DataFrame:
        """Load and convert spatial positions"""
        # Find position file
        all_files = list(self.input_dir.rglob("*"))
        position_files = [f for f in all_files if 'tissue_position' in f.name.lower() and 
                         (f.name.endswith('.csv') or f.name.endswith('.csv.gz'))]
        
        if not position_files:
            raise FileNotFoundError("Could not find tissue_positions file")
        
        pos_path = position_files[0]
        print(f"[GEOHarmonize] Loading positions: {pos_path.name}")
        
        # Load CSV - try with header first, if fails try without
        try:
            if pos_path.name.endswith('.gz'):
                pos_df = pd.read_csv(pos_path, compression='gzip')
            else:
                pos_df = pd.read_csv(pos_path)
            
            # Check if first row looks like data (not header)
            if pos_df.columns[0].startswith('AAAC') or '-' in str(pos_df.columns[0]):
                # First line is data, no header - reload without header
                if pos_path.name.endswith('.gz'):
                    pos_df = pd.read_csv(pos_path, compression='gzip', header=None)
                else:
                    pos_df = pd.read_csv(pos_path, header=None)
        except:
            # Try without header
            if pos_path.name.endswith('.gz'):
                pos_df = pd.read_csv(pos_path, compression='gzip', header=None)
            else:
                pos_df = pd.read_csv(pos_path, header=None)
        
        # Handle different column naming conventions
        # Standard format: barcode, in_tissue, array_row, array_col, pxl_row_in_fullres, pxl_col_in_fullres
        
        # If columns are integers (no header), assign standard names
        if isinstance(pos_df.columns[0], (int, np.integer)):
            if len(pos_df.columns) == 6:
                pos_df.columns = ['barcode', 'in_tissue', 'array_row', 'array_col', 
                                 'pxl_row_in_fullres', 'pxl_col_in_fullres']
            elif len(pos_df.columns) == 5:
                pos_df.columns = ['barcode', 'in_tissue', 'array_row', 'array_col', 
                                 'pxl_row_in_fullres']
                pos_df['pxl_col_in_fullres'] = 0
        elif not isinstance(pos_df.columns[0], str):
            # Non-string, non-integer columns - convert to standard names
            if len(pos_df.columns) == 6:
                pos_df.columns = ['barcode', 'in_tissue', 'array_row', 'array_col', 
                                 'pxl_row_in_fullres', 'pxl_col_in_fullres']
            elif len(pos_df.columns) == 5:
                pos_df.columns = ['barcode', 'in_tissue', 'array_row', 'array_col', 
                                 'pxl_row_in_fullres']
                pos_df['pxl_col_in_fullres'] = 0
        else:
            # Standardize column names
            pos_df.columns = [c.lower().strip() for c in pos_df.columns]
            
            # If column names look numeric or default, reassign
            if pos_df.columns[0] == '0' or all(c.isdigit() for c in pos_df.columns):
                if len(pos_df.columns) == 6:
                    pos_df.columns = ['barcode', 'in_tissue', 'array_row', 'array_col', 
                                     'pxl_row_in_fullres', 'pxl_col_in_fullres']
                elif len(pos_df.columns) == 5:
                    pos_df.columns = ['barcode', 'in_tissue', 'array_row', 'array_col', 
                                     'pxl_row_in_fullres']
                    pos_df['pxl_col_in_fullres'] = 0
        
        # Load scale factors for mm conversion
        scale_factors = self._load_scale_factors()
        
        # Add mm-scale coordinates
        if scale_factors:
            pixel_per_micron = scale_factors['spot_diameter_fullres'] / 55.0  # Visium spot = 55 μm
            pos_df['pxl_row_in_mm'] = pos_df['pxl_row_in_fullres'] / pixel_per_micron / 1000.0
            pos_df['pxl_col_in_mm'] = pos_df['pxl_col_in_fullres'] / pixel_per_micron / 1000.0
        else:
            print("[GEOHarmonize] WARNING: Scale factors not found, using placeholder mm coordinates")
            pos_df['pxl_row_in_mm'] = 0.0
            pos_df['pxl_col_in_mm'] = 0.0
        
        return pos_df
    
    def _load_scale_factors(self) -> Optional[Dict]:
        """Load scalefactors_json.json if available"""
        all_files = list(self.input_dir.rglob("*"))
        scale_files = [f for f in all_files if 'scalefactor' in f.name.lower() and
                      f.name.endswith(('.json', '.json.gz'))]
        
        if not scale_files:
            return None
        
        scale_path = scale_files[0]
        print(f"[GEOHarmonize] Loading scale factors: {scale_path.name}")
        
        try:
            if scale_path.name.endswith('.gz'):
                with gzip.open(scale_path, 'rt') as f:
                    return json.load(f)
            else:
                with open(scale_path, 'r') as f:
                    return json.load(f)
        except Exception as e:
            print(f"[GEOHarmonize] WARNING: Could not load scale factors: {e}")
            return None
    
    def _filter_and_align(self, matrix: np.ndarray, barcodes: List[str], 
                         positions_df: pd.DataFrame) -> Tuple[np.ndarray, List[str], pd.DataFrame]:
        """Filter to in-tissue spots and align all data"""
        # Ensure barcode column is string type
        positions_df['barcode'] = positions_df['barcode'].astype(str)
        
        # Filter to in-tissue only
        if 'in_tissue' in positions_df.columns:
            in_tissue = positions_df['in_tissue'] == 1
            positions_filtered = positions_df[in_tissue].copy()
        else:
            print("[GEOHarmonize] WARNING: No in_tissue column, using all spots")
            positions_filtered = positions_df.copy()
        
        # Get barcodes that are in-tissue
        in_tissue_barcodes = set(positions_filtered['barcode'].values)
        
        # Filter matrix and barcodes
        keep_indices = [i for i, bc in enumerate(barcodes) if bc in in_tissue_barcodes]
        matrix_filtered = matrix[keep_indices, :]
        barcodes_filtered = [barcodes[i] for i in keep_indices]
        
        # Align positions to match barcode order
        positions_filtered = positions_filtered.set_index('barcode')
        positions_filtered = positions_filtered.loc[barcodes_filtered].reset_index()
        
        return matrix_filtered, barcodes_filtered, positions_filtered
    
    def _write_matrix(self, matrix: np.ndarray, output_path: Path):
        """Write matrix in TumorSPACE format (no headers, tab-delimited)"""
        print(f"[GEOHarmonize] Writing matrix: {output_path.name}")
        np.savetxt(output_path, matrix, delimiter='\t', fmt='%g')
    
    def _write_barcodes(self, barcodes: List[str], output_path: Path):
        """Write barcodes with header"""
        print(f"[GEOHarmonize] Writing barcodes: {output_path.name}")
        with open(output_path, 'w') as f:
            f.write("barcode\n")
            for bc in barcodes:
                f.write(f"{bc}\n")
    
    def _write_features(self, features: List[str], output_path: Path):
        """Write features with header"""
        print(f"[GEOHarmonize] Writing features: {output_path.name}")
        with open(output_path, 'w') as f:
            # Use ensembl_gene_id if features look like ENSG IDs, otherwise gene_id
            header = "ensembl_gene_id" if any(f.startswith("ENS") for f in features[:10]) else "gene_id"
            f.write(f"{header}\n")
            for feat in features:
                f.write(f"{feat}\n")
    
    def _write_positions(self, positions_df: pd.DataFrame, output_path: Path):
        """Write positions in 8-column TumorSPACE format"""
        print(f"[GEOHarmonize] Writing positions: {output_path.name}")
        
        # Ensure required columns exist
        required_cols = ['barcode', 'in_tissue', 'array_row', 'array_col', 
                        'pxl_row_in_fullres', 'pxl_col_in_fullres', 
                        'pxl_row_in_mm', 'pxl_col_in_mm']
        
        for col in required_cols:
            if col not in positions_df.columns:
                print(f"[GEOHarmonize] WARNING: Missing column {col}, filling with zeros")
                positions_df[col] = 0
        
        # Write with headers
        positions_df[required_cols].to_csv(output_path, sep='\t', index=False)


def main():
    """Command-line interface"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Harmonize GEO data to TumorSPACE format")
    parser.add_argument("input_dir", help="Directory with downloaded GEO files")
    parser.add_argument("output_dir", help="Output directory (e.g., local/datasets/GSE123/input_data/)")
    
    args = parser.parse_args()
    
    harmonizer = GEOHarmonizer(Path(args.input_dir), Path(args.output_dir))
    success = harmonizer.harmonize()
    
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
