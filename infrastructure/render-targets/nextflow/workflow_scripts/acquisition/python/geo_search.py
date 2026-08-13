#!/usr/bin/env python3
"""
GEO Search Module

Search NCBI GEO database for 10x Visium spatial transcriptomics datasets.
Uses NCBI E-utilities API for querying.
"""

import json
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional

try:
    import requests
except ImportError:
    print("ERROR: requests library not found. Install with: pip install requests", file=sys.stderr)
    sys.exit(1)

# Bump this integer whenever the structure or fields stored in cache change.
# Any cache file written with a different version will be automatically discarded
# and re-fetched, so users never see stale/incomplete data after a code upgrade.
CACHE_SCHEMA_VERSION = 2


class GEOSearcher:
    """Search and retrieve GEO dataset information"""
    
    def __init__(self, cache_dir: Optional[Path] = None):
        """
        Initialize GEO searcher
        
        Args:
            cache_dir: Directory to cache search results (default: reference_data/feature_references/geo_tool/cache/)
        """
        if cache_dir is None:
            # Find workspace root (where .git directory is)
            workspace_root = Path(__file__).resolve()
            while workspace_root.parent != workspace_root:
                if (workspace_root / ".git").exists():
                    break
                workspace_root = workspace_root.parent
            cache_dir = workspace_root / "reference_data" / "feature_references" / "geo_tool" / "cache"
        
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        
        self.base_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
        self.email = "tumorspace@example.com"  # NCBI prefers contact email
        self.cache_expiry_days = 7
        self.last_search_total = 0  # total hits reported by NCBI for the most recent search
    
    def search(self, query: str, max_results: int = 50, organism: Optional[str] = None,
               refresh: bool = False) -> List[Dict]:
        """
        Search GEO for datasets matching query
        
        Args:
            query: Free-text search query (e.g., "melanoma visium")
            max_results: Maximum number of results to return
            organism: Optional organism filter ("Homo sapiens" or "Mus musculus")
            refresh: If True, ignore and overwrite the cached result for this query
        
        Returns:
            List of dataset metadata dictionaries
        """
        # Check cache first
        cache_key = self._get_cache_key(query, organism)
        if refresh:
            self._delete_cache(cache_key)
        cached = self._load_from_cache(cache_key)
        if cached is not None:
            self.last_search_total = cached.get("total_count", len(cached.get("results", cached)))
            results = cached.get("results", cached) if isinstance(cached, dict) else cached
            print(f"[GEOSearch] Loaded {len(results)} results from cache "
                  f"(~{self.last_search_total} total on GEO)")
            return results[:max_results]
        
        print(f"[GEOSearch] Searching GEO for: {query}")
        
        # Build search query — GSE (series) entry type only
        search_terms = [query]
        search_terms.append('"10x Visium"[Platform] OR "spatial transcriptomics"[All Fields]')
        search_terms.append('"gse"[Entry Type]')
        
        if organism:
            search_terms.append(f'"{organism}"[Organism]')
        
        full_query = " AND ".join(f"({term})" for term in search_terms)
        
        # ESearch - get list of IDs (also sets self.last_search_total)
        geo_ids = self._esearch(full_query, max_results)
        if not geo_ids:
            print("[GEOSearch] No results found")
            return []
        
        print(f"[GEOSearch] Fetching metadata for {len(geo_ids)} datasets "
              f"(~{self.last_search_total} total on GEO)")
        
        # ESummary - get metadata for each ID
        results = []
        batch_size = 20
        for i in range(0, len(geo_ids), batch_size):
            batch_ids = geo_ids[i:i+batch_size]
            batch_results = self._esummary(batch_ids)
            results.extend(batch_results)
            time.sleep(0.34)  # NCBI rate limit: 3 requests/second
        
        # Save to cache (new format includes total_count)
        self._save_to_cache(cache_key, {"total_count": self.last_search_total, "results": results})
        
        return results[:max_results]
    
    def get_dataset_details(self, geo_id: str, refresh: bool = False) -> Optional[Dict]:
        """
        Get detailed information for a specific GEO dataset
        
        Args:
            geo_id: GSE or GSM accession (e.g., "GSE213688" or "GSM6592057")
            refresh: If True, ignore and overwrite the cached result
        
        Returns:
            Dataset metadata dictionary or None if not found
        """
        # Normalize ID
        geo_id = geo_id.upper().strip()
        if not geo_id.startswith("GSE") and not geo_id.startswith("GSM"):
            print(f"[GEOSearch] Invalid GEO ID: {geo_id}")
            return None
        
        # Check cache
        cache_key = f"details_{geo_id}"
        if refresh:
            self._delete_cache(cache_key)
        cached_details = self._load_from_cache(cache_key)
        if cached_details is not None:
            return cached_details
        
        print(f"[GEOSearch] Fetching details for {geo_id}")
        
        # NCBI ESummary (db=gds) requires integer UIDs, not accession strings.
        # Resolve the accession → integer UID via ESearch first.
        uid_list = self._esearch(f"{geo_id}[Accession]", max_results=1)
        if not uid_list:
            return None
        
        results = self._esummary(uid_list)
        if not results:
            return None

        details = results[0]

        # ESummary (db=gds) does not expose Overall Design — fetch it from the
        # GEO SOFT text record for GSE entries.
        if geo_id.startswith("GSE") and not details.get("overall_design"):
            try:
                time.sleep(0.34)
                soft_url = (
                    "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi"
                    f"?acc={geo_id}&targ=self&form=text&view=quick"
                )
                soft_resp = requests.get(soft_url, timeout=30)
                soft_resp.raise_for_status()
                m = re.search(r'!Series_overall_design\s*=\s*(.+)', soft_resp.text)
                if m:
                    details["overall_design"] = m.group(1).strip()
            except Exception as e:
                print(f"[GEOSearch] Warning: could not fetch Overall Design: {e}", file=sys.stderr)

        self._save_to_cache(cache_key, details)
        return details
    
    def get_supplementary_files(self, geo_id: str) -> List[Dict]:
        """
        Get list of supplementary files for a GEO dataset
        
        Args:
            geo_id: GSE or GSM accession
        
        Returns:
            List of file dictionaries with 'name', 'url', 'size' keys
        """
        geo_id = geo_id.upper().strip()
        
        # Try to parse from GEO FTP structure
        # Format: https://ftp.ncbi.nlm.nih.gov/geo/series/GSE###nnn/GSE####/suppl/
        files = []
        
        try:
            # Composite GSE_GSM ID (e.g. "GSE213688_GSM6592057"):
            # Use the GSE portion for the FTP path and filter results by the GSM portion.
            # This avoids any SOFT lookup and is the most reliable path.
            composite_match = re.match(r'^(GSE\d+)_(GSM\d+)$', geo_id)
            if composite_match:
                composite_cache_key = f"suppl_files_{geo_id}"
                cached_files = self._load_from_cache(composite_cache_key)
                if cached_files is not None:
                    return cached_files

                gse_part = composite_match.group(1)
                gsm_part = composite_match.group(2)

                # Fetch the full series supplementary file list
                gse_files = self.get_supplementary_files(gse_part)

                # Prefer files explicitly named after the GSM sample
                gsm_files = [f for f in gse_files if gsm_part in f.get("name", "")]
                if not gsm_files:
                    # Fall back to the entire series listing if no GSM-specific files
                    print(
                        f"[GEOSearch] No GSM-specific files found under {gse_part}; "
                        f"returning all {len(gse_files)} series files"
                    )
                    gsm_files = gse_files

                if gsm_files:
                    self._save_to_cache(composite_cache_key, gsm_files)
                return gsm_files

            if geo_id.startswith("GSE"):
                # Extract series number for FTP path
                series_num = geo_id[3:]  # Remove "GSE"
                series_folder = f"GSE{series_num[:-3]}nnn"  # e.g., GSE213000nnn for GSE213688
                ftp_url = f"https://ftp.ncbi.nlm.nih.gov/geo/series/{series_folder}/{geo_id}/suppl/"
            elif geo_id.startswith("GSM"):
                # Resolve GSM to its parent GSE via the GEO SOFT text record, then
                # fetch supplementary files for that series (filtering by GSM ID).
                gsm_cache_key = f"gsm_files_{geo_id}"
                cached_files = self._load_from_cache(gsm_cache_key)
                if cached_files is not None:
                    return cached_files

                print(f"[GEOSearch] Resolving parent GSE for {geo_id} via NCBI...")
                try:
                    # The GEO SOFT text mini-record reliably exposes the parent series ID
                    soft_url = (
                        "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi"
                        f"?acc={geo_id}&targ=self&form=text&view=quick"
                    )
                    soft_resp = requests.get(soft_url, timeout=30)
                    soft_resp.raise_for_status()
                    series_match = re.search(
                        r'!Sample_series_id\s*=\s*(GSE\d+)', soft_resp.text, re.IGNORECASE
                    )
                    if not series_match:
                        print(f"[GEOSearch] Could not determine parent GSE for {geo_id}")
                        return []

                    parent_gse = series_match.group(1)
                    print(f"[GEOSearch] {geo_id} belongs to {parent_gse}")
                    time.sleep(0.34)  # NCBI rate limit

                    # Fetch all supplementary files for the parent series
                    gse_files = self.get_supplementary_files(parent_gse)

                    # Prefer files whose names contain the GSM ID
                    gsm_files = [f for f in gse_files if geo_id in f.get("name", "")]
                    if not gsm_files:
                        print(
                            f"[GEOSearch] No GSM-specific files found in {parent_gse}; "
                            f"returning all {len(gse_files)} series files"
                        )
                        gsm_files = gse_files

                    if gsm_files:
                        self._save_to_cache(gsm_cache_key, gsm_files)
                    return gsm_files

                except Exception as e:
                    print(f"[GEOSearch] Error resolving GSM {geo_id}: {e}")
                    return []
            else:
                return []
            
            # Fetch directory listing
            response = requests.get(ftp_url, timeout=30)
            if response.status_code == 200:
                # Parse HTML directory listing
                html = response.text
                # Simple regex to extract filenames from href links
                file_pattern = re.compile(r'href="([^"]+)"[^>]*>\1</a>\s+(\d{2}-[A-Za-z]{3}-\d{4}\s+\d{2}:\d{2})\s+(\d+|[\d.]+[KMG]?)')
                for match in file_pattern.finditer(html):
                    filename = match.group(1)
                    if filename not in ["../", "/"]:
                        files.append({
                            "name": filename,
                            "url": ftp_url + filename,
                            "size": match.group(3) if len(match.groups()) >= 3 else "unknown"
                        })
            
        except Exception as e:
            print(f"[GEOSearch] Error fetching supplementary files: {e}")
        
        return files
    
    def _esearch(self, query: str, max_results: int) -> List[str]:
        """Execute ESearch query"""
        url = f"{self.base_url}esearch.fcgi"
        params = {
            "db": "gds",  # GEO database
            "term": query,
            "retmax": max_results,
            "retmode": "json",
            "email": self.email
        }
        
        try:
            response = requests.get(url, params=params, timeout=30)
            response.raise_for_status()
            data = response.json()
            esresult = data.get("esearchresult", {})
            self.last_search_total = int(esresult.get("count", 0))
            return esresult.get("idlist", [])
        except Exception as e:
            print(f"[GEOSearch] ESearch error: {e}", file=sys.stderr)
            return []
    
    def _esummary(self, id_list: List[str]) -> List[Dict]:
        """Execute ESummary query for list of IDs"""
        url = f"{self.base_url}esummary.fcgi"
        params = {
            "db": "gds",
            "id": ",".join(id_list),
            "retmode": "json",
            "email": self.email
        }
        
        try:
            response = requests.get(url, params=params, timeout=30)
            response.raise_for_status()
            data = response.json()
            
            results = []
            result_data = data.get("result", {})
            
            # Remove 'uids' key which is metadata, not a dataset
            if 'uids' in result_data:
                del result_data['uids']
            
            for key, item in result_data.items():
                # Skip non-dict entries
                if not isinstance(item, dict):
                    continue
                # Parse each item
                try:
                    results.append(self._parse_summary(item))
                except Exception as e:
                    print(f"[GEOSearch] Warning: Could not parse item {key}: {e}", file=sys.stderr)
                    continue
            
            return results
        except Exception as e:
            print(f"[GEOSearch] ESummary error: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc()
            return []
    
    def _parse_summary(self, item: Dict) -> Dict:
        """Parse ESummary result into standardized format"""
        # Extract key metadata with safe defaults
        accession = item.get("accession", item.get("Accession", ""))
        title = item.get("title", item.get("Title", ""))
        summary = item.get("summary", item.get("Summary", ""))
        organism = item.get("taxon", item.get("Organism", ""))
        
        # Try to extract tissue/sample type from title
        tissue = self._extract_tissue(title, summary)
        
        # Extract platform info
        platform = ""
        if "gpl" in item:
            platform = item["gpl"]
        elif "GPL" in item:
            platform = item["GPL"]
        
        # Determine entry type (GSE series vs GSM sample)
        entry_type = item.get("entrytype", item.get("EntryType", ""))
        
        # Extract PubMed IDs
        pubmed_id = ""
        if "pubmedids" in item and item["pubmedids"]:
            if isinstance(item["pubmedids"], list):
                pubmed_id = item["pubmedids"][0] if item["pubmedids"] else ""
            else:
                pubmed_id = str(item["pubmedids"])
        elif "PubMedIds" in item and item["PubMedIds"]:
            if isinstance(item["PubMedIds"], list):
                pubmed_id = item["PubMedIds"][0] if item["PubMedIds"] else ""
            else:
                pubmed_id = str(item["PubMedIds"])
        
        # Extract GSM sample count
        n_samples = 0
        if "n_samples" in item:
            try:
                n_samples = int(item["n_samples"])
            except (ValueError, TypeError):
                pass
        elif "samples" in item and isinstance(item["samples"], list):
            n_samples = len(item["samples"])
        
        # Extract overall design
        overall_design = item.get("overall_design", item.get("OverallDesign", ""))
        
        return {
            "geo_id": accession,
            "title": title,
            "summary": summary[:500] if summary else "",  # Truncate long summaries
            "organism": organism,
            "tissue": tissue,
            "platform": platform,
            "entry_type": entry_type,
            "pubmed_id": pubmed_id,
            "n_samples": n_samples,
            "overall_design": overall_design,
            "geo_url": f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={accession}"
        }
    
    def _extract_tissue(self, title: str, summary: str) -> str:
        """Extract tissue type from title or summary"""
        text = (title + " " + summary).lower()
        
        # Common tissue patterns
        tissues = {
            "melanoma": ["melanoma", "skin cancer"],
            "breast": ["breast cancer", "breast tumor", "brca"],
            "brain": ["glioma", "glioblastoma", "gbm", "brain tumor"],
            "ovarian": ["ovarian", "ovary"],
            "lung": ["lung", "nsclc", "luad"],
            "colon": ["colorectal", "colon", "crc"],
            "pancreas": ["pancreatic", "pancreas", "pdac"],
            "liver": ["liver", "hepatocellular", "hcc"],
            "kidney": ["kidney", "renal"],
            "prostate": ["prostate"]
        }
        
        for tissue, keywords in tissues.items():
            if any(kw in text for kw in keywords):
                return tissue.capitalize()
        
        return "Unknown"
    
    def _get_cache_key(self, query: str, organism: Optional[str]) -> str:
        """Generate cache key for query"""
        key_parts = [query]
        if organism:
            key_parts.append(organism)
        key_str = "_".join(key_parts)
        # Sanitize for filename
        key_str = re.sub(r'[^\w\s-]', '', key_str).strip().replace(' ', '_')
        return f"search_{key_str}"
    
    def _load_from_cache(self, cache_key: str) -> Optional[List[Dict]]:
        """Load results from cache if not expired and schema version matches"""
        cache_file = self.cache_dir / f"{cache_key}.json"
        if not cache_file.exists():
            return None
        
        # Check expiry
        mtime = datetime.fromtimestamp(cache_file.stat().st_mtime)
        if datetime.now() - mtime > timedelta(days=self.cache_expiry_days):
            return None
        
        try:
            with open(cache_file, 'r') as f:
                raw = json.load(f)
            # Versioned envelope format: {"schema_version": N, "payload": ...}
            if not isinstance(raw, dict) or raw.get("schema_version") != CACHE_SCHEMA_VERSION:
                # Wrong version (or old unversioned format) — treat as expired
                return None
            return raw["payload"]
        except Exception as e:
            print(f"[GEOSearch] Cache load error: {e}", file=sys.stderr)
            return None
    
    def _save_to_cache(self, cache_key: str, data: any):
        """Save results to cache, wrapped in a versioned envelope"""
        cache_file = self.cache_dir / f"{cache_key}.json"
        envelope = {"schema_version": CACHE_SCHEMA_VERSION, "payload": data}
        try:
            with open(cache_file, 'w') as f:
                json.dump(envelope, f, indent=2)
        except Exception as e:
            print(f"[GEOSearch] Cache save error: {e}", file=sys.stderr)

    def _delete_cache(self, cache_key: str):
        """Delete a specific cache file (used by --refresh)"""
        cache_file = self.cache_dir / f"{cache_key}.json"
        if cache_file.exists():
            cache_file.unlink()
            print(f"[GEOSearch] Cache cleared: {cache_file.name}")


def main():
    """Command-line interface for testing"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Search GEO for Visium datasets")
    parser.add_argument("query", help="Search query")
    parser.add_argument("--max-results", type=int, default=20, help="Maximum results")
    parser.add_argument("--organism", choices=["Homo sapiens", "Mus musculus"], help="Filter by organism")
    parser.add_argument("--details", help="Get details for specific GEO ID")
    parser.add_argument("--files", help="List supplementary files for GEO ID")
    
    args = parser.parse_args()
    
    searcher = GEOSearcher()
    
    if args.details:
        details = searcher.get_dataset_details(args.details)
        if details:
            print(json.dumps(details, indent=2))
        else:
            print(f"Dataset {args.details} not found")
    elif args.files:
        files = searcher.get_supplementary_files(args.files)
        print(f"Found {len(files)} supplementary files:")
        for f in files:
            print(f"  {f['name']} ({f['size']})")
            print(f"    {f['url']}")
    else:
        results = searcher.search(args.query, max_results=args.max_results, organism=args.organism)
        print(f"\nFound {len(results)} datasets:\n")
        for i, result in enumerate(results, 1):
            print(f"{i}. {result['geo_id']} - {result['title']}")
            print(f"   Organism: {result['organism']}, Tissue: {result['tissue']}")
            print(f"   {result['geo_url']}\n")


if __name__ == "__main__":
    main()
