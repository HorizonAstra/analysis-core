# BayesSpace Feature

[BayesSpace](https://bioconductor.org/packages/BayesSpace) spatial clustering on
10x Visium data. Runs independently of `tumorspace_core` — consumes the same
Visium input data and produces complementary cluster assignments.

Supports **single-sample** and **joint (multi-sample)** clustering. Joint mode
passes multiple directories as a comma-separated `--datapath` list and uses
Harmony integration to produce shared cluster labels across samples.

BayesSpace is included in the shared `tumorspace_r.sif` container (R 4.4.1,
Bioconductor 3.20, BayesSpace 1.16+). No separate container build is required.

## Contents

| File | Description |
|------|-------------|
| `R/run_bayesspace.R` | Core R analysis script |
| `orchestration/run_bayesspace.sh` | Bash wrapper (interactive or batch) |
| `orchestration/submit_bayesspace.sbatch` | SLURM job submission script |

## Supported Input Formats

The pipeline auto-detects the input format based on directory contents:

- **Standard Visium**: Space Ranger output directory containing
  `filtered_feature_bc_matrix/` and `spatial/`. Compatible with Space Ranger V1
  and V2+.
- **Reformatted Visium**: Custom format with `M.txt`, `features.txt`,
  `barcodes.txt`, and `barcodes_positions.txt` (or `barcodes_positions_imageScaling.txt`).

## Outputs

| File | Description |
|------|-------------|
| `bayesspace_coldata.csv` | colData with spatial cluster labels |
| `cluster_plot.png` | BayesSpace cluster visualization (single mode) |
| `cluster_plot_<sample>.png` | Per-sample cluster visualizations (joint mode) |
| `parameters.txt` | All parameters used, including random seeds |

## Usage

All commands run from the **repo root**.

### Single-sample

```bash
bash workflows/bayesspace/orchestration/run_bayesspace.sh \
  --datapath /path/to/visium/data \
  --outdir /path/to/output
```

### Joint (multi-sample)

Pass a comma-separated list of directories. Harmony integration is applied
automatically when more than one path is provided.

```bash
bash workflows/bayesspace/orchestration/run_bayesspace.sh \
  --datapath /path/to/sample1,/path/to/sample2 \
  --outdir /path/to/output
```

### SLURM

Edit the parameters at the top of `submit_bayesspace.sbatch`, then:

```bash
sbatch workflows/bayesspace/orchestration/submit_bayesspace.sbatch
```

To override SLURM resource defaults:

```bash
sbatch --mem=32G --time=08:00:00 workflows/bayesspace/orchestration/submit_bayesspace.sbatch
```

### Command-Line Options

| Option | Default | Description |
|--------|---------|-------------|
| `--datapath` | (required) | Path to Visium data directory, or comma-separated list for multi-sample |
| `--outdir` | `.` | Output directory |
| `--nPCs` | `15` | Number of principal components |
| `--q` | `8` | Number of spatial clusters |
| `--theta` | `2` | Harmony clustering penalty (joint mode only) |
| `--container` | `containers/tumorspace_r.sif` | Path to Singularity .sif file |
| `--no-container` | — | Force native mode (bypass container) |
| `--test` | `false` | Run in test mode with fixed seeds |

### SLURM Resource Defaults

| Resource | Default |
|----------|---------|
| CPUs | 1 |
| Memory | 16 GB |
| Time | 30 minutes |

## Test Mode

Test mode runs the pipeline with fixed seeds (`seed1=42`, `seed2=123`) and
writes `test_coldata_single.csv` (single mode) or `test_coldata_joint.csv`
(joint mode) to the output directory for md5sum validation.

**Automated validation (recommended):**

```bash
bash tests/bayesspace/test_bayesspace.sh
```

This runs both single and joint modes in container mode and asserts that outputs
exactly match the committed baselines in
`benchmarks/GSE213688_GSM6592057/expected_outputs/`.

To regenerate baselines (e.g. after an intentional algorithm or seed change):

```bash
bash tests/bayesspace/test_bayesspace.sh --generate-reference
# then commit:
# git add benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_single.csv
# git add benchmarks/GSE213688_GSM6592057/expected_outputs/test_coldata_joint.csv
```

## Container

BayesSpace is bundled in the main R container (`containers/tumorspace_r.sif`),
built during `setup.sh`. If the container needs to be rebuilt:

```bash
bash containers/build_r_container.sh --force
```
