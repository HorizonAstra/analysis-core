"""The catalog format and the one reader of it.

Nothing here knows anything about the science, and nothing here knows anything
about a machine. It resolves placeholders, checks digests, and reports. It lives
beside the schema because it changes when the schema changes, and every reader
of a catalog entry imports it so that no two of them can drift apart.
"""

from __future__ import annotations

import hashlib
import json
import re
import shlex
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]   # last-resort root only

# Logical directory roles a contract may reference. A kernel that reads fixed
# filenames does so relative to one of these; the caller decides what each maps
# to on disk, which is the whole point of keeping them symbolic in the contract.
DIR_ROLES = ("work_dir", "input_base", "output_base", "data_dir")

# Where each role sits when a runner lays out a single staging tree.
DEFAULT_LAYOUT = {
    "work_dir": "stage",
    "input_base": "stage",
    "output_base": "out",
    "data_dir": "stage/data",
}


def load(path: str | Path) -> dict:
    with open(path) as fh:
        contract = json.load(fh)
    contract["_source"] = str(Path(path).resolve())
    return contract


def entry_paths(tree: str | Path | None = None, *,
                domains: list[str] | None = None,
                general: bool | None = None) -> list[Path]:
    """Every catalog entry, or the ones a caller asked for.

    There was a `sorted((tree / "domains").glob("*/catalog/*.json"))` in twelve
    files: both graph modules, the installer, four checks, the tool server, and
    four places in the web client. Twelve answers to "what can this do", each
    free to disagree with the rest about where entries live, whether a
    subdirectory counts, and what order they come back in — and any narrowing of
    the set had to be invented separately in every one of them.

    `domains` names the ecosystems wanted. `general` selects on what kind they
    are: True for the general engines, False for the sciences, None for both.
    Both filters read what is already on disk, so a client says which bag of
    tools it wants without holding a list of names that goes stale the day an
    ecosystem is added.
    """
    root = Path(tree).resolve() if tree else REPO
    found = sorted((root / "domains").glob("*/catalog/*.json"))
    if domains is not None:
        found = [p for p in found if p.parents[1].name in domains]
    if general is not None:
        found = [p for p in found if is_general(p.parents[1]) == general]
    return found


def entries(tree: str | Path | None = None, **which) -> list[dict]:
    """The same set, loaded. See `entry_paths` for what `which` selects."""
    return [load(p) for p in entry_paths(tree, **which)]


def is_general(domain_dir: str | Path) -> bool:
    """Whether this ecosystem's tools mean anything outside a science.

    The tree's own distinction, in the README's words: `domains/` is "the
    science, one directory per field", and separately "its general engines are
    in `domains/statistics`". Correlation, charting and running submitted code
    are the same operations on a microbiome table and on a spreadsheet of
    anything; a taxon and a tissue spot are not.

    It matters for more than tidiness. Delete every science from this tree and
    the general engines still work; delete `statistics` and microbiome's
    differential abundance stops, because it runs in that environment and
    imports those primitives. The dependency only ever points one way, and this
    is the fact that says which way.

    Declared in the ecosystem's own `domain.json` rather than guessed at, so a
    new one says what it is instead of being classified by something it happens
    to lack.
    """
    where = Path(domain_dir) / "domain.json"
    if not where.exists():
        return False
    with open(where) as fh:
        return bool(json.load(fh).get("general", False))


def public(contract: dict) -> dict:
    """The entry as the format defines it.

    A reader needs to remember where it loaded an entry from, and the only place
    to keep that is the entry itself. Anything a reader adds is prefixed with an
    underscore and stripped here, so bookkeeping can never reach a schema check
    or get written back into a file.
    """
    return {k: v for k, v in contract.items() if not k.startswith("_")}


def code_root(contract: dict, path: str | Path | None = None) -> Path:
    """Where this capability's kernel files live.

    An entry sits at <domain>/catalog/<name>.json and its kernel paths are
    relative to <domain>. Deriving the root from the entry itself is what lets
    one machine serve every domain: nothing about where code lives has to be
    written down twice, and no site description ever names a project.
    """
    src = path or contract.get("_source")
    return Path(src).resolve().parent.parent if src else REPO


def domain(contract: dict, path: str | Path | None = None) -> str:
    """Which domain owns this entry, from where the entry sits."""
    return code_root(contract, path).name


def qualified_id(contract: dict, path: str | Path | None = None) -> str:
    """The name an entry answers to once more than one domain exists.

    Two domains can each have a capability called differential abundance, and
    both of ours do. The domain already knows its own name and the entry already
    knows which domain it sits in, so the qualified name is derived rather than
    written down a second place that can disagree.
    """
    return f"{domain(contract, path)}/{contract['id']}"


# How an entry describes itself to whoever is choosing whether to call it.
#
# Every surface has to answer this, and two of ours answered it separately. The
# rendered MCP schema and the tool the server actually serves are both built from
# the same entry by two functions that had drifted: the live one told the caller
# an input is a reference and how to write one, and said whether a capability
# reasons about one sample or the set; the rendered one said neither. A caller
# reading the render was told less than a caller talking to the server, and
# nothing compared them, because the check asks whether the render *runs*.
#
# So it belongs here, in the vocabulary both partitions already import, and each
# surface arranges the text rather than composing it.

# What one invocation reasons about. Worth saying out loud: without it a caller
# cannot tell whether an answer describes one sample or the set, and asking a
# per-sample capability a question about a cohort produces an answer that looks
# right and means something else.
SCOPE = {
    "per_sample": "Runs on one sample. The answer is about that sample and no other, "
                  "so comparing two samples means running it on each.",
    "cross_sample": "Reasons across samples in one go. The answer belongs to the set "
                    "rather than to any single sample in it.",
}


# The one argument every capability takes that no entry declares. Not a
# destination — the store decides where a result lives, and a caller naming its
# own is how results end up scattered — so it is a shelf to find the result on
# again. Here for the same reason as the rest: both surfaces invented their own
# sentence for it, and they said different things.
WORKSPACE_NOTE = ("Which workspace to file the result under, so it can be found "
                  "again. Use one per study or per line of work; the store "
                  "decides where on disk it goes.")


def input_note(spec: dict) -> str:
    """What a caller is told about one input, including how to name it."""
    note = spec.get("description", "")
    if spec.get("produced_by"):
        note += f" Produced by '{spec['produced_by']}'."
    if spec.get("type") != "text":
        # Said on every input rather than once in a brief, because this is the
        # moment the value is chosen. A caller that builds a path here is a
        # caller that can hand one machine's path to another machine.
        note += (" A reference: study:<study>/<role> from list_data, or "
                 "run:<id>/<output> from an earlier run. Not a file path.")
    return note


def describe(contract: dict) -> str:
    """What a caller is told a capability is, and how to read its answer."""
    desc = contract.get("summary", contract["title"])
    reasons_about = SCOPE.get(contract.get("scope", ""))
    if reasons_about:
        desc += " " + reasons_about
    det = contract["determinism"]
    if det["consumes_rng"] and not det.get("seeded_by_default"):
        desc += " Results vary between runs unless a seed is supplied."
    # A model reading this tool is exactly who the caveats were written for, and
    # carrying them here is the reason interpretation sits in the catalog rather
    # than in whichever client happened to be written first.
    if contract.get("interpretation"):
        desc += "\n\nReading the result: " + contract["interpretation"]
    return desc


def resolve_ref(ref: str, within: str) -> str:
    """A reference to another capability, made absolute.

    A bare name means the same domain, which is what a domain author writes and
    what every entry written before a second domain existed already says. A name
    with a slash crosses domains and has to be deliberate.
    """
    return ref if "/" in ref else f"{within}/{ref}"


def resolve(text: str, contract: dict, roots: dict, param_ref) -> str:
    """Substitute {placeholders} in a contract string.

    roots     maps each directory role to a concrete path
    param_ref renders a parameter, letting callers choose their own convention
    """
    entry = contract["kernel"].get("entrypoint")
    if entry:
        text = text.replace("{entrypoint}", entry)
    for role, value in roots.items():
        text = text.replace("{" + role + "}", str(value))
    for p in contract.get("parameters", []):
        if p.get("env_var"):
            continue
        text = text.replace("{" + p["name"] + "}", param_ref(p))
    return text


def layout(stage_root: Path) -> dict:
    """Concrete paths for every directory role under one staging tree."""
    return {role: stage_root / sub for role, sub in DEFAULT_LAYOUT.items()}


def anchors(contract: dict) -> list[str]:
    """What, if anything, identifies the computation that will actually run.

    A version string is not an anchor. "MetaPhlAn 4.1.1" names a release; it does
    not say which bytes are on this machine under that name. An anchor is
    something that would differ if the executed thing differed, and where it
    lives depends on where the computation lives:

        first-party code   the file digests in kernel.sha256
        a container        the image digests in environment.digests
        a package set      a lockfile, hashed rather than merely pointed at

    A capability with none of these produces results nothing can be traced to,
    and the check below used to pass it silently because it iterated an empty
    map and found no mismatches.
    """
    found = []
    if contract["kernel"].get("sha256"):
        found.append("kernel files")
    if (contract.get("environment") or {}).get("digests"):
        found.append("image digests")
    if (contract.get("environment") or {}).get("manifest"):
        found.append("environment manifest")
    return found


def kernel_check(contract: dict, root: Path | None = None) -> tuple[list[str], bool]:
    """Has anything that decides the numbers moved.

    `root` is where the contract's files live. It defaults to the domain that
    owns the entry, because resolving against the wrong tree reports a missing
    file for one that is present.
    """
    lines, ok = [], True
    root = Path(root or code_root(contract))

    present = anchors(contract)
    if not present:
        lines.append("  UNANCHORED  nothing identifies what will run: no kernel file")
        lines.append("              digests, no image digests, no environment manifest")
        ok = False

    for rel, expected in contract["kernel"]["sha256"].items():
        path = root / rel
        if not path.exists():
            lines.append(f"  MISSING  {rel}")
            ok = False
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual == expected:
            lines.append(f"  ok       {rel}")
        else:
            lines.append(f"  CHANGED  {rel}")
            lines.append(f"             expected {expected}")
            lines.append(f"             actual   {actual}")
            ok = False

    # A lockfile is only an anchor once its content is fixed. Pointing at one
    # that anybody may edit records an intention rather than a fact.
    manifest = (contract.get("environment") or {}).get("manifest")
    if manifest:
        path = root / manifest
        expected = (contract.get("environment") or {}).get("manifest_sha256")
        if not path.exists():
            lines.append(f"  MISSING  {manifest}")
            ok = False
        elif not expected:
            lines.append(f"  UNPINNED {manifest} (present, but its digest is not recorded)")
            ok = False
        else:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            lines.append(f"  {'ok      ' if actual == expected else 'CHANGED '} {manifest}")
            ok = ok and actual == expected

    for tp in contract["kernel"].get("third_party", []):
        version = tp.get("version")
        lines.append(f"  {'ok      ' if version else 'UNPINNED'} {tp['name']} "
                     f"({version or 'unpinned'})")
        if not version:
            ok = False

    return lines, ok


def environment_check(contract: dict, root: Path | None = None) -> tuple[list[str], bool]:
    """Is the declared environment actually built on this machine.

    A pinned environment that has not been restored here fails deep inside the
    kernel, minutes in, with an error from whichever language it is written in.
    The entry names one path that exists only once the build has happened, so
    the check is a file test and stays free of any knowledge about renv, conda
    or poetry.
    """
    act = (contract.get("environment") or {}).get("activation") or {}
    if not act.get("path") or not act.get("ready_when"):
        return [], True
    base = Path(root or code_root(contract)) / act["path"]
    if (base / act["ready_when"]).exists():
        return [f"  ok       environment built at {act['path']}"], True
    lines = [f"  MISSING  {act['path']}/{act['ready_when']}",
             "",
             f"The environment this capability declares has not been built on this",
             f"machine. Build it once:",
             "",
             f"    cd {base}",
             f"    {act.get('restore_with', '(the entry does not say how)')}"]
    return lines, False


def repin(contract: dict, path: Path, root: Path | None = None) -> list[str]:
    """Recompute every digest a contract records, and say what moved.

    Editing a kernel invalidates its pin, which is the point. But a pin that has
    to be hand-copied is one that gets left stale or deleted, and a stale pin is
    worse than none because the manifest still claims the run was verified. This
    makes accepting a change one deliberate command that reports what it accepted.
    """
    root = Path(root or code_root(contract, path))
    changed = []
    for rel in list(contract["kernel"]["sha256"]) or contract["kernel"].get("files", []):
        f = root / rel
        if not f.exists():
            changed.append(f"  missing, left alone: {rel}")
            continue
        new = hashlib.sha256(f.read_bytes()).hexdigest()
        old = contract["kernel"]["sha256"].get(rel)
        contract["kernel"]["sha256"][rel] = new
        if old != new:
            changed.append(f"  {'repinned' if old else 'newly pinned'}: {rel}")
            if old:
                changed.append(f"      {old[:16]} -> {new[:16]}")

    env = contract.get("environment") or {}
    if env.get("manifest"):
        f = root / env["manifest"]
        if f.exists():
            new = hashlib.sha256(f.read_bytes()).hexdigest()
            if env.get("manifest_sha256") != new:
                changed.append(f"  {'repinned' if env.get('manifest_sha256') else 'newly pinned'}"
                               f": {env['manifest']}")
            env["manifest_sha256"] = new
        else:
            changed.append(f"  missing, left alone: {env['manifest']}")

    Path(path).write_text(json.dumps(public(contract), indent=2) + "\n")
    return changed or ["  nothing moved; every digest already matched"]


# --- arity ----------------------------------------------------------------
#
# Most kernels here open with a guard on how many positional arguments they
# were given, and abort otherwise. That guard is a machine readable statement
# of the calling convention, written by whoever wrote the kernel, and it costs
# nothing to hold a contract's template against it.
#
# The reason to bother: an adapter that passes four arguments to a kernel
# demanding three fails only once it is running, which on a cluster means after
# the queue, the image, and every stage before it. This turns that into a
# refusal before submission.
#
# Only the two unambiguous guards are read. `!=` states an exact count and `<`
# a minimum. Forms like `>=` inside a ternary express an optional argument
# rather than a requirement, and a kernel parsing named flags in a loop has no
# fixed arity at all; both are reported as unchecked rather than guessed at.

_ARITY_GUARD = re.compile(r"length\((?:ARGS|args)\)\s*(!=|<)\s*(\d+)")


def kernel_arity(rel: str, root: Path | None = None) -> dict | None:
    """How many positional arguments a kernel insists on, per its own guard."""
    path = Path(root or REPO) / rel
    if not path.exists() or path.suffix not in (".jl", ".R"):
        return None
    exact, minimum = None, None
    for op, count in _ARITY_GUARD.findall(path.read_text(errors="replace")):
        n = int(count)
        if op == "!=" and exact is None:
            exact = n
        elif op == "<" and minimum is None:
            minimum = n
    if exact is not None:
        return {"exact": exact}
    if minimum is not None:
        return {"min": minimum}
    return None


def template_arity(template: str, entrypoint: str) -> int | None:
    """How many positional arguments a template passes, or None if unreadable.

    A template that hands the work to `sh -c` is a script rather than a call,
    so its argument count is not visible here and is left unchecked.
    """
    try:
        tokens = shlex.split(template.replace("{entrypoint}", entrypoint))
    except ValueError:
        return None
    if not tokens or tokens[0] in ("sh", "bash") and "-c" in tokens[:2]:
        return None
    if entrypoint not in tokens:
        return None
    return len(tokens) - tokens.index(entrypoint) - 1


# Placeholders a template may legitimately use. Anything else in braces was
# never going to be substituted, and reaches the kernel as literal text.
_KNOWN = set(DIR_ROLES) | {"entrypoint", "run", "item", "run_dir",
                           "fan_out_count", "when_seeded"}

# A shell expansion is not a template placeholder: ${VAR} and $(seq ...) both
# contain braces and both belong to the command rather than to the contract.
_PLACEHOLDER = re.compile(r"(?<!\$)\{([a-zA-Z_][a-zA-Z0-9_]*)\}")


def placeholder_check(contract: dict) -> tuple[list[str], bool]:
    """Would every {placeholder} in every template actually be substituted.

    An input's name is not a placeholder. Only directory roles and parameters
    are, so a template writing {ref_dir} for an input called ref_dir passes the
    kernel that text verbatim and the kernel then opens a path that does not
    exist. Staging tells you where an input landed; the template has to name
    that location, not the input.
    """
    lines, ok = [], True
    allowed = _KNOWN | {p["name"] for p in contract.get("parameters", [])}
    inputs = {i["name"] for i in contract.get("inputs", [])}

    for s in stages(contract):
        unknown = sorted(set(_PLACEHOLDER.findall(s["template"])) - allowed)
        if not unknown:
            continue
        for name in unknown:
            why = ("names an input; use the path it is staged to"
                   if name in inputs else "matches no role or parameter")
            lines.append(f"  UNRESOLVED {s['id']:<18} {{{name}}} {why}")
        ok = False
    return lines, ok


def staging_check(contract: dict) -> tuple[list[str], bool]:
    """Does every staged path land inside the staging tree.

    `staged_as` is resolved by substituting directory roles, so a value naming
    no role stays relative and the adapter then writes it wherever the runner
    happens to be standing. That is silent: the copy succeeds, the kernel is
    handed a path under the staging tree that was never written, and the failure
    surfaces as a missing input several steps from the cause. Every path here has
    to begin with a role.

    And: a directory the machine provides is never copied. `from_site` names
    something the site holds that belongs to no study and is produced by no run
    — a reference genome, a database, a lookup table. It is shared, read only,
    and the same bytes for everybody, so copying it into a staging tree moves it
    once per run, per sample fanned out, and per user. `spacet` did exactly that
    with a reference directory. It is 8.7 MB today, which is why nobody noticed,
    and the next reference put beside it is a genome index at three to thirty
    gigabytes. Staging mode is a property of what the input is, so it is checked
    rather than remembered each time one is added.
    """
    lines, ok = [], True
    roles = "|".join(DIR_ROLES)
    rx = re.compile(r"^\{(" + roles + r")\}")
    for kind in ("inputs", "outputs"):
        for item in contract.get(kind, []):
            if not rx.match(item.get("staged_as", "")):
                lines.append(f"  UNROOTED  {kind[:-1]} {item['name']:<20} "
                             f"staged_as {item.get('staged_as')!r} names no directory "
                             f"role, so it resolves relative to the runner")
                ok = False
    for i in contract.get("inputs", []):
        if i.get("from_site") and i.get("stage_mode") != "link":
            lines.append(f"  COPIED    input {i['name']:<20} comes from the site and "
                         f"would be copied into the staging tree. Set "
                         f"\"stage_mode\": \"link\": the machine owns it, nothing "
                         f"writes to it, and its size is not this run's business")
            ok = False
    return lines, ok


def parameter_check(contract: dict) -> tuple[list[str], bool]:
    """Does every parameter offering a fixed set of values agree with itself.

    A parameter may declare `values`, which is how a caller learns the set it
    may choose from without discovering it by being refused. Two things then
    have to hold, and neither is expressible in the schema.

    The default has to be one of them. A surface renders the set as a choice, so
    a default outside it is a value the caller cannot re-select once they have
    moved off it, and for a host that validates the choice it is a default that
    fails validation before anything runs.

    And a set of one is not a choice. It is a constant, and belongs in the
    kernel rather than in a signature that invites a caller to pick.
    """
    lines, ok = [], True
    for p in contract.get("parameters", []):
        if p.get("required") and "default" in p:
            ok = False
            lines.append(f"  {p['name']}: required, but carries a default "
                         f"({p['default']!r}) — a default says not supplying it is fine")
        values = p.get("values")
        if not values:
            continue
        if "default" in p and p["default"] not in values:
            ok = False
            lines.append(f"  {p['name']}: default {p['default']!r} is not one of "
                         f"{', '.join(map(repr, values))}")
        else:
            lines.append(f"  {p['name']}: {len(values)} values, default holds")
    return lines or ["  no parameter declares a fixed set of values"], ok


def wiring_check(contract: dict) -> tuple[list[str], bool]:
    """Is every input read from the place it was staged to.

    `staged_as` says where the adapter puts a file. The invocation says where
    the kernel looks for it. Nothing tied the two together, so an entry could
    stage `markers.csv` and read `markers.tsv`, and it did: the file was copied,
    the kernel found nothing at the path it was given, and because the input was
    optional the run finished clean with the answer silently missing.

    A required input mismatched this way fails loudly on the first run. An
    optional one never fails at all, which is why this is worth a check rather
    than a convention.

    Only inputs staged to a named file are checked, and only where the
    invocation does not hand the whole directory over. A kernel given
    `--datapath {data_dir}` opens the files inside it by names of its own, and
    the entry staging them to those names is exactly how that is arranged; the
    template naming each one would be wrong. So a role passed whole excuses
    every file staged under it, and what is left is a path the kernel was told
    to read and never was.
    """
    lines, ok = [], True
    roles = "|".join(DIR_ROLES)
    named = re.compile(r"^\{(" + roles + r")\}/.+")
    # Across every stage, not one at a time. A multi-stage entry stages its
    # inputs once and the stages read them at different points, so an input read
    # by the third stage is wired even though the first never names it.
    every = "\n".join(s.get("template") or "" for s in stages(contract))
    if not every.strip():
        return lines, ok
    whole = {r for r in DIR_ROLES if re.search(r"\{" + r + r"\}(?![/\w])", every)}
    for i in contract.get("inputs", []):
        where = i.get("staged_as", "")
        hit = named.match(where)
        if not hit or where in every or hit.group(1) in whole:
            continue
        lines.append(f"  UNREAD    input {i['name']:<20} is staged to "
                     f"{where!r}, which the invocation never mentions"
                     + ("" if i.get("required", True) else
                        ", and it is optional, so nothing will report it missing"))
        ok = False
    return lines, ok


def arity_check(contract: dict) -> tuple[list[str], bool]:
    """Does every stage call its kernel the way that kernel demands."""
    lines, ok = [], True
    for s in stages(contract):
        entry = s.get("entrypoint")
        if not entry:
            continue
        want = kernel_arity(entry, code_root(contract))
        got = template_arity(s["template"], entry)
        if want is None or got is None:
            reason = ("kernel declares no fixed arity" if want is None
                      else "template is a script, not a direct call")
            lines.append(f"  unchecked {s['id']:<18} {reason}")
            continue
        if "exact" in want:
            good, expected = got == want["exact"], f"exactly {want['exact']}"
        else:
            good, expected = got >= want["min"], f"at least {want['min']}"
        if good:
            lines.append(f"  ok        {s['id']:<18} passes {got}, wants {expected}")
        else:
            lines.append(f"  WRONG     {s['id']:<18} passes {got}, but "
                         f"{Path(entry).name} wants {expected}")
            ok = False
    return lines, ok


SCHEMA = Path(__file__).resolve().parent / "schema.json"   # it sits beside this reader


def schema_check(contract: dict) -> tuple[list[str], bool]:
    """Does this contract still match the schema that describes contracts.

    The schema existed from the start and nothing ran it, so it drifted: fields
    in daily use were not allowed by it, and a nullable one was declared as a
    string. Nobody noticed, because a description that is never checked is a
    comment. Running it here is the only thing that keeps it a specification.

    Skipped rather than failed where jsonschema is absent, since it is not
    otherwise needed and refusing to work without it would be worse than the
    problem.
    """
    try:
        import jsonschema
    except ImportError:
        return ["  skipped  jsonschema is not installed on this host"], True

    schema = load(SCHEMA)
    errors = sorted(jsonschema.Draft202012Validator(schema).iter_errors(public(contract)),
                    key=lambda e: list(e.path))
    if not errors:
        return ["  ok       matches schema.json"], True
    lines = []
    for e in errors:
        where = ".".join(str(x) for x in e.path) or "(root)"
        lines.append(f"  INVALID  {where}: {e.message}")
    return lines, False


def stage_image(stage: dict, contract: dict) -> str | None:
    """Which image a stage needs.

    Usually the one for its language, but a stage may name an image explicitly.
    That matters where a binary is installed into another language's image, as
    gotree is into the Julia one.
    """
    if stage.get("image"):
        return stage["image"]
    language = stage.get("language", contract["kernel"]["language"])
    return (contract["environment"].get("images") or {}).get(language)


def wrap(command: str, image: str | None, profile: dict, subs: dict,
         extra_binds: list | None = None) -> str:
    """Apply a profile's launcher to one invocation.

    The contract supplies the image name; the profile supplies everything about
    how to launch it. Neither knows the other's business.

    extra_binds carries paths the run needs visible that the profile could not
    have known about: an input staged as a link points outside the staging tree,
    and inside a container that link resolves to nothing unless its target is
    mounted too.
    """
    launcher = profile.get("launcher")
    if not launcher or not image:
        return command

    root = profile.get("image_root") or "."
    paths = [subs.get(b.strip("{}"), b) for b in profile.get("binds", [])]
    paths += [str(p) for p in (extra_binds or [])]
    binds = " ".join(f"--bind {p}" for p in dict.fromkeys(paths))
    return (launcher
            .replace("{binds}", binds)
            .replace("{image}", f"{root}/{image}")
            .replace("{command}", command)
            .replace("{env_file}", subs.get("env_file", "/dev/null")))


def staging(contract: dict) -> str:
    """Whether an adapter must assemble a directory of fixed filenames.

    Multi stage capabilities always stage, because their kernels address each
    other through a shared working directory.
    """
    inv = contract.get("invocation")
    if inv:
        return inv.get("staging", "none")
    return "directory"


def stages(contract: dict) -> list:
    """Execution stages in dependency order.

    A single stage capability is normalised into a one element list so that
    callers never need two code paths.
    """
    declared = contract.get("stages")
    if not declared:
        inv = contract["invocation"]
        return [{
            "id": contract["id"],
            "title": contract["title"],
            "language": contract["kernel"]["language"],
            "entrypoint": contract["kernel"]["entrypoint"],
            "template": inv["template"],
            "after": [],
            "fan_out_over": None,
            "consumes_rng": contract["determinism"]["consumes_rng"],
        }]

    by_id = {s["id"]: s for s in declared}
    ordered, seen = [], set()

    def visit(sid: str, path: tuple = ()):
        if sid in seen:
            return
        if sid in path:
            raise ValueError(f"stage cycle: {' -> '.join(path + (sid,))}")
        for dep in by_id[sid].get("after", []):
            if dep not in by_id:
                raise ValueError(f"stage '{sid}' waits on unknown stage '{dep}'")
            visit(dep, path + (sid,))
        seen.add(sid)
        ordered.append(by_id[sid])

    for s in declared:
        visit(s["id"])
    return ordered


def stage_command(stage: dict, contract: dict, roots: dict, param_ref,
                  loop: dict | None = None) -> str:
    """Resolve one stage's command, using its own entrypoint.

    A fan out stage is repeated across the values of one list parameter. Inside
    such a stage three extra placeholders are available:

        {run}      1 based index of this iteration
        {item}     the list element for this iteration
        {run_dir}  a working directory private to this iteration

    Each iteration needing its own directory is not a detail. The stages write
    fixed filenames, so a shared directory would have every iteration overwrite
    the last.
    """
    text = stage["template"].replace("{entrypoint}", stage["entrypoint"])
    for key, value in (loop or {}).items():
        text = text.replace("{" + key + "}", str(value))
    for role, value in roots.items():
        text = text.replace("{" + role + "}", str(value))
    for p in contract.get("parameters", []):
        if p.get("env_var"):
            continue
        text = text.replace("{" + p["name"] + "}", param_ref(p))
    return text


def fan_out_values(stage: dict, params: dict) -> list | None:
    """The list a fan out stage repeats over, or None when it runs once."""
    name = stage.get("fan_out_over")
    if not name:
        return None
    values = params.get(name)
    if values is None:
        return None
    return list(values) if isinstance(values, (list, tuple)) else [values]


def fan_out_count(contract: dict, params: dict) -> int:
    """How many iterations this capability's fan out has.

    A stage that runs once but has to reason about the iterations before it
    needs this: the SVD selection reads one file from each svd_run_N and has no
    other way to know how many there are. Available in any template as
    {fan_out_count}.
    """
    name = (contract.get("resources") or {}).get("fan_out_over")
    values = params.get(name) if name else None
    if values is None:
        return 0
    return len(values) if isinstance(values, (list, tuple)) else 1


def run_dir(roots: dict, index: int) -> str:
    """Per iteration working directory, matching the layout the pipeline uses."""
    return f"{roots['output_base']}/svd_run_{index}"


def param_values(contract: dict, supplied: dict) -> dict:
    """Merge supplied parameters over their declared defaults."""
    out = {}
    for p in contract.get("parameters", []):
        name = p["name"]
        if supplied.get(name) is not None:
            out[name] = supplied[name]
        elif "default" in p:
            out[name] = p["default"]
    return out
