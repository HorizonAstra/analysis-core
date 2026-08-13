"""
Unit tests for DatasetValidator (validate_dataset.py).

All tests run offline using the tmp_canonical_dataset fixture.
"""

import numpy as np
import pandas as pd
import pytest


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

def test_valid_dataset_passes(tmp_canonical_dataset):
    from validate_dataset import DatasetValidator

    v = DatasetValidator(tmp_canonical_dataset)
    assert v.validate(min_spots=1, min_genes=1) is True
    assert v.errors == []


# ---------------------------------------------------------------------------
# Missing file failures
# ---------------------------------------------------------------------------

def test_missing_matrix_fails(tmp_canonical_dataset):
    from validate_dataset import DatasetValidator

    (tmp_canonical_dataset / "input_data" / "M.txt").unlink()
    v = DatasetValidator(tmp_canonical_dataset)
    assert v.validate(min_spots=1, min_genes=1) is False
    assert any("M.txt" in e for e in v.errors)


def test_missing_barcodes_fails(tmp_canonical_dataset):
    from validate_dataset import DatasetValidator

    (tmp_canonical_dataset / "input_data" / "barcodes.txt").unlink()
    v = DatasetValidator(tmp_canonical_dataset)
    assert v.validate(min_spots=1, min_genes=1) is False
    assert any("barcodes.txt" in e for e in v.errors)


# ---------------------------------------------------------------------------
# Dimension mismatch
# ---------------------------------------------------------------------------

def test_spot_count_mismatch_fails(tmp_canonical_dataset):
    from validate_dataset import DatasetValidator

    # Overwrite M.txt with 4 spots; barcodes.txt still has 3
    bad_matrix = np.ones((4, 5), dtype=float)
    np.savetxt(
        tmp_canonical_dataset / "input_data" / "M.txt",
        bad_matrix,
        delimiter="\t",
        fmt="%g",
    )
    v = DatasetValidator(tmp_canonical_dataset)
    assert v.validate(min_spots=1, min_genes=1) is False
    assert any("mismatch" in e.lower() for e in v.errors)


# ---------------------------------------------------------------------------
# Threshold checks
# ---------------------------------------------------------------------------

def test_too_few_spots_fails(tmp_canonical_dataset):
    from validate_dataset import DatasetValidator

    v = DatasetValidator(tmp_canonical_dataset)
    # fixture has 3 spots; require 100
    assert v.validate(min_spots=100, min_genes=1) is False
    assert any("spots" in e.lower() for e in v.errors)


def test_too_few_genes_fails(tmp_canonical_dataset):
    from validate_dataset import DatasetValidator

    v = DatasetValidator(tmp_canonical_dataset)
    # fixture has 5 genes; require 1000
    assert v.validate(min_spots=1, min_genes=1000) is False
    assert any("genes" in e.lower() for e in v.errors)


# ---------------------------------------------------------------------------
# Coordinate warnings (should warn but not fail)
# ---------------------------------------------------------------------------

def test_zero_mm_coords_warns_not_fails(tmp_canonical_dataset):
    from validate_dataset import DatasetValidator

    pos_path = tmp_canonical_dataset / "input_data" / "barcodes_positions.txt"
    pos = pd.read_csv(pos_path, sep="\t")
    pos["pxl_row_in_mm"] = 0.0
    pos["pxl_col_in_mm"] = 0.0
    pos.to_csv(pos_path, sep="\t", index=False)

    v = DatasetValidator(tmp_canonical_dataset)
    assert v.validate(min_spots=1, min_genes=1) is True
    assert any("zero" in w.lower() or "mm" in w.lower() for w in v.warnings)
