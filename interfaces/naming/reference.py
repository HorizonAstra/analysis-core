"""What a reference says, before anything tries to find what it points at.

Split from `refs.py`, which resolves one against a filesystem. Reading a
reference and resolving it are different jobs with different needs: resolving
has to know the machine, the layout and the domain, and reading is string
handling. Keeping them together meant that anything wanting to read one had to
import the whole data layer, and two of the places that need it cannot — the
artifact store answers over ssh under whatever `python3` a cluster has, and a
run's manifest is read there too.

So this file imports nothing. That is the point of it, and it is why the same
answer is available on both machines rather than approximated separately on each.

    study:<name>/<sample>/<role>     what data is
    study:<name>@<version>/<sample>  the same, in one version of it
    run:<id>/<output>                what an earlier run produced
    site:<name>                      something the machine itself provides

Beyond the syntax there is one question here, because it is asked everywhere and
was answered differently in four places: which sample a piece of work is about.
"""

from __future__ import annotations

SCHEMES = ("study", "run", "site")

# How a reference names one version of a study's data. In the reference rather
# than beside it, so the machine that resolves it knows which data to open and a
# run records which it read.
AT = "@"


def looks_like_reference(value) -> bool:
    return isinstance(value, str) and value.split(":", 1)[0] in SCHEMES


def split_version(name: str) -> tuple:
    """A study name split from the version it asks for, if it asks for one."""
    study, _, version = str(name).partition(AT)
    return study, version


def study_parts(reference) -> list:
    """A `study:` reference, split into the study and whatever it named inside.

    The study name comes back with no version on it, and that is the point of
    having this at all. A version says which copy of the data to read; it never
    says what the data is. So everything that asks "which study is this" — does
    this machine hold it, which sample was that run about, which study to file a
    result under — gets the same answer whether or not somebody pinned a
    version, and none of them has to learn that versions exist.

    Empty for anything that is not a study reference, so a caller can ask without
    checking first.
    """
    text = str(reference or "")
    if not text.startswith("study:"):
        return []
    parts = [p for p in text[len("study:"):].strip("/").split("/") if p]
    if parts:
        parts[0] = split_version(parts[0])[0]
    return parts


def run_named(reference) -> str:
    """The run a `run:` reference names, or "" for anything else."""
    text = str(reference or "")
    if not text.startswith("run:"):
        return ""
    return text[len("run:"):].strip("/").split("/")[0]


def subject(inputs, reads, roles=(), memo=None, _walking=None) -> str:
    """Which sample a piece of work is about, or "" when it is not about one.

    Everything here is about a sample or about a set of them, and almost nothing
    says so outright. A capability is handed a matrix and some positions; only
    the first stage of a chain is handed anything that names a sample, and every
    stage after it names the stage before. So the answer is found by following
    what was read, back to the data.

    `reads` is how to look up what an earlier run read, given its id: a registry
    for work that has been submitted, the manifests for work that has finished.
    Passing it in is what lets one implementation serve both, which matters more
    than it sounds — this was written out four times, and three of those did not
    follow the chain at all. The one in the results panel decided which sample a
    result belonged to; the one deciding whether to recompute did not, so
    emptying one sample's cell recomputed that step for every sample.

    Exactly one distinct answer counts. Work that read two samples is about
    neither of them on its own, and saying it is about the first one found would
    file a cohort's result under whichever sample sorted first.

    `roles` are the names a domain uses for parts of a study, so that
    `study:<name>/<role>` is not mistaken for a sample.

    `memo` carries answers between calls, and is worth passing when asking about
    a set of runs: a study's worth of work all leads back to the same few early
    steps, and four of a capability's five inputs commonly name the same one.

    It is separate from the set of runs being walked right now, and conflating
    them is a bug rather than an economy: one "already visited" set answers the
    first mention of a run with its sample and every later mention with nothing,
    so the result depends on the order a dictionary happened to be in.
    """
    memo = {} if memo is None else memo
    walking = set() if _walking is None else _walking
    found = set()
    for value in (inputs or {}).values():
        named = study_parts(value)
        if len(named) >= 2:
            if named[1] not in roles:
                found.add(named[1])
        else:
            earlier = run_named(value)
            if earlier and earlier not in walking:
                if earlier in memo:
                    answer = memo[earlier]
                else:
                    deeper = reads(earlier)
                    if deeper is None:
                        answer = ""            # not ours to see, or long gone
                    else:
                        walking.add(earlier)
                        answer = subject(deeper, reads, roles, memo, walking)
                        walking.discard(earlier)
                    memo[earlier] = answer
                if answer:
                    found.add(answer)
        # Two different samples already, so this is about neither. Nothing
        # further can change that, and the walk can be expensive.
        if len(found) > 1:
            return ""
    return found.pop() if len(found) == 1 else ""
