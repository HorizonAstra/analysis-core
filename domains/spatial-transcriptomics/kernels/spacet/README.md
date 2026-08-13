# SpaCET Workflow

Cell-type deconvolution for Visium spatial transcriptomics data using SpaCET.

Core logic verbatim from `Revisions_TumorSPACE_v1.R` (spacet task block, lines 237–305).

## Usage

```bash
bash workflows/spacet/orchestration/run_spacet.sh \
  --raw-data-dir benchmarks/GSE213688_GSM6592057/input_data \
  --outdir local/outputs/spacet_test \
  --cancer-type BRCA
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--raw-data-dir` | yes | Input data directory (must contain `M.txt`, `features.txt`, `barcodes_positions.txt`) |
| `--outdir` | yes | Output directory for `Spacet_Matrix.txt` and cache files |
| `--cancer-type` | yes | SpaCET cancer type string (see lookup table below) |
| `--cores` | no | Parallel cores for deconvolution [default: 8] |
| `--container` | no | Force container mode with this SIF path |
| `--no-container` | no | Force native mode |

## Cancer type mapping

See `reference_data/spacet/tissue_types_lookup.txt` for the full table.

| Tissue_Type | SpaCET_CancerType |
|-------------|-------------------|
| TNBC | BRCA |
| breast carcinoma | BRCA |
| CRC | COAD |
| HCC | LIHC |
| HNSCC | HNSC |
| lung adenocarcinoma / NSCLC | LUAD |
| PDAC | PAAD |
| melanoma | SKCM |
| glioblastoma | GBM |
| HGSOC / ovarian | OV |
| PANCAN | PANCAN |

## Inputs

- `M.txt` — spot × gene count matrix (no header, tab-separated)
- `features.txt` — one column `ensembl_gene_id` (Ensembl gene IDs)
- `barcodes_positions.txt` — columns: `barcode`, `pxl_row_in_fullres`, `pxl_col_in_fullres`, …

Gene name conversion (Ensembl → common name) is performed automatically using
`reference_data/Hg38_GeneNames_MultipleFormats.txt`. Duplicate gene names are
collapsed by summing counts across barcodes.

## Outputs

| File | Description |
|------|-------------|
| `Spacet_Matrix.txt` | Barcode × CellType proportion matrix. One row per barcode passing QC. CellType names have spaces replaced with `_`. |
| `M_nodup.txt` | Cached de-duplicated count matrix (re-used on reruns) |
| `features_nodup.txt` | Cached de-duplicated gene names |

## Test

```bash
bash tests/spacet/test_spacet.sh
```

Tests against `benchmarks/GSE213688_GSM6592057/input_data/` with `--cancer-type BRCA`.
Structure-only assertions (file existence, non-empty, expected column shape).

---

## CT-DA-SLAB: Cell Type Differential Abundance + Spatial SLAB

The CT-DA-SLAB step converts the SpaCET output into a second **feature space** for
Differential Abundance and SLAB scoring, running the same Julia analysis that the
gene-expression space uses (Steps 8–9), but for cell types.

### Inputs required

| File | Source |
|------|--------|
| `Spacet_Matrix.txt` | Output of `run_spacet.sh` |
| `OptimalTree_pruned_node_compare_list.txt` | Output of Step 7 (in `optimal/`) |
| `OptimalTree_pruned_node_compare_leaves.txt` | Output of Step 7 (in `optimal/`) |
| `barcodes_positions.txt` | Input data directory |

### Preparation step (R)

`workflows/spacet/R/prepare_ct_matrix.R` reshapes `Spacet_Matrix.txt` into the
standard Julia DA/SLAB interface inside `optimal/ct/`:

| Output | Format |
|--------|--------|
| `M.txt` | Numeric matrix, no header/rownames, barcodes × cell types |
| `barcodes.txt` | Header `barcode`, one barcode per line |
| `genes.txt` | Header `cell_type`, one cell type per line |
| `barcodes_positions.txt` | Copied from `--input-dir` |
| `OptimalTree_pruned_node_compare_list.txt` | Relative symlink to `../` |
| `OptimalTree_pruned_node_compare_leaves.txt` | Relative symlink to `../` |
| `feature_space_info.txt` | Metadata: type, n_features, source path, timestamp |

Barcodes are filtered to those present in `barcodes_positions.txt`.
Exits non-zero if tree files are missing or fewer than 2 cell types pass filtering.

### Full CT-DA-SLAB SLURM job

`workflows/spacet/orchestration/run_ct_da_slab.sh` submits a single SLURM job
that runs: R preparation → Julia DA (permutation test) → Julia SLAB scoring.

```bash
bash workflows/spacet/orchestration/run_ct_da_slab.sh \
  --dataset SAMPLE_ID \
  --account ACCOUNT \
  --partition PARTITION \
  --spacet-dir /path/to/spacet_output \
  --input-base /path/to/output_base \
  --input-dir /path/to/input_data \
  --workspace-root /path/to/TumorSPACE_AWS \
  --container containers/ \
  --num-shuffle 100 \
  --dependency STEP7_JOB_ID
```

Outputs are written to `optimal/ct/` alongside `optimal/gene/` (gene-space outputs).
On completion, `ct_slab_done.txt` is written and an entry is appended to `feature_spaces.tsv`.

### Integration with run_pipeline_full.sh

When `--cancer-type` is provided, `run_pipeline_full.sh` automatically:
1. Submits `run_spacet.sh` immediately after Step 1 (no SLURM dependency — runs in parallel)
2. Submits `run_ct_da_slab.sh` after Step 7 completes AND SpaCET completes
3. Step 10 (pipeline completion) waits for both gene SLAB (Step 9) and CT-DA-SLAB

Use `--no-spacet` to disable or `--num-shuffle-ct N` to change permutation count.

### Test

```bash
bash tests/spacet/test_ct_da_slab.sh
```

Validates `prepare_ct_matrix.R` with a synthetic `Spacet_Matrix.txt` generated
from benchmark barcodes. Checks M.txt format, header values, dimension consistency,
proportion range, symlinks, and `feature_space_info.txt`.
