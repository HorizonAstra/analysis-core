# TumorSPACE Documentation

Complete documentation for the TumorSPACE spatial transcriptomics analysis pipeline.

## Quick Links

- 🚀 **[Getting Started](GETTING_STARTED.md)** - Your first analysis in 15 minutes
- 📖 **[Usage Guide](usage_guide.md)** - Running the pipeline with orchestration scripts
- ⚡ **[Performance Benchmarks](benchmarks.md)** - Runtime data and resource planning

## Documentation Structure

### User Guides

| Document | Audience | Description |
|----------|----------|-------------|
| [GETTING_STARTED.md](GETTING_STARTED.md) | Beginners | Step-by-step tutorial for first-time users |
| [usage_guide.md](usage_guide.md) | Regular users | How to run the pipeline on your data |
| [benchmarks.md](benchmarks.md) | All users | Performance data and resource requirements |

### Advanced Documentation

| Document | Purpose |
|----------|---------|
| [advanced/INPUT_OUTPUT_SPEC.md](advanced/INPUT_OUTPUT_SPEC.md) | Exact file format specifications |
| [advanced/NATIVE_INSTALLATION.md](advanced/NATIVE_INSTALLATION.md) | Installing without containers |
| [advanced/DEVELOPMENT_NOTES.md](advanced/DEVELOPMENT_NOTES.md) | Internal design decisions (not for GitHub) |

## Pipeline Overview

TumorSPACE analyzes spatial transcriptomics data through the following stages:

### Stage 1: Tree Building & Optimization (Parallel SVD Processing)

Process **30 SVDs in parallel** to find optimal tree structure:

- **phylo_tree_build** - Build phylogenetic trees from expression data
- **phylo_node_extract** - Extract node relationships and hierarchy
- **spatial_optimize** - Hyperparameter search + spatial clustering (calculates NodeCor)
- **phylo_tree_prune** - Prune tree by support threshold
- **SVD selection** - Identify best SVD by max(NodeCor), create `optimal/` symlink

### Stage 2: Spatial Group Analysis (Single Optimal SVD)

Run on the selected optimal SVD only:

- **sg_identify_pairs** - Identify Spatial Group (SG) sibling pairs (R)
- **sg_diff_abundance** - Test differential gene expression between SGs
- **sg_slab_score** - Calculate spatial localization scores (SLAB)
- **pipeline_report** - Generate pipeline validation report

## Key Concepts

**Spatial Groups (SG):** Phylogenetically-related clusters of spots that share spatial proximity and expression patterns.

**NodeCor:** Correlation between predicted and actual spot locations. Higher values (0-1) indicate better spatial clustering. Used to select the optimal SVD.

**SLAB Score:** Spatially Localized Abundance Bias. Fraction of tissue showing differential abundance: `SLAB = (# spots with DA) / (total spots)`.

## Execution Modes

| Mode | Use When | Command Pattern |
|------|----------|-----------------|
| **Native** | Direct HPC execution | `bash workflows/tumorspace_core/orchestration/run_*.sh --dataset DATASET ...` |
| **Container** | Reproducibility needed | Same command + `--container containers` |
| **Dependencies** | End-to-end automation | Add `--dependency JOB_ID` to chain steps |

## Quick Start Examples

```bash
# Run full pipeline on test data (native mode)
bash workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh \
    --dataset GSE213688_GSM6592057 \
    --account <your-account> --partition <your-partition> \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base results/test_run \
    --test

# Run with containers for reproducibility
bash workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh \
    --dataset GSE213688_GSM6592057 \
    --account <your-account> --partition <your-partition> \
    --input-dir benchmarks/GSE213688_GSM6592057/input_data \
    --data-dir benchmarks/GSE213688_GSM6592057/input_data \
    --output-base results/test_run \
    --container containers/julia_1.9_with_gotree.sif \
    --test
```

## Getting Help

1. **For installation issues:** See [Getting Started](GETTING_STARTED.md)
2. **For usage questions:** See [Usage Guide](usage_guide.md)
3. **For performance planning:** See [Benchmarks](benchmarks.md)
4. **For file format errors:** See [Input/Output Spec](advanced/INPUT_OUTPUT_SPEC.md)
5. **For development:** See [Development Notes](advanced/DEVELOPMENT_NOTES.md)

## Recent Updates

- **Jan 17, 2026:** Added parallel SVD processing with job arrays and automatic selection
- **Jan 16, 2026:** Completed full pipeline (phylo_tree_build through sg_slab_score)
- **Jan 15, 2026:** Established portable framework pattern with native + container modes
