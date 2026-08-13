#!/usr/bin/env python3
"""
GEO Download Module

Download and extract supplementary files from GEO datasets.
Handles TAR, TAR.GZ, GZ, and ZIP archives.
"""

import gzip
import os
import re
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlparse

try:
    import requests
    from tqdm import tqdm
except ImportError as e:
    print(f"ERROR: Required library not found: {e}", file=sys.stderr)
    print("Install with: pip install requests tqdm", file=sys.stderr)
    sys.exit(1)

try:
    import yaml
except ImportError:
    print("WARNING: pyyaml not installed. Format pattern matching will be limited.", file=sys.stderr)
    yaml = None


class GEODownloader:
    """Download and extract GEO supplementary files"""
    
    def __init__(self, output_dir: Path, patterns_file: Optional[Path] = None):
        """
        Initialize GEO downloader
        
        Args:
            output_dir: Directory to save downloaded files
            patterns_file: Path to format_patterns.yaml (auto-detected if None)
        """
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        # Load format patterns
        if patterns_file is None:
            workspace_root = Path(__file__).resolve()
            while workspace_root.parent != workspace_root:
                if (workspace_root / ".git").exists():
                    break
                workspace_root = workspace_root.parent
            patterns_file = workspace_root / "reference_data" / "feature_references" / "geo_tool" / "format_patterns.yaml"
        
        self.patterns = self._load_patterns(patterns_file)
    
    def download_dataset(self, geo_id: str, file_urls: List[str]) -> Dict[str, Path]:
        """
        Download all files for a dataset
        
        Args:
            geo_id: GEO accession (e.g., "GSE213688")
            file_urls: List of URLs to download
        
        Returns:
            Dictionary mapping file type to local path
        """
        print(f"[GEODownload] Downloading {len(file_urls)} files for {geo_id}")
        
        # Create dataset directory
        dataset_dir = self.output_dir / geo_id
        dataset_dir.mkdir(parents=True, exist_ok=True)
        
        # Download each file
        downloaded_files = []
        for url in file_urls:
            try:
                local_path = self._download_file(url, dataset_dir)
                if local_path:
                    downloaded_files.append(local_path)
            except Exception as e:
                print(f"[GEODownload] Error downloading {url}: {e}", file=sys.stderr)
        
        print(f"[GEODownload] Downloaded {len(downloaded_files)} files")
        
        # Extract archives
        extracted_files = []
        for file_path in downloaded_files:
            extracted = self._extract_if_archive(file_path, dataset_dir)
            extracted_files.extend(extracted)
        
        # Find all files (including extracted)
        all_files = list(dataset_dir.rglob("*"))
        all_files = [f for f in all_files if f.is_file()]
        
        print(f"[GEODownload] Total files after extraction: {len(all_files)}")
        
        # Detect and classify files
        file_map = self._classify_files(all_files)
        
        return file_map
    
    def _download_file(self, url: str, dest_dir: Path) -> Optional[Path]:
        """Download a single file with progress bar"""
        filename = Path(urlparse(url).path).name
        if not filename:
            filename = "downloaded_file"
        
        local_path = dest_dir / filename
        
        # Skip if already exists
        if local_path.exists():
            print(f"[GEODownload] Skipping {filename} (already exists)")
            return local_path
        
        print(f"[GEODownload] Downloading {filename}")
        
        try:
            response = requests.get(url, stream=True, timeout=60)
            response.raise_for_status()
            
            total_size = int(response.headers.get('content-length', 0))
            
            with open(local_path, 'wb') as f:
                if total_size > 0:
                    with tqdm(total=total_size, unit='B', unit_scale=True, desc=filename) as pbar:
                        for chunk in response.iter_content(chunk_size=8192):
                            f.write(chunk)
                            pbar.update(len(chunk))
                else:
                    for chunk in response.iter_content(chunk_size=8192):
                        f.write(chunk)
            
            return local_path
        
        except Exception as e:
            print(f"[GEODownload] Download failed: {e}", file=sys.stderr)
            if local_path.exists():
                local_path.unlink()
            return None
    
    def _extract_if_archive(self, file_path: Path, dest_dir: Path) -> List[Path]:
        """Extract archive if applicable, return list of extracted files"""
        suffix = file_path.suffix.lower()
        extracted = []
        
        try:
            if suffix == '.gz' and file_path.stem.endswith('.tar'):
                # .tar.gz
                print(f"[GEODownload] Extracting {file_path.name}")
                with tarfile.open(file_path, 'r:gz') as tar:
                    tar.extractall(dest_dir, filter='data')
                    extracted = [dest_dir / member.name for member in tar.getmembers() if member.isfile()]
            
            elif suffix == '.tar' or suffix == '.tgz':
                # .tar or .tgz
                print(f"[GEODownload] Extracting {file_path.name}")
                with tarfile.open(file_path, 'r') as tar:
                    tar.extractall(dest_dir, filter='data')
                    extracted = [dest_dir / member.name for member in tar.getmembers() if member.isfile()]
            
            elif suffix == '.gz':
                # Plain .gz (decompress in place)
                output_path = dest_dir / file_path.stem
                if not output_path.exists():
                    print(f"[GEODownload] Decompressing {file_path.name}")
                    with gzip.open(file_path, 'rb') as f_in:
                        with open(output_path, 'wb') as f_out:
                            shutil.copyfileobj(f_in, f_out)
                    extracted = [output_path]
            
            elif suffix == '.zip':
                # .zip
                print(f"[GEODownload] Extracting {file_path.name}")
                with zipfile.ZipFile(file_path, 'r') as zip_ref:
                    zip_ref.extractall(dest_dir)
                    extracted = [dest_dir / name for name in zip_ref.namelist() if not name.endswith('/')]
        
        except Exception as e:
            print(f"[GEODownload] Extraction error for {file_path.name}: {e}", file=sys.stderr)
        
        return extracted
    
    def _classify_files(self, file_list: List[Path]) -> Dict[str, List[Path]]:
        """Classify files by type using pattern matching"""
        classified = {
            "matrix": [],
            "barcodes": [],
            "features": [],
            "positions": [],
            "scalefactors": [],
            "images": [],
            "other": []
        }
        
        for file_path in file_list:
            filename = file_path.name
            file_type = self._detect_file_type(filename)
            classified[file_type].append(file_path)
        
        # Print summary
        print("[GEODownload] File classification:")
        for file_type, files in classified.items():
            if files:
                print(f"  {file_type}: {len(files)} file(s)")
                for f in files:
                    print(f"    - {f.name}")
        
        return classified
    
    def _detect_file_type(self, filename: str) -> str:
        """Detect file type from filename using patterns"""
        filename_lower = filename.lower()
        
        # Matrix files
        if self.patterns and 'matrix_files' in self.patterns:
            for fmt, patterns in self.patterns['matrix_files'].items():
                for pattern in patterns:
                    if re.match(pattern, filename):
                        return "matrix"
        
        # Fallback patterns if YAML not loaded
        if 'matrix.mtx' in filename_lower or 'feature_bc_matrix.h5' in filename_lower or 'counts.csv' in filename_lower:
            return "matrix"
        
        # Barcodes
        if self.patterns and 'barcode_files' in self.patterns:
            for pattern in self.patterns['barcode_files']:
                if re.match(pattern, filename):
                    return "barcodes"
        if 'barcode' in filename_lower:
            return "barcodes"
        
        # Features/genes
        if self.patterns and 'feature_files' in self.patterns:
            for pattern in self.patterns['feature_files']:
                if re.match(pattern, filename):
                    return "features"
        if 'feature' in filename_lower or 'gene' in filename_lower:
            return "features"
        
        # Positions
        if self.patterns and 'position_files' in self.patterns:
            for pattern in self.patterns['position_files']:
                if re.match(pattern, filename):
                    return "positions"
        if 'tissue_position' in filename_lower or 'spatial' in filename_lower:
            return "positions"
        
        # Scale factors
        if self.patterns and 'scalefactor_files' in self.patterns:
            for pattern in self.patterns['scalefactor_files']:
                if re.match(pattern, filename):
                    return "scalefactors"
        if 'scalefactor' in filename_lower:
            return "scalefactors"
        
        # Images
        if filename_lower.endswith(('.png', '.jpg', '.jpeg', '.tif', '.tiff')):
            return "images"
        
        return "other"
    
    def _load_patterns(self, patterns_file: Path) -> Optional[Dict]:
        """Load format patterns from YAML file"""
        if yaml is None or not patterns_file.exists():
            return None
        
        try:
            with open(patterns_file, 'r') as f:
                return yaml.safe_load(f)
        except Exception as e:
            print(f"[GEODownload] Error loading patterns: {e}", file=sys.stderr)
            return None


def main():
    """Command-line interface for testing"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Download GEO supplementary files")
    parser.add_argument("geo_id", help="GEO accession (e.g., GSE213688)")
    parser.add_argument("--output-dir", default="./downloads", help="Output directory")
    parser.add_argument("urls", nargs="+", help="URLs to download")
    
    args = parser.parse_args()
    
    downloader = GEODownloader(Path(args.output_dir))
    file_map = downloader.download_dataset(args.geo_id, args.urls)
    
    print(f"\nDownload complete. Files saved to {args.output_dir}/{args.geo_id}")


if __name__ == "__main__":
    main()
