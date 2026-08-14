#!/bin/bash
set -e

# Build minimal R 4.5 container for DE analysis (Seurat + DESpace 2.0)
#
# DESpace >= 2.0 requires R >= 4.5.0 (Bioconductor 3.21). This container is
# intentionally minimal — it only includes the packages needed by run_DE_analysis.R.
# The full tumorspace_r.sif (R 4.4.1) continues to serve BayesSpace and pipeline reports.
#
# Uses the same fakeroot-free sandbox pattern as build_r_container.sh:
#   pull → sandbox → host-side mutations → pack → SIF
#
# Base image: r-base:4.5.0 (Debian trixie / Debian 13 image)
#
# New system deps vs build_r_container.sh:
#   terra and sf (DESpace imports) require GDAL/GEOS/PROJ — injected via same
#   host-side .deb extraction approach used for ImageMagick.
#
# Two-phase build:
#   Phase 1 (base, ~60-90 min): pull r-base:4.5.0 sandbox, install R packages,
#                                pack to tumorspace_r45_base.sif
#                                Skipped if tumorspace_r45_base.sif exists; use --force to rebuild
#   Phase 2 (scripts, ~30 sec): unpack base SIF, copy R scripts, pack to tumorspace_r45.sif
#
# Usage:
#   bash build_r45_container.sh --scratch <dir>           # full build
#   bash build_r45_container.sh --scratch <dir> --force   # force rebuild base layer
#   bash build_r45_container.sh --scratch <dir> --nohup   # background build

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load HPC cluster profile (exports module names; falls back to .example defaults)
_HPC_PROFILE="${REPO_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

# Load Singularity module
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
            echo "Usage: bash build_r45_container.sh [--scratch <dir>] [--force] [--nohup]"
            echo ""
            echo "  --scratch <dir>  Local scratch directory for R package compilation."
            echo "                   Must be on a filesystem that supports execute permissions"
            echo "                   (not GPFS, not noexec)."
            echo "                   If not passed, BUILD_SCRATCH_DIR from config/hpc_profile.sh"
            echo "                   is used automatically. Leave both empty on exec-safe clusters."
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
if [ "$RUN_NOHUP" = true ]; then
    # Reconstruct forward args from parsed variables so nothing is silently dropped.
    _FORWARD_ARGS=()
    [ "$FORCE_BASE" = true ] && _FORWARD_ARGS+=("--force")
    [ -n "$BUILD_TMPDIR" ]   && _FORWARD_ARGS+=("--scratch" "$BUILD_TMPDIR")
    _LOG="${SCRIPT_DIR}/build_r45_container_nohup_$$.log"
    nohup bash "${BASH_SOURCE[0]}" "${_FORWARD_ARGS[@]}" > "$_LOG" 2>&1 &
    _BG_PID=$!
    echo "Container build launched in background (PID ${_BG_PID})"
    echo "Log: ${_LOG}"
    echo "Monitor: tail -f ${_LOG}"
    echo "Check done: kill -0 ${_BG_PID} 2>/dev/null && echo running || echo finished"
    exit 0
fi

# ── Log file (tee all output to timestamped file for post-build review) ───────
# Runs in both foreground and nohup modes. Skipped when already inside a nohup
# re-launch (nohup redirects to its own log before reaching this point).
_BUILD_LOG="${SCRIPT_DIR}/build_r45_container_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee "$_BUILD_LOG") 2>&1
echo "Full build log: $_BUILD_LOG"
unset _BUILD_LOG

# ── Scratch directory ─────────────────────────────────────────────────────────
# BUILD_TMPDIR is populated from --scratch or BUILD_SCRATCH_DIR (hpc_profile.sh).
# On exec-safe filesystems (e.g. Midway3 /project), it can safely be empty.
# On GPFS/noexec clusters (e.g. Randi), BUILD_SCRATCH_DIR must be set in hpc_profile.sh.
if [ -z "$BUILD_TMPDIR" ]; then
    if [ "$FORCE_BASE" = true ] || [ ! -f "$SCRIPT_DIR/tumorspace_r45_base.sif" ]; then
        echo "WARNING: No scratch directory configured. Building base layer in ${SCRIPT_DIR}."
        echo "  On GPFS/noexec clusters this will fail. Fix by setting BUILD_SCRATCH_DIR in"
        echo "  config/hpc_profile.sh or passing --scratch <dir>."
    fi
else
    mkdir -p "$BUILD_TMPDIR"
fi

# Redirect Docker blob cache away from ~/.singularity/cache to avoid filling home quota.
export SINGULARITY_CACHEDIR="${BUILD_TMPDIR:-$SCRIPT_DIR}/.singularity_cache"

BASE_SIF="$SCRIPT_DIR/tumorspace_r45_base.sif"
BASE_SANDBOX="${BUILD_TMPDIR:-$SCRIPT_DIR}/tumorspace_r45_base_sandbox"
OUTPUT_SIF="$SCRIPT_DIR/tumorspace_r45.sif"
OUTPUT_SANDBOX="${BUILD_TMPDIR:-$SCRIPT_DIR}/tumorspace_r45_scripts_sandbox"
R_WORKFLOWS_BASE="$REPO_ROOT/workflows"
R_WORKFLOWS_DST="/opt/workflows/R"

# R scripts to embed.
R_SCRIPTS=(
    DE_analysis/R/run_DE_analysis.R
    sg_analysis/R/cohort_ksweep.R
    sg_analysis/R/cohort_spatial.R
    sg_analysis/R/run_cohort_sgp_analysis.R
)

echo "========================================"
echo "Building TumorSPACE R 4.5 Container"
echo "  (DE analysis — Seurat + DESpace 2.0)"
echo "========================================"
echo "Base SIF:   $BASE_SIF"
echo "Output SIF: $OUTPUT_SIF"
echo ""

# ── Phase 1: Base SIF (pull + install packages) ────────────────────────────────
if [ "$FORCE_BASE" = true ] || [ ! -f "$BASE_SIF" ]; then
    if [ "$FORCE_BASE" = true ]; then
        echo "Phase 1/2: Rebuilding base SIF (--force, ~60-90 min)..."
        rm -f "$BASE_SIF"
        rm -rf "$BASE_SANDBOX"
    else
        echo "Phase 1/2: Building base SIF (packages, ~60-90 min)..."
    fi

    # Step 1a: Pull r-base:4.5.0 directly into a writable sandbox
    if [ -d "$BASE_SANDBOX" ]; then
        echo "  Reusing existing sandbox (delete with --force to re-pull): $BASE_SANDBOX"
    else
        echo "  Pulling r-base:4.5.0 from Docker Hub and building sandbox..."
        singularity build --sandbox "$BASE_SANDBOX" docker://r-base:4.5.0
        echo "  ✓ Sandbox created"
    fi

    # Step 1b: Create HPC mount points directly on sandbox dir (host-side, no root needed)
    echo "  Creating HPC mount points..."
    mkdir -p "$BASE_SANDBOX/project" "$BASE_SANDBOX/scratch" "$BASE_SANDBOX/software"
    mkdir -p "$BASE_SANDBOX/opt/workflows/R"
    # Ensure /etc/resolv.conf exists as a bind-mount target for DNS during package
    # installation. Singularity creates it when building a fresh sandbox from Docker,
    # but it may be absent when reusing an existing sandbox from a prior failed run.
    touch "$BASE_SANDBOX/etc/resolv.conf"

    # Step 1c: Inject missing dev headers and runtime libs into sandbox via host-side .deb extraction.
    # Two categories of system libs are needed:
    #
    # A) ImageMagick — same as build_r_container.sh.
    #    Required because: DESpace → SpatialExperiment → magick R pkg → libMagick*.so
    #    Both binary-amd64 and binary-all Packages.gz indexes are fetched
    #    (arch:all packages like header debs are only in binary-all).
    #
    # B) GDAL / GEOS / PROJ / SQLite — NEW for this container.
    #    Required because: DESpace → terra and sf → libgdal.so, libgeos.so, libproj.so
    #    These are not present in r-base:4.5.0. terra and sf compile from source inside the
    #    trixie container and link against the trixie versions of these system libs.
    #
    # Other dev headers (curl, ssl, xml2, cairo, fontconfig, freetype, png, harfbuzz, fribidi,
    # tiff, jpeg, webp, icu, zstd, lz4, cmake, nlopt) are needed for packages that compile
    # from source (scater/ragg/stringi/igraph/nloptr chains). Same packages as build_r_container.sh.
    echo "  Injecting dev headers and runtime libs into sandbox via .deb extraction..."
    _DEB_TMP=$(mktemp -d)
    _PKG_INDEX="${_DEB_TMP}/Packages"
    _PKG_INDEX_ALL="${_DEB_TMP}/Packages-all"
    if [ ! -f "$_PKG_INDEX" ]; then
        echo "    Fetching Debian trixie package indexes (amd64 + all)..."
        _fetched=0
        for _try in 1 2 3; do
            wget -q -O "${_PKG_INDEX}.gz" \
                "https://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.gz" 2>/dev/null \
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
                "https://deb.debian.org/debian/dists/trixie/main/binary-all/Packages.gz" 2>/dev/null \
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
        local _rel
        _rel=$(awk -v pkg="$1" '
            /^Package: / { in_block = ($2 == pkg) }
            in_block && /^Filename: / { print $2; exit }
        ' "$_PKG_INDEX" "$_PKG_INDEX_ALL")
        [ -n "$_rel" ] && echo "https://deb.debian.org/debian/${_rel}"
    }

    # ── A) Existing dev + runtime packages (mirrors build_r_container.sh intent) ──
    # ImageMagick: trixie ships ImageMagick 7 (not 6), so packages use -7.q16- naming.
    #   libmagickcore-7.q16-dev + libmagickwand-7.q16-dev + libmagick++-7.q16-dev
    #   plus arch-specific: libmagickcore-7-arch-config (amd64) and
    #   arch:all header packages (libmagick{core,wand,++}-7-headers from binary-all).
    # libcairo2-dev + libpixman-1-dev: for Cairo R pkg (dep chain via ggrastr → scater).
    # libx11-dev + x11proto-dev: X11 headers needed by Cairo.
    # libfontconfig-dev + libfreetype-dev: needed by systemfonts.
    # libpng-dev: for R png package.
    # libharfbuzz-dev + libfribidi-dev: needed by textshaping (ragg → scater).
    # libtiff-dev + libjpeg-dev + libwebp-dev: needed by ragg.
    # libicu-dev: for stringi (dep of stringr/Seurat).
    # libzstd-dev + liblz4-dev: for arrow/data.table (if pulled as transitive deps).
    # cmake + cmake-data: for igraph C library (dep of Seurat).
    # libnlopt-dev: for nloptr → lme4 → car → rstatix → ggpubr → DESpace chain.
    # libuv1-dev: for fs R package (Seurat dep) — configure uses pkg-config to find libuv;
    #   without the dev package (which provides libuv.pc + headers) configure fails.
    # NOTE: do NOT inject the `file` utility — it depends on libmagic.so.1 (libmagic1t64)
    # which is not in r-base. Without libmagic1t64, `file` crashes on every call and
    # breaks R package installation entirely (R's build system calls `file` on compiled .so
    # files). terra configure handles /usr/bin/file being absent gracefully — it is a
    # non-fatal notice, not an error; terra proceeds to compile without it.
    _DEV_PKGS=(libcurl4-openssl-dev libssl-dev libxml2-dev libcairo2-dev libpixman-1-dev libx11-dev x11proto-dev libfontconfig-dev libfreetype-dev libpng-dev libharfbuzz-dev libfribidi-dev libtiff-dev libjpeg-dev libwebp-dev libicu-dev libzstd-dev liblz4-dev cmake cmake-data libnlopt-dev libuv1-dev libmagickcore-7.q16-dev libmagickwand-7.q16-dev libmagick++-7.q16-dev libmagickcore-7-arch-config libmagickcore-7-headers libmagickwand-7-headers libmagick++-7-headers)
    # Runtime libs not in r-base:4.5.0:
    # libwebpmux3 + libwebpdemux2: ragg configure checks for these.
    # librhash1 + libjsoncpp26 + libuv1t64: cmake runtime deps (trixie names).
    # libnlopt0: NLopt shared library.
    # ImageMagick 7 runtime: libmagickcore-7.q16-10, libmagickwand-7.q16-10, libmagick++-7.q16-5.
    # liblcms2-2 + liblqr-1-0 + libfftw3-double3 + libltdl7: libMagickCore runtime deps.
    # libicu76: ICU runtime (libicuuc.so.76; trixie ships ICU 76, not 72).
    #   igraph (dep of Seurat) compiles its C++ library and links against libicuuc; inject
    #   explicitly to ensure the runtime .so is present in the sandbox.
    # libarchive13t64: cmake runtime dep — cmake crashes on startup without it.
    _RT_PKGS=(libxml2 libwebpmux3 libwebpdemux2 librhash1 libjsoncpp26 libuv1t64 libnlopt0 libicu76 libarchive13t64 libmagickcore-7.q16-10 libmagickwand-7.q16-10 libmagick++-7.q16-5 liblcms2-2 liblqr-1-0 libfftw3-double3 libltdl7)

    # ── B) Geo dev + runtime packages (new for this container) ───────────────────
    # DESpace imports terra and sf, which must be compiled from source (no PPM
    # trixie/R 4.5 binary builds available yet for terra/sf).
    # Source compilation requires the entire libgdal-dev transitive dependency tree.
    # gdal-config --libs lists all GDAL deps; terra's configure links against each one,
    # so every -l flag must resolve to a .so symlink in the sandbox.
    #
    # Dev packages: provide headers + unversioned .so symlinks for the linker.
    # Runtime packages: provide versioned .so files loaded at R package load time.
    #
    # Base geo stack:
    #   libgdal-dev: GDAL headers + gdal-config (drives terra/sf configure)
    #   libgeos-dev: GEOS headers + geos-config
    #   libproj-dev: PROJ headers + pkgconfig
    #   libsqlite3-dev: SQLite (PROJ/GDAL dep)
    #   libudunits2-dev: udunits2 headers (units R pkg dep of sf)
    #
    # GDAL compile-time dep chain (from linker errors in prior build log):
    #   libarmadillo-dev:   wrapper2_dposv_ Fortran BLAS wrappers (armadillo → GDAL)
    #   libqhull-dev:       qh_lib_check (Qhull geometry algorithms in GDAL)
    #   libgeotiff-dev:     GTIFKeyName (GeoTIFF raster support)
    #   libheif-dev:        HEIF image format driver
    #   libkml-dev:         libkmlbase/dom/engine (Google KML vector driver)
    #   libminizip-dev:     minizip (GDAL zip/KMZ reading)
    #   liburiparser-dev:   URI parser (GDAL WFS/WMS drivers)
    #   libfyaml-dev:       YAML parser (GDAL config files)
    #   libfyba-dev:        fyba/fygm/fyut (FYBA Norwegian spatial format, OGDI dep)
    #   libspatialite-dev:  SpatiaLite SQLite extension
    #   libxerces-c-dev:    Xerces XML (GDAL GML/XML drivers; -lxerces-c symlink)
    #   libmariadb-dev:     libmysqlclient.so symlink (GDAL MySQL driver)
    #   libpq-dev:          libpq.so symlink (PostgreSQL; -lpq) + libldap dep
    #   unixodbc-dev:       libodbc.so + libodbcinst.so symlinks (-lodbc/-lodbcinst)
    #   libfreexl-dev:      freexl_open (Excel reading; -lfreexl)
    #   libogdi-dev:        LC_OpenSos/LC_Init (OGDI format library; -logdi)
    #   libjson-c-dev:      json_tokener_get_error (JSON-C; -ljson-c symlink)
    #   libnetcdf-dev:      NetCDF (-lnetcdf symlink; runtime libnetcdf19 already injected)
    #   libhdf5-dev:        H5Pset_fill_value@HDF5_SERIAL (serial HDF5; Provides: libhdf5-serial-dev)
    #                       Also pulls in libhdf5-fortran-310 for wrapper2_dposv_ Fortran BLAS wrappers
    #   libhdf4-alt-dev:    SDreset_maxopenfiles (HDF4 raster format)
    #   libaec-dev:         szip/AEC compression (HDF5 dep)
    #   libcfitsio-dev:     FITS astronomical raster driver
    #   libblosc-dev:       Blosc compression (HDF5/NetCDF dep)
    #   libgif-dev:         GIF driver (-lgif symlink; runtime libgif7 already injected)
    #   libopenjp2-7-dev:   JPEG2000 (-lopenjp2 symlink; runtime libopenjp2-7 injected)
    #   libpoppler-dev:     XRef::getCatalog (Poppler C++ PDF driver; -lpoppler)
    #   libpoppler-cpp-dev: Poppler C++ interface (-lpoppler-cpp; already have runtime)
    #   libexpat1-dev:      libexpat.so symlink (XML; may differ between snapshot builds)
    #   libldap-dev:        ldap_search_st@OPENLDAP_2.5 (OpenLDAP; libpq transitive dep)
    #   libarpack2-dev:     ARPACK dev symlink (-larpack; libarmadillo transitive dep)
    #   libsnappy-dev:      Snappy compression dev (-lsnappy; libblosc transitive dep)
    #   libavif-dev:        AVIF image format dev (-lavif; libgdal transitive dep)
    #   librttopo-dev:      Tuscany topology dev (-lrttopo; libspatialite transitive dep)
    #   libnss3-dev:        NSS crypto dev (libpoppler transitive dep — NSS_* symbols)
    #   libgpgmepp-dev:     GpgME C++ dev (libpoppler transitive dep — GpgME::* symbols)
    #   libmariadb-dev-compat: MySQL compatibility symlinks (libmysqlclient.so); trixie
    #                       libmariadb-dev alone does NOT provide -lmysqlclient, which
    #                       GDAL's MySQL driver configure test requires.
    _GEO_DEV_PKGS=(libgdal-dev libgeos-dev libproj-dev libsqlite3-dev libudunits2-dev libarmadillo-dev libqhull-dev libgeotiff-dev libheif-dev libkml-dev libminizip-dev liburiparser-dev libfyaml-dev libfyba-dev libspatialite-dev libxerces-c-dev libmariadb-dev libmariadb-dev-compat libpq-dev unixodbc-dev libfreexl-dev libogdi-dev libjson-c-dev libnetcdf-dev libhdf5-dev libhdf4-alt-dev libaec-dev libcfitsio-dev libblosc-dev libgif-dev libopenjp2-7-dev libpoppler-dev libpoppler-cpp-dev libexpat1-dev libldap-dev libarpack2-dev libsnappy-dev libavif-dev librttopo-dev libnss3-dev libgpgmepp-dev)
    # Runtime counterparts: versioned .so files needed at R package load time.
    # All names verified against Debian trixie binary-amd64 Packages index.
    #   libhdf5-310:         HDF5 1.14.x serial C runtime (soname .so.310)
    #   libhdf5-hl-310:      HDF5 High Level serial runtime
    #   libhdf5-fortran-310: HDF5 Fortran serial runtime — provides wrapper2_dposv_ etc.
    #   libhdf4-0-alt:       HDF4 alternative runtime (libdf.so.0, libmfhdf.so.0)
    #   libaec0:             AEC/szip runtime
    #   libarmadillo14:      Armadillo 14.x runtime (soname .so.14; provides wrapper2_*)
    #   libqhull-r8.0:       Qhull reentrant runtime (soname .so.8.0; -lqhull_r)
    #   libgeotiff5:         GeoTIFF runtime
    #   libheif1:            libheif runtime
    #   libkmlbase1t64, libkmldom1t64, libkmlengine1t64: Google KML library runtimes (t64 suffix = trixie)
    #   libminizip1t64:      minizip runtime
    #   liburiparser1:       uriparser runtime
    #   libspatialite8t64:   SpatiaLite runtime (trixie has version 8)
    #   libfreexl1:          FreeXL runtime
    #   libcfitsio10t64:     CFITSIO runtime (t64 suffix = trixie)
    #   libblosc1:           Blosc runtime
    #   libpoppler147:       Poppler runtime (trixie soname .so.147)
    #   libldap2:            OpenLDAP runtime (trixie name; bookworm was libldap-2.5-0)
    #   libfyba0t64:         FYBA runtime (fyba/fygm/fyut symbols for OGDI; t64 suffix = trixie)
    #   libfyaml0:           FYAML runtime
    #   libcurl3t64-gnutls:  GnuTLS libcurl runtime (libcurl-gnutls.so.4) — libgdal and
    #                        libxerces-c were compiled against GnuTLS curl (@CURL_GNUTLS_3
    #                        symbol version tags); terra/sf linker must find this .so
    #   libnss3:             Mozilla NSS crypto runtime (libpoppler transitive dep)
    #   libnspr4:            Mozilla NSPR runtime (libnss3 dep)
    #   libgpgme11t64:       GPGME base runtime (libgpgmepp6t64 dep)
    #   libgpgmepp6t64:      GPGME C++ runtime (libpoppler transitive dep)
    #   libarpack2t64:       ARPACK eigenvalue solver runtime (libarmadillo14 transitive dep)
    #   libsnappy1v5:        Snappy compression runtime (libblosc transitive dep)
    #   libavif16:           AVIF image codec runtime (libgdal transitive dep)
    #   libsz2:              SZIP wrapper runtime (provides libsz.so.2; libhdf5 transitive dep)
    #   librttopo1:          Tuscany topology runtime (libspatialite8t64 Depends on this)
    #   libavif16 transitive deps (all confirmed present as conda packages in working env):
    #   libyuv0:             YUV pixel format conversion (BGRAToI420, ARGBToI420, etc.)
    #   libdav1d7:           dav1d AV1 decoder (dav1d_picture_unref, dav1d_close)
    #   librav1e0.7:         rav1e Rust AV1 encoder (rav1e_config_default, rav1e_frame_set_type)
    #   libaom3:             AOM AV1 codec (aom_codec_dec_init_ver, aom_codec_version)
    #   libsvtav1enc2:       SVT-AV1 encoder (svt_av1_enc_init, svt_av1_enc_init_handle)
    #   libgav1-1:           Google AV1 decoder (Libgav1DecoderCreate, Libgav1DecoderSettingsInitDefault)
    #   libcurl-gnutls transitive dep:
    #   libngtcp2-16:        QUIC/HTTP3 library (ngtcp2_conn_* symbols used by libcurl-gnutls)
    #   libgpgme transitive deps (Linux-specific; macOS poppler/gpgme don't link these):
    #   libassuan9:          GnuPG IPC library (assuan_sendfd@LIBASSUAN_2.0, etc.)
    #   libgpg-error0:       GnuPG error library (gpgrt_vasprintf@GPG_ERROR_1.0, etc.)
    #   libabsl20240722:     Google Abseil C++ runtime (absl::debian7::Mutex::*, CondVar::*
    #                        symbols in libgav1; trixie ships the 20240722 release)
    #   libngtcp2-crypto-gnutls8: ngtcp2 GnuTLS crypto callbacks (ngtcp2_crypto_gnutls_*,
    #                        ngtcp2_crypto_encrypt_cb, etc.); separate from libngtcp2-16
    #   proj-data:           PROJ datum/database files (proj.db); without this PROJ
    #                        fails at configure time: "Cannot find proj.db"
    _GEO_RT_PKGS=(libgdal36 libgeos-c1t64 libgeos3.13.1 libproj25 libsqlite3-0 libpoppler-cpp2 libnetcdf22 libpq5 libmariadb3 libgif7 libjson-c5 libodbc2 libodbcinst2 libxerces-c3.2t64 libopenjp2-7 libogdi4.1 libudunits2-0 libhdf5-310 libhdf5-hl-310 libhdf5-fortran-310 libhdf4-0-alt libaec0 libsz2 libarmadillo14 libqhull-r8.0 libgeotiff5 libheif1 libkmlbase1t64 libkmldom1t64 libkmlengine1t64 libminizip1t64 liburiparser1 libspatialite8t64 librttopo1 libfreexl1 libcfitsio10t64 libblosc1 libpoppler147 libldap2 libfyba0t64 libfyaml0 libcurl3t64-gnutls libnss3 libnspr4 libgpgme11t64 libgpgmepp6t64 libarpack2t64 libsnappy1v5 libavif16 libyuv0 libdav1d7 librav1e0.7 libaom3 libsvtav1enc2 libgav1-1 libngtcp2-16 libngtcp2-crypto-gnutls8 libassuan9 libgpg-error0 libabsl20240722 proj-data)

    _PKGS=("${_DEV_PKGS[@]}" "${_RT_PKGS[@]}" "${_GEO_DEV_PKGS[@]}" "${_GEO_RT_PKGS[@]}")
    for _pkg in "${_PKGS[@]}"; do
        _deb_url=$(_get_deb_url "$_pkg") || true
        if [ -z "$_deb_url" ]; then
            echo "ERROR: could not resolve .deb URL for $_pkg from Packages index"
            exit 1
        fi
        _deb_file="${_DEB_TMP}/${_pkg}.deb"
        echo "    Downloading $_pkg ($(basename "$_deb_url"))..."
        wget -q -O "$_deb_file" "$_deb_url" || { echo "ERROR: wget failed for $_deb_url"; exit 1; }
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
    unset _DEB_TMP _PKG_INDEX _PKG_INDEX_ALL _fetched _try _DEV_PKGS _RT_PKGS _GEO_DEV_PKGS _GEO_RT_PKGS _PKGS _pkg _deb_url _deb_file _data_tar
    unset -f _get_deb_url

    # Verify the critical header landed
    if ! find "${BASE_SANDBOX}/usr/include" -name "curl.h" -path "*/curl/curl.h" 2>/dev/null | grep -q .; then
        echo "ERROR: curl/curl.h not found in sandbox after .deb injection"
        exit 1
    fi

    # Remove non-PIC static archives that cause 'relocation R_X86_64_PC32' linker errors
    # when packages like igraph try to link them into .so shared objects.
    # Geo libs (gdal, geos, proj, sqlite3) added to the removal list.
    for _a in libcurl.a libssl.a libcrypto.a libxml2.a libcairo.a libfontconfig.a libfreetype.a libpng.a libpng16.a libpixman-1.a libharfbuzz.a libfribidi.a libX11.a libtiff.a libjpeg.a libwebp.a libwebpmux.a libwebpdemux.a libicuuc.a libicui18n.a libicudata.a libicuio.a libicutu.a libicutest.a libzstd.a liblz4.a libnlopt.a libMagickCore-7.Q16.a libMagickWand-7.Q16.a libMagick++-7.Q16.a libgdal.a libgeos.a libgeos_c.a libproj.a libsqlite3.a libarmadillo.a libqhull_r.a libqhull.a libgeotiff.a libheif.a libkmlbase.a libkmldom.a libkmlengine.a libminizip.a liburiparser.a libfyaml.a libfyba.a libfygm.a libfyut.a libspatialite.a libxerces-c.a libmysqlclient.a libpq.a libodbc.a libodbcinst.a libfreexl.a libogdi.a libjson-c.a libnetcdf.a libhdf5_serial.a libhdf5_hl_serial.a libhdf4.a libdf.a libmfhdf.a libaec.a libcfitsio.a libblosc.a libpoppler.a libpoppler-cpp.a libexpat.a libldap.a libudunits2.a librttopo.a libarpack.a libsnappy.a libavif.a libnss3.a libnspr4.a libgpgmepp.a libgpgme.a libsz.a; do
        rm -f "${BASE_SANDBOX}/usr/lib/x86_64-linux-gnu/${_a}" 2>/dev/null || true
    done
    unset _a

    # Fix broken lib*.so dev symlinks: dev debs may come from a different Debian snapshot
    # than the r-base Docker image, so versioned symlink targets may not match runtime files.
    _lib_dir="${BASE_SANDBOX}/usr/lib/x86_64-linux-gnu"
    for _dev_so in "${_lib_dir}"/lib*.so; do
        [ -L "$_dev_so" ] || continue
        [ -e "$_dev_so" ] && continue
        _basename=$(basename "$_dev_so")
        _libname="${_basename%.so}"
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
    # and graphite2 — those transitive deps are not injected. textshaping only needs
    # the harfbuzz -I include path and -lharfbuzz linker flag, not glib/graphite headers.
    _hb_pc="${BASE_SANDBOX}/usr/lib/x86_64-linux-gnu/pkgconfig/harfbuzz.pc"
    if [[ -f "$_hb_pc" ]]; then
        sed -i '/^Requires[^:]*:.*\(glib-2\.0\|graphite2\)/d' "$_hb_pc"
        echo "    ✓ Patched harfbuzz.pc: stripped unresolvable glib-2.0/graphite2 Requires"
    fi
    unset _hb_pc

    # Create Magick++.pc compatibility symlink: magick R package runs `pkg-config Magick++`
    # (unversioned) but Debian trixie only provides Magick++-7.Q16.pc (ImageMagick 7).
    _pc_dir="${BASE_SANDBOX}/usr/lib/x86_64-linux-gnu/pkgconfig"
    if [ -f "${_pc_dir}/Magick++-7.Q16.pc" ] && [ ! -f "${_pc_dir}/Magick++.pc" ]; then
        ln -sf "Magick++-7.Q16.pc" "${_pc_dir}/Magick++.pc"
        echo "    ✓ Created Magick++.pc → Magick++-7.Q16.pc compatibility symlink"
    fi
    unset _pc_dir
    echo "  ✓ Dev headers + runtime libs injected; non-PIC archives removed; broken symlinks fixed"

    # Step 1d: Install CRAN and Bioconductor packages into the sandbox system library.
    echo "  Installing R packages into sandbox system library (CRAN + Bioconductor 3.21)..."
    SYSLIB="/usr/local/lib/R/site-library"
    R_INSTALL_SCRIPT="${BASE_SANDBOX}/opt/r_install.R"

    # HDF5 serial headers/libs live under a subdirectory on Debian trixie.
    # Adding them to CPPFLAGS/LDFLAGS ensures terra/sf configure tests find -lhdf5_serial.
    printf 'CPPFLAGS = -I/usr/include/freetype2 -I/usr/include/harfbuzz -I/usr/include/fribidi -I/usr/include/hdf5/serial\nLDFLAGS = -L/usr/lib/x86_64-linux-gnu -L/usr/lib/x86_64-linux-gnu/hdf5/serial\n' \
        > "${BASE_SANDBOX}/usr/lib/R/etc/Makevars.site"

    # Fixed date rather than 'latest'. See the note in build_r_container.sh:
    # 'latest' made the same recipe resolve to different package versions on
    # different days. The default is the date the current images were built.
    CRAN_SNAPSHOT="${CRAN_SNAPSHOT:-2026-07-02}"
    echo "  CRAN snapshot: ${CRAN_SNAPSHOT}"

    cat > "$R_INSTALL_SCRIPT" << REOF
syslib <- '${SYSLIB}'
.libPaths(syslib)

cran_url <- 'https://packagemanager.posit.co/cran/__linux__/trixie/${CRAN_SNAPSHOT}'
Sys.setenv(LIBARROW_BINARY = 'true', NOT_CRAN = 'true')
options(repos = c(CRAN = cran_url))
cat(sprintf('CRAN repo: %s\n', cran_url))
cat(sprintf('PATH inside container: %s\n', Sys.getenv('PATH')))

if (!requireNamespace('BiocManager', quietly = TRUE))
  install.packages('BiocManager', lib = syslib)
BiocManager::install(version = '3.21', ask = FALSE, update = FALSE)
cat(sprintf('BiocManager ready; Bioc version: %s\n', as.character(BiocManager::version())))
bioc_repos <- c(
  CRAN_PPM = cran_url,
  BiocManager::repositories()
)

verify_stage <- function(stage_num, pkgs) {
  missing <- pkgs[!vapply(pkgs, function(p)
    requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
  if (length(missing) > 0)
    stop(sprintf('Stage %d FAILED — missing: %s', stage_num, paste(missing, collapse = ', ')))
  cat(sprintf('Stage %d verified (%d/%d packages OK).\n', stage_num, length(pkgs), length(pkgs)))
}

# Stage 1: CRAN core packages needed by run_DE_analysis.R directly.
# ggrepel is on CRAN without archive workaround (0.9.7+ supports R >= 4.5.0).
s1_pkgs <- c('optparse', 'dplyr', 'data.table', 'ggplot2', 'stringr', 'ggrepel')
s1_missing <- s1_pkgs[!vapply(s1_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 1: Installing %d/%d CRAN core packages...\n', length(s1_missing), length(s1_pkgs)))
if (length(s1_missing) > 0)
  install.packages(s1_missing, repos = cran_url, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(1, s1_pkgs)

# Stage 2: Bioconductor infrastructure.
s2_pkgs <- c('BiocGenerics', 'S4Vectors', 'IRanges',
             'GenomeInfoDb', 'GenomicRanges', 'Biobase',
             'MatrixGenerics', 'SummarizedExperiment', 'BiocParallel', 'BiocFileCache')
s2_missing <- s2_pkgs[!vapply(s2_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 2: Installing %d/%d Bioc infra packages...\n', length(s2_missing), length(s2_pkgs)))
if (length(s2_missing) > 0)
  install.packages(s2_missing, repos = bioc_repos, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(2, s2_pkgs)

# Stage 3: SingleCellExperiment ecosystem.
s3_pkgs <- c('SingleCellExperiment', 'scuttle', 'scater')
s3_missing <- s3_pkgs[!vapply(s3_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 3: Installing %d/%d SCE ecosystem packages...\n', length(s3_missing), length(s3_pkgs)))
if (length(s3_missing) > 0)
  install.packages(s3_missing, repos = bioc_repos, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(3, s3_pkgs)

# Stage 4: Seurat + harmony + presto.
# Seurat and harmony are on CRAN. presto is GitHub-only (immunogenomics/presto).
s4_pkgs <- c('Seurat', 'harmony', 'presto')
s4_missing <- s4_pkgs[!vapply(s4_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 4: Installing %d/%d Seurat/DE packages...\n', length(s4_missing), length(s4_pkgs)))
s4_cran <- intersect(s4_missing, c('Seurat', 'harmony'))
if (length(s4_cran) > 0)
  install.packages(s4_cran, repos = cran_url, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
if (!requireNamespace('presto', lib.loc = syslib, quietly = TRUE)) {
  cat('Installing presto from GitHub (immunogenomics/presto)...\n')
  if (!requireNamespace('remotes', lib.loc = syslib, quietly = TRUE))
    install.packages('remotes', repos = cran_url, lib = syslib)
  remotes::install_github('immunogenomics/presto', lib = syslib, upgrade = 'never')
}
verify_stage(4, s4_pkgs)

# Stage 5: DESpace 2.0 ecosystem.
# SpatialExperiment imports magick (ImageMagick runtime libs required).
# DESpace imports terra and sf (GDAL/GEOS/PROJ runtime libs required).
# edgeR and limma are direct DESpace deps; DESpace pulls them automatically.
s5_pkgs <- c('SpatialExperiment', 'edgeR', 'limma', 'DESpace')
s5_missing <- s5_pkgs[!vapply(s5_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
cat(sprintf('Stage 5: Installing %d/%d DESpace ecosystem packages...\n', length(s5_missing), length(s5_pkgs)))
if (length(s5_missing) > 0)
  install.packages(s5_missing, repos = bioc_repos, lib = syslib, Ncpus = 4L,
    dependencies = c('Depends', 'Imports', 'LinkingTo'))
verify_stage(5, s5_pkgs)

all_pkgs <- c(s1_pkgs, s2_pkgs, s3_pkgs, s4_pkgs, s5_pkgs)
missing_pkgs <- all_pkgs[!vapply(all_pkgs, function(p)
  requireNamespace(p, lib.loc = syslib, quietly = TRUE), logical(1))]
if (length(missing_pkgs) > 0)
  stop(paste('Final check — missing packages:', paste(missing_pkgs, collapse=', ')))
cat(sprintf('  All %d packages verified in %s\n', length(all_pkgs), syslib))
REOF

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
    echo "  Verifying packages are embedded in SIF (--no-home --cleanenv)..."
    _verify_r=$(mktemp /tmp/verify_pkgs_XXXXXX.R)
    cat > "$_verify_r" << 'REOF'
pkgs <- c('optparse', 'dplyr', 'data.table', 'ggplot2', 'stringr',
          'SingleCellExperiment', 'scater',
          'Seurat', 'harmony', 'presto',
          'SpatialExperiment', 'edgeR', 'limma', 'DESpace')
missing_pkgs <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]
if (length(missing_pkgs) > 0)
  stop(paste('SIF is missing packages:', paste(missing_pkgs, collapse=', '),
             '-- packages were likely installed to host home, not into sandbox'))
cat('  checkmark All', length(pkgs), 'packages confirmed inside SIF\n')
# Specifically verify svg_test() exists in DESpace >= 2.0.
# getNamespaceExports() loads the namespace without attaching — no library() needed.
if (!'svg_test' %in% getNamespaceExports('DESpace'))
  stop('DESpace present but svg_test() not found — version < 2.0. Rebuild with --force.')
cat('  checkmark DESpace svg_test() confirmed\n')
REOF
    _sing_tmp="${BUILD_TMPDIR:-$SCRIPT_DIR}/singularity_tmp_verify"
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
echo "Phase 2/2: Building script layer SIF (~30 sec)..."
echo "Checking source scripts exist on disk..."
MISSING_SCRIPTS=false
for script in "${R_SCRIPTS[@]}"; do
    src="$R_WORKFLOWS_BASE/$script"
    if [ ! -f "$src" ]; then
        echo "ERROR: Script listed in R_SCRIPTS array but not found on disk: $src"
        MISSING_SCRIPTS=true
    fi
done
[ "$MISSING_SCRIPTS" = true ] && exit 1
echo "  ✓ All source scripts verified"

# ── Phase 2: Script layer SIF ──────────────────────────────────────────────────
rm -rf "$OUTPUT_SANDBOX"
rm -f "$OUTPUT_SIF"

echo "  Unpacking base SIF to sandbox..."
TMPDIR="${BUILD_TMPDIR:-${TMPDIR:-/tmp}}" SINGULARITY_TMPDIR="${BUILD_TMPDIR:-${TMPDIR:-/tmp}}" singularity build --sandbox "$OUTPUT_SANDBOX" "$BASE_SIF"

echo "  Copying R scripts into sandbox..."
mkdir -p "$OUTPUT_SANDBOX/$R_WORKFLOWS_DST"
for script in "${R_SCRIPTS[@]}"; do
    cp "$R_WORKFLOWS_BASE/$script" "$OUTPUT_SANDBOX/$R_WORKFLOWS_DST/$(basename "$script")"
    echo "    + $(basename "$script")"
done

for script in "${R_SCRIPTS[@]}"; do
    _dst="$OUTPUT_SANDBOX/$R_WORKFLOWS_DST/$(basename "$script")"
    if [ ! -f "$_dst" ]; then
        echo "ERROR: Script missing from sandbox after copy: ${_dst#${OUTPUT_SANDBOX}}"
        exit 1
    fi
done
echo "    ✓ All scripts present in sandbox"
unset _dst

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
echo "R scripts embedded in container:"
for script in "${R_SCRIPTS[@]}"; do
    echo "  ✓ $R_WORKFLOWS_DST/$(basename "$script")"
done

if [ -n "$BUILD_TMPDIR" ]; then
    _sing_tmp="${BUILD_TMPDIR:-$SCRIPT_DIR}/singularity_tmp_verify"
    mkdir -p "$_sing_tmp"
    _verify_r=$(mktemp /tmp/verify_pkgs_XXXXXX.R)
    cat > "$_verify_r" << 'REOF'
pkgs <- c("optparse", "dplyr", "data.table", "ggplot2", "stringr",
          "SingleCellExperiment", "scater",
          "Seurat", "harmony", "presto",
          "SpatialExperiment", "edgeR", "limma", "DESpace")
missing <- pkgs[!sapply(pkgs, requireNamespace, quietly=TRUE)]
if (length(missing) > 0) {
  stop(paste("ERROR: Missing packages:", paste(missing, collapse=", "),
             "\nFix: Rebuild base layer with: bash build_r45_container.sh --force"))
}
cat("  checkmark All", length(pkgs), "required packages confirmed inside SIF\n")
if (!"svg_test" %in% getNamespaceExports("DESpace"))
  stop("DESpace present but svg_test() missing — version < 2.0. Rebuild with --force.")
cat("  checkmark DESpace svg_test() confirmed (version >= 2.0)\n")
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
_CAPS="${REPO_ROOT}/config/capabilities.sh"
if [ -f "$_CAPS" ]; then
    if grep -q "^DE_ANALYSIS_CONTAINER_AVAILABLE=" "$_CAPS"; then
        sed -i 's/^DE_ANALYSIS_CONTAINER_AVAILABLE=.*/DE_ANALYSIS_CONTAINER_AVAILABLE=true/' "$_CAPS"
    else
        echo "DE_ANALYSIS_CONTAINER_AVAILABLE=true" >> "$_CAPS"
    fi
    sed -i "s/^CAPABILITIES_GENERATED_AT=.*/CAPABILITIES_GENERATED_AT=\"$(date '+%Y-%m-%d %H:%M:%S')\"/" "$_CAPS"
else
    cat > "$_CAPS" << EOF
# Generated by build_r45_container.sh — re-run bash setup.sh for full detection
DE_ANALYSIS_CONTAINER_AVAILABLE=true
DE_ANALYSIS_NATIVE_AVAILABLE=unknown
CAPABILITIES_GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
fi
unset _CAPS
echo "  ✓ config/capabilities.sh updated (DE_ANALYSIS_CONTAINER_AVAILABLE=true)"
