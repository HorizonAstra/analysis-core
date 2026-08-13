# biobakery — metagenomics pipeline tooling for Randi HPC

Run the Huttenhower lab's **biobakery_workflows** (whole-metagenome shotgun, "wmgx")
on the CRI *Randi* cluster, without having to relearn the plumbing each time.

This repo is **tooling only** — runners, cluster config, and templates. It makes no
assumption about where your data lives: inputs, outputs, and scratch are all passed
by path at runtime. Study data is kept in a **separate** `studies/` tree (see below).

If you've never touched these tools or SLURM before, read sections 1–7 top to bottom.
If you just want to run something, jump to [8. Run a study](#8-run-a-study).

---

## Contents
1. [What this pipeline does](#1-what-this-pipeline-does)
2. [What you need before you start](#2-what-you-need-before-you-start)
3. [Repo layout](#3-repo-layout)
4. [Input — what to give it](#4-input--what-to-give-it)
5. [Output — what you get back](#5-output--what-you-get-back)
6. [Setup (first time on Randi)](#6-setup-first-time-on-randi)
7. [SLURM in five minutes](#7-slurm-in-five-minutes)
8. [Run a study](#8-run-a-study)
9. [Monitor, resume, cancel](#9-monitor-resume-cancel)
10. [Options — what's possible](#10-options--whats-possible)
11. [Configuration reference](#11-configuration-reference)
12. [Operating rules](#12-operating-rules)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. What this pipeline does

You give it raw **shotgun metagenomic sequencing reads** (all the DNA in a sample —
e.g. a stool sample — sequenced without targeting any single gene). It gives you
back **who is there** and **what they can do**, as clean tables.

It runs four tools in sequence, coordinated by a fifth:

| Tool | Stage | What it does | Produces |
|------|-------|--------------|----------|
| **KneadData** | Quality control | Trims low-quality/adapter bases (Trimmomatic), removes human/host reads (Bowtie2 vs the T2T human genome), drops tandem repeats (TRF) | Clean, host-free reads |
| **MetaPhlAn** | Taxonomic profiling | Matches reads to unique microbial marker genes | Relative abundance of each microbe (down to species / strain-group) |
| **HUMAnN** | Functional profiling *(optional)* | Maps reads to gene families (UniRef90) and metabolic pathways (MetaCyc) | Gene-family and pathway abundance tables |
| **StrainPhlAn** | Strain profiling *(optional)* | SNP-level profiling of marker genes | Strain-level comparisons across samples |
| **AnADAMA2** | Orchestration | Defines the task order, tracks what's done, submits each tool as its own SLURM job | Runs the whole thing, resumably |

`wmgx` is biobakery's **w**hole-**m**eta**g**enome shotgun workflow. (For 16S amplicon
data this is the wrong one — biobakery has a separate `16s` workflow.)

**Why AnADAMA2 matters:** it turns the pipeline into a dependency graph, records each
finished step in a small database, and fans the heavy tools out across the cluster as
separate jobs. If a run dies halfway, re-submitting the *same command* skips everything
already done. You interact with `biobakery_workflows`; AnADAMA2 works underneath it.

---

## 2. What you need before you start

- **A Randi account** and membership in the **`dfi` labshare** (`/gpfs/data/dfi-cores/`).
  You should be able to `ssh` in and land on a login node (`cri22in*`).
- **The shared reference databases** — large (multi-TB) static DBs for KneadData /
  MetaPhlAn / HUMAnN. These already live on the labshare at
  `/gpfs/data/dfi-cores/biobakery/databases/` and this repo symlinks to them
  (section 6). You do **not** download these yourself.
- **This repo, cloned on Randi**, plus its conda environment built once (section 6).
- Basic comfort with a terminal. No prior SLURM or biobakery knowledge assumed —
  sections 7 and 1 cover those.

---

## 3. Repo layout

```
biobakery/
├── bin/
│   ├── submit_wmgx.sh   ← you run THIS (from a login node); it sbatches the orchestrator
│   └── run_wmgx.sh      the orchestrator; runs on a compute node, drives biobakery_workflows
├── config/
│   ├── site.sh          SLURM partition / account / grid job count  (edit per cluster)
│   ├── env.sh           reference-DB paths + cache redirection to scratch
│   └── activate.sh      loads conda + activates the env in envs/
├── templates/
│   └── study-run.sh     copy into a study dir, edit paths, run
├── provenance/
│   └── runs.tsv         one row per run (timestamp, study, workflow, host, output)
├── envs/
│   └── exports/         tracked conda lockfiles = reproducible env rebuilds
├── references/          symlinks to shared DBs  (gitignored; created on-cluster)
├── bootstrap.sh         recreates runtime dirs git can't carry
└── README.md
```

**Tool ≠ data.** This repo (`biobakery/`) is the tool. Your sequencing data and results
live in a *sibling* directory that is never committed:

```
/gpfs/data/dfi-cores/rijul/studies/<study>/
├── input/      raw fastqs for this study
├── output/     results  ← persistent; also holds AnADAMA2's tracking DB
├── metadata/   sample sheets / mapping files
└── analysis/   downstream stats (MaAsLin2, notebooks)
```

Keeping them separate means you can re-run, add studies, or move data without ever
touching the tool code, and vice versa.

---

## 4. Input — what to give it

**File type:** whole-metagenome shotgun sequencing reads, gzipped FASTQ (`.fastq.gz`).
Paired-end is typical; single-end is supported.

**One directory per study**, containing every sample's fastqs. For paired-end, each
sample is two files:

```
input/
├── SAMPLE1_R1_001.fastq.gz    # forward reads
├── SAMPLE1_R2_001.fastq.gz    # reverse reads
├── SAMPLE2_R1_001.fastq.gz
└── SAMPLE2_R2_001.fastq.gz
```

**Pair identifier — important.** biobakery_workflows figures out which two files are a
pair from a marker string in the forward file's name. Our example files use
`_R1_001` / `_R2_001`, so we pass `--pair-identifier _R1_001`. **The tool's default may
not match your naming** — if your files use `.R1`/`.R2` or `_1`/`_2`, set
`--pair-identifier` accordingly, or the tool will silently treat everything as
single-end. The **sample name** is the filename with the pair identifier and extension
stripped (`SAMPLE1_R1_001.fastq.gz` → `SAMPLE1`).

**If your extension differs** (e.g. `.fastq`, `.fq.gz`), pass `--input-extension`.

**Not** for: 16S amplicon reads, already-assembled contigs, or BAM/CRAM. This is
raw-reads-in.

---

## 5. Output — what you get back

Everything lands under your `--output` directory:

```
output/
├── kneaddata/
│   ├── main/                     cleaned, host-removed reads per sample
│   └── ...                       kneaddata_read_count_table.tsv (reads kept at each step)
├── metaphlan/
│   ├── main/                     per-sample taxonomic profile (relative abundances)
│   └── merged/                   all samples joined into one table + species counts
├── humann/                       (only if functional profiling is NOT bypassed)
│   ├── main/                     per-sample gene families, pathway abundance/coverage
│   ├── merged/                   joined + normalized (relative abundance / CPM) tables
│   └── counts/                   feature and read-count summaries
├── anadama.log                   per-task log — the REAL errors show up here
├── slurm_files/                  each tool's grid job: script + .out / .err / .rc
├── .anadama/                     AnADAMA2's tracking DB (this is what enables resume)
└── PROVENANCE_*.txt              this runner's record of what ran (added by us)
```

The two tables you'll actually analyze first:
- **`metaphlan/merged/…taxonomic_profiles.tsv`** — the community composition (who's there).
- **`humann/merged/…`** — gene-family / pathway abundances (what they can do).

Want the polished **HTML report** (summary figures, QC plots, top taxa)? That's a
separate visualization workflow — see [section 10](#10-options--whats-possible).

Exact filenames vary slightly by tool version; the folder structure above is stable.

---

## 6. Setup (first time on Randi)

Run these once, on a **login node**.

```bash
# 1. Clone and prepare the repo
git clone <remote> biobakery && cd biobakery
chmod +x bootstrap.sh bin/*.sh config/*.sh templates/*.sh   # git can drop exec bits here
bash bootstrap.sh                                            # recreate runtime dirs

# 2. Build the conda environment (the tools) from a tracked lockfile
module load gcc/12.1.0 miniconda3/24.9.2
conda create -p envs/biobakery_workflows --file envs/exports/<lockfile>
#   ^ the lockfile pins exact, verified versions — reproducible.
#     To build fresh instead (slower, resolves live):
#     conda create -p envs/biobakery_workflows -c biobakery -c bioconda -c conda-forge biobakery_workflows

# 3. Point references/ at the shared databases (symlinks, not copies)
mkdir -p references
ln -s /gpfs/data/dfi-cores/biobakery/databases/chocophlan        references/chocophlan
ln -s /gpfs/data/dfi-cores/biobakery/databases/uniref            references/uniref
ln -s /gpfs/data/dfi-cores/biobakery/databases/utility_mapping   references/utility_mapping
ln -s /gpfs/data/dfi-cores/biobakery/databases/kneaddata_hg39    references/kneaddata_hg39
#   (paths shown are representative — confirm the real subfolders on the labshare.)
#   NOTE: the MetaPhlAn DB is NOT symlinked under references/. Runs pass it explicitly
#   via config/env.sh ($MPA_DB_DIR_*), and the metaphlan package default is set by
#   bin/link_metaphlan_db.sh. A references/metaphlan_db link would be unused (and lie).

# 4. Set your cluster specifics
$EDITOR config/site.sh     # partition (e.g. tier1q), account (dfi)
```

Sanity check the environment:
```bash
source config/activate.sh
biobakery_workflows --version      # should print v3.1
which kneaddata metaphlan humann trf trimmomatic   # all should resolve inside envs/
```

---

## 7. SLURM in five minutes

Randi is a **shared** cluster: hundreds of people, one set of machines. You don't run
heavy work directly — you hand it to **SLURM**, the job scheduler, which places it on a
free **compute node**.

- **Login node** (`cri22in*`) — where `ssh` drops you. For editing, git, and *submitting*
  jobs. **Never run heavy compute here** (it's shared and monitored).
- **Compute node** (`cri22cn*`) — where jobs actually run. You reach it through SLURM.

Commands you'll use:

| Command | What it does |
|---------|--------------|
| `sbatch <script>` | Submit a **batch** job — runs unattended, **survives you disconnecting**. This is how the pipeline is launched. |
| `srun -p tier1q -t 4:00:00 --mem=16G -c 4 --pty bash` | Get an **interactive** shell on a compute node (for poking around). |
| `squeue -u $USER` | List **your** jobs and their state. |
| `sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed,MaxRSS,ReqMem` | Job **history** — works after a job ends; shows how it died and how much memory it used. |
| `scancel <jobid>` | Cancel a job. |
| `sinfo` | Show partitions and how busy they are. |

Reading `squeue`: the **ST** column is the job state — `R` running, `PD` pending
(waiting for resources), `CG` completing. Jobs need a **partition** (`-p`, e.g.
`tier1q`), an **account** (`-A dfi`), a **wall-time** limit (`-t`), memory (`--mem`),
and cores (`-c`). This repo sets those for you in `config/site.sh` and the runners.

> ⚠️ `sacct` State can read `COMPLETED` even when a task inside the run **failed**.
> Always confirm with the logs and output files, not the job state alone.

---

## 8. Run a study

**Recommended — the template flow.** Copy the template into your study directory, edit
the two paths at the top, and run it from a **login node**:

```bash
cp templates/study-run.sh /gpfs/data/dfi-cores/rijul/studies/<study>/run.sh
$EDITOR /gpfs/data/dfi-cores/rijul/studies/<study>/run.sh    # set STUDY and BASE
bash    /gpfs/data/dfi-cores/rijul/studies/<study>/run.sh
```

**What happens under the hood:**
1. The template calls `bin/submit_wmgx.sh`.
2. `submit_wmgx.sh` runs `sbatch` (lightweight — fine on the login node) to launch the
   **orchestrator** on a compute node. Because it's a batch job, **it keeps running even
   if you close your laptop** — no tmux, no worrying about which login node you're on.
3. The orchestrator `bin/run_wmgx.sh` activates the env and runs `biobakery_workflows`,
   which uses AnADAMA2 to submit each tool (KneadData, MetaPhlAn, …) as its **own** grid
   job sized to its needs.

**Direct / ad-hoc form** (skip the template):
```bash
bash bin/submit_wmgx.sh \
  --study   NAME \
  --input   /path/to/study/input \
  --output  /path/to/study/output \
  --scratch /scratch/$USER/local-biobakery/NAME/$(date +%Y%m%d_%H%M%S) \
  [--jobs 20] [--mode wmgx|taxonomy] \
  [--pair-identifier _R1_001] [--bypass-functional-profiling]
```

It prints a job id and the log path. `--study`, `--input`, `--output`, and `--scratch`
are required; anything else is forwarded straight to `biobakery_workflows`
(see [section 10](#10-options--whats-possible)).

**`--mode` picks the MetaPhlAn DB for you** (no hand-editing `config/env.sh`):
- `--mode wmgx` (default) — full pipeline (QC → taxonomy → function → strain) on the
  **COMPAT** DB (`vJun23`), the newest DB HUMAnN 3.9 can consume. Keeps MetaPhlAn,
  HUMAnN, and StrainPhlAn on one DB version.
- `--mode taxonomy` — QC → taxonomy only, on the **LATEST** SGB DB (`vJan25`). It
  auto-adds `--bypass-functional-profiling --bypass-strain-profiling`, so the newer DB
  is safe (nothing downstream needs the HUMAnN-compatible version).

---

## 9. Monitor, resume, cancel

```bash
squeue -u $USER                                  # is it running? (orchestrator + tool jobs)
tail -f <output>/orchestrator_<jobid>.log        # high-level progress
tail -f <output>/anadama.log                     # per-task detail — real errors live here
ls      <output>/slurm_files/                    # each tool's script + .out/.err/.rc
```

**Resume:** just re-submit the exact same command. AnADAMA2 checks `<output>/.anadama/`,
skips completed tasks, and only redoes what failed or is missing.

**Cancel:** `scancel <orchestrator_jobid>` stops the coordinator; cancel any still-running
tool jobs the same way (find their ids with `squeue -u $USER`).

---

## 10. Options — what's possible

The full, authoritative list is `biobakery_workflows wmgx --help`. The ones you'll reach
for most:

**Choosing what to run**
- `--bypass-functional-profiling` — skip HUMAnN. Much faster; use when you only need
  taxonomy (who's there), not function.
- `--bypass-strain-profiling` — skip StrainPhlAn.
- `--bypass-quality-control` — skip KneadData (only if reads are already cleaned).

**Inputs**
- `--pair-identifier STR` — the forward-read marker (e.g. `_R1_001`). See section 4.
- `--input-extension EXT` — default `fastq.gz`.

**Scale / resources**
- `--jobs N` — how many grid jobs AnADAMA2 runs at once (parallelism across samples).
- `--threads N` — cores per tool task.

**Passthrough to the underlying tools** (advanced) — give raw option strings:
- `--taxonomic-profiling-options "..."`, `--functional-profiling-options "..."`,
  `--qc-options "..."`.

**Other workflows** (run instead of `wmgx`):
- **Visualization report:** `biobakery_workflows wmgx_vis --input <wmgx output> --output <report dir>`
  builds an HTML summary (QC, top taxa, diversity) from a finished wmgx run.
- `16s`, `isolate` — different data types; separate workflows.

---

## 11. Configuration reference

- **`config/site.sh`** — cluster-specific SLURM settings: `SLURM_PARTITION`,
  `SLURM_ACCOUNT`, `GRID_JOBS`, and how `--grid-options` (e.g. `--account=dfi`) is built.
  This is the file you edit when moving to a different cluster or account.
- **`config/env.sh`** — where the reference DBs are
  (`BIOBAKERY_WORKFLOWS_DATABASES`, MetaPhlAn index, KneadData host genome) and cache
  redirection: it pushes `$HOME`-hungry tool caches (conda pkgs, matplotlib, numba,
  tmp) onto scratch so they don't blow your small home quota.
- **`config/activate.sh`** — sources `env.sh`, then loads conda and activates the env in
  `envs/`. Source this whenever you want the tools on your PATH interactively.

The runners source all three for you; you only *edit* them.

---

## 12. Operating rules

1. **One persistent `--output` per study**, on the labshare. AnADAMA2's tracking DB,
   logs, and grid scripts live there — that DB is what enables resume and prevents two
   runs from colliding. Don't reuse one output dir for different studies.
2. **Scratch / grid-scratch → GPFS `/scratch/$USER/…`** — a *shared* filesystem every
   node can see. Never node-local `/tmp` (a compute node can't see another's `/tmp`).
   Scratch is auto-cleaned (~monthly), so it's for intermediates, not results.
3. **Never run the orchestrator on a login node.** Submit with `bin/submit_wmgx.sh` from
   the login node (it only calls `sbatch`); `run_wmgx.sh` refuses to start on a login
   node on purpose.
4. **Bulk data transfers go through `cri-datamover.cri.uchicago.edu`** (rsync/sftp), not
   a login node, and not from compute nodes (which are firewalled off the internet).
5. `--remove-intermediate-output` keeps disposable KneadData/HUMAnN intermediates out of
   your persistent `output/` — they stay on scratch.

---

## 13. Troubleshooting

| Symptom | Where to look / what it means | Fix |
|---------|-------------------------------|-----|
| Job shows `State=COMPLETED` but you have no results | The SLURM job state lies here; a task inside failed | Read `<output>/anadama.log` and `slurm_files/*.err` — those have the real error |
| `ERROR: Unable to find <tool>` (e.g. `trf`) | That tool isn't on PATH in the env, or a broken build shipped no binary | `conda install -c bioconda '<tool>=<stable version>'`; avoid release-candidate (`rcN`) versions |
| `java: undefined symbol: JLI_StringDup` | Two conflicting JDKs in the env clobbering each other | Collapse to a single `openjdk` (conda-forge); remove the deprecated `java-jdk` |
| Runner exits: "on login node … request an allocation" | You tried to run the orchestrator directly on a login node | Submit via `bin/submit_wmgx.sh`, or get an allocation with `srun --pty bash` first |
| Files treated as single-end when they're paired | `--pair-identifier` doesn't match your filenames | Pass the correct marker, e.g. `--pair-identifier _R1_001` |
| `conda` install/solve takes forever | Live channel resolution + GPFS is slow with many tiny files | Be patient, or add `--solver=libmamba --freeze-installed`; then **freeze a lockfile** into `envs/exports/` so you never re-solve |
| `Disk quota exceeded` during conda | conda cached packages under your small `$HOME` | Already handled by `CONDA_PKGS_DIRS` in `config/env.sh` (points at the labshare) |
| Box / external download "connection reset" on a node | CRI firewall blocks compute/login nodes from the internet | Move data via `cri-datamover`; don't try to reach external hosts from nodes |
| A tool job fails instantly (~1s, ~0 memory) | The task wrapper died before doing work — usually a missing dependency, not a resource problem | Check `slurm_files/*.err`; it's almost always a missing/broken tool in the env |

When in doubt, the single most useful file is **`<output>/anadama.log`** — it logs the
exact command each task ran and the exact error it hit.
