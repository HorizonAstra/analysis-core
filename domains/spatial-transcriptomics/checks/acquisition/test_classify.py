"""
Unit tests for GEODownloader._detect_file_type() — the file-type classifier.

Tests run offline, using GEODownloader.__new__ to bypass __init__ (no network,
no downloads). patterns=None forces the fallback heuristic-matching path.
"""

import pytest


# (filename, expected_type)  — covering fallback heuristics (self.patterns = None)
CLASSIFY_CASES = [
    # Matrix formats
    ("filtered_feature_bc_matrix.h5", "matrix"),
    ("matrix.mtx",                    "matrix"),
    ("matrix.mtx.gz",                 "matrix"),
    ("counts.csv",                    "matrix"),
    # Barcodes
    ("barcodes.tsv",                  "barcodes"),
    ("barcodes.tsv.gz",               "barcodes"),
    # Features / genes
    ("features.tsv.gz",               "features"),
    ("genes.tsv.gz",                  "features"),
    ("features.tsv",                  "features"),
    # Spatial positions  (must NOT contain "barcode" to avoid earlier fallback)
    ("tissue_positions_list.csv",     "positions"),
    ("tissue_positions.csv",          "positions"),
    # Scale factors
    ("scalefactors_json.json",        "scalefactors"),
    ("scalefactors_json.json.gz",     "scalefactors"),
    # Images
    ("tissue_lowres_image.png",       "images"),
    ("tissue_hires_image.tiff",       "images"),
    ("brightfield.jpg",               "images"),
    # Other
    ("README.txt",                    "other"),
    ("GEO_submission_metadata.csv",   "other"),
]


@pytest.mark.parametrize("filename, expected", CLASSIFY_CASES)
def test_detect_file_type_fallback(filename, expected):
    """_detect_file_type() must return the expected category using fallback heuristics."""
    from geo_download import GEODownloader

    # Bypass __init__ so no filesystem access or pattern-file loading occurs
    d = GEODownloader.__new__(GEODownloader)
    d.patterns = None  # force fallback path

    result = d._detect_file_type(filename)
    assert result == expected, (
        f"classify({filename!r}) → {result!r}, expected {expected!r}"
    )
