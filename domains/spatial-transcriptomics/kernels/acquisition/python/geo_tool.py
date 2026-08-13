#!/usr/bin/env python3
"""
GEO Tool - Interactive CLI for GEO Dataset Discovery and Acquisition

Main entry point for searching, downloading, and harmonizing GEO datasets.
"""

import argparse
import sys
from pathlib import Path
from typing import List, Optional

# Import our modules
from geo_search import GEOSearcher
from geo_download import GEODownloader
from geo_harmonize import GEOHarmonizer
from validate_dataset import DatasetValidator


class GEOTool:
    """Main GEO tool controller"""
    
    def __init__(self, workspace_root: Optional[Path] = None):
        """Initialize GEO tool"""
        if workspace_root is None:
            # Auto-detect workspace root
            workspace_root = Path(__file__).resolve()
            while workspace_root.parent != workspace_root:
                if (workspace_root / ".git").exists():
                    break
                workspace_root = workspace_root.parent
        
        self.workspace_root = Path(workspace_root)
        self.local_datasets_dir = self.workspace_root / "local" / "datasets"
        self.local_datasets_dir.mkdir(parents=True, exist_ok=True)
        
        self.searcher = GEOSearcher()
    
    def search(self, query: str, max_results: int = 20, organism: Optional[str] = None,
               interactive: bool = False, refresh: bool = False):
        """
        Search GEO for datasets.

        max_results controls how many records are fetched from NCBI and cached
        (default 20; raise with --max-results for a larger pool to browse).
        Results are always displayed 5 at a time.
        """
        import re as _re

        results = self.searcher.search(query, max_results=max_results, organism=organism,
                                       refresh=refresh)
        total_on_geo = self.searcher.last_search_total

        if not results:
            print("No datasets found matching your query.")
            return

        # Write full result list to local/
        safe_query = _re.sub(r'[^\w\s-]', '', query).strip().replace(' ', '_')
        output_file = self.workspace_root / "local" / f"geo_search_{safe_query}.txt"
        self._write_results_file(output_file, results, total_on_geo, query)

        PAGE_SIZE = 5
        self._display_page(results, 0, PAGE_SIZE, total_on_geo, output_file)

        if interactive:
            self._interactive_selection(results, total_on_geo, PAGE_SIZE)
        elif len(results) > PAGE_SIZE:
            print(f"  ({len(results) - PAGE_SIZE} more retrieved — use --interactive to browse, "
                  f"or see {output_file})\n")
    
    def show_details(self, geo_id: str, refresh: bool = False):
        """Show detailed information for a dataset"""
        details = self.searcher.get_dataset_details(geo_id, refresh=refresh)
        
        if not details:
            print(f"Dataset {geo_id} not found.")
            return
        
        print(f"\n{'='*80}")
        print(f"Dataset Details: {details['geo_id']}")
        print(f"{'='*80}\n")
        
        print(f"Title: {details['title']}")
        print(f"Organism: {details['organism']}")
        print(f"Tissue: {details['tissue']}")
        print(f"Platform: {details['platform']}")
        print(f"Type: {details['entry_type']}")
        if details.get('n_samples'):
            print(f"Samples: {details['n_samples']} GSM")
        if details.get('pubmed_id'):
            print(f"Citation: https://pubmed.ncbi.nlm.nih.gov/{details['pubmed_id']}/")
        print(f"\nSummary:\n{details.get('summary', '')}")
        if details.get('overall_design'):
            print(f"\nOverall Design:\n{details['overall_design']}")
        print(f"\nGEO URL: {details['geo_url']}")
        
        # Try to get supplementary files
        print(f"\n{'='*80}")
        print("Supplementary Files:")
        print(f"{'='*80}\n")
        
        files = self.searcher.get_supplementary_files(geo_id)
        if files:
            for f in files:
                print(f"  {f['name']} ({f['size']})")
        else:
            print("  (File listing not available - will be discovered during download)")
    
    def download(self, geo_id: str, skip_validation: bool = False):
        """
        Download and harmonize a GEO dataset
        
        Args:
            geo_id: GEO accession (GSE or GSM)
            skip_validation: If True, skip final validation
        """
        print(f"\n{'='*80}")
        print(f"Downloading and Harmonizing {geo_id}")
        print(f"{'='*80}\n")
        
        # Get supplementary file URLs
        files = self.searcher.get_supplementary_files(geo_id)
        
        if not files:
            print(f"ERROR: Could not find supplementary files for {geo_id}")
            print("The dataset may not have publicly available supplementary files,")
            print("or the GEO ID may be invalid.")
            return False
        
        print(f"Found {len(files)} supplementary files")
        
        # Create download directory
        download_dir = self.local_datasets_dir / geo_id / "raw"
        download_dir.mkdir(parents=True, exist_ok=True)
        
        # Download files
        downloader = GEODownloader(download_dir)
        file_urls = [f['url'] for f in files]
        
        try:
            file_map = downloader.download_dataset(geo_id, file_urls)
        except Exception as e:
            print(f"ERROR during download: {e}")
            return False
        
        # Harmonize to TumorSPACE format
        print(f"\n{'='*80}")
        print("Harmonizing to TumorSPACE format")
        print(f"{'='*80}\n")
        
        output_dir = self.local_datasets_dir / geo_id / "input_data"
        harmonizer = GEOHarmonizer(download_dir, output_dir)
        
        try:
            success = harmonizer.harmonize()
        except Exception as e:
            print(f"ERROR during harmonization: {e}")
            import traceback
            traceback.print_exc()
            return False
        
        if not success:
            print(f"ERROR: Harmonization failed for {geo_id}")
            return False
        
        # Validate
        if not skip_validation:
            print(f"\n{'='*80}")
            print("Validating dataset")
            print(f"{'='*80}\n")
            
            dataset_dir = self.local_datasets_dir / geo_id
            validator = DatasetValidator(dataset_dir)
            validation_success = validator.validate()
            
            if not validation_success:
                print(f"\nWARNING: Validation found issues. Check VALIDATION_REPORT.txt")
                return False
        
        print(f"\n{'='*80}")
        print(f"SUCCESS: {geo_id} is ready for TumorSPACE pipeline")
        print(f"{'='*80}")
        print(f"\nDataset location: {self.local_datasets_dir / geo_id}")
        print(f"Input data: {self.local_datasets_dir / geo_id / 'input_data'}")
        print(f"\nTo run pipeline:")
        print(f"  bash run_pipeline.sh \\")
        print(f"    --dataset {geo_id} \\")
        print(f"    --input-dir {self.local_datasets_dir / geo_id / 'input_data'} \\")
        print(f"    --output-base local/outputs/{geo_id} \\")
        print(f"    --test")
        
        return True
    
    def list_local(self):
        """List locally downloaded datasets with validation status"""
        print(f"\n{'='*80}")
        print("Locally Available Datasets")
        print(f"{'='*80}\n")
        
        if not self.local_datasets_dir.exists():
            print("No local datasets found.")
            return
        
        datasets = [d for d in self.local_datasets_dir.iterdir() if d.is_dir()]
        
        if not datasets:
            print("No local datasets found.")
            return
        
        for dataset_dir in sorted(datasets):
            geo_id = dataset_dir.name
            input_data_dir = dataset_dir / "input_data"
            validation_report = dataset_dir / "VALIDATION_REPORT.txt"
            
            # Check status
            if not input_data_dir.exists():
                status = "❌ INCOMPLETE (no input_data/)"
            elif validation_report.exists():
                # Parse validation report
                with open(validation_report, 'r') as f:
                    content = f.read()
                    if "Status: PASS" in content:
                        status = "✓ VALIDATED"
                    else:
                        status = "⚠ VALIDATION FAILED"
            else:
                status = "? NOT VALIDATED"
            
            print(f"{geo_id:<25} {status}")
            
            # Show metadata if available
            if validation_report.exists():
                with open(validation_report, 'r') as f:
                    for line in f:
                        if line.strip().startswith("n_spots:"):
                            print(f"  {line.strip()}")
                        elif line.strip().startswith("n_genes:"):
                            print(f"  {line.strip()}")
        
        print()
    
    def _write_results_file(self, output_file: Path, results: List[dict], total_on_geo: int, query: str):
        """Write full result list to a text file in local/"""
        from datetime import datetime
        output_file.parent.mkdir(parents=True, exist_ok=True)
        with open(output_file, 'w') as f:
            f.write(f"GEO Search Results\n")
            f.write(f"Query:     {query}\n")
            f.write(f"Date:      {datetime.now().strftime('%Y-%m-%d %H:%M')}\n")
            f.write(f"Retrieved: {len(results)}  |  Total matching on GEO: ~{total_on_geo}\n")
            f.write("=" * 80 + "\n\n")
            for i, r in enumerate(results, 1):
                f.write(f"{i}. {r['geo_id']} - {r['title']}\n")
                f.write(f"   Organism: {r['organism']}\n")
                f.write(f"   Tissue:   {r['tissue']}\n")
                if r.get('n_samples'):
                    f.write(f"   Samples:  {r['n_samples']} GSM\n")
                if r.get('pubmed_id'):
                    f.write(f"   Citation: https://pubmed.ncbi.nlm.nih.gov/{r['pubmed_id']}/\n")
                f.write(f"   URL:      {r['geo_url']}\n")
                f.write("\n")
        print(f"[GEOSearch] Full results ({len(results)}) written to: {output_file}")

    def _display_page(self, results: List[dict], offset: int, page_size: int,
                      total_on_geo: int, output_file: Optional[Path]):
        """Print one page (page_size items starting at offset) of results"""
        page = results[offset:offset + page_size]
        end = offset + len(page)

        print(f"\n{'='*80}")
        header = f"Showing {offset+1}\u2013{end} of {len(results)} retrieved"
        if total_on_geo > len(results):
            header += f"  (~{total_on_geo} total on GEO)"
        if output_file:
            header += f"  \u2022  Full list: {output_file}"
        print(header)
        print(f"{'='*80}\n")

        for i, result in enumerate(page, offset + 1):
            print(f"{i}. {result['geo_id']} - {result['title']}")
            print(f"   Organism: {result['organism']}")
            print(f"   Tissue: {result['tissue']}")
            if result.get('n_samples'):
                print(f"   Samples: {result['n_samples']} GSM")
            if result.get('pubmed_id'):
                print(f"   Citation: https://pubmed.ncbi.nlm.nih.gov/{result['pubmed_id']}/")
            print(f"   URL: {result['geo_url']}")
            print()

    def _interactive_selection(self, results: List[dict], total_on_geo: int = 0, page_size: int = 5):
        """Interactive menu: page through results, show details, or download"""
        offset = 0  # first page already displayed by search()

        while True:
            try:
                has_next = offset + page_size < len(results)
                has_prev = offset > 0

                parts = ["Enter number to download", "'s <N>' for details"]
                if has_next:
                    parts.append("'n' next 5")
                if has_prev:
                    parts.append("'p' prev 5")
                parts.append("'q' quit")

                print(f"\n{'='*80}")
                choice = input(f"\n{', '.join(parts)}: ").strip().lower()

                if choice == 'q':
                    break

                if choice == 'n':
                    if has_next:
                        offset += page_size
                        self._display_page(results, offset, page_size, total_on_geo, None)
                    else:
                        print("Already at last page.")
                    continue

                if choice == 'p':
                    if has_prev:
                        offset = max(0, offset - page_size)
                        self._display_page(results, offset, page_size, total_on_geo, None)
                    else:
                        print("Already at first page.")
                    continue

                if choice.startswith('s'):
                    tokens = choice.split()
                    if len(tokens) == 2:
                        num_str = tokens[1]
                    else:
                        num_str = input("Enter number to show details: ").strip()
                    try:
                        idx = int(num_str) - 1
                    except ValueError:
                        print("Usage: s <number>")
                        continue
                    if 0 <= idx < len(results):
                        self.show_details(results[idx]['geo_id'])
                    else:
                        print(f"Invalid number (valid: 1\u2013{len(results)})")
                    continue

                try:
                    idx = int(choice) - 1
                    if 0 <= idx < len(results):
                        geo_id = results[idx]['geo_id']
                        confirm = input(f"\nDownload {geo_id}? [y/N]: ").strip().lower()
                        if confirm == 'y':
                            self.download(geo_id)
                            break
                    else:
                        print(f"Invalid number (valid: 1\u2013{len(results)})")
                except ValueError:
                    print("Invalid input")

            except (KeyboardInterrupt, EOFError):
                print("\n\nInterrupted.")
                break


def main():
    """Command-line interface"""
    parser = argparse.ArgumentParser(
        description="GEO Dataset Discovery and Acquisition Tool for TumorSPACE",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Search for datasets
  python geo_tool.py search "melanoma visium"
  
  # Interactive search (select from results)
  python geo_tool.py search "breast cancer" --interactive
  
  # Show details for specific dataset
  python geo_tool.py show GSE213688
  
  # Download and harmonize dataset
  python geo_tool.py download GSE213688_GSM6592057
  
  # List locally available datasets
  python geo_tool.py list-local
        """
    )
    
    subparsers = parser.add_subparsers(dest='command', help='Command to execute')
    
    # Search command
    search_parser = subparsers.add_parser('search', help='Search GEO for datasets')
    search_parser.add_argument('query', help='Search query (e.g., "melanoma visium")')
    search_parser.add_argument('--max-results', type=int, default=20, help='Maximum results (default: 20)')
    search_parser.add_argument('--organism', choices=['Homo sapiens', 'Mus musculus'], help='Filter by organism')
    search_parser.add_argument('--interactive', action='store_true', help='Interactive selection mode')
    search_parser.add_argument('--refresh', action='store_true', help='Ignore cache and re-fetch from NCBI')
    
    # Show command
    show_parser = subparsers.add_parser('show', help='Show details for a dataset')
    show_parser.add_argument('geo_id', help='GEO accession (e.g., GSE213688)')
    show_parser.add_argument('--refresh', action='store_true', help='Ignore cache and re-fetch from NCBI')
    
    # Download command
    download_parser = subparsers.add_parser('download', help='Download and harmonize dataset')
    download_parser.add_argument('geo_id', help='GEO accession (e.g., GSE213688_GSM6592057)')
    download_parser.add_argument('--skip-validation', action='store_true', help='Skip final validation')
    
    # List local command
    list_parser = subparsers.add_parser('list-local', help='List locally downloaded datasets')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        sys.exit(1)
    
    # Initialize tool
    tool = GEOTool()
    
    # Execute command
    if args.command == 'search':
        tool.search(args.query, max_results=args.max_results, organism=args.organism,
                   interactive=args.interactive, refresh=args.refresh)
    
    elif args.command == 'show':
        tool.show_details(args.geo_id, refresh=args.refresh)
    
    elif args.command == 'download':
        success = tool.download(args.geo_id, skip_validation=args.skip_validation)
        sys.exit(0 if success else 1)
    
    elif args.command == 'list-local':
        tool.list_local()


if __name__ == "__main__":
    main()
