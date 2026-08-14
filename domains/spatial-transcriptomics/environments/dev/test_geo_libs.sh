#!/bin/bash
set -e

# test_geo_libs.sh — Isolated test for geo lib deb injection + terra/sf compilation.
#
# Replicates exactly the deb injection and R package install steps from
# build_r45_container.sh, but installs ONLY terra and sf (plus their direct
# R package dependencies). Skips Stages 1–4 (~60 min) to give a fast feedback
# loop (~20–30 min) when debugging geo lib issues.
#
# Usage:
#   bash test_geo_libs.sh --scratch <dir>
#   bash test_geo_libs.sh --scratch <dir> --nohup
#   bash test_geo_libs.sh --scratch <dir> --keep-sandbox

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

_HPC_PROFILE="${REPO_ROOT}/config/hpc_profile.sh"
[[ -f "$_HPC_PROFILE" ]] || _HPC_PROFILE="${_HPC_PROFILE}.example"
# shellcheck disable=SC1090
source "$_HPC_PROFILE" && unset _HPC_PROFILE

hpc_module_load MODULE_SINGULARITY

if ! command -v singularity &>/dev/null; then
    echo "ERROR: singularity not found after module load."
    exit 1
fi

SCRATCH=""
RUN_NOHUP=false
KEEP_SANDBOX=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scratch)      SCRATCH="$2"; shift 2 ;;
        --nohup)        RUN_NOHUP=true; shift ;;
        --keep-sandbox) KEEP_SANDBOX=true; shift ;;
        --help|-h)
            echo "Usage: bash test_geo_libs.sh --scratch <dir> [--nohup] [--keep-sandbox]"
            echo ""
            echo "  --scratch <dir>   Scratch directory with execute permissions (required)."
            echo "  --nohup           Run in background; output written to test_geo_libs_<ts>.log."
            echo "  --keep-sandbox    Do not delete sandbox after test (useful for inspection)."
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$SCRATCH" ]; then
    echo "ERROR: --scratch <dir> is required."
    echo "  Example: bash test_geo_libs.sh --scratch /scratch/\$USER/tmp"
    exit 1
fi

# ── nohup self-relaunch ───────────────────────────────────────────────────────
if [ "$RUN_NOHUP" = true ]; then
    _FORWARD_ARGS=(--scratch "$SCRATCH")
    [ "$KEEP_SANDBOX" = true ] && _FORWARD_ARGS+=(--keep-sandbox)
    _LOG="${SCRIPT_DIR}/test_geo_libs_$(date '+%Y%m%d_%H%M%S').log"
    nohup bash "${BASH_SOURCE[0]}" "${_FORWARD_ARGS[@]}" > "$_LOG" 2>&1 &
    echo "Test launched in background (PID $!)"
    echo "Log: $_LOG"
    echo "Monitor: tail -f $_LOG"
    exit 0
fi

# ── Log file ──────────────────────────────────────────────────────────────────
_TEST_LOG="${SCRIPT_DIR}/test_geo_libs_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee "$_TEST_LOG") 2>&1
echo "Full test log: $_TEST_LOG"

mkdir -p "$SCRATCH"
SANDBOX="${SCRATCH}/test_geo_libs_sandbox"

echo "========================================"
echo "Geo Libs Test: terra + sf compilation"
echo "  Base image: r-base:4.5.0 (Debian trixie)"
echo "  Sandbox:    $SANDBOX"
echo "========================================"
echo ""

# ── Step 1: Pull r-base sandbox ───────────────────────────────────────────────
if [ -d "$SANDBOX" ]; then
    echo "Reusing existing sandbox: $SANDBOX"
    echo "(Delete it manually to re-pull the Docker image)"
else
    echo "Pulling r-base:4.5.0 from Docker Hub..."
    SINGULARITY_TMPDIR="$SCRATCH" singularity build --sandbox "$SANDBOX" docker://r-base:4.5.0
    echo "✓ Sandbox created"
fi
echo ""

mkdir -p "$SANDBOX/etc"
touch "$SANDBOX/etc/resolv.conf"

# ── Step 2: Deb injection ─────────────────────────────────────────────────────
echo "Injecting system lib debs..."

_DEB_TMP=$(mktemp -d)
_PKG_INDEX="${_DEB_TMP}/Packages"
_PKG_INDEX_ALL="${_DEB_TMP}/Packages-all"

# Cache indexes in scratch to avoid re-downloading on repeat runs.
_INDEX_CACHE="${SCRATCH}/debian_indexes/trixie"
mkdir -p "$_INDEX_CACHE"

if [ -f "${_INDEX_CACHE}/Packages" ] && [ -f "${_INDEX_CACHE}/Packages-all" ]; then
    echo "  Using cached trixie Packages.gz indexes from ${_INDEX_CACHE}"
    cp "${_INDEX_CACHE}/Packages"     "$_PKG_INDEX"
    cp "${_INDEX_CACHE}/Packages-all" "$_PKG_INDEX_ALL"
else
    echo "  Fetching trixie Packages.gz indexes..."
    _fetched=0
    for _try in 1 2 3; do
        wget -q -O "${_PKG_INDEX}.gz" \
            "https://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.gz" 2>/dev/null \
            && gunzip -f "${_PKG_INDEX}.gz" && _fetched=1 && break
        echo "  [retry ${_try}/3] amd64 Packages.gz failed, retrying in 10s..." >&2; sleep 10
    done
    [ "$_fetched" -eq 0 ] && { echo "ERROR: could not download amd64 Packages.gz"; exit 1; }
    _fetched=0
    for _try in 1 2 3; do
        wget -q -O "${_PKG_INDEX_ALL}.gz" \
            "https://deb.debian.org/debian/dists/trixie/main/binary-all/Packages.gz" 2>/dev/null \
            && gunzip -f "${_PKG_INDEX_ALL}.gz" && _fetched=1 && break
        echo "  [retry ${_try}/3] binary-all Packages.gz failed, retrying in 10s..." >&2; sleep 10
    done
    [ "$_fetched" -eq 0 ] && { echo "ERROR: could not download binary-all Packages.gz"; exit 1; }
    cp "$_PKG_INDEX"     "${_INDEX_CACHE}/Packages"
    cp "$_PKG_INDEX_ALL" "${_INDEX_CACHE}/Packages-all"
    echo "  ✓ Indexes cached at ${_INDEX_CACHE}"
fi

_get_deb_url() {
    local _rel
    _rel=$(awk -v pkg="$1" '
        /^Package: / { in_block = ($2 == pkg) }
        in_block && /^Filename: / { print $2; exit }
    ' "$_PKG_INDEX" "$_PKG_INDEX_ALL")
    [ -n "$_rel" ] && echo "https://deb.debian.org/debian/${_rel}"
}

# Same package lists as build_r45_container.sh — injecting all debs replicates
# the exact sandbox state that terra/sf will compile against.
_DEV_PKGS=(libcurl4-openssl-dev libssl-dev libxml2-dev libcairo2-dev libpixman-1-dev libx11-dev x11proto-dev libfontconfig-dev libfreetype-dev libpng-dev libharfbuzz-dev libfribidi-dev libtiff-dev libjpeg-dev libwebp-dev libicu-dev libzstd-dev liblz4-dev cmake cmake-data libnlopt-dev libmagickcore-7.q16-dev libmagickwand-7.q16-dev libmagick++-7.q16-dev libmagickcore-7-arch-config libmagickcore-7-headers libmagickwand-7-headers libmagick++-7-headers)

_RT_PKGS=(libxml2 libwebpmux3 libwebpdemux2 librhash1 libjsoncpp26 libuv1t64 libnlopt0 libicu76 libarchive13t64 libmagickcore-7.q16-10 libmagickwand-7.q16-10 libmagick++-7.q16-5 liblcms2-2 liblqr-1-0 libfftw3-double3 libltdl7)

_GEO_DEV_PKGS=(libgdal-dev libgeos-dev libproj-dev libsqlite3-dev libudunits2-dev libarmadillo-dev libqhull-dev libgeotiff-dev libheif-dev libkml-dev libminizip-dev liburiparser-dev libfyaml-dev libfyba-dev libspatialite-dev libxerces-c-dev libmariadb-dev libmariadb-dev-compat libpq-dev unixodbc-dev libfreexl-dev libogdi-dev libjson-c-dev libnetcdf-dev libhdf5-dev libhdf4-alt-dev libaec-dev libcfitsio-dev libblosc-dev libgif-dev libopenjp2-7-dev libpoppler-dev libpoppler-cpp-dev libexpat1-dev libldap-dev libarpack2-dev libsnappy-dev libavif-dev librttopo-dev libnss3-dev libgpgmepp-dev)

_GEO_RT_PKGS=(libgdal36 libgeos-c1t64 libgeos3.13.1 libproj25 libsqlite3-0 libpoppler-cpp2 libnetcdf22 libpq5 libmariadb3 libgif7 libjson-c5 libodbc2 libodbcinst2 libxerces-c3.2t64 libopenjp2-7 libogdi4.1 libudunits2-0 libhdf5-310 libhdf5-hl-310 libhdf5-fortran-310 libhdf4-0-alt libaec0 libsz2 libarmadillo14 libqhull-r8.0 libgeotiff5 libheif1 libkmlbase1t64 libkmldom1t64 libkmlengine1t64 libminizip1t64 liburiparser1 libspatialite8t64 librttopo1 libfreexl1 libcfitsio10t64 libblosc1 libpoppler147 libldap2 libfyba0t64 libfyaml0 libcurl3t64-gnutls libnss3 libnspr4 libgpgme11t64 libgpgmepp6t64 libarpack2t64 libsnappy1v5 libavif16 libyuv0 libdav1d7 librav1e0.7 libaom3 libsvtav1enc2 libgav1-1 libngtcp2-16 libngtcp2-crypto-gnutls8 libassuan9 libgpg-error0 libabsl20240722 proj-data)

_PKGS=("${_DEV_PKGS[@]}" "${_RT_PKGS[@]}" "${_GEO_DEV_PKGS[@]}" "${_GEO_RT_PKGS[@]}")

echo "  Resolving and downloading ${#_PKGS[@]} packages..."
for _pkg in "${_PKGS[@]}"; do
    _deb_url=$(_get_deb_url "$_pkg") || true
    if [ -z "$_deb_url" ]; then
        echo "ERROR: could not resolve .deb URL for $_pkg from Packages index"
        exit 1
    fi
    _deb_file="${_DEB_TMP}/${_pkg}.deb"
    wget -q -O "$_deb_file" "$_deb_url" || { echo "ERROR: wget failed for $_deb_url"; exit 1; }
    ( cd "$_DEB_TMP" && ar x "${_pkg}.deb" )
    _data_tar=$(ls "${_DEB_TMP}"/data.tar.* 2>/dev/null | head -1)
    [ -z "$_data_tar" ] && { echo "ERROR: no data.tar.* in ${_pkg}.deb"; exit 1; }
    tar -xf "$_data_tar" -C "$SANDBOX" "./usr/include" "./usr/lib" "./usr/bin" "./usr/share" 2>/dev/null || true
    rm -f "${_DEB_TMP}"/data.tar.* "${_DEB_TMP}"/control.tar.* "${_DEB_TMP}"/debian-binary "$_deb_file"
    echo "  ✓ ${_pkg}"
done
rm -rf "$_DEB_TMP"
unset _DEB_TMP _PKG_INDEX _PKG_INDEX_ALL _PKGS _pkg _deb_url _deb_file _data_tar _fetched _try
unset -f _get_deb_url

# Remove non-PIC static archives (same list as build_r45_container.sh)
_lib_dir="${SANDBOX}/usr/lib/x86_64-linux-gnu"
for _a in libcurl.a libssl.a libcrypto.a libxml2.a libcairo.a libfontconfig.a libfreetype.a libpng.a libpng16.a libpixman-1.a libharfbuzz.a libfribidi.a libX11.a libtiff.a libjpeg.a libwebp.a libwebpmux.a libwebpdemux.a libicuuc.a libicui18n.a libicudata.a libicuio.a libicutu.a libicutest.a libzstd.a liblz4.a libnlopt.a libMagickCore-7.Q16.a libMagickWand-7.Q16.a libMagick++-7.Q16.a libgdal.a libgeos.a libgeos_c.a libproj.a libsqlite3.a libarmadillo.a libqhull_r.a libqhull.a libgeotiff.a libheif.a libkmlbase.a libkmldom.a libkmlengine.a libminizip.a liburiparser.a libfyaml.a libfyba.a libfygm.a libfyut.a libspatialite.a libxerces-c.a libmysqlclient.a libpq.a libodbc.a libodbcinst.a libfreexl.a libogdi.a libjson-c.a libnetcdf.a libhdf5_serial.a libhdf5_hl_serial.a libhdf4.a libdf.a libmfhdf.a libaec.a libcfitsio.a libblosc.a libpoppler.a libpoppler-cpp.a libexpat.a libldap.a libudunits2.a librttopo.a libarpack.a libsnappy.a libavif.a libnss3.a libnspr4.a libgpgmepp.a libgpgme.a libsz.a; do
    rm -f "${_lib_dir}/${_a}" 2>/dev/null || true
done

# Fix broken lib*.so dev symlinks
for _dev_so in "${_lib_dir}"/lib*.so; do
    [ -L "$_dev_so" ] || continue
    [ -e "$_dev_so" ] && continue
    _basename=$(basename "$_dev_so")
    _libname="${_basename%.so}"
    _soname=$(find "$_lib_dir" -maxdepth 1 -name "${_libname}.so.*" 2>/dev/null \
        | grep -E "\\.so\\.[0-9]+$" | sort -V | tail -1)
    if [ -n "$_soname" ]; then
        ln -sf "$(basename "$_soname")" "$_dev_so"
        echo "  ✓ Fixed broken symlink: ${_basename} → $(basename "$_soname")"
    fi
done
unset _lib_dir _a _dev_so _basename _libname _soname

# Patch harfbuzz.pc
_hb_pc="${SANDBOX}/usr/lib/x86_64-linux-gnu/pkgconfig/harfbuzz.pc"
[[ -f "$_hb_pc" ]] && sed -i '/^Requires[^:]*:.*\(glib-2\.0\|graphite2\)/d' "$_hb_pc"
unset _hb_pc

# Magick++.pc compatibility symlink
_pc_dir="${SANDBOX}/usr/lib/x86_64-linux-gnu/pkgconfig"
[ -f "${_pc_dir}/Magick++-7.Q16.pc" ] && [ ! -f "${_pc_dir}/Magick++.pc" ] \
    && ln -sf "Magick++-7.Q16.pc" "${_pc_dir}/Magick++.pc"
unset _pc_dir

echo "✓ Deb injection complete"
echo ""

# ── Step 3: Makevars.site (HDF5 serial paths) ─────────────────────────────────
printf 'CPPFLAGS = -I/usr/include/freetype2 -I/usr/include/harfbuzz -I/usr/include/fribidi -I/usr/include/hdf5/serial\nLDFLAGS = -L/usr/lib/x86_64-linux-gnu -L/usr/lib/x86_64-linux-gnu/hdf5/serial\n' \
    > "${SANDBOX}/usr/lib/R/etc/Makevars.site"

# ── Step 4: Install terra + sf only ──────────────────────────────────────────
echo "Installing terra and sf (+ auto-resolved R deps)..."
SYSLIB="/usr/local/lib/R/site-library"
_INSTALL_R="${SANDBOX}/opt/test_install.R"
mkdir -p "${SANDBOX}/opt"

# Create the scratch mount point inside the sandbox so the -B bind works.
mkdir -p "${SANDBOX}${SCRATCH}"

cat > "$_INSTALL_R" << 'REOF'
syslib <- '/usr/local/lib/R/site-library'
.libPaths(syslib)

cran_url <- 'https://packagemanager.posit.co/cran/__linux__/trixie/latest'
options(repos = c(CRAN = cran_url))
cat(sprintf('CRAN repo: %s\n', cran_url))

pkgs <- c('terra', 'sf')
cat(sprintf('Installing: %s\n', paste(pkgs, collapse=', ')))
install.packages(pkgs, lib = syslib, dependencies = TRUE)

cat('\n--- Verification ---\n')
ok <- TRUE
for (pkg in pkgs) {
    if (requireNamespace(pkg, lib.loc = syslib, quietly = TRUE)) {
        cat(sprintf('  PASS  library(%s)\n', pkg))
    } else {
        cat(sprintf('  FAIL  library(%s)\n', pkg))
        ok <- FALSE
    }
}
if (!ok) stop('One or more packages failed to load.')
cat('\nAll packages verified.\n')
REOF

SINGULARITY_TMPDIR="$SCRATCH" \
    singularity exec --writable --no-home --cleanenv \
    -B /etc/resolv.conf \
    -B "${SCRATCH}:${SCRATCH}" \
    "$SANDBOX" \
    bash -c '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/tmp
export TMPDIR='"$SCRATCH"'
export PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig
export R_LIBS_SITE='"$SYSLIB"'
export R_LIBS_USER='"$SYSLIB"'
export R_MAKEVARS_USER=/dev/null
Rscript /opt/test_install.R'

echo ""
echo "========================================"
echo "TEST PASSED — terra and sf installed and loaded successfully"
echo "========================================"

# ── Cleanup ───────────────────────────────────────────────────────────────────
if [ "$KEEP_SANDBOX" = false ]; then
    echo "Removing sandbox (use --keep-sandbox to retain it)..."
    chmod -R u+w "$SANDBOX" && rm -rf "$SANDBOX"
fi

echo "Log: $_TEST_LOG"
