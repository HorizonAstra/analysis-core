"""
Unit tests for GEOHarmonizer (geo_harmonize.py).

All tests run offline using synthetic fixtures.
"""

import gzip
import json
from pathlib import Path

import numpy as np
import pandas as pd
import pytest


# ---------------------------------------------------------------------------
# MTX end-to-end harmonization
# ---------------------------------------------------------------------------

def test_mtx_harmonize_returns_true(tmp_mtx_dataset):
    from geo_harmonize import GEOHarmonizer

    input_dir, output_dir = tmp_mtx_dataset
    h = GEOHarmonizer(input_dir, output_dir)
    assert h.harmonize() is True


def test_mtx_harmonize_produces_four_files(tmp_mtx_dataset):
    from geo_harmonize import GEOHarmonizer

    input_dir, output_dir = tmp_mtx_dataset
    GEOHarmonizer(input_dir, output_dir).harmonize()

    for fname in ["M.txt", "barcodes.txt", "features.txt", "barcodes_positions.txt"]:
        assert (output_dir / fname).exists(), f"Missing output file: {fname}"


def test_mtx_harmonize_dimensions_consistent(tmp_mtx_dataset):
    """Matrix rows == barcodes; matrix cols == features; matrix rows == positions rows."""
    from geo_harmonize import GEOHarmonizer

    input_dir, output_dir = tmp_mtx_dataset
    GEOHarmonizer(input_dir, output_dir).harmonize()

    matrix = np.loadtxt(output_dir / "M.txt", delimiter="\t")
    barcodes = (output_dir / "barcodes.txt").read_text().splitlines()[1:]  # skip header
    features = (output_dir / "features.txt").read_text().splitlines()[1:]  # skip header
    positions = pd.read_csv(output_dir / "barcodes_positions.txt", sep="\t")

    if matrix.ndim == 1:
        # Single-spot edge case: treat as 1×n
        n_spots, n_genes = 1, matrix.shape[0]
    else:
        n_spots, n_genes = matrix.shape

    assert n_spots == len(barcodes)
    assert n_genes == len(features)
    assert n_spots == len(positions)


# ---------------------------------------------------------------------------
# mm coordinate columns
# ---------------------------------------------------------------------------

def test_mm_columns_present_in_output(tmp_mtx_dataset):
    """pxl_row_in_mm and pxl_col_in_mm must be present and non-zero when scale
    factors are available."""
    from geo_harmonize import GEOHarmonizer

    input_dir, output_dir = tmp_mtx_dataset
    GEOHarmonizer(input_dir, output_dir).harmonize()

    pos = pd.read_csv(output_dir / "barcodes_positions.txt", sep="\t")
    assert "pxl_row_in_mm" in pos.columns, "pxl_row_in_mm column missing"
    assert "pxl_col_in_mm" in pos.columns, "pxl_col_in_mm column missing"
    # Scale factors are present in the fixture, so values should be non-zero
    assert pos["pxl_row_in_mm"].sum() != 0, "pxl_row_in_mm is all zeros despite scale factors"
    assert pos["pxl_col_in_mm"].sum() != 0, "pxl_col_in_mm is all zeros despite scale factors"


# ---------------------------------------------------------------------------
# Regression: operator precedence fix in _load_scale_factors
# ---------------------------------------------------------------------------

def test_scale_factors_operator_precedence_regression(tmp_path):
    """
    Regression test for the operator-precedence bug in _load_scale_factors().

    Before the fix:
        condition = 'scalefactor' in name AND endswith('.json') OR endswith('.json.gz')
        (the OR was outside the AND, so any *.json.gz would match regardless of name)

    After the fix with endswith(('.json', '.json.gz')):
        A decoy file named 'other_data.json.gz' must NOT be picked up.
    """
    from geo_harmonize import GEOHarmonizer

    input_dir = tmp_path / "input"
    input_dir.mkdir()
    output_dir = tmp_path / "output"
    output_dir.mkdir()

    # Decoy: a .json.gz file with NO 'scalefactor' in the name
    decoy = input_dir / "other_data.json.gz"
    with gzip.open(decoy, "wt") as f:
        json.dump({"should_not_be_loaded": True}, f)

    # Real scale factors file
    (input_dir / "scalefactors_json.json").write_text(
        json.dumps({"spot_diameter_fullres": 177.5, "tissue_hires_scalef": 0.2})
    )

    h = GEOHarmonizer(input_dir, output_dir)
    result = h._load_scale_factors()

    assert result is not None, "_load_scale_factors() returned None; real file not loaded"
    assert "spot_diameter_fullres" in result
    assert result.get("should_not_be_loaded") is None, "Decoy .json.gz file was incorrectly loaded"


# ---------------------------------------------------------------------------
# Missing data graceful failure
# ---------------------------------------------------------------------------

def test_harmonize_returns_false_on_unrecognised_format(tmp_path):
    """A directory with no recognised data files should return False, not raise."""
    from geo_harmonize import GEOHarmonizer

    input_dir = tmp_path / "empty_input"
    input_dir.mkdir()
    output_dir = tmp_path / "output"
    output_dir.mkdir()

    h = GEOHarmonizer(input_dir, output_dir)
    assert h.harmonize() is False
