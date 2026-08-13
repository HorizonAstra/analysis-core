"""
Integration test: run DatasetValidator against the real benchmark dataset.

Skipped automatically when the benchmark directory is absent (e.g., on CI
without the data checkout). On a developer machine with the full repo, this
should always pass.
"""

from pathlib import Path

import pytest

BENCHMARK_DIR = (
    Path(__file__).parent.parent.parent / "benchmarks" / "GSE213688_GSM6592057"
)


@pytest.mark.skipif(
    not (BENCHMARK_DIR / "input_data").exists(),
    reason="Benchmark dataset not available at benchmarks/GSE213688_GSM6592057/input_data/",
)
def test_benchmark_validation_passes():
    from validate_dataset import DatasetValidator

    v = DatasetValidator(BENCHMARK_DIR)
    result = v.validate(min_spots=100, min_genes=1000)

    assert result is True, f"Validation failed. Errors: {v.errors}"
    assert v.errors == []
    assert v.metadata.get("n_spots", 0) > 100, "Fewer spots than expected in benchmark"
    assert v.metadata.get("n_genes", 0) > 1000, "Fewer genes than expected in benchmark"


@pytest.mark.skipif(
    not (BENCHMARK_DIR / "input_data").exists(),
    reason="Benchmark dataset not available",
)
def test_benchmark_metadata_populated():
    """Validator must report n_spots, n_genes, and spatial_extent_mm."""
    from validate_dataset import DatasetValidator

    v = DatasetValidator(BENCHMARK_DIR)
    v.validate(min_spots=100, min_genes=1000)

    assert "n_spots" in v.metadata
    assert "n_genes" in v.metadata
    assert "spatial_extent_mm" in v.metadata
