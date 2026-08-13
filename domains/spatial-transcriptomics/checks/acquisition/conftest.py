"""
Shared fixtures for the acquisition feature pytest suite.

All unit tests run offline — no network access required.
Import path: workflows/acquisition/python is inserted via sys.path.
"""

import gzip
import json
import os
import sys
from io import BytesIO
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

# Make acquisition Python modules importable without installation
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "workflows" / "acquisition" / "python"))


@pytest.fixture
def tmp_canonical_dataset(tmp_path):
    """
    Minimal synthetic canonical TumorSPACE dataset (3 spots × 5 genes).

    Creates the 4 required files inside tmp_path/input_data/:
      M.txt, barcodes.txt, features.txt, barcodes_positions.txt
    Returns tmp_path (the dataset root, analogous to benchmarks/GSE.../  ).
    """
    input_data = tmp_path / "input_data"
    input_data.mkdir()

    # M.txt: 3 spots × 5 genes, tab-delimited, no header
    matrix = np.array(
        [[1, 0, 2, 0, 3],
         [0, 4, 0, 5, 0],
         [6, 0, 7, 0, 8]],
        dtype=float,
    )
    np.savetxt(input_data / "M.txt", matrix, delimiter="\t", fmt="%g")

    # barcodes.txt
    (input_data / "barcodes.txt").write_text(
        "barcode\nAACGAAAA\nAACGBBBB\nAACGCCCC\n"
    )

    # features.txt
    (input_data / "features.txt").write_text(
        "ensembl_gene_id\n"
        "ENSG00000001\nENSG00000002\nENSG00000003\nENSG00000004\nENSG00000005\n"
    )

    # barcodes_positions.txt
    (input_data / "barcodes_positions.txt").write_text(
        "barcode\tin_tissue\tarray_row\tarray_col\t"
        "pxl_row_in_fullres\tpxl_col_in_fullres\tpxl_row_in_mm\tpxl_col_in_mm\n"
        "AACGAAAA\t1\t1\t1\t100\t200\t1.0\t2.0\n"
        "AACGBBBB\t1\t2\t2\t150\t250\t1.5\t2.5\n"
        "AACGCCCC\t1\t3\t3\t200\t300\t2.0\t3.0\n"
    )

    return tmp_path


@pytest.fixture
def tmp_mtx_dataset(tmp_path):
    """
    Minimal synthetic 10x MTX-format dataset ready for GEOHarmonizer.

    Creates:
      input_dir/  — matrix.mtx.gz, barcodes.tsv.gz, features.tsv.gz,
                    tissue_positions.csv, scalefactors_json.json
      output_dir/ — empty, for harmonizer to write into

    Returns (input_dir, output_dir).
    """
    try:
        from scipy.io import mmwrite
        from scipy.sparse import csc_matrix
    except ImportError:
        pytest.skip("scipy not available")

    input_dir = tmp_path / "raw_data"
    input_dir.mkdir()
    output_dir = tmp_path / "output" / "input_data"
    output_dir.mkdir(parents=True)

    # Matrix: 5 genes × 3 spots  (MTX standard: rows=genes, cols=spots)
    dense = np.array(
        [[1, 0, 6],
         [0, 4, 0],
         [2, 0, 7],
         [0, 5, 0],
         [3, 0, 8]],
        dtype=float,
    )
    sparse = csc_matrix(dense)
    buf = BytesIO()
    mmwrite(buf, sparse)
    # Write as uncompressed .mtx — scipy mmread doesn't decompress .gz transparently
    # in all versions. The harmonizer's _detect_format picks up both .mtx and .mtx.gz.
    with open(input_dir / "matrix.mtx", "wb") as f:
        f.write(buf.getvalue())

    # barcodes.tsv.gz  (3 spots)
    with gzip.open(input_dir / "barcodes.tsv.gz", "wt") as f:
        f.write("AACGAAAA\nAACGBBBB\nAACGCCCC\n")

    # features.tsv.gz  (5 genes)
    with gzip.open(input_dir / "features.tsv.gz", "wt") as f:
        for i in range(1, 6):
            f.write(f"ENSG{i:08d}\tGene{i}\tGene Expression\n")

    # tissue_positions.csv  (all 3 spots in-tissue)
    (input_dir / "tissue_positions.csv").write_text(
        "barcode,in_tissue,array_row,array_col,pxl_row_in_fullres,pxl_col_in_fullres\n"
        "AACGAAAA,1,1,1,100,200\n"
        "AACGBBBB,1,2,2,150,250\n"
        "AACGCCCC,1,3,3,200,300\n"
    )

    # scalefactors_json.json  (Visium spot = 55 µm, ~3.22 px/µm at full res)
    (input_dir / "scalefactors_json.json").write_text(
        json.dumps({"spot_diameter_fullres": 177.5, "tissue_hires_scalef": 0.2})
    )

    return input_dir, output_dir


@pytest.fixture
def geo_searcher(tmp_path):
    """GEOSearcher instance backed by a temp cache directory (no network required for cache tests)."""
    from geo_search import GEOSearcher
    return GEOSearcher(cache_dir=tmp_path / "cache")
