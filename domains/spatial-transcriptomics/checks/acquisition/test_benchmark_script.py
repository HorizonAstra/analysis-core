"""
Tests for run_benchmark.sh existence, permissions, and help flag.

These are fast, offline smoke tests — they do NOT actually run the benchmark.
"""

import os
import subprocess
from pathlib import Path

import pytest

# Beside the other checks of this domain, which is where the script now lives.
# It used to be looked for at the root of the repository this came from, and for
# as long as that was written here it was looked for in a directory that has
# never held it in this tree.
CHECKS = Path(__file__).parent.parent
BENCHMARK_SCRIPT = CHECKS / "run_benchmark.sh"


def test_benchmark_script_exists():
    """run_benchmark.sh must exist at the repo root."""
    assert BENCHMARK_SCRIPT.exists(), (
        f"run_benchmark.sh not found at {BENCHMARK_SCRIPT}; "
        "expected a file at the repo root alongside run_pipeline.sh and setup.sh"
    )


def test_benchmark_script_is_executable():
    """run_benchmark.sh must have the executable bit set."""
    assert os.access(BENCHMARK_SCRIPT, os.X_OK), (
        f"{BENCHMARK_SCRIPT} is not executable. "
        "Fix with: chmod +x run_benchmark.sh"
    )


def test_benchmark_script_help_exits_zero():
    """run_benchmark.sh --help must print usage and exit 0."""
    result = subprocess.run(
        ["bash", str(BENCHMARK_SCRIPT), "--help"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, (
        f"run_benchmark.sh --help exited with code {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )
    # Sanity-check that some usage text appeared
    combined = result.stdout + result.stderr
    assert "run_benchmark" in combined.lower() or "benchmark" in combined.lower(), (
        "--help output does not mention 'benchmark' — help text may be missing"
    )


def test_benchmark_script_missing_args_exits_nonzero():
    """run_benchmark.sh without required --account / --partition must exit non-zero."""
    result = subprocess.run(
        ["bash", str(BENCHMARK_SCRIPT)],
        capture_output=True,
        text=True,
        timeout=30,
        # Provide no args so it hits the missing-account guard before any SLURM calls
        env={**os.environ, "SLURM_ACCOUNT": "", "SLURM_PARTITION": ""},
    )
    assert result.returncode != 0, (
        "run_benchmark.sh with no account/partition should exit non-zero, "
        f"but exited {result.returncode}"
    )
    combined = result.stdout + result.stderr
    assert "account" in combined.lower() or "partition" in combined.lower(), (
        "Expected an error message mentioning --account or --partition"
    )


def test_benchmark_script_unknown_flag_exits_nonzero():
    """run_benchmark.sh with an unrecognised flag should exit non-zero."""
    result = subprocess.run(
        ["bash", str(BENCHMARK_SCRIPT), "--totally-unknown-flag"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode != 0, (
        "run_benchmark.sh with unknown flag should exit non-zero, "
        f"but exited {result.returncode}"
    )
