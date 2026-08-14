#!/bin/bash
set -e

# Build R container for Step 6 (SG Identification), Pipeline Report, and BayesSpace
#
# Uses the fakeroot-free sandbox pattern (same as add_gotree_to_julia.sh):
#   pull → sandbox → host-side mutations → pack → SIF
# This works on clusters where --fakeroot is not configured (e.g. midway3).
#
# Base image: r-base:4.4.1 (official CRAN Debian bookworm image)
# r-base:4.4.1 ships r-base-dev with all dev headers needed for source compilation:
# libcurl4-openssl-dev, libssl-dev, libxml2-dev, zlib1g-dev, build-essential, etc.
# Headers are present at pull time — no apt-get step needed (which would silently fail
# without --fakeroot, since apt-get can't write to root-owned paths in a sandbox).
# See containers/tumorspace_r_base.def for the reference spec (not the active build driver).
#
# Two-phase build:
#   Phase 1 (base, ~10 min): pull r-base:4.4.1 sandbox, install R packages
#                             via `singularity exec --writable`, pack to tumorspace_r_base.sif
#                             Skipped if tumorspace_r_base.sif exists; use --force to rebuild
#   Phase 2 (scripts, ~30 sec): unpack base SIF to sandbox, copy R scripts in from host,
#                                pack to tumorspace_r.sif — always runs
#
# Usage:
#   bash build_r_container.sh                    # run entire build on login node (foreground)
#   bash build_r_container.sh --nohup            # run on login node in background (nohup)
#   bash build_r_container.sh --sbatch           # alias for --nohup (legacy name retained)
#   bash build_r_container.sh --force            # always rebuild the base layer too
#   bash build_r_container.sh --nohup --force    # background + forced base rebuild
#
# Phase 1 MUST run on a login node: pull from Docker Hub, apt-get, and R package
# downloads all require internet. Compute nodes block packagemanager.posit.co;
# cloud.r-project.org and bioconductor.org are only reliably reachable from login nodes.
# --nohup backgrounds the build to survive SSH disconnects (~60-90 min total).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load HPC cluster profile (exports module names; falls back to .example defaults)
_HPC_PROFILE="${REPO_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# Load Singularity module — load any prerequisites first (e.g. go/1.24.6 on Randi
# where singularity/4.3.6 requires go/1.24.6 to be loaded first), then the module
# itself.  MODULE_SINGULARITY_PREREQS is exported by hpc_profile.sh.
if [[ -n "${MODULE_SINGULARITY_PREREQS:-}" ]]; then
    for _prereq in ${MODULE_SINGULARITY_PREREQS}; do
        if command -v module &>/dev/null; then
            module load "${_prereq}" 2>/dev/null || \
                echo "[build] WARNING: 'module load ${_prereq}' failed (continuing)" >&2
        fi
    done
    unset _prereq
fi
hpc_module_load MODULE_SINGULARITY

if ! command -v singularity &>/dev/null; then
    echo "ERROR: singularity not found after module load."
    echo "Fix: Ensure MODULE_SINGULARITY is set correctly in config/hpc_profile.sh"
    exit 1
fi

FORCE_BASE=false
RUN_NOHUP=false
BUILD_TMPDIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)          FORCE_BASE=true; shift ;;
        --nohup)          RUN_NOHUP=true;  shift ;;
        --sbatch)         RUN_NOHUP=true;  shift ;;  # legacy alias
        --scratch)        BUILD_TMPDIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: bash build_r_container.sh --scratch <dir> [--force] [--nohup]"
            echo ""
            echo "  --scratch <dir>  Local scratch directory for R package compilation."
            echo "                   Must be on a filesystem that supports execute permissions"
            echo "                   (not GPFS, not noexec). Required for Phase 1 builds."
            echo "                   Example: --scratch /scratch/shapiro/tmp"
            echo "  --force          Rebuild base SIF even if it already exists."
            echo "  --nohup          Run Phase 1 in the background via nohup."
            exit 0 ;;
        *) echo "Unknown option: $1"; echo "Run with --help for usage."; exit 1 ;;
    esac
done

# Auto-apply BUILD_SCRATCH_DIR from hpc_profile if --scratch not passed explicitly
if [ -z "$BUILD_TMPDIR" ] && [ -n "${BUILD_SCRATCH_DIR:-}" ]; then
    BUILD_TMPDIR="$BUILD_SCRATCH_DIR"
fi

# ── nohup self-relaunch ───────────────────────────────────────────────────────
# Phase 1 requires internet (docker pull, apt-get, R downloads) so it MUST run
# on a login node — compute nodes block packagemanager.posit.co and apt repos.
# --nohup relaunches this script in the background via nohup so it survives SSH
# disconnects (~60-90 min total). Logs go to containers/build_container_<PID>.log.
if [ "$RUN_NOHUP" = true ]; then
    # Reconstruct forward args from parsed variables so nothing is silently dropped.
    _FORWARD_ARGS=()
    [ "$FORCE_BASE" = true ] && _FORWARD_ARGS+=("--force")
    [ -n "$BUILD_TMPDIR" ]   && _FORWARD_ARGS+=("--scratch" "$BUILD_TMPDIR")
    _LOG="${SCRIPT_DIR}/build_container_nohup_$$.log"
    nohup bash "${BASH_SOURCE[0]}" "${_FORWARD_ARGS[@]}" > "$_LOG" 2>&1 &
    _BG_PID=$!
    echo "Container build launched in background (PID ${_BG_PID})"
    echo "Log: ${_LOG}"
    echo "Monitor: tail -f ${_LOG}"
    echo "Check done: kill -0 ${_BG_PID} 2>/dev/null && echo running || echo finished"
    exit 0
fi

# ── Scratch directory validation ─────────────────────────────────────────────
# Only required when Phase 1 will run (base SIF missing or --force).
# Phase 2 (script layer only) does not compile anything and does not need it.
if [ "$FORCE_BASE" = true ] || [ ! -f "$SCRIPT_DIR/tumorspace_r_base.sif" ]; then
    if [ -z "$BUILD_TMPDIR" ]; then
        echo "ERROR: --scratch <dir> is required when building the base layer."
        echo ""
        echo "  Provide a local scratch directory that supports execute permissions."
        echo "  On GPFS clusters, /tmp and /dev/shm are often noexec; use a personal"
        echo "  scratch path instead:"
        echo ""
        echo "    bash build_r_container.sh --scratch /scratch/\$USER/tmp --force"
        exit 1
    fi
    mkdir -p "$BUILD_TMPDIR"
fi

export SINGULARITY_CACHEDIR="${BUILD_TMPDIR:-$SCRIPT_DIR}/.singularity_cache"

BASE_SIF="$SCRIPT_DIR/tumorspace_r_base.sif"
BASE_SANDBOX="${BUILD_TMPDIR:-$SCRIPT_DIR}/tumorspace_r_base_sandbox"
SCRIPTS_DEF="$SCRIPT_DIR/tumorspace_r_scripts.def"
OUTPUT_SIF="$SCRIPT_DIR/tumorspace_r.sif"
OUTPUT_SANDBOX="${BUILD_TMPDIR:-$SCRIPT_DIR}/tumorspace_r_scripts_sandbox"
R_WORKFLOWS_BASE="$REPO_ROOT/workflows"
R_WORKFLOWS_DST="/opt/workflows/R"

# Redirect Singularity's tmp/cache away from home (quota too small for ~4-6 GB
# temp files during SIF packing).  On GPFS clusters (e.g. Randi) containers/ is
# on a noexec filesystem, so use BUILD_TMPDIR (scratch) when it is set.  On other
# clusters containers/ is exec-safe, so fall back to a subdir there.
export SINGULARITY_TMPDIR="${BUILD_TMPDIR:+${BUILD_TMPDIR}/singularity-tmpdir}"
export SINGULARITY_TMPDIR="${SINGULARITY_TMPDIR:-${SCRIPT_DIR}/singularity-tmpdir}"
mkdir -p "$SINGULARITY_TMPDIR"

# R scripts to embed — paths relative to workflows/ root, matching new feature structure.
# Container destination is always /opt/workflows/R/<basename> regardless of source feature dir.
R_SCRIPTS=(
    preprocessing/R/preprocess_harmonize.R
    preprocessing/R/preprocess_umi_qc.R
    preprocessing/R/preprocess_umi_qc_summary.R
    tumorspace_core/R/compute_ripley_k.R
    tumorspace_core/R/sg_identify_pairs.R
    tumorspace_core/R/diagnose_tree_pruning.R
    tumorspace_core/R/diagnose_pruning_hyperparameters.R
    pipeline_report/R/generate_qc_single_run.R
    pipeline_report/R/generate_qc_plots.R
    bayesspace/R/run_bayesspace.R
    DE_analysis/R/run_DE_analysis.R
    spacet/R/run_spacet.R
    spacet/R/prepare_ct_matrix.R
)

echo "========================================"
echo "Building TumorSPACE R Container"
echo "========================================"
echo "Base SIF:   $BASE_SIF"
echo "Output SIF: $OUTPUT_SIF"
echo ""

# ── Phase 1: Base SIF (pull + install packages) ────────────────────────────────
if [ "$FORCE_BASE" = true ] || [ ! -f "$BASE_SIF" ]; then
    if [ "$FORCE_BASE" = true ]; then
        echo "Phase 1/2: Rebuilding base SIF (--force, ~10 min)..."
        rm -f "$BASE_SIF"
        rm -rf "$BASE_SANDBOX"
    else
        echo "Phase 1/2: Building base SIF (packages, ~10 min)..."
    fi

    # Step 1a: Pull r-base:4.4.1 directly into a writable sandbox
    # Skip the docker pull if the sandbox already exists (e.g. a previous run
    # built the sandbox but failed during R package install). Reuse it to save
    # ~5 min on the re-pull. Use --force to delete and start completely fresh.
    # r-base:4.4.1 (official CRAN Debian bookworm image) ships r-base-dev, which
    # includes all dev headers needed for source compilation: libcurl4-openssl-dev,
    # libssl-dev, libxml2-dev, zlib1g-dev, etc. Headers are present at pull time —
    # no apt-get write step needed (which would silently fail without fakeroot).
    # No separate pull→SIF→unpack step needed; build --sandbox accepts docker:// directly.
    if [ -d "$BASE_SANDBOX" ]; then
        echo "  Reusing existing sandbox (delete with --force to re-pull): $BASE_SANDBOX"
    else
        echo "  Pulling r-base:4.4.1 from Docker Hub and building sandbox..."
        singularity build --sandbox "$BASE_SANDBOX" docker://r-base:4.4.1
        echo "  ✓ Sandbox created"
    fi

    # Step 1b: Create HPC mount points directly on sandbox dir (host-side, no root needed)
    echo "  Creating HPC mount points..."
    mkdir -p "$BASE_SANDBOX/project" "$BASE_SANDBOX/scratch" "$BASE_SANDBOX/software"
    mkdir -p "$BASE_SANDBOX/opt/workflows/R"

    # Step 1c: Inject missing dev headers into sandbox via host-side .deb extraction.
    # r-base:4.4.1 ships headers R itself needs (bzlib.h, lzma.h, pcre2.h, etc.) but NOT
    # libcurl4-openssl-dev, libssl-dev, or libxml2-dev (optional deps not needed by R core).
    # Without --fakeroot, apt-get cannot write to root-owned sandbox paths, so we instead:
    #   1. Query packages.debian.org to get the current bookworm .deb URL (version-agnostic)
    #   2. wget the .deb (no root, just HTTP)
    #   3. Extract with 'ar x' + 'tar' into the sandbox host-side (fully non-root)
    # This is equivalent to apt-get install but works without any elevated privileges.
    echo "  Injecting dev headers into sandbox via .deb extraction..."
    _DEB_TMP=$(mktemp -d)
    # Resolve current bookworm .deb URL from the official Debian Packages.gz index.
    # Avoids HTML scraping against packages.debian.org (fragile, rate-limited).
    # Downloads the Packages.gz index once and caches it; all lookups use the local copy.
    # Retries index fetch up to 3 times for transient network issues.
    _PKG_INDEX="${_DEB_TMP}/Packages"
    _PKG_INDEX_ALL="${_DEB_TMP}/Packages-all"
    if [ ! -f "$_PKG_INDEX" ]; then
        echo "    Fetching Debian bookworm package indexes (amd64 + all)..."
        _fetched=0
        for _try in 1 2 3; do
            wget -q -O "${_PKG_INDEX}.gz" \
                "https://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.gz" 2>/dev/null \
                && gunzip -f "${_PKG_INDEX}.gz" \
                && _fetched=1 && break
            echo "    [retry ${_try}/3] Packages.gz fetch failed, retrying in 10s..." >&2
            sleep 10
        done
        if [ "$_fetched" -eq 0 ]; then
            echo "ERROR: could not download Debian Packages.gz index after 3 attempts"; exit 1
        fi
        _fetched=0
        for _try in 1 2 3; do
            wget -q -O "${_PKG_INDEX_ALL}.gz" \
                "https://deb.debian.org/debian/dists/bookworm/main/binary-all/Packages.gz" 2>/dev/null \
                && gunzip -f "${_PKG_INDEX_ALL}.gz" \
                && _fetched=1 && break
            echo "    [retry ${_try}/3] Packages-all.gz fetch failed, retrying in 10s..." >&2
            sleep 10
        done
        if [ "$_fetched" -eq 0 ]; then
            echo "ERROR: could not download Debian Packages-all.gz index after 3 attempts"; exit 1
        fi
        echo "    ✓ Package indexes ready"
    fi
    _get_deb_url() {
        # Search amd64 index first, then arch-independent (all) index.
        # Some packages (e.g. libmagick++-6-headers) are arch:all and only appear in binary-all.
        local _rel
        _rel=$(awk -v pkg="$1" '
            /^Package: / { in_block = ($2 == pkg) }
            in_block && /^Filename: / { print $2; exit }
        ' "$_PKG_INDEX" "$_PKG_INDEX_ALL")
        [ -n "$_rel" ] && echo "https://deb.debian.org/debian/${_rel}"
    }
    # Inject: dev packages (headers + curl-config + link-time .so symlinks)
    #         plus libxml2 runtime — r-base ships only the dangling libxml2.so symlink
    #         (not libxml2.so.2.9.14), so igraph gets 'cannot find -lxml2' without it.
    # libcurl4 and libssl3 runtimes are already in r-base; only libxml2 runtime is missing.
    # libcairo2-dev + libpixman-1-dev: needed for libcairo.so symlink repair (runtime already in r-base).
    #   The Cairo *R package* is NOT installed via our stage pkgs, but install.packages follows
    #   the ggrastr (Imports of scater) → Cairo Imports chain. Cairo needs X11 headers.
    # libx11-dev: provides X11/Xlib.h (needed by Cairo R package; cairo-xlib.h requires it)
    # x11proto-dev: provides X11/X.h (required by Xlib.h; separate deb on bookworm)
    # libfontconfig-dev + libfreetype-dev: needed by systemfonts.
    # libpng-dev: needed by R png package; provides libpng16.so linker symlink.
    # libharfbuzz-dev + libfribidi-dev: needed by textshaping (ragg → scater chain).
    #   CPPFLAGS adds -I/usr/include/harfbuzz and -I/usr/include/fribidi (headers in subdirs).
    # libtiff-dev + libjpeg-dev + libwebp-dev: needed by ragg.
    #   ragg configure checks for libtiff-4, libjpeg, libwebp, libwebpmux (all from these debs).
    #   libwebpmux-dev/libwebpdemux-dev symlinks require runtime libs not present in r-base image:
    #   libwebpmux3 (libwebpmux.so.3) and libwebpdemux2 (libwebpdemux.so.2) added to _RT_PKGS.
    # libicu-dev: ICU headers needed by stringi (dep of stringr/Seurat) so it can link against
    #   the system libicu72 already in r-base instead of compiling its own ICU from source.
    # libzstd-dev: zstd headers needed by arrow and data.table (zstd compression support).
    # liblz4-dev: lz4 headers needed by arrow and data.table (lz4 compression support).
    # cmake + cmake-data: igraph R package 2.x bundles igraph C library and builds it with CMake.
    #   cmake provides /usr/bin/cmake; cmake-data provides /usr/share/cmake-*/Modules/ (cmake
    #   module files required at cmake runtime — cmake fails to start without them).
    # libnlopt-dev: NLopt headers needed by nloptr R package (dep of lme4 → pbkrtest → car →
    #   rstatix → ggpubr → DESpace). r-base does not ship libnlopt; runtime lib also needed.
    # libmagickcore-6.q16-dev: ImageMagick core dev (.pc file, devlink .so).
    # libmagickwand-6.q16-dev: provides MagickWand-6.Q16.pc queried by magick R package configure.
    # libmagick++-6.q16-dev: C++ dev (.pc, .so devlink, .a). Since the Dec 2025 bookworm security
    #   update, headers were split: libmagickcore-6-arch-config (amd64, generated config header
    #   magick-baseconfig.h), libmagick{core,wand,++}-6-headers (arch:all, from binary-all).
    #   Runtime libs (core, wand, c++) added to _RT_PKGS — none are in r-base:4.4.1.
    _DEV_PKGS=(libcurl4-openssl-dev libssl-dev libxml2-dev libcairo2-dev libpixman-1-dev libx11-dev x11proto-dev libfontconfig-dev libfreetype-dev libpng-dev libharfbuzz-dev libfribidi-dev libtiff-dev libjpeg-dev libwebp-dev libicu-dev libzstd-dev liblz4-dev cmake cmake-data libnlopt-dev libuv1-dev libmagickcore-6.q16-dev libmagickwand-6.q16-dev libmagick++-6.q16-dev libmagickcore-6-arch-config libmagickcore-6-headers libmagickwand-6-headers libmagick++-6-headers)
    # cmake runtime deps: librhash0, libjsoncpp25, libuv1 are not in r-base:4.4.1.
    # libnlopt0: NLopt shared library required at link time and runtime by nloptr/lme4.
    # ImageMagick runtime: libmagickcore-6.q16-6, libmagickwand-6.q16-6 use SONAME version 6;
    #   the C++ library SONAME was bumped to 8 in bookworm → package is libmagick++-6.q16-8.
    # liblcms2-2: Little CMS; liblqr-1-0: LiquidRescale; libfftw3-double3: FFT;
    # libltdl7: libtool dynamic loader — all linked by libMagickCore at runtime, not in r-base.
    # libfontconfig1, libfreetype6, libxext6, libx11-6, libbz2-1.0 are also libMagickCore deps but
    # are already in r-base:4.4.1; injecting them breaks the merged-usr /lib→/usr/lib symlink.
    _RT_PKGS=(libxml2 libwebpmux3 libwebpdemux2 librhash0 libjsoncpp25 libuv1 libnlopt0 libmagickcore-6.q16-6 libmagickwand-6.q16-6 libmagick++-6.q16-8 liblcms2-2 liblqr-1-0 libfftw3-double3 libltdl7)
    _PKGS=("${_DEV_PKGS[@]}" "${_RT_PKGS[@]}")
    for _pkg in "${_PKGS[@]}"; do
        _deb_url=$(_get_deb_url "$_pkg") || true   # || true: _get_deb_url returns 1 when not found; set -e would silently exit without it
        if [ -z "$_deb_url" ]; then
            echo "ERROR: could not resolve .deb URL for $_pkg from Packages index"
            exit 1
        fi
        _deb_file="${_DEB_TMP}/${_pkg}.deb"
        echo "    Downloading $_pkg ($(basename "$_deb_url"))..."
        wget -q -O "$_deb_file" "$_deb_url" || { echo "ERROR: wget failed for $_deb_url"; exit 1; }
        # Extract .deb: ar extracts data.tar.* then tar copies into sandbox
        ( cd "$_DEB_TMP" && ar x "${_pkg}.deb" )
        _data_tar=$(ls "${_DEB_TMP}"/data.tar.* 2>/dev/null | head -1)
        if [ -z "$_data_tar" ]; then
            echo "ERROR: no data.tar.* found in ${_pkg}.deb"; exit 1
        fi
        tar -xf "$_data_tar" -C "$BASE_SANDBOX" "./usr/include" "./usr/lib" "./usr/bin" "./usr/share" 2>/dev/null || true
        rm -f "${_DEB_TMP}"/data.tar.* "${_DEB_TMP}"/control.tar.* "${_DEB_TMP}"/debian-binary "${_deb_file}"
        echo "    ✓ ${_pkg} injected"
    done
    rm -rf "$_DEB_TMP"
    unset _DEB_TMP _PKG_INDEX _PKG_INDEX_ALL _fetched _try _DEV_PKGS _RT_PKGS _PKGS _pkg _deb_url _deb_file _data_tar
    unset -f _get_deb_url
    # Verify the critical header landed (Debian bookworm uses multiarch path x86_64-linux-gnu)
    if ! find "${BASE_SANDBOX}/usr/include" -name "curl.h" -path "*/curl/curl.h" 2>/dev/null | grep -q .; then
        echo "ERROR: curl/curl.h not found in sandbox after .deb injection"
        exit 1
    fi
    # Remove only the specific non-PIC static archives we injected — NOT all .a files.
    # Bulk deletion breaks GCC link stubs (libc_nonshared.a etc.) and corrupts the sandbox.
    # These injected archives lack -fPIC and cause 'relocation R_X86_64_PC32' linker errors
    # when packages like igraph try to link them into .so shared objects.
    # cairo/fontconfig/freetype/png .a archives added alongside curl/ssl/xml2 for same reason.
    for _a in libcurl.a libssl.a libcrypto.a libxml2.a libcairo.a libfontconfig.a libfreetype.a libpng.a libpng16.a libpixman-1.a libharfbuzz.a libfribidi.a libX11.a libtiff.a libjpeg.a libwebp.a libwebpmux.a libwebpdemux.a libicuuc.a libicui18n.a libicudata.a libicuio.a libicutu.a libicutest.a libzstd.a liblz4.a libnlopt.a libMagickCore-6.Q16.a libMagickWand-6.Q16.a libMagick++-6.Q16.a; do
        rm -f "${BASE_SANDBOX}/usr/lib/x86_64-linux-gnu/${_a}" 2>/dev/null || true
    done
    unset _a
    # Fix broken lib*.so dev symlinks: dev debs are from a different Debian snapshot than
    # the r-base Docker image, so the versioned symlink targets (e.g. libpng16.so.16.39.0)
    # may not match the runtime files present in the image (e.g. libpng16.so.16.44.0).
    # Strategy: for each broken lib*.so dev symlink, find the SONAME-level symlink
    # (lib*.so.N where N is a single integer) that exists in the sandbox and re-target it.
    _lib_dir="${BASE_SANDBOX}/usr/lib/x86_64-linux-gnu"
    for _dev_so in "${_lib_dir}"/lib*.so; do
        [ -L "$_dev_so" ] || continue          # skip non-symlinks
        [ -e "$_dev_so" ] && continue          # skip already-good symlinks
        _basename=$(basename "$_dev_so")
        _libname="${_basename%.so}"            # e.g. libpng16
        # Find the SONAME symlink: lib*.so.N (exactly one numeric component after .so.)
        _soname=$(find "$_lib_dir" -maxdepth 1 -name "${_libname}.so.*" 2>/dev/null \
            | grep -E "\\.so\\.[0-9]+$" | sort -V | tail -1)
        if [ -n "$_soname" ]; then
            ln -sf "$(basename "$_soname")" "$_dev_so"
            echo "    ✓ Fixed broken symlink: ${_basename} → $(basename "$_soname")"
        else
            echo "    WARNING: broken symlink ${_basename} — no SONAME found, leaving as-is"
        fi
    done
    unset _lib_dir _dev_so _basename _libname _soname
    # Patch harfbuzz.pc: strip Requires/Requires.private lines referencing glib-2.0
    # and graphite2 — those are transitive deps of harfbuzz that we cannot easily inject
    # into the sandbox. Without the patch, 'pkg-config --cflags harfbuzz' returns an error
    # (can't resolve dependencies), leaving PKG_CFLAGS empty in textshaping's configure,
    # which then can't find hb-ft.h. Stripping those lines is safe because textshaping
    # only needs the harfbuzz Cflags (-I/usr/include/harfbuzz) and -lharfbuzz linker flag,
    # not any glib/graphite headers at build time.
    _hb_pc="${BASE_SANDBOX}/usr/lib/x86_64-linux-gnu/pkgconfig/harfbuzz.pc"
    if [[ -f "$_hb_pc" ]]; then
        sed -i '/^Requires[^:]*:.*\(glib-2\.0\|graphite2\)/d' "$_hb_pc"
        echo "    ✓ Patched harfbuzz.pc: stripped unresolvable glib-2.0/graphite2 Requires"
    fi
    unset _hb_pc
    # Create Magick++.pc compatibility symlink: the magick R package configure script runs
    # `pkg-config Magick++` (unversioned) but Debian bookworm only provides the versioned
    # Magick++-6.Q16.pc. Without the unversioned alias, pkg-config returns empty CFLAGS
    # and Magick++.h is not found even though the header and .pc file are present.
    _pc_dir="${BASE_SANDBOX}/usr/lib/x86_64-linux-gnu/pkgconfig"
    if [ -f "${_pc_dir}/Magick++-6.Q16.pc" ] && [ ! -f "${_pc_dir}/Magick++.pc" ]; then
        ln -sf "Magick++-6.Q16.pc" "${_pc_dir}/Magick++.pc"
        echo "    ✓ Created Magick++.pc → Magick++-6.Q16.pc compatibility symlink"
    fi
    unset _pc_dir
    echo "  ✓ Dev headers + libxml2 runtime injected; non-PIC static archives removed; broken symlinks fixed"

    # Step 1d: Install CRAN and Bioconductor packages into the sandbox system library.
    # lib=syslib: forces all installs into /usr/local/lib/R/site-library (inside sandbox).
    # Repos: cloud.r-project.org (CRAN) and bioconductor.org are reachable from login nodes.
    #
    # Environment isolation approach:
    #   - Write R install script directly into sandbox filesystem (host-side, mkdir -p already
    #     created $BASE_SANDBOX/opt in Step 1b). Avoids bind-mounting, which fails when the
    #     target path does not pre-exist in the writable sandbox.
    #   - Write Makevars.site into sandbox to blank CXX20/CXX20FLAGS/CXX20STD, so host
    #     ~/.R/Makevars (NFS-mounted, visible even with --no-home) cannot override the
    #     container's gcc with the host gcc-12 toolchain.
    #   - Use 'bash -c export PATH=...' as the container entrypoint so PATH is set at
    #     shell level BEFORE R/cmake/configure run, ensuring pkg-config and libcurl are
    #     found in the container's /usr and that /software/gcc-12 is excluded.
    echo "  Installing R packages into sandbox system library (CRAN + Bioconductor)..."
    SYSLIB="/usr/local/lib/R/site-library"
    R_INSTALL_SCRIPT="${BASE_SANDBOX}/opt/r_install.R"

    # Makevars.site: inject CPPFLAGS and LDFLAGS so all packages find injected headers/libs.
    # - CXX20 is NOT blanked here; R_MAKEVARS_USER=/dev/null already blocks host ~/.R/Makevars.
    # - Blanking CXX20 here would break arrow (requires C++20 compiler detection).
    # CPPFLAGS: add subdir include paths so packages find headers that aren't on the default path:
    #   freetype2: ft2build.h (needed by systemfonts)
    #   harfbuzz:  hb-ft.h and other HB headers (needed by textshaping)
    #   fribidi:   fribidi.h (needed by textshaping/string_bidi.cpp)
    # LDFLAGS: add multiarch lib dir so linker finds libpng16.so, libcairo.so, etc.
    #   (R's Makefile only passes -L/usr/lib/R/lib; /usr/lib/x86_64-linux-gnu is not searched otherwise)
    printf 'CPPFLAGS = -I/usr/include/freetype2 -I/usr/include/harfbuzz -I/usr/include/fribidi\nLDFLAGS = -L/usr/lib/x86_64-linux-gnu\n' \
        > "${BASE_SANDBOX}/usr/lib/R/etc/Makevars.site"

    # Package repositories are resolved against a fixed date, not 'latest'.
    # With 'latest' the same recipe produced different package versions on
    # different days, which left the built .sif as the only record of what a
    # result was actually computed with. The default below is the date the
    # images currently on Randi were built, so a rebuild reproduces them.
    # Override with CRAN_SNAPSHOT=YYYY-MM-DD to move deliberately.
    CRAN_SNAPSHOT="${CRAN_SNAPSHOT:-2026-07-02}"
    echo "  CRAN snapshot: ${CRAN_SNAPSHOT}"

    # Write R install code to a temp file (bash expands ${SYSLIB} at write time)
    cat > "$R_INSTALL_SCRIPT" << REOF
syslib <- '${SYSLIB}'
.libPaths(syslib)

cran_url <- 'https://packagemanager.posit.co/cran/__linux__/bookworm/${CRAN_SNAPSHOT}'
Sys.setenv(LIBARROW_BINARY = 'true', NOT_CRAN = 'true')
options(repos = c(CRAN = cran_url))
options(timeout = 600)
cat(sprintf('CRAN repo: %s\n', cran_url))
cat(sprintf('PATH inside container: %s\n', Sys.getenv('PATH')))

if (!requireNamespace('BiocManager', quietly = TRUE))
  install.packages('BiocManager', lib = syslib)
BiocManager::install(version = '3.20', ask = FALSE, update = FALSE)
cat(sprintf('BiocManager ready; Bioc version: %s\n', as.character(BiocManager::version())))
# Use install.packages() directly with Bioc repos so that the 'dependencies' arg
# is honoured at graph-resolution time (BiocManager::install pre-computes Suggests
# before calling install.packages, bypassing our filter).
bioc_repos <- c(
  BioCsoft_PPM = 'https://packagemanager.posit.co/bioconductor/3.20/__linux__/bookworm/${CRAN_SNAPSHOT}',
  BiocManager::repositories()
)

verify_stage <- function(stage_num, pkgs) {
  missing <- pkgs[!vapply(pkgs, function(p)
    requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
  if (length(missing) > 0)
    stop(sprintf('Stage %d FAILED — missing: %s', stage_num, paste(missing, collapse = ', ')))
  cat(sprintf('Stage %d verified (%d/%d packages OK).\n', stage_num, length(pkgs), length(pkgs)))
}

s1_pkgs <- c('dplyr','data.table','ape','phangorn','ggplot2','patchwork',
             'tidyr','gridExtra','cowplot','msigdbr',
             'optparse','arrow','RCurl','spatstat','remotes')
s1_missing <- s1_pkgs[!vapply(s1_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 1: Installing %d/%d CRAN packages...\n', length(s1_missing), length(s1_pkgs)))
if (length(s1_missing) > 0)
  install.packages(s1_missing, repos = cran_url, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(1, s1_pkgs)

# ggrepel: CRAN version 0.9.7 requires R >= 4.5.0 but this container uses R 4.4.1.
# Install 0.9.6 from CRAN archive — the last release compatible with R < 4.5.0.
if (!requireNamespace('ggrepel', lib.loc = syslib, quietly = TRUE)) {
  cat('Installing ggrepel 0.9.6 from CRAN archive (0.9.7 requires R >= 4.5.0)...\n')
  install.packages(
    'https://cran.r-project.org/src/contrib/Archive/ggrepel/ggrepel_0.9.6.tar.gz',
    repos = NULL, type = 'source', lib = syslib
  )
}
if (!requireNamespace('ggrepel', lib.loc = syslib, quietly = TRUE))
  stop('ggrepel install from archive failed')
cat('ggrepel 0.9.6 verified.\n')

s2_pkgs <- c('BiocGenerics','S4Vectors','IRanges',
             'GenomeInfoDb','GenomicRanges','Biobase',
             'MatrixGenerics','SparseArray','DelayedArray',
             'SummarizedExperiment','BiocParallel','BiocFileCache','rhdf5','Rhdf5lib')
s2_missing <- s2_pkgs[!vapply(s2_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 2: Installing %d/%d Bioc infra packages...\n', length(s2_missing), length(s2_pkgs)))
if (length(s2_missing) > 0)
  install.packages(s2_missing, repos = bioc_repos, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(2, s2_pkgs)

s3_pkgs <- c('SingleCellExperiment','beachmat','BiocSingular','ScaledMatrix',
             'scuttle','scater','scran')
s3_missing <- s3_pkgs[!vapply(s3_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 3: Installing %d/%d SCE ecosystem packages...\n', length(s3_missing), length(s3_pkgs)))
if (length(s3_missing) > 0)
  install.packages(s3_missing, repos = bioc_repos, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(3, s3_pkgs)

s4_pkgs <- c('AnnotationDbi','org.Mm.eg.db','org.Hs.eg.db','fgsea')
s4_missing <- s4_pkgs[!vapply(s4_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 4: Installing %d/%d annotation packages...\n', length(s4_missing), length(s4_pkgs)))
if (length(s4_missing) > 0)
  install.packages(s4_missing, repos = bioc_repos, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(4, s4_pkgs)

s5_pkgs <- c('BayesSpace')
s5_missing <- s5_pkgs[!vapply(s5_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 5: Installing %d/%d BayesSpace packages...\n', length(s5_missing), length(s5_pkgs)))
if (length(s5_missing) > 0)
  install.packages(s5_missing, repos = bioc_repos, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(5, s5_pkgs)

s6_pkgs <- c('Seurat', 'stringr', 'harmony', 'presto')
s6_missing <- s6_pkgs[!vapply(s6_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 6: Installing %d/%d DE analysis packages...\n', length(s6_missing), length(s6_pkgs)))
# Seurat, stringr, and harmony are on CRAN; presto is GitHub-only (not on CRAN for R < 4.5)
s6_cran <- intersect(s6_missing, c('Seurat', 'stringr', 'harmony'))
if (length(s6_cran) > 0)
  install.packages(s6_cran, repos = cran_url, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
if (!requireNamespace('presto', lib.loc = syslib, quietly = TRUE)) {
  cat('Installing presto from GitHub (immunogenomics/presto)...\n')
  remotes::install_github('immunogenomics/presto', lib = syslib, upgrade = 'never')
}
verify_stage(6, s6_pkgs)

s7_pkgs <- c('DESpace')
s7_missing <- s7_pkgs[!vapply(s7_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 7: Installing %d/%d DESpace (Bioc)...\n', length(s7_missing), length(s7_pkgs)))
if (length(s7_missing) > 0)
  install.packages(s7_missing, repos = bioc_repos, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(7, s7_pkgs)

# Stage 8: factoextra (CRAN dependency of SpaCET)
# nloptr 2.x requires cmake which is absent from the r-base:4.4.1 image.
# Pre-install nloptr 1.2.2.3 (last cmake-free version) from CRAN archive.
# lme4 requires nloptr >= 1.0.4 — 1.2.2.3 satisfies this constraint.
if (!requireNamespace('nloptr', lib.loc = syslib, quietly = TRUE))
  remotes::install_version('nloptr', version = '1.2.2.3', repos = cran_url,
    lib = syslib, dependencies = c('Depends', 'Imports', 'LinkingTo'))
s8_pkgs <- c('factoextra')
s8_missing <- s8_pkgs[!vapply(s8_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 8: Installing %d/%d factoextra...\n', length(s8_missing), length(s8_pkgs)))
if (length(s8_missing) > 0)
  install.packages(s8_missing, repos = cran_url, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(8, s8_pkgs)

# Stage 9: MUDAN — GitHub-only dependency of SpaCET (JEFworks/MUDAN)
# MUDAN requires sva (Bioconductor); install it first before the GitHub install.
if (!requireNamespace('sva', lib.loc = syslib, quietly = TRUE))
  BiocManager::install('sva', lib = syslib, ask = FALSE, update = FALSE)
s9_pkgs <- c('MUDAN')
s9_missing <- s9_pkgs[!vapply(s9_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 9: Installing %d/%d MUDAN (GitHub)...\n', length(s9_missing), length(s9_pkgs)))
if (length(s9_missing) > 0)
  remotes::install_github('JEFworks/MUDAN', lib = syslib,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(9, s9_pkgs)

# Stage 10: SpaCET (GitHub)
s10_pkgs <- c('SpaCET')
s10_missing <- s10_pkgs[!vapply(s10_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 10: Installing %d/%d SpaCET (GitHub)...\n', length(s10_missing), length(s10_pkgs)))
if (length(s10_missing) > 0)
  remotes::install_github('data2intelligence/SpaCET', lib = syslib,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(10, s10_pkgs)

all_pkgs <- c(s1_pkgs, 'ggrepel', s2_pkgs, s3_pkgs, s4_pkgs, s5_pkgs, s6_pkgs, s7_pkgs, s8_pkgs, s9_pkgs, s10_pkgs)
missing_pkgs <- all_pkgs[!vapply(all_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
if (length(missing_pkgs) > 0)
  stop(paste('Final check — missing packages:', paste(missing_pkgs, collapse=', ')))
cat(sprintf('  All %d packages verified in %s\n', length(all_pkgs), syslib))
REOF

    # Create the scratch mount point inside the sandbox so Singularity can bind it.
    mkdir -p "${BASE_SANDBOX}${BUILD_TMPDIR}"

    singularity exec --writable --no-home --cleanenv \
        -B /etc/resolv.conf \
        -B "${BUILD_TMPDIR}:${BUILD_TMPDIR}" \
        "$BASE_SANDBOX" \
        bash -c '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/tmp
export TMPDIR='"${BUILD_TMPDIR}"'
export PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig
export R_LIBS_SITE='"${SYSLIB}"'
export R_LIBS_USER='"${SYSLIB}"'
export R_MAKEVARS_USER=/dev/null
Rscript /opt/r_install.R'

    rm -f "$R_INSTALL_SCRIPT"
    echo "  ✓ R packages installed into $SYSLIB"

    # Step 1e: Pack sandbox → base SIF
    echo "  Packing base SIF..."
    TMPDIR="$BUILD_TMPDIR" SINGULARITY_TMPDIR="$BUILD_TMPDIR" singularity build "$BASE_SIF" "$BASE_SANDBOX"
    rm -rf "$BASE_SANDBOX"

    if [ ! -f "$BASE_SIF" ]; then
        echo "ERROR: Base SIF was not created: $BASE_SIF"
        exit 1
    fi
    echo "  ✓ Base SIF built: $(du -sh "$BASE_SIF" | cut -f1)"

    # Post-build verification: confirm packages are inside the SIF, not the host home.
    # --no-home --cleanenv: prevent host bind-mounts
    # --env R_LIBS_USER=<non-empty>: critical — R treats empty-string as "not set" and
    #   falls back to its compiled-in default ~/R/x86_64-pc-linux-gnu-library/4.4, which
    #   resolves to the NFS-mounted host path (NFS is visible even with --no-home on midway3).
    #   Host-installed .so files then fail because libRblas.so is a Debian symlink absent on RHEL.
    #   NOTE: --env HOME=/tmp is blocked by Singularity policy on this cluster; HOME stays
    #   /home/$USER, so R_LIBS_USER must be non-empty to prevent the ~/R/... fallback.
    echo "  Verifying packages are embedded in SIF (--no-home --cleanenv)..."
    _verify_r=$(mktemp /tmp/verify_pkgs_XXXXXX.R)
    cat > "$_verify_r" << 'REOF'
pkgs <- c('jsonlite','Matrix',
          'dplyr','data.table','ape','phangorn','ggplot2','patchwork',
          'tidyr','gridExtra','cowplot','ggrepel','msigdbr','optparse',
          'arrow','AnnotationDbi','fgsea','SingleCellExperiment','BayesSpace',
          'Seurat','stringr','harmony','presto','DESpace',
          'factoextra','MUDAN','SpaCET')
missing_pkgs <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]
if (length(missing_pkgs) > 0)
  stop(paste('SIF is missing packages:', paste(missing_pkgs, collapse=', '),
             '-- packages were likely installed to host home, not into sandbox'))
cat('  checkmark All', length(pkgs), 'packages confirmed inside SIF\n')
REOF
    _sing_tmp="${BUILD_TMPDIR}/singularity_tmp_verify"
    mkdir -p "$_sing_tmp"
    SINGULARITY_TMPDIR="$_sing_tmp" singularity exec --no-home --cleanenv \
        --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --env R_LIBS_USER="/usr/local/lib/R/site-library" \
        --bind "${_verify_r}:${_verify_r}:ro" \
        "$BASE_SIF" /bin/sh -c "Rscript --vanilla '${_verify_r}'"
    rm -f "$_verify_r"
    rm -rf "$_sing_tmp"
    unset _verify_r _sing_tmp
    echo "  ✓ Base SIF post-build verification passed"
else
    echo "Phase 1/2: Skipping base SIF (exists; use --force to rebuild)"
    echo "  ✓ Using: $BASE_SIF ($(du -sh "$BASE_SIF" | cut -f1))"
fi

echo ""

# ── Pre-build check: all R scripts exist on disk ───────────────────────────────
echo "Phase 2/2: Building script layer SIF (~10-15 min on GPFS)..."
echo "Checking source scripts exist on disk..."
MISSING_SCRIPTS=false
for script in "${R_SCRIPTS[@]}"; do
    src="$R_WORKFLOWS_BASE/$script"
    if [ ! -f "$src" ]; then
        echo "ERROR: Script listed in R_SCRIPTS array but not found on disk: $src"
        echo "Fix: Add the file to its feature directory under workflows/ or remove it from R_SCRIPTS in build_r_container.sh"
        MISSING_SCRIPTS=true
    fi
done
[ "$MISSING_SCRIPTS" = true ] && exit 1
echo "  ✓ All source scripts verified"

# ── Phase 2: Script layer SIF ──────────────────────────────────────────────────
# Clean up any leftover sandbox from a previous failed run
rm -rf "$OUTPUT_SANDBOX"
rm -f "$OUTPUT_SIF"

# Step 2a: Unpack base SIF to new sandbox
echo "  Unpacking base SIF to sandbox..."
TMPDIR="${BUILD_TMPDIR:-${TMPDIR:-/tmp}}" SINGULARITY_TMPDIR="${BUILD_TMPDIR:-${TMPDIR:-/tmp}}" singularity build --sandbox "$OUTPUT_SANDBOX" "$BASE_SIF"

# Step 2b: Copy R scripts into sandbox (host-side, no root needed)
echo "  Copying R scripts into sandbox..."
mkdir -p "$OUTPUT_SANDBOX/$R_WORKFLOWS_DST"
for script in "${R_SCRIPTS[@]}"; do
    cp "$R_WORKFLOWS_BASE/$script" "$OUTPUT_SANDBOX/$R_WORKFLOWS_DST/$(basename "$script")"
    echo "    + $(basename "$script")"
done

# Step 2b-verify: Confirm scripts landed in sandbox before packing (plain file check —
# avoids singularity exec on the SIF, which requires a writable TMPDIR not on GPFS).
for script in "${R_SCRIPTS[@]}"; do
    _dst="$OUTPUT_SANDBOX/$R_WORKFLOWS_DST/$(basename "$script")"
    if [ ! -f "$_dst" ]; then
        echo "ERROR: Script missing from sandbox after copy: ${_dst#${OUTPUT_SANDBOX}}"
        exit 1
    fi
done
echo "    ✓ All scripts present in sandbox"
unset _dst

# Step 2c: Pack sandbox → output SIF
echo "  Packing output SIF..."
TMPDIR="${BUILD_TMPDIR:-${TMPDIR:-/tmp}}" SINGULARITY_TMPDIR="${BUILD_TMPDIR:-${TMPDIR:-/tmp}}" singularity build "$OUTPUT_SIF" "$OUTPUT_SANDBOX"
rm -rf "$OUTPUT_SANDBOX"

if [ ! -f "$OUTPUT_SIF" ]; then
    echo "ERROR: Output SIF was not created: $OUTPUT_SIF"
    exit 1
fi
echo "  ✓ Script layer SIF built: $(du -sh "$OUTPUT_SIF" | cut -f1)"

echo ""
echo "========================================"
echo "Build Complete"
echo "========================================"
echo "Base SIF:   $BASE_SIF"
echo "Output SIF: $OUTPUT_SIF"
echo ""

# ── Post-build verification ────────────────────────────────────────────────────
echo "Running post-build verification..."

# R script presence was verified in the sandbox before packing (Step 2b-verify above).
# List them here for confirmation in the log.
echo "R scripts embedded in container:"
for script in "${R_SCRIPTS[@]}"; do
    echo "  ✓ $R_WORKFLOWS_DST/$(basename "$script")"
done

# Verify required packages load — requires a writable local TMPDIR for Singularity to
# extract the SIF. Only runs when --scratch is provided; on GPFS the default TMPDIR is
# noexec and singularity exec fails with "permission denied" without it.
# (Package presence was already verified when the base SIF was built with --force.)
if [ -n "$BUILD_TMPDIR" ]; then
    _sing_tmp="${BUILD_TMPDIR}/singularity_tmp_verify"
    mkdir -p "$_sing_tmp"
    _verify_r=$(mktemp /tmp/verify_pkgs_XXXXXX.R)
    cat > "$_verify_r" << 'REOF'
pkgs <- c("jsonlite", "Matrix",
          "dplyr", "data.table", "ape", "phangorn", "ggplot2", "patchwork",
          "tidyr", "gridExtra", "cowplot", "ggrepel", "msigdbr",
          "fgsea", "AnnotationDbi", "optparse", "arrow",
          "SingleCellExperiment", "BayesSpace",
          "Seurat", "stringr", "harmony", "presto", "DESpace",
          "factoextra", "MUDAN", "SpaCET")
missing <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]
if (length(missing) > 0) {
  stop(paste("ERROR: Missing packages:", paste(missing, collapse=", "),
             "\nFix: Rebuild base layer with: bash build_r_container.sh --force"))
}
cat("  checkmark All", length(pkgs), "required packages confirmed inside SIF\n")
REOF
    SINGULARITY_TMPDIR="$_sing_tmp" singularity exec --no-home --cleanenv \
        --env "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --env R_LIBS_USER="/usr/local/lib/R/site-library" \
        --bind "${_verify_r}:${_verify_r}:ro" \
        "$OUTPUT_SIF" /bin/sh -c "Rscript --vanilla '${_verify_r}'"
    rm -f "$_verify_r"
    rm -rf "$_sing_tmp"
    unset _verify_r _sing_tmp
else
    echo "  (Skipping package load check — pass --scratch to enable; packages verified at base SIF build time)"
fi

echo ""
echo "✓ Post-build verification passed"
echo "Container ready: $OUTPUT_SIF"

# ── Update config/capabilities.sh ─────────────────────────────────────────────
# Preserve any existing entries for other features; set container availability flags.
_CAPS="${REPO_ROOT}/config/capabilities.sh"
if [ -f "$_CAPS" ]; then
    # Update existing entries in-place (or append if not present)
    if grep -q "^BAYESSPACE_CONTAINER_AVAILABLE=" "$_CAPS"; then
        sed -i 's/^BAYESSPACE_CONTAINER_AVAILABLE=.*/BAYESSPACE_CONTAINER_AVAILABLE=true/' "$_CAPS"
    else
        echo "BAYESSPACE_CONTAINER_AVAILABLE=true" >> "$_CAPS"
    fi
    if grep -q "^DE_ANALYSIS_CONTAINER_AVAILABLE=" "$_CAPS"; then
        sed -i 's/^DE_ANALYSIS_CONTAINER_AVAILABLE=.*/DE_ANALYSIS_CONTAINER_AVAILABLE=true/' "$_CAPS"
    else
        echo "DE_ANALYSIS_CONTAINER_AVAILABLE=true" >> "$_CAPS"
    fi
    if grep -q "^SPACET_CONTAINER_AVAILABLE=" "$_CAPS"; then
        sed -i 's/^SPACET_CONTAINER_AVAILABLE=.*/SPACET_CONTAINER_AVAILABLE=true/' "$_CAPS"
    else
        echo "SPACET_CONTAINER_AVAILABLE=true" >> "$_CAPS"
    fi
    sed -i "s/^CAPABILITIES_GENERATED_AT=.*/CAPABILITIES_GENERATED_AT=\"$(date '+%Y-%m-%d %H:%M:%S')\"/" "$_CAPS"
else
    cat > "$_CAPS" << EOF
# Generated by build_r_container.sh — re-run bash setup.sh for full detection
BAYESSPACE_CONTAINER_AVAILABLE=true
BAYESSPACE_NATIVE_AVAILABLE=unknown
DE_ANALYSIS_CONTAINER_AVAILABLE=true
DE_ANALYSIS_NATIVE_AVAILABLE=unknown
SPACET_CONTAINER_AVAILABLE=true
SPACET_NATIVE_AVAILABLE=unknown
CAPABILITIES_GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
fi
unset _CAPS
echo "  ✓ config/capabilities.sh updated (BAYESSPACE_CONTAINER_AVAILABLE=true, DE_ANALYSIS_CONTAINER_AVAILABLE=true, SPACET_CONTAINER_AVAILABLE=true)"
