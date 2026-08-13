# TumorSPACE_AWS

A reproducible platform for spatial transcriptomics analysis on HPC clusters, with containerized (Singularity) and native execution modes.

## Quick Links

- **[Guided Tour](docs/TOUR.md)** - Start here for a meeting walkthrough or first orientation
- **[Installation & First Run](docs/GETTING_STARTED.md)** - Set up and run your first analysis
- **[Benchmarks & Timing Data](docs/benchmarks.md)** - Benchmark datasets and performance analysis
- **[Development Guide](docs/DEVELOPMENT.md)** - Edit code and test changes
- **[Container Build](containers/BUILD_INSTRUCTIONS.md)** - Build and customize containers

## Overview

TumorSPACE_AWS provides a reproducible, scalable framework for analyzing spatial transcriptomics data. Containerized execution (Singularity) is the recommended mode for production; native execution is supported primarily for development and debugging.

## Features

- **Singularity Containers**: Reproducible Julia and R execution environments for HPC — full rebuild ~30 min; incremental R script-only updates under 1 min
- **Bootstrap Validation**: Phylogenetic bootstrap analysis with deterministic seeding
- **Automated Orchestration**: SLURM job array orchestration for multi-step pipeline
- **Fixed-Seed Reproducibility**: Test mode with deterministic seeding ensures identical results across runs
- **Performance Optimized**: Production mode (30 SVDs) ~25 min (370 spots), ~90 min (1,109 spots), ~6 hrs (4,342 spots); test mode ~5-15 min (see [benchmarks](docs/benchmarks.md))
- **Benchmark Datasets**: Small (370 spots), medium (1,109 spots), and large (4,342 spots) datasets production-validated with documented resource requirements

## Requirements

- **HPC Cluster (Recommended):** Access to cluster with SLURM job scheduler for automated orchestration and parallel processing
- **Singularity/Apptainer:** Available via module (e.g., `module load singularity`)
- **Memory:** 4GB minimum (small datasets), 16GB+ recommended (large datasets with >10K DA genes)
- **Disk Space:** ~500 MB for container image and working files

**Note:** The orchestration scripts are optimized for HPC with SLURM. Advanced users can run individual pipeline steps locally on workstations with sufficient memory (see [Native Installation](docs/advanced/NATIVE_INSTALLATION.md) for manual execution). Small datasets (<1000 spots) are feasible on local machines.

For development without containers, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Installation

```bash
# Clone repository
git clone https://github.com/aramanlab/TumorSPACE_AWS.git
cd TumorSPACE_AWS

# Automated setup (builds container)
./setup.sh

# Configure SLURM (edit with your account/partition)
cp config/slurm_config.sh.example config/slurm_config.sh
nano config/slurm_config.sh  # Edit as needed
```

Next: [Getting Started](docs/GETTING_STARTED.md)

## Repository Structure

| Folder | Purpose |
|--------|---------|
| `containers/` | Singularity container build scripts and images |
| `workflows/` | Analysis workflow orchestration and scripts |
| `benchmarks/` | Test datasets and benchmark results |
| `benchmarking/` | Performance measurement utilities and timing analysis |
| `config/` | SLURM configuration and runtime settings |
| `docs/` | User documentation |
| `tests/` | Unit tests and validation scripts |
| `bin/` | Pre-built binaries (gotree) |
| `reference_data/` | Reference gene annotation files |
| `logs/` | Runtime logs from SLURM jobs |
| `archive/` | Historical documentation and obsolete scripts |

## Example Dataset

Included benchmark dataset: **GSE213688_GSM6592057** (370 spots, ~13 MB)  
Location: `benchmarks/GSE213688_GSM6592057/input_data/`  
Use this for your first test run — expected runtime ~25 min native / ~45 min container on typical HPC nodes.

## Development

To modify TumorSPACE_AWS code:

1. **Edit Julia code** in `workflows/tumorspace_core/julia/` — rebuild with `bash containers/add_gotree_to_julia.sh` (~8 min)
2. **Edit R code (BayesSpace / pipeline report)** in the appropriate `workflows/<feature>/R/` directory — rebuild with `bash containers/build_r_container.sh` (~30 sec). See [DEVELOPMENT.md](docs/DEVELOPMENT.md) for where new feature R scripts belong.
3. **Edit R code (DE analysis)** in `workflows/DE_analysis/R/` — rebuild with `bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp` (~30 sec for script-only changes).
4. **Test native mode:** `bash run_pipeline.sh --test`
5. **Test container mode:** `bash run_pipeline.sh --container containers --test`

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for detailed guidance and debugging tips.

## Roadmap

### Backend Pipeline

| Version | Feature | Status |
|---------|---------|--------|
| v1 | Data Acquisition (GEO search + harmonization) | ✅ Production |
| v1 | TumorSPACE Core (Steps 1–9: tree, SGs, DA, SLAB) | ✅ Production |
| v1 | BayesSpace Spatial Clustering | ✅ Production |
| v1 | Pipeline Report | ✅ Production |
| v2 | Spatial Domain Analysis (GSEA, pathway enrichment, SG/BayesSpace/annotation-flexible DE) | 🔲 Pre-production (scripts in `workflows/sg_analysis/R/`) |
| v2 | SpaCET Cell Type Deconvolution | 🔲 Planned — Vivek |
| v2 | DE Analysis (Seurat + DESpace) | 🔲 Built — Jason |
| v3 | Probabilistic Region Alignment | 🔲 Planned |

### Frontend Outputs Enabled

This table describes what the backend produces and what each output is sufficient to support on the frontend, by version.

| Version | Backend Output | Frontend capability enabled |
|---------|---------------|-----------------------------|
| v1 | `bayesspace_coldata.csv` | H&E image with overlaid spot cluster locations; per-cluster composition plots (e.g. % lymphocytes) |
| v1 | `sg_pairs.tsv` | SG classification visualization in tissue space |
| v1 | `DA_significant.txt`, `SLAB_scores.txt` | Download of TumorSPACE differential abundance and lability results |
| v1 | `Pipeline_Report.pdf` | QC and validation summary |
| v2 | Spatial domain analysis outputs | DE analysis between SG / BayesSpace / user-annotated cluster pairs; volcano plots; pathway enrichment |
| v2 | SpaCET deconvolution results | Spot-level cell type composition plots |
| v2 | DESpace outputs | Spatially-resolved differential expression results |

See [docs/FEATURE_ROLLOUT.md](docs/FEATURE_ROLLOUT.md) for developer detail on rollout phases and implementation playbook.

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.

## Citation

If you use TumorSPACE_AWS in your research, please cite:

Behera, V. et al. Conserved principles of spatial biology define tumor heterogeneity and response to immunotherapy. *bioRxiv*, 2024.10.18.619136 (2025). https://doi.org/10.1101/2024.10.18.619136

## Related Projects

- [TumorSPACE.jl](https://github.com/aramanlab/TumorSPACE.jl) - Core Julia package
- [Behera_etal_2025](https://github.com/aramanlab/Behera_etal_2025) - Analysis workflows

## Contact

For questions or issues, please:
- Open an issue on GitHub
- Contact: Vivek Behera (beheravivek@gmail.com)

## Acknowledgments

Developed at the [Arjun Raman Lab](https://ramanlab.net/) for spatial transcriptomics analysis.
