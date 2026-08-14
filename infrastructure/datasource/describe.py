"""What a study actually contains, rather than only that it exists.

Listing a study used to answer with the names of the roles it filled — five
words, no columns, no counts, nothing about how the tables relate. Whoever read
that had two ways forward and both were bad. Guess, which produces confident
sentences about a table nobody looked at. Or compute: submit a job whose only
purpose is to print a column name, wait for it, read it back, and do that once
per table before the real question can even be framed. A four-job detour to
learn something the filesystem could have said in a third of a second.

Two things are answered here.

**Every file, not only the recognised ones.** A domain recognises tables by name,
so anything it did not anticipate was dropped from the listing entirely — a
study with seven tables reported five, and the other two could not be named,
opened or asked about. The recognition still happens, but it labels rather than
filters: a file whose role is not recognised is listed with no role, which is a
fact about the file rather than a reason to hide it.

**How the tables relate, inferred rather than declared.** A column that is unique
within its table identifies its rows; the same column appearing in another table
with repeats is that table pointing back. That is enough to say a study has
repeated measures, which is the fact that decides whether pooling rows is sound.
Inferring it means a domain declares nothing extra and a study whose columns are
named `study_id` and `timeline_collected` reads as well as one using the names
somebody expected.

Nothing here is specific to a domain. A study is a folder of tables, and this
describes tables.
"""

from __future__ import annotations

import os

from . import domains as _domains
from . import tables as _tables

# Past this many distinct values a column is a measurement rather than something
# to group by, and its values are not worth listing. Also the point past which a
# column is not treated as a candidate key for linking two tables.
SMALL = 20


def files(study_dir: str, domain: str) -> list[dict]:
    """Every file in a study, with the role it fills when the domain knows one.

    `role` is None for a file the domain does not recognise. That is the whole
    point: those files exist, hold data, and were previously invisible.
    """
    try:
        by_role = _domains.match_roles(study_dir, domain) or {}
    except Exception:                                        # noqa: BLE001
        by_role = {}
    role_of = {os.path.abspath(p): r for r, p in by_role.items()}
    out = []
    for name in sorted(os.listdir(study_dir)):
        path = os.path.join(study_dir, name)
        if name.startswith(".") or not os.path.isfile(path):
            continue
        out.append({"file": name,
                    "role": role_of.get(os.path.abspath(path)),
                    "bytes": os.path.getsize(path)})
    return out


def _links(described: dict) -> list[dict]:
    """How the tables join, worked out from the columns they share.

    A column unique within its table identifies that table's rows. The same
    column elsewhere, with fewer distinct values than rows, is a reference back
    to it — and that repetition is what "more than one measurement per subject"
    means, said in terms of the data rather than assumed from a table's name.
    """
    where: dict = {}
    for role, d in described.items():
        for col in d.get("columns", []):
            where.setdefault(col["name"], {})[role] = (col["distinct"], d.get("rows", 0))
    out = []
    for column, seen in sorted(where.items()):
        if len(seen) < 2:
            continue
        identifies = [r for r, (n, rows) in seen.items() if rows and n == rows]
        repeats = {r: rows for r, (n, rows) in seen.items() if rows and n < rows}
        if not identifies:
            continue
        link = {"column": column, "identifies": sorted(identifies),
                "also_in": sorted(r for r in seen if r not in identifies)}
        if repeats:
            # Said plainly, because it decides whether rows may be pooled. Two
            # measurements of one subject are not two independent observations,
            # and a reader that does not know this is told it here rather than
            # finding out from a reviewer.
            link["repeated_measures"] = True
            link["note"] = (f"{column} identifies a row in "
                            f"{', '.join(sorted(identifies))} and repeats in "
                            f"{', '.join(sorted(repeats))}. Rows there are not "
                            f"independent of each other.")
        out.append(link)
    return out


def study(study_dir: str, domain: str, name: str = "") -> dict:
    """One study, described: every file, every table's shape, and how they join.

    A table that cannot be read is reported with its error rather than left out,
    for the same reason an unrecognised file is listed: a caller can act on a
    table it has been told about and failed to read, and can do nothing at all
    about one it was never told existed.
    """
    listing = files(study_dir, domain)
    described: dict = {}
    for entry in listing:
        role = entry["role"]
        if not role:
            continue                      # listed above; not read until asked for
        path = os.path.join(study_dir, entry["file"])
        try:
            described[role] = _tables.describe(path, small=SMALL)
        except Exception as e:            # noqa: BLE001 - reported, not raised
            described[role] = {"error": f"{type(e).__name__}: {e}"}
        described[role]["file"] = entry["file"]
    unread = [e["file"] for e in listing if not e["role"]]
    out = {
        "study": name or os.path.basename(study_dir.rstrip("/")),
        "domain": domain,
        "tables": described,
        "links": _links(described),
    }
    if unread:
        out["other_files"] = unread
        out["other_files_note"] = (
            "Real data this domain has no role for. Not loaded by anything "
            "automatically, and readable by naming the file.")
    return out
