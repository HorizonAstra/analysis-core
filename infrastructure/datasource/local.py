"""LocalSource: studies as per-study folders on local disk, served through the
Parquet/DuckDB read engine (tables.py).

This module owns the *physical* knowledge — which folders are studies, which file fills
which role, how to read an arbitrary raw file safely. The engine's study assembler
(analysis/domains/*/study.py) sits on top and stays purely about domain shaping.

Studies live at `data/<domain>/<study>/` (see domains.py). The study name remains the
identifier used by allowlists and provenance, so nothing outside this module had to
learn about domains; a study folder still sitting directly under `data/` is recognized
too, which is what makes migrating the tree safe.
"""

from __future__ import annotations

import json
import os

import pandas as pd

from . import domains
from .base import DataSource
from .tables import read_tabular

def allowed_studies() -> set[str] | None:
    """Per-process study allowlist from the ALLOWED_STUDIES env var (comma-separated).

    This is how access control is enforced without copying data: each user's MCP server
    runs with its own ALLOWED_STUDIES, so the data layer itself refuses studies the user
    can't see — the model never even learns they exist. Read from the live environment on
    every call, so a front end can also narrow the working set mid-session.

    The convention, and the empty case matters:
      unset          -> unrestricted (None)
      "*" / "all"    -> unrestricted (None)
      anything else  -> exactly that set, and an EMPTY value is the empty set, not a
                        wildcard. A user with no studies, or a scope that intersects to
                        nothing, must resolve to no access rather than all access; an
                        allowlist that is present and empty allows nothing.
    """
    v = os.environ.get("ALLOWED_STUDIES")
    if v is None or v.strip().lower() in ("*", "all"):
        return None
    return {s.strip() for s in v.split(",") if s.strip()}


def allowed_domains() -> set[str] | None:
    """Per-process domain allowlist from ALLOWED_DOMAINS, same convention as
    ALLOWED_STUDIES: unset or "*"/"all" is unrestricted, and a present-but-empty value
    allows nothing. Domain and study allowlists are independent gates — a study must
    pass both.
    """
    v = os.environ.get("ALLOWED_DOMAINS")
    if v is None or v.strip().lower() in ("*", "all"):
        return None
    return {s.strip() for s in v.split(",") if s.strip()}


def domain_allowed(domain: str | None) -> bool:
    """Whether a caller may reach a domain.

    The gate is about data. A domain that holds none is not gated by it: nothing
    it offers can reveal a study, because everything it offers works on a table
    it is handed. Applying the data rule to those as well took charting and
    general statistics away from every scoped person, which protected nothing
    and left them unable to plot what they were already allowed to compute.
    """
    allow = allowed_domains()
    if allow is None:
        return True
    if domain is None:
        return False
    if domain in allow:
        return True
    spec = domains.spec(domain)
    return spec is None or not spec.datasets


def study_allowed(study: str) -> bool:
    allow = allowed_studies()
    return allow is None or os.path.basename(str(study).rstrip("/\\")) in allow


def _scan(data_root: str) -> dict[str, dict]:
    """Every study under a data root, as name -> {"domain", "dir"}.

    Two shapes are accepted: `data/<domain>/<study>/`, and a study sitting directly at
    `data/<study>/`, whose domain is worked out from its own shape. Study
    names are the system-wide identifier, so a name appearing in two domains is a
    collision; the first by domain order wins and the loser is recorded in `_collisions`
    for callers that want to surface it.
    """
    root = os.path.abspath(data_root)
    found: dict[str, dict] = {}
    collisions: list[tuple[str, str, str]] = []
    if not os.path.isdir(root):
        return found

    def claim(name: str, domain: str, path: str) -> None:
        prior = found.get(name)
        if prior is not None:
            collisions.append((name, prior["domain"], domain))
            return
        found[name] = {"domain": domain, "dir": path}

    for entry in sorted(os.listdir(root)):
        if entry.startswith("."):
            continue
        path = os.path.join(root, entry)
        if not os.path.isdir(path):
            continue
        # A study directly under data/: the pre-domain layout.
        direct = domains.detect_domain(path)
        if direct is not None:
            claim(entry, direct, path)
            continue
        # Otherwise treat it as a domain folder and look one level deeper.
        for sub in sorted(os.listdir(path)):
            if sub.startswith("."):
                continue
            sdir = os.path.join(path, sub)
            if not os.path.isdir(sdir):
                continue
            # Inside a known domain folder, that domain wins over content sniffing, so a
            # sparse study is still read with its own domain's roles.
            dom = entry if entry in domains.DOMAINS else domains.detect_domain(sdir)
            if dom is None or not domains.is_study(sdir, dom):
                continue
            claim(sub, dom, sdir)

    found["_collisions"] = collisions  # type: ignore[assignment]
    return found


def scan_studies(data_root: str = "data") -> dict[str, dict]:
    """name -> {"domain", "dir"} for every study on disk, ignoring allowlists."""
    out = dict(_scan(data_root))
    out.pop("_collisions", None)
    return out


def study_collisions(data_root: str = "data") -> list[tuple[str, str, str]]:
    """Study names claimed by more than one domain, as (name, kept, dropped).

    Study names are the identifier used by allowlists and provenance paths, so a
    collision is a real ambiguity rather than something to resolve silently. Empty is
    the healthy case.
    """
    return list(_scan(data_root).get("_collisions", []))  # type: ignore[arg-type]


def study_domain(study: str, data_root: str = "data") -> str | None:
    """The domain a study belongs to, or None if it is not on disk."""
    rec = scan_studies(data_root).get(os.path.basename(str(study).rstrip("/\\")))
    return rec["domain"] if rec else None


def find_domains(data_root: str = "data") -> list[str]:
    """Domains that actually hold at least one visible study."""
    return sorted({rec["domain"] for name, rec in scan_studies(data_root).items()
                   if domain_allowed(rec["domain"]) and study_allowed(name)})


def resolve_study_dir(study: str, data_root: str) -> str:
    """The folder for a study. Accepts a bare study name (searched across domains), a
    "<domain>/<study>" path, or an absolute path."""
    if os.path.isdir(study):
        return os.path.abspath(study)
    name = os.path.basename(str(study).rstrip("/\\"))
    rec = scan_studies(data_root).get(name)
    if rec is not None:
        return rec["dir"]
    # Not on disk: fall back to the literal join so callers still get a usable path to
    # report in an error.
    return os.path.abspath(os.path.join(data_root, study))


def resolve_files(study_dir: str, domain: str | None = None) -> dict:
    """Map each role to its file, for whichever roles are present. Missing roles are
    simply omitted; nothing is required. Hidden files and the .cache sidecar are skipped.

    The role set depends on the domain. When it is not given it is detected from the
    folder's contents, which keeps every existing single-argument caller working.
    """
    dom = domain or domains.detect_domain(study_dir)
    return domains.match_roles(study_dir, dom) if dom else {}


def fingerprint(study_dir: str) -> tuple:
    """A cache key for the assembled study: the role files and their mtimes."""
    return tuple((r, os.path.getmtime(p)) for r, p in sorted(resolve_files(study_dir).items()))


def find_studies(data_root: str = "data") -> list[str]:
    """Visible study names, across every domain. Both allowlists apply."""
    return sorted(
        name for name, rec in scan_studies(data_root).items()
        if domain_allowed(rec["domain"]) and study_allowed(name)
    )


class LocalSource(DataSource):
    """A DataSource over `data_root/<domain>/<study>/` folders."""

    def __init__(self, data_root: str = "data"):
        self.data_root = os.path.abspath(data_root)

    # -- discovery -----------------------------------------------------------
    def list_studies(self) -> list[str]:
        return find_studies(self.data_root)

    def list_domains(self) -> list[str]:
        return find_domains(self.data_root)

    def domain_of(self, study: str) -> str | None:
        return study_domain(study, self.data_root)

    def _visible(self, study: str) -> bool:
        """Both gates: the study allowlist and the domain allowlist."""
        return study_allowed(study) and domain_allowed(study_domain(study, self.data_root))

    def has_study(self, study: str) -> bool:
        d = resolve_study_dir(study, self.data_root)
        return self._visible(study) and os.path.isdir(d) and bool(resolve_files(d))

    def local_dir(self, study: str) -> str | None:
        d = resolve_study_dir(study, self.data_root)
        return d if (self._visible(study) and os.path.isdir(d)) else None

    def table_roles(self, study: str) -> dict[str, str]:
        d = resolve_study_dir(study, self.data_root)
        return resolve_files(d, study_domain(study, self.data_root))

    # -- recognized tables ---------------------------------------------------
    def read_table(self, study: str, role: str, *, columns=None, where=None) -> pd.DataFrame:
        if not self._visible(study):
            raise FileNotFoundError(f"study '{study}' not found")
        files = self.table_roles(study)
        if role not in files:
            raise KeyError(f"study '{study}' has no '{role}' table (present: {sorted(files)})")
        return read_tabular(files[role], columns=columns, where=where)

    # -- arbitrary raw files -------------------------------------------------
    def list_files(self, study: str) -> list[dict]:
        if not self._visible(study):
            raise FileNotFoundError(f"study '{study}' not found")
        sdir = resolve_study_dir(study, self.data_root)
        if not os.path.isdir(sdir):
            raise FileNotFoundError(f"study folder not found: {sdir}")
        role_by_path = {os.path.abspath(p): r for r, p in resolve_files(sdir).items()}
        files = []
        for name in sorted(os.listdir(sdir)):
            p = os.path.join(sdir, name)
            if not os.path.isfile(p) or name.startswith("."):
                continue
            files.append({"file": name, "role": role_by_path.get(os.path.abspath(p)),
                          "bytes": os.path.getsize(p)})
        return files

    def read_file(self, study: str, filename: str, *, as_text: bool = False, columns=None):
        if not self._visible(study):
            raise FileNotFoundError(f"study '{study}' not found")
        sdir = resolve_study_dir(study, self.data_root)
        base = os.path.realpath(sdir)
        target = os.path.realpath(os.path.join(base, filename))
        if base != os.path.commonpath([base, target]):
            raise ValueError(f"path '{filename}' escapes the study folder")
        if not os.path.isfile(target):
            raise FileNotFoundError(f"file '{filename}' not found in study '{study}'")
        ext = os.path.splitext(target)[1].lower()
        if as_text:
            with open(target, errors="replace") as f:
                return f.read()
        if ext in (".csv", ".tsv", ".tab"):
            return read_tabular(target, columns=columns)
        if ext == ".json":
            with open(target) as f:
                return json.load(f)
        with open(target, errors="replace") as f:
            return f.read()
