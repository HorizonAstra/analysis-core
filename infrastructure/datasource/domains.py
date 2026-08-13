"""Which families of study data exist, and how to recognise one on disk.

A domain is a data shape here: which files fill which role, and whether the study
is one wide table or a tree of samples. Everything that has to know "what kind of
study is this" keys off it.

Nothing in this file knows what any of those shapes are. Each domain declares its
own in `domains/<name>/study.json`, beside its catalog, and this reads them. That
is the same arrangement as the catalog itself: a domain describes itself and
infrastructure runs on the description, so adding a domain adds a file here and
changes no code.

A domain that holds no study data of its own, such as statistics or
visualization, simply has no such file. It works on tables it is handed.

Physical layout is `<data root>/<domain>/<study>/`. The study name stays the
identifier everywhere else, and the domain is metadata carried alongside it.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

_DOMAINS_DIR = Path(__file__).resolve().parents[2] / "domains"


@dataclass(frozen=True)
class DatasetSpec:
    """One shape a domain's data comes in.

    A domain has more than one, and that is the whole point. Spatial data exists
    as a Space Ranger run, as harmonised samples, and as a study of finished
    per-sample results — the same science at three stages, in three layouts,
    with the output of one stage being the input of the next. A declaration that
    described only one of them could not recognise the other two, and discovery
    would report a folder full of data as nothing at all.

    id          what this shape is called, reported so a caller knows what it found.
    roles       role name -> filename keywords, matched case-insensitively as
                substrings, so any prefix convention works. A role may name a
                directory as well as a file.
    extensions  file extensions eligible for role matching.
    sample_dir  where per-sample folders live: "" for none, a name for a subfolder,
                "." when the children of the directory are themselves the samples.
    requires    the roles that must be present for a folder to be this shape. Empty
                means any single role is enough, which is the older, looser rule.
    """

    id: str = "study"
    roles: dict[str, tuple[str, ...]] = field(default_factory=dict)
    extensions: tuple[str, ...] = (".csv",)
    sample_dir: str = ""
    requires: tuple[str, ...] = ()
    label: str = ""
    notes: str = ""

    @classmethod
    def read(cls, d: dict) -> "DatasetSpec":
        return cls(
            id=d.get("id", "study"),
            roles={k: tuple(v) for k, v in (d.get("roles") or {}).items()},
            extensions=tuple(d.get("extensions") or (".csv",)),
            sample_dir=d.get("sample_dir", ""),
            requires=tuple(d.get("requires") or ()),
            label=d.get("label", ""),
            notes=d.get("notes", ""),
        )


@dataclass(frozen=True)
class DomainSpec:
    """What the data layer needs to know about one domain.

    datasets    the shapes this domain's data comes in, most specific first.
    label       human-readable name for the UI.
    notes       one line describing the *data*, shown to the user when they pick a
                domain. Keep it about the science, not about file layout.
    input_label what to call this domain's data where it is shown beside the
                results computed from it. Declared here because only the domain
                knows it: to the people using this one, the thing every analysis
                starts from is the Space Ranger run, and calling that column
                "Data" made them look for a column that was already there.
    """

    datasets: tuple[DatasetSpec, ...] = ()
    label: str = ""
    notes: str = field(default="")
    input_label: str = ""

    @classmethod
    def read(cls, path: Path) -> "DomainSpec":
        d = json.loads(path.read_text())
        declared = d.get("datasets")
        if not declared:
            # A domain that declares one shape at the top level, which is how
            # this began. Read as a single dataset so nothing else needs to know
            # there were ever two spellings.
            declared = [{k: d[k] for k in ("roles", "extensions", "sample_dir")
                         if k in d}]
        return cls(
            datasets=tuple(DatasetSpec.read(x) for x in declared),
            label=d.get("label", ""),
            notes=d.get("notes", ""),
            input_label=d.get("input_label", ""),
        )

    # --- the older single-shape view, for callers that only want the first ---
    @property
    def sample_dir(self) -> str:
        return self.datasets[0].sample_dir if self.datasets else ""

    @property
    def roles(self) -> dict:
        return self.datasets[0].roles if self.datasets else {}


def _load() -> dict[str, DomainSpec]:
    """Every domain that declares a study shape, read from its own directory."""
    out: dict[str, DomainSpec] = {}
    for path in sorted(_DOMAINS_DIR.glob("*/study.json")):
        try:
            out[path.parent.name] = DomainSpec.read(path)
        except (OSError, json.JSONDecodeError, TypeError):
            continue     # a malformed declaration hides one domain, not all of them
    return out


DOMAINS: dict[str, DomainSpec] = _load()


def known_domains() -> list[str]:
    return sorted(DOMAINS)


def role_names() -> frozenset:
    """Every role name any domain declares, across every shape.

    `study:NSCLC-Neoadjuvant/counts` and `study:NSCLC-Neoadjuvant/1N` are the
    same shape, and only these declarations tell them apart. Asked here rather
    than worked out by each caller, because three of them were working it out
    and a domain adding a role should not have to remember any of their names.
    """
    return frozenset(r for spec in DOMAINS.values()
                     for dataset in spec.datasets for r in dataset.roles)


def spec(domain: str) -> DomainSpec | None:
    return DOMAINS.get(domain)


def label(domain: str) -> str:
    s = DOMAINS.get(domain)
    return (s.label if s and s.label else domain)


def _roles_of(study_dir: str, dataset: DatasetSpec) -> dict[str, str]:
    """Role -> path within one folder, for one shape. Missing roles are omitted.

    A role may be a file or a directory: a Space Ranger run is recognised by the
    folders inside it, not by any table at its root.
    """
    try:
        entries = sorted(n for n in os.listdir(study_dir) if not n.startswith("."))
    except OSError:
        return {}
    files = [n for n in entries
             if n.lower().endswith(dataset.extensions)
             and os.path.isfile(os.path.join(study_dir, n))]
    dirs = [n for n in entries if os.path.isdir(os.path.join(study_dir, n))]
    roles: dict[str, str] = {}
    for role, keys in dataset.roles.items():
        # An entry a key names outright beats one that merely contains it.
        # Without this, an instrument writing both `x/` and `x.h5` gives the
        # role the file, because files are looked at first, and anything asking
        # for something inside the role then finds a file where it expected a
        # folder. Substring matching stays, because a role is usually named by a
        # stem rather than by a whole filename.
        hit = next((n for n in files + dirs
                    if any(k == n.lower() for k in keys)), None)
        if hit is None:
            hit = next((n for n in files + dirs
                        if any(k in n.lower() for k in keys)), None)
        if hit is not None:
            roles[role] = os.path.join(study_dir, hit)
    return roles


def _samples_of(study_dir: str, dataset: DatasetSpec) -> list[str]:
    if not dataset.sample_dir:
        return []
    root = (study_dir if dataset.sample_dir == "."
            else os.path.join(study_dir, dataset.sample_dir))
    if not os.path.isdir(root):
        return []
    try:
        names = sorted(n for n in os.listdir(root)
                       if not n.startswith(".") and os.path.isdir(os.path.join(root, n)))
    except OSError:
        return []
    if dataset.sample_dir != ".":
        return names
    # Children are the samples only if they look like one. Otherwise every
    # directory of directories anywhere would answer to this shape.
    return [n for n in names
            if _satisfied(_roles_of(os.path.join(root, n), dataset), dataset)]


def _satisfied(roles: dict, dataset: DatasetSpec) -> bool:
    if dataset.requires:
        return all(r in roles for r in dataset.requires)
    return bool(roles)


def identify(study_dir: str, domain: str) -> tuple[DatasetSpec, dict[str, str]] | None:
    """Which of a domain's shapes this folder is, and the roles it fills.

    Shapes are tried in the order the domain declared them, and the best fit
    wins rather than the first partial one, so a folder that satisfies a
    specific shape is not claimed by a looser one declared beside it.
    """
    s = DOMAINS.get(domain)
    if s is None or not os.path.isdir(study_dir):
        return None
    best = None
    for dataset in s.datasets:
        roles = _roles_of(study_dir, dataset)
        samples = _samples_of(study_dir, dataset)
        if not _satisfied(roles, dataset) and not samples:
            continue
        score = len(roles) + (1 if samples else 0)
        if best is None or score > best[0]:
            best = (score, dataset, roles)
    return (best[1], best[2]) if best else None


def match_roles(study_dir: str, domain: str) -> dict[str, str]:
    """Role -> path for whichever of the domain's shapes this folder is."""
    found = identify(study_dir, domain)
    return found[1] if found else {}


def sample_dirs(study_dir: str, domain: str) -> list[str]:
    """Per-sample folder names, for whichever shape this folder is."""
    found = identify(study_dir, domain)
    return _samples_of(study_dir, found[0]) if found else []


def sample_root(study_dir: str, domain: str) -> str:
    """Where this folder's per-sample directories actually sit.

    From the shape this folder turned out to be, not from the domain's first
    declaration. A domain declaring several shapes has several answers, and
    taking the first one silently drops the subfolder for every other shape:
    the samples are then listed correctly and none of them can be opened.
    """
    found = identify(study_dir, domain)
    sub = found[0].sample_dir if found else ""
    return study_dir if sub in ("", ".") else os.path.join(study_dir, sub)


def dataset_of(study_dir: str, domain: str) -> str:
    """What shape this folder is, by the domain's own name for it."""
    found = identify(study_dir, domain)
    return found[0].id if found else ""


def _score(study_dir: str, domain: str) -> int:
    """How well a folder fits a domain: matched roles, plus its sample tree."""
    found = identify(study_dir, domain)
    if not found:
        return 0
    return len(found[1]) + (1 if _samples_of(study_dir, found[0]) else 0)


def detect_domain(study_dir: str) -> str | None:
    """The domain this folder best fits, or None if it is no study at all.

    Scored by how much of the domain's shape is present, so a folder satisfying two
    of one domain's roles beats a weaker partial match elsewhere. Ties break on
    domain name, for determinism rather than for any reason about the data.
    """
    scored = [(_score(study_dir, d), d) for d in sorted(DOMAINS)]
    best_n, best_d = max(scored, default=(0, None))
    return best_d if best_n else None


def is_study(study_dir: str, domain: str) -> bool:
    """Whether this folder is a study of the given domain."""
    return _score(study_dir, domain) > 0
