#!/usr/bin/env bash
# Which reference data this domain's pipeline needs, by version.
#
# This file used to also say where those databases sit on one cluster, and where
# to put a package cache to stay off that cluster's home quota. Those are
# properties of a machine, so they now come from the site file as ANALYSIS_*
# variables and a second machine costs nothing here.
#
# The values below are scientific: which marker set was used decides which
# organisms can be detected at all, so changing one changes the answers.

: "${ANALYSIS_REF_MICROBIOME_DATABASES:?the site must say where shared databases live}"

# COMPAT (vJun23): the newest database HUMAnN 3.9 can consume. A full run pins it
#   so that MetaPhlAn profiling, HUMAnN and StrainPhlAn all agree on one database.
#   The name is compat rather than humann because StrainPhlAn's markers have to
#   match the profiling database too. It is also the MetaPhlAn package default,
#   which is what StrainPhlAn reads.
# LATEST (vJan25): newer SGB markers, for taxonomy-only runs, which drop HUMAnN
#   and StrainPhlAn and so carry neither compatibility constraint.
#
# Hard-set rather than ${VAR:-...} on purpose: sbatch --export=ALL passes the
# submitting shell's environment into the job, and a stale index would otherwise
# leak in and win.
export MPA_INDEX_COMPAT="mpa_vJun23_CHOCOPhlAnSGB_202403"
export MPA_INDEX_LATEST="mpa_vJan25_CHOCOPhlAnSGB_202503"

# Shared database directories are named for the index they hold.
export MPA_DB_DIR_COMPAT="$ANALYSIS_REF_MICROBIOME_DATABASES/metaphlan/$MPA_INDEX_COMPAT"
export MPA_DB_DIR_LATEST="$ANALYSIS_REF_MICROBIOME_DATABASES/metaphlan/$MPA_INDEX_LATEST"
export MPA_INDEX="$MPA_INDEX_COMPAT"

# biobakery_workflows checks for the host genome at startup; even --help fails
# without it. It lives with this domain's other reference links.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export BIOBAKERY_WORKFLOWS_DATABASES="$HERE/reference"
export KNEADDATA_DB_HUMAN_GENOME="$HERE/reference/kneaddata_hg39"

[ -n "${ANALYSIS_REF_CONDA_PKGS:-}" ] && export CONDA_PKGS_DIRS="$ANALYSIS_REF_CONDA_PKGS"
