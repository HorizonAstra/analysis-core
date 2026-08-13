# DE Analysis

Spatial differential expression analysis on pre-clustered Visium data.

Runs **Seurat FindAllMarkers** to identify cluster marker genes. Optionally runs
**DESpace** spatially-variable gene detection when `--despace` is passed and all
clusters are present in all samples.

Supports **single-sample** and **joint (multi-sample)** analysis. For joint mode,
pass a comma-separated list of Visium directories to `--datapath` and provide a
metadata file covering all samples.

---

## Inputs

| Item | Description |
|------|-------------|
| `--datapath` | Path to Visium data directory, or comma-separated list for multi-sample |
| `--metapath` | Path to metadata CSV containing barcode, cluster, and sample ID columns (e.g. output of `run_bayesspace.R`) |
| `--clustercol` | `colData` column holding cluster IDs (default: `spatial.cluster`) |
| `--idcol` | `colData` column holding sample identifiers (default: `sample`) |

---

## Outputs

| File | Description |
|------|-------------|
| `seurat_cluster_markers_all.csv` | All Seurat marker genes per cluster, sorted by cluster then avg_log2FC descending |
| `seurat_cluster_markers_top50.csv` | Top 50 markers per cluster by avg_log2FC |
| `despace_results_all.csv` | DESpace results across all genes (`--despace` only) |
| `despace_results_byCluster.csv` | DESpace per-cluster results (`--despace` only) |

---

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--datapath` | — | Visium input directory, or comma-separated list (required) |
| `--metapath` | — | Metadata CSV with barcode and cluster columns (required) |
| `--outdir` | — | Output directory (required) |
| `--clustercol` | `spatial.cluster` | colData column with cluster assignments |
| `--idcol` | `sample` | colData column with sample IDs |
| `--despace` | off | Run DESpace spatially-variable gene detection |
| `--container` | auto | Path to Singularity `.sif` (forces container mode) |
| `--no-container` | off | Force native mode |
| `--test` | off | Reserved for future fixed-seed validation |

---

## Example Commands

**Single-sample (container mode, recommended on HPC):**
```bash
bash workflows/DE_analysis/orchestration/run_de_analysis.sh \
    --datapath /path/to/visium/data \
    --metapath /path/to/bayesspace_coldata.csv \
    --outdir /path/to/results/de_analysis
```

**Joint (multi-sample):**
```bash
bash workflows/DE_analysis/orchestration/run_de_analysis.sh \
    --datapath /path/to/sample1,/path/to/sample2 \
    --metapath /path/to/joint_coldata.csv \
    --outdir /path/to/results/de_analysis
```

**With DESpace:**
```bash
bash workflows/DE_analysis/orchestration/run_de_analysis.sh \
    --datapath /path/to/visium/data \
    --metapath /path/to/bayesspace_coldata.csv \
    --outdir /path/to/results/de_analysis \
    --despace
```

**Custom cluster and sample ID columns:**
```bash
bash workflows/DE_analysis/orchestration/run_de_analysis.sh \
    --datapath /path/to/visium/data \
    --metapath /path/to/coldata.csv \
    --outdir /path/to/results \
    --clustercol my.clusters \
    --idcol patient_id
```

**Native mode:**
```bash
bash workflows/DE_analysis/orchestration/run_de_analysis.sh \
    --datapath /path/to/visium/data \
    --metapath /path/to/bayesspace_coldata.csv \
    --outdir /path/to/results/de_analysis \
    --no-container
```

---

## Notes on DESpace

DESpace requires that **all clusters are present in all samples**. If any sample
is missing one or more clusters, DESpace is skipped with a warning and only
Seurat results are written. Pass `--despace` explicitly to opt in; Seurat
analysis always runs regardless.

---

## Testing

```bash
# Generate baselines (first time):
bash tests/de_analysis/test_de_analysis.sh --generate-reference

# Validate (same or different cluster):
bash tests/de_analysis/test_de_analysis.sh
```

Validates `seurat_cluster_markers_all.csv`, `seurat_cluster_markers_top50.csv`,
`despace_results_all.csv`, and `despace_results_byCluster.csv` via md5sum in
both single and joint modes. Baselines are committed to
`benchmarks/GSE213688_GSM6592057/expected_outputs/`.

---

## Container

Uses a dedicated R 4.5 / Bioconductor 3.21 container (`containers/tumorspace_r45.sif`)
that includes Seurat, DESpace 2.0, and all required geo libraries (GDAL, GEOS, PROJ).
This is separate from `tumorspace_r.sif` (used by BayesSpace and pipeline report).

Rebuild the base layer when R packages change:

```bash
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp --force
```

Script-only changes (no package changes) only need the script layer (~30 sec):

```bash
bash containers/build_r45_container.sh --scratch /scratch/$USER/tmp
```
