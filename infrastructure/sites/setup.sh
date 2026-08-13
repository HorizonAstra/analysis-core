#!/bin/bash

# TumorSPACE_AWS Setup Script
# Automatically builds containers based on environment detection
# Author: Vivek Behera

set -e

# ── Argument parsing ────────────────────────────────────────────────────────────
INSTALL_NATIVE=false
SCRATCH_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-native)
            INSTALL_NATIVE=true; shift ;;
        --scratch)
            SCRATCH_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: bash setup.sh --scratch <dir> [--install-native]"
            echo ""
            echo "  --scratch <dir>    Local scratch directory for R package compilation."
            echo "                     Must be on a filesystem that supports execute permissions"
            echo "                     (not GPFS, not noexec). Required for container builds."
            echo "                     Example: --scratch /scratch/shapiro/tmp"
            echo "  --install-native   Install BayesSpace R packages natively without"
            echo "                     an interactive prompt. Exits with code 1 if the"
            echo "                     install fails. Use when running non-interactively."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run 'bash setup.sh --help' for usage."
            exit 1
            ;;
    esac
done

# Auto-apply BUILD_SCRATCH_DIR from hpc_profile if --scratch not passed explicitly
if [ -z "$SCRATCH_DIR" ] && [ -n "${BUILD_SCRATCH_DIR:-}" ]; then
    SCRATCH_DIR="$BUILD_SCRATCH_DIR"
fi

# Load HPC cluster profile (exports module names; falls back to .example defaults)
_HPC_PROFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# Load Slurm config if present (exports SLURM_ACCOUNT, SLURM_PARTITION for srun/sbatch calls)
_SLURM_CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config/slurm_config.sh"
# shellcheck disable=SC1090
[[ -f "$_SLURM_CFG" ]] && source "$_SLURM_CFG"
unset _SLURM_CFG

# igraph (dep of phangorn and BayesSpace) transitively loads anaconda's libicuuc.so.73,
# which requires GLIBCXX_3.4.30. module load gcc/10.2.0 only provides up to 3.4.29.
# Prepend gcc-12.2.0/lib64 globally so ALL Rscript calls (detection + install) resolve it.
export LD_LIBRARY_PATH="/software/gcc-12.2.0-el8-x86_64/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

echo "================================================"
echo "TumorSPACE_AWS Setup Script"
echo "================================================"
echo ""

# Detect environment (container building only needs Singularity; SLURM is only needed
# at pipeline-execution time, not at setup time)
if command -v singularity &> /dev/null; then
    ENV_TYPE="SINGULARITY"
    echo "✓ Detected Singularity — can build containers"
else
    # Try to load it via the HPC profile module name, then recheck
    hpc_module_load MODULE_SINGULARITY 2>/dev/null || true
    if command -v singularity &> /dev/null; then
        ENV_TYPE="SINGULARITY"
        echo "✓ Singularity loaded via module — can build containers"
    else
        ENV_TYPE="UNKNOWN"
        echo "⚠ Singularity not found"
    fi
fi

if command -v sbatch &> /dev/null; then
    echo "✓ SLURM detected (pipeline execution will be available)"
else
    echo "ℹ SLURM not detected — container build will still proceed;"
    echo "  pipeline execution requires SLURM at job-submission time."
fi

echo ""
echo "Environment: $ENV_TYPE"
echo ""

# Function to build Singularity container
build_singularity() {
    echo "Building Singularity container (two-stage process)..."
    echo "This may take 15-25 minutes..."
    
    if ! command -v singularity &> /dev/null; then
        hpc_module_load MODULE_SINGULARITY
    fi
    if ! command -v singularity &> /dev/null; then
        echo "❌ Error: Singularity not found. Please load the singularity module:"
        echo "   module load ${MODULE_SINGULARITY:-singularity}"
        exit 1
    fi
    
    cd containers
    
    # Stage 1: Pull base Julia container from Docker Hub
    echo ""
    echo "Stage 1/2: Pulling base Julia 1.9 container from Docker Hub..."
    if [ ! -f julia_1.9.sif ]; then
        singularity pull julia_1.9.sif docker://julia:1.9
        if [ $? -ne 0 ]; then
            echo "❌ Failed to pull base Julia container"
            exit 1
        fi
        echo "✓ Base container downloaded: julia_1.9.sif"
    else
        echo "✓ Base container already exists: julia_1.9.sif"
    fi
    
    # Stage 2: Add gotree binary and workflows
    echo ""
    echo "Stage 2/2: Adding gotree binary and workflow scripts..."
    bash add_gotree_to_julia.sh
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✓ Production container built successfully: containers/julia_1.9_with_gotree.sif"
    else
        echo "❌ Container enhancement failed"
        exit 1
    fi
    
    cd ..
}

# Function to build R Singularity container
build_r_singularity() {
    echo ""
    echo "Building R container (Step 6 + Pipeline Report)..."
    echo "This may take 15-30 minutes..."

    if ! command -v singularity &> /dev/null; then
        hpc_module_load MODULE_SINGULARITY
    fi
    if ! command -v singularity &> /dev/null; then
        echo "❌ Error: Singularity not found. Please load the singularity module:"
        echo "   module load ${MODULE_SINGULARITY:-singularity}"
        exit 1
    fi

    cd containers
    bash build_r_container.sh --scratch "$SCRATCH_DIR"
    if [ $? -ne 0 ]; then
        echo "❌ R container build failed"
        exit 1
    fi
    echo "✓ R container built successfully: containers/tumorspace_r.sif"
    cd ..
}

# Function to build R 4.5 Singularity container (DE analysis — DESpace 2.0)
build_r45_singularity() {
    echo ""
    echo "Building R 4.5 container (DE analysis — Seurat + DESpace 2.0)..."
    echo "This may take 60-90 minutes..."

    if ! command -v singularity &> /dev/null; then
        hpc_module_load MODULE_SINGULARITY
    fi
    if ! command -v singularity &> /dev/null; then
        echo "❌ Error: Singularity not found. Please load the singularity module:"
        echo "   module load ${MODULE_SINGULARITY:-singularity}"
        exit 1
    fi

    cd containers
    bash build_r45_container.sh --scratch "$SCRATCH_DIR"
    if [ $? -ne 0 ]; then
        echo "❌ R 4.5 container build failed"
        exit 1
    fi
    echo "✓ R 4.5 container built successfully: containers/tumorspace_r45.sif"
    cd ..
}

# Function to detect available execution modes and write config/capabilities.sh
detect_and_write_capabilities() {
    echo ""
    echo "================================================"
    echo "Detecting Execution Mode Availability"
    echo "================================================"

    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CAPS_FILE="${REPO_ROOT}/config/capabilities.sh"

    # ── acquisition ─────────────────────────────────────────────────────────────
    echo ""
    echo "acquisition (python3 + numpy/pandas):"
    ACQ_NATIVE=false
    # Run python detection in a subshell so `module load python/anaconda` does NOT
    # pollute LD_LIBRARY_PATH in the parent.  Anaconda prepends its own lib/ dir,
    # which causes igraph.so (loaded during R's phangorn/BayesSpace detection) to
    # find anaconda's libicuuc.so.73, which requires GLIBCXX_3.4.30 — unavailable
    # from igraph's own baked-in RPATH (gcc-10.2.0).  The ( ) subshell inherits
    # stdout/stderr so output still reaches the terminal; its env changes die with it.
    (
        hpc_module_load MODULE_PYTHON 2>/dev/null || true
        if command -v python3 &>/dev/null; then
            if python3 -c "import numpy, pandas" &>/dev/null 2>&1; then
                echo "  [✓] native  — python3 found, numpy and pandas available"
                exit 0
            else
                echo "  [✗] native  — python3 found but numpy/pandas missing"
                echo "       Fix: pip install numpy pandas"
                echo "            or: module load python/anaconda-2022.05"
                exit 1
            fi
        else
            echo "  [✗] native  — python3 not found"
            echo "       Fix: module load python/anaconda-2022.05  or install Python 3.8+"
            exit 1
        fi
    ) && ACQ_NATIVE=true

    # ── tumorspace_core ─────────────────────────────────────────────────────────
    echo ""
    echo "tumorspace_core:"
    TS_CONTAINER=false
    TS_NATIVE=false
    JULIA_SIF="${REPO_ROOT}/containers/julia_1.9_with_gotree.sif"
    if [ -f "$JULIA_SIF" ]; then
        TS_CONTAINER=true
        echo "  [✓] container — julia_1.9_with_gotree.sif present"
    else
        echo "  [✗] container — julia_1.9_with_gotree.sif not found"
        echo "       Fix: bash containers/add_gotree_to_julia.sh"
    fi
    hpc_load_julia 2>/dev/null || true
    hpc_module_load MODULE_R 2>/dev/null || true
    # gotree ships in $REPO_ROOT/bin — add to PATH so command -v finds it
    export PATH="${REPO_ROOT}/bin:${PATH}"
    if command -v julia &>/dev/null && command -v gotree &>/dev/null && command -v Rscript &>/dev/null; then
        if LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
           Rscript -e "library(dplyr);library(data.table);library(ape);library(phangorn)" &>/dev/null 2>&1; then
            TS_NATIVE=true
            echo "  [✓] native  — julia, gotree, Rscript available; dplyr/data.table/ape/phangorn present"
        else
            echo "  [✗] native  — julia/gotree/Rscript found but R packages missing"
            # Fire when: (a) stdin is a tty (interactive), or (b) --install-native flag was passed
            if [ -t 0 ] || [ "$INSTALL_NATIVE" = "true" ]; then
                echo ""
                echo "  Install tumorspace_core R packages natively now?"
                echo "  Packages: dplyr, data.table, ape, phangorn (CRAN)"
                echo "  This may take 5-10 minutes."
                if [ -t 0 ] && [ "$INSTALL_NATIVE" != "true" ]; then
                    read -r -p "  [y/N] " _ans
                else
                    _ans="y"
                    echo "  (--install-native: proceeding automatically)"
                fi
                if [[ "$_ans" =~ ^[Yy]$ ]]; then
                    echo "  Installing..."
                    hpc_module_load MODULE_GCC 2>/dev/null || true
                    # Ensure user R library dir exists (may have been wiped during ABI repairs)
                    _rlib=~/R/x86_64-pc-linux-gnu-library/$(Rscript -e "cat(paste0(R.version\$major,'.',substr(R.version\$minor,1,1)))")
                    mkdir -p "$_rlib" && unset _rlib
                    Rscript -e '
                      pkgs <- c("dplyr","data.table","ape","phangorn")
                      missing <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]
                      if (length(missing)) {
                        cat("  Installing:", paste(missing, collapse=", "), "\n")
                        install.packages(missing, repos="https://cloud.r-project.org")
                      } else {
                        cat("  All tumorspace_core R packages already present\n")
                      }
                    '
                    if LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
                       Rscript -e "library(dplyr);library(data.table);library(ape);library(phangorn)" &>/dev/null 2>&1; then
                        TS_NATIVE=true
                        echo "  [✓] native  — tumorspace_core R packages successfully installed"
                    else
                        echo "  [✗] native  — install did not complete successfully"
                        if [ "$INSTALL_NATIVE" = "true" ]; then
                            echo "  ERROR: --install-native was requested but tumorspace_core install failed. Aborting."
                            exit 1
                        fi
                    fi
                fi
                unset _ans
            else
                echo "       Fix: bash setup.sh --install-native"
                echo "            or: Rscript -e 'install.packages(c(\"dplyr\",\"data.table\",\"ape\",\"phangorn\"))'"
            fi
        fi
    else
        _missing=""
        command -v julia    &>/dev/null || _missing="${_missing} julia"
        command -v gotree   &>/dev/null || _missing="${_missing} gotree"
        command -v Rscript  &>/dev/null || _missing="${_missing} Rscript"
        echo "  [✗] native  — missing:${_missing}"
        unset _missing
    fi

    # ── bayesspace ───────────────────────────────────────────────────────────────
    echo ""
    echo "bayesspace:"
    BS_CONTAINER=false
    BS_NATIVE=false
    # SINGULARITY_TMPDIR: singularity exec needs a writable local dir to extract the SIF.
    # On GPFS the default TMPDIR is noexec; use --scratch dir when available.
    _SING_TMP="${SCRATCH_DIR:+${SCRATCH_DIR}/singularity_tmp_caps}"
    [ -n "$_SING_TMP" ] && mkdir -p "$_SING_TMP"

    R_SIF="${REPO_ROOT}/containers/tumorspace_r.sif"
    if [ -f "$R_SIF" ]; then
        hpc_module_load MODULE_SINGULARITY 2>/dev/null || true
        if command -v singularity &>/dev/null; then
            if SINGULARITY_TMPDIR="${_SING_TMP:-/tmp}" singularity exec --no-home --cleanenv \
                --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                --env R_LIBS_USER="/usr/local/lib/R/site-library" \
                "$R_SIF" /bin/sh -c 'Rscript -e "library(BayesSpace);library(harmony)"' &>/dev/null 2>&1; then
                BS_CONTAINER=true
                echo "  [✓] container — tumorspace_r.sif present, BayesSpace verified"
            else
                echo "  [✗] container — tumorspace_r.sif present but BayesSpace not installed in it"
                echo "       Fix: bash containers/build_r_container.sh --force"
            fi
        else
            echo "  [?] container — SIF present but singularity not available to verify"
        fi
    else
        echo "  [✗] container — tumorspace_r.sif not found"
        echo "       Fix: bash containers/build_r_container.sh [--force]"
    fi
    if command -v Rscript &>/dev/null; then
        if LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
           Rscript -e "library(optparse);library(data.table);library(ggplot2);library(SingleCellExperiment);library(BayesSpace);library(harmony)" &>/dev/null 2>&1; then
            BS_NATIVE=true
            echo "  [✓] native  — R found, all BayesSpace dependencies present"
        else
            echo "  [✗] native  — R found but BayesSpace dependencies missing"
            # Fire when: (a) stdin is a tty (interactive), or (b) --install-native flag was passed
            if [ -t 0 ] || [ "$INSTALL_NATIVE" = "true" ]; then
                echo ""
                echo "  Install BayesSpace natively now?"
                echo "  Packages: optparse, data.table, ggplot2 (CRAN) + SingleCellExperiment, BayesSpace (Bioconductor)"
                echo "  This may take 10-20 minutes."
                # In interactive mode (tty, no flag): prompt the user.
                # In --install-native mode: auto-answer y regardless of tty.
                if [ -t 0 ] && [ "$INSTALL_NATIVE" != "true" ]; then
                    read -r -p "  [y/N] " _ans
                else
                    _ans="y"
                    echo "  (--install-native: proceeding automatically)"
                fi
                if [[ "$_ans" =~ ^[Yy]$ ]]; then
                    echo "  Installing..."
                    # Load GCC matching R's build environment to prevent ABI mismatch
                    hpc_module_load MODULE_GCC 2>/dev/null || true
                    # Ensure user R library dir exists (may have been wiped during ABI repairs)
                    _rlib=~/R/x86_64-pc-linux-gnu-library/$(Rscript -e "cat(paste0(R.version\$major,'.',substr(R.version\$minor,1,1)))")
                    mkdir -p "$_rlib" && unset _rlib

                    # BayesSpace requires 'arrow' which compiles Arrow C++ from source
                    # and needs ~16GB RAM peak — login nodes are OOM-killed mid-build.
                    # Detect login node by hostname; if srun is available submit the
                    # install as an interactive compute job (blocks until done).
                    _on_login=false
                    [[ "$(hostname)" =~ login ]] && _on_login=true

                    # Write a self-contained install script (heredoc expands MODULE_*
                    # variables from current scope so the compute node loads the same
                    # modules without needing the hpc_profile sourced again).
                    # Write to HOME (shared filesystem) not /tmp — /tmp is node-local
                    # and won't be visible on the compute node that srun dispatches to.
                    _bs_install_script="$(mktemp "${HOME}/.bs_install_XXXX.sh")"
                    cat > "$_bs_install_script" << BSEOF
#!/bin/bash
source /software/modules/init/bash 2>/dev/null || true
module load ${MODULE_R:-R/4.4.1} ${MODULE_GCC:-gcc/10.2.0} 2>/dev/null || true
# LD_LIBRARY_PATH is inherited from the login-node environment via srun.
# Re-export gcc-12.2.0/lib64 here too in case srun drops the inherited value.
export LD_LIBRARY_PATH="/software/gcc-12.2.0-el8-x86_64/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export LIBARROW_MINIMAL=true NOT_CRAN=true HOME="${HOME}"
# Remove stale LOCK dirs left by any previous failed install attempts.
# These cause "failed to lock directory" errors that block reinstallation.
_rlib="${HOME}/R/x86_64-pc-linux-gnu-library"
find "${_rlib}" -maxdepth 2 -name '00LOCK-*' -type d -exec rm -rf {} + 2>/dev/null || true
find "${_rlib}" -maxdepth 2 -name '00new'    -type d -exec rm -rf {} + 2>/dev/null || true
unset _rlib
Rscript -e '
  cran_pkgs <- c("optparse","data.table","ggplot2","BiocManager")
  missing_cran <- cran_pkgs[!sapply(cran_pkgs, requireNamespace, quietly=TRUE)]
  if (length(missing_cran)) {
    cat("  Installing CRAN:", paste(missing_cran, collapse=", "), "\n")
    install.packages(missing_cran, repos="https://cloud.r-project.org")
  } else {
    cat("  All CRAN packages already present\n")
  }
  bioc_pkgs <- c("SingleCellExperiment","BayesSpace")
  missing_bioc <- bioc_pkgs[!sapply(bioc_pkgs, requireNamespace, quietly=TRUE)]
  if (length(missing_bioc)) {
    cat("  Installing Bioc:", paste(missing_bioc, collapse=", "), "\n")
    BiocManager::install(missing_bioc, ask=FALSE, update=FALSE)
  } else {
    cat("  All Bioconductor packages already present\n")
  }
'
BSEOF
                    chmod +x "$_bs_install_script"

                    if [ "$_on_login" = "true" ] && command -v srun &>/dev/null; then
                        echo "  NOTE: Arrow C++ build needs ~16GB RAM — not available on login nodes."
                        echo "  Submitting install to a compute node via srun (30-60 min)..."
                        srun --mem=16G --cpus-per-task=4 --time=90 \
                            ${SLURM_ACCOUNT:+--account=${SLURM_ACCOUNT}} \
                            ${SLURM_PARTITION:+--partition=${SLURM_PARTITION}} \
                            bash "$_bs_install_script"
                        _bs_exit=$?
                    elif [ "$_on_login" = "true" ]; then
                        echo "  ERROR: Arrow build needs ~16GB RAM unavailable on login nodes."
                        echo "         Run on a compute node: srun --mem=16G bash setup.sh --install-native"
                        rm -f "$_bs_install_script"
                        if [ "$INSTALL_NATIVE" = "true" ]; then exit 1; fi
                        _bs_exit=1
                    else
                        bash "$_bs_install_script"
                        _bs_exit=$?
                    fi
                    rm -f "$_bs_install_script"
                    unset _on_login _bs_install_script

                    if [ "${_bs_exit:-0}" -eq 0 ] && \
                       LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
                       Rscript -e "library(BayesSpace)" &>/dev/null 2>&1; then
                        BS_NATIVE=true
                        echo "  [✓] native  — BayesSpace successfully installed"
                    else
                        echo "  [✗] native  — install did not complete successfully"
                        if [ "$INSTALL_NATIVE" = "true" ]; then
                            echo "  ERROR: --install-native was requested but BayesSpace install failed. Aborting."
                            exit 1
                        fi
                    fi
                    unset _bs_exit
                fi
                unset _ans
            fi
        fi
    fi

    # ── de_analysis ──────────────────────────────────────────────────────────────
    echo ""
    echo "de_analysis:"
    DA_CONTAINER=false
    DA_NATIVE=false
    R45_SIF="${REPO_ROOT}/containers/tumorspace_r45.sif"
    if [ -f "$R45_SIF" ]; then
        hpc_module_load MODULE_SINGULARITY 2>/dev/null || true
        if command -v singularity &>/dev/null; then
            if SINGULARITY_TMPDIR="${_SING_TMP:-/tmp}" singularity exec --no-home --cleanenv \
                --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                --env R_LIBS_USER="/usr/local/lib/R/site-library" \
                "$R45_SIF" /bin/sh -c 'Rscript -e "library(Seurat);library(DESpace)"' &>/dev/null 2>&1; then
                DA_CONTAINER=true
                echo "  [✓] container — tumorspace_r45.sif present, Seurat and DESpace verified"
            else
                echo "  [✗] container — tumorspace_r45.sif present but Seurat/DESpace not installed in it"
                echo "       Fix: bash containers/build_r45_container.sh --force"
            fi
        else
            echo "  [?] container — SIF present but singularity not available to verify"
        fi
    else
        echo "  [✗] container — tumorspace_r45.sif not found"
        echo "       Fix: bash containers/build_r45_container.sh [--force]"
    fi
    if command -v Rscript &>/dev/null; then
        if LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
           Rscript -e "library(optparse);library(Seurat);library(SingleCellExperiment);library(DESpace)" &>/dev/null 2>&1; then
            DA_NATIVE=true
            echo "  [✓] native  — R found, all DE analysis dependencies present"
        else
            echo "  [✗] native  — R found but Seurat/DESpace dependencies missing"
            echo "       Fix: bash containers/build_r45_container.sh --force  (or install packages natively)"
        fi
    fi

    # ── sgp_analysis derives from de_analysis (same tumorspace_r45.sif) ────────
    SGP_CONTAINER=${DA_CONTAINER}
    SGP_NATIVE=${DA_NATIVE}

    # ── spacet ──────────────────────────────────────────────────────────────────────
    echo ""
    echo "spacet:"
    ST_CONTAINER=false
    ST_NATIVE=false
    if [ -f "$R_SIF" ]; then
        hpc_module_load MODULE_SINGULARITY 2>/dev/null || true
        if command -v singularity &>/dev/null; then
            if singularity exec --no-home --cleanenv \
                --env R_LIBS_USER="/usr/local/lib/R/site-library" \
                "$R_SIF" Rscript -e "library(SpaCET)" &>/dev/null 2>&1; then
                ST_CONTAINER=true
                echo "  [✓] container — tumorspace_r.sif present, SpaCET verified"
            else
                echo "  [✗] container — tumorspace_r.sif present but SpaCET not installed in it"
                echo "       Fix: bash containers/build_r_container.sh --force"
            fi
        else
            echo "  [?] container — SIF present but singularity not available to verify"
        fi
    else
        echo "  [✗] container — tumorspace_r.sif not found"
        echo "       Fix: bash containers/build_r_container.sh [--force]"
    fi
    if command -v Rscript &>/dev/null; then
        if LD_PRELOAD="/software/gcc-12.2.0-el8-x86_64/lib64/libstdc++.so.6${LD_PRELOAD:+:${LD_PRELOAD}}" \
           Rscript -e "library(optparse);library(data.table);library(dplyr);library(SpaCET)" &>/dev/null 2>&1; then
            ST_NATIVE=true
            echo "  [✓] native  — R found, all SpaCET dependencies present"
        else
            echo "  [✗] native  — R found but SpaCET dependencies missing"
        fi
    fi
    # ── Write config/capabilities.sh ────────────────────────────────────────────
    cat > "$CAPS_FILE" << EOF
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Re-generate: bash setup.sh
# Do not edit manually.

# acquisition (python3 + numpy/pandas)
ACQUISITION_NATIVE_AVAILABLE=${ACQ_NATIVE}

# tumorspace_core
TUMORSPACE_CONTAINER_AVAILABLE=${TS_CONTAINER}
TUMORSPACE_NATIVE_AVAILABLE=${TS_NATIVE}

# bayesspace
BAYESSPACE_CONTAINER_AVAILABLE=${BS_CONTAINER}
BAYESSPACE_NATIVE_AVAILABLE=${BS_NATIVE}

# de_analysis
DE_ANALYSIS_CONTAINER_AVAILABLE=${DA_CONTAINER}
DE_ANALYSIS_NATIVE_AVAILABLE=${DA_NATIVE}

# sgp_analysis (cohort K-sweep; same tumorspace_r45.sif as de_analysis)
SGP_ANALYSIS_CONTAINER_AVAILABLE=${SGP_CONTAINER}
SGP_ANALYSIS_NATIVE_AVAILABLE=${SGP_NATIVE}

# spacet
SPACET_CONTAINER_AVAILABLE=${ST_CONTAINER}
SPACET_NATIVE_AVAILABLE=${ST_NATIVE}

CAPABILITIES_GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    echo ""
    echo "✓ config/capabilities.sh written"

    # ── Summary report ───────────────────────────────────────────────────────────
    echo ""
    echo "Capability summary:"
    printf "  %-28s %s\n" "acquisition native:"      "$([ "$ACQ_NATIVE"    = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "tumorspace container:"    "$([ "$TS_CONTAINER"  = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "tumorspace native:"       "$([ "$TS_NATIVE"     = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "bayesspace container:"    "$([ "$BS_CONTAINER"  = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "bayesspace native:"       "$([ "$BS_NATIVE"     = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "de_analysis container:"   "$([ "$DA_CONTAINER"  = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "de_analysis native:"      "$([ "$DA_NATIVE"     = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "sgp_analysis container:"  "$([ "$SGP_CONTAINER" = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "sgp_analysis native:"     "$([ "$SGP_NATIVE"    = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "spacet container:"         "$([ "$ST_CONTAINER"  = true ] && echo '[✓]' || echo '[✗]')"
    printf "  %-28s %s\n" "spacet native:"            "$([ "$ST_NATIVE"     = true ] && echo '[✓]' || echo '[✗]')"
}

# ── Scratch directory validation ────────────────────────────────────────────────
# Required for container builds (Phase 1 compiles R packages from source).
# Not needed for --install-native (native mode uses the system R directly).
if [ "$INSTALL_NATIVE" != "true" ] && [ "$ENV_TYPE" = "SINGULARITY" ]; then
    if [ -z "$SCRATCH_DIR" ]; then
        echo "ERROR: --scratch <dir> is required for container builds."
        echo ""
        echo "  Provide a local scratch directory that supports execute permissions."
        echo "  On GPFS clusters, /tmp and /dev/shm are often noexec; use a personal"
        echo "  scratch path instead:"
        echo ""
        echo "    bash setup.sh --scratch /scratch/\$USER/tmp"
        exit 1
    fi
fi

# Build based on environment (skipped when --install-native is set)
if [ "$INSTALL_NATIVE" = "true" ]; then
    echo ""
    echo "(--install-native: skipping container builds — running capability detection only)"
else
case $ENV_TYPE in
    SINGULARITY)
        echo "Building containers with Singularity..."
        build_singularity
        build_r_singularity
        build_r45_singularity
        ;;
    UNKNOWN)
        echo ""
        echo "ERROR: Singularity not found. Container building requires Singularity."
        echo "Fix: Load the singularity module before running setup.sh:"
        echo "     module load ${MODULE_SINGULARITY:-singularity} && bash setup.sh"
        exit 1
        ;;
esac
fi  # end of --install-native skip

# Post-build verification for Julia container (skipped when --install-native)
if [ "$INSTALL_NATIVE" != "true" ] && [ "$ENV_TYPE" = "SINGULARITY" ]; then
    echo ""
    echo "Running post-build verification for Julia container..."
    JULIA_SIF="containers/julia_1.9_with_gotree.sif"
    if [ ! -f "$JULIA_SIF" ]; then
        echo "ERROR: Julia container not found: $JULIA_SIF"
        exit 1
    fi
    _sing_tmp_julia="${SCRATCH_DIR:+${SCRATCH_DIR}/singularity_tmp_julia}"
    [ -n "$_sing_tmp_julia" ] && mkdir -p "$_sing_tmp_julia"
    if ! SINGULARITY_TMPDIR="${_sing_tmp_julia:-/tmp}" \
         singularity exec --no-home --cleanenv "$JULIA_SIF" /bin/sh -c \
         'export LD_LIBRARY_PATH=/lib64:$LD_LIBRARY_PATH && gotree 2>&1 | grep -q "Usage:"'; then
        echo "ERROR: gotree not functional in Julia container"
        echo "Fix: Rebuild with cd containers && bash add_gotree_to_julia.sh"
        exit 1
    fi
    echo "  ✓ gotree verified in Julia container"
    if ! SINGULARITY_TMPDIR="${_sing_tmp_julia:-/tmp}" \
         singularity exec "$JULIA_SIF" /bin/sh -c \
         'test -f /opt/workflows/julia/phylo_tree_build.jl'; then
        echo "ERROR: Julia workflow scripts not found in container"
        echo "Fix: Rebuild with cd containers && bash add_gotree_to_julia.sh"
        exit 1
    fi
    unset _sing_tmp_julia
    echo "  ✓ Julia workflow scripts verified"
    if [ ! -f "containers/tumorspace_r.sif" ]; then
        echo "ERROR: R container not found: containers/tumorspace_r.sif"
        echo "Fix: Run cd containers && bash build_r_container.sh"
        exit 1
    fi
    echo "  ✓ R container verified (tumorspace_r.sif)"
    if [ ! -f "containers/tumorspace_r45.sif" ]; then
        echo "ERROR: R 4.5 container not found: containers/tumorspace_r45.sif"
        echo "Fix: Run cd containers && bash build_r45_container.sh --scratch \$SCRATCH_DIR"
        exit 1
    fi
    echo "  ✓ R 4.5 container verified (tumorspace_r45.sif)"
    echo "✓ All post-build verifications passed"
fi

# Detect and record available execution modes
detect_and_write_capabilities

echo ""
echo "================================================"
echo "Setup Complete!"
echo "================================================"
echo ""
echo "Next steps:"
echo "1. Review documentation: docs/GETTING_STARTED.md"
echo "2. Run the benchmark end-to-end test:  bash run_benchmark.sh --account <ACCOUNT> --partition <PARTITION>"
echo "   (Acquires GSE213688_GSM6592057 from GEO, harmonizes, then runs pipeline in --test mode)"
echo "   Fast path (skip download): bash run_benchmark.sh --skip-acquisition --account <ACCOUNT> --partition <PARTITION>"
echo "3. Run the BayesSpace integration test: bash tests/bayesspace/test_bayesspace.sh"
echo "4. Run the SpaCET integration test:    bash tests/spacet/test_spacet.sh"
echo "5. Configure your analysis: config/"
echo ""
