#!/usr/bin/env python3
"""Compose capabilities into a pipeline from what they already declare.

Every contract names the capabilities it consumes and, per input, which one
produces it. That is a dependency graph nobody was reading. This turns it into
an execution order, a wiring diagram, or a Nextflow workflow block.

    graph.py --as order      topological order, with what each one waits on
    graph.py --as dot        graphviz, for a picture
    graph.py --as workflow   a Nextflow workflow block wiring the processes
    graph.py --as pipeline   every process plus that workflow, runnable
    graph.py --as check      unmet inputs and anything unreachable

Nothing here is hand maintained. Add a capability and the graph changes.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# The catalog reader lives with the schema it reads; profiles live with sites.
_ROOT = Path(__file__).resolve().parents[2]
RUNNER = _ROOT / "infrastructure" / "runner" / "run.py"
CATALOG = _ROOT / "domains"
sys.path.insert(0, str(_ROOT / "interfaces" / "catalog"))
sys.path.insert(0, str(_ROOT / "infrastructure" / "sites"))
# The renderer declares the processes; this file writes the workflow that calls
# them. It is imported rather than partly reimplemented here, so that a process
# name and the name used to call it cannot disagree. This path was missing, which
# is why `--as pipeline` could not import it and so could not run at all.
sys.path.insert(0, str(_ROOT / "infrastructure" / "render-targets"))
import entry as C
import profile as P
import render

CAPS = CATALOG  # every domain's catalog, not one project's


def load_all() -> dict:
    """Every entry in every domain, keyed by its qualified name.

    The graph does not care which domain an entry came from. Two domains that
    never reference each other simply produce two disconnected components, which
    is the correct answer rather than a special case.
    """
    caps = {}
    for c in C.entries(CAPS.parent):
        qid = C.qualified_id(c)
        if qid in caps:
            raise SystemExit(f"two entries claim {qid}")
        caps[qid] = c
    return caps


def edges(caps: dict) -> list:
    """(producer, consumer, input, kind) for every declared dependency.

    Two kinds, because there are two shapes of dependency here.

    `produced_by` is one run feeding one run: a named output of a single
    capability, for a single sample. That is a join.

    `aggregates` is many runs feeding one: an input assembled from the outputs
    of several capabilities across every sample in a cohort. It cannot name a
    single producing output because it is a directory layout rather than a file,
    and it is what makes a capability cross sample. That is a gather.

    `consumes` is the coarser claim; anything named there and resolved by
    neither is reported by the check target rather than silently ignored.
    """
    out = []
    for cid, c in caps.items():
        within = cid.rsplit("/", 1)[0]
        for i in c.get("inputs", []):
            if i.get("produced_by"):
                out.append((C.resolve_ref(i["produced_by"], within), cid, i["name"], "join"))
            for producer in i.get("aggregates", []):
                out.append((C.resolve_ref(producer, within), cid, i["name"], "gather"))
    return out


def order(caps: dict) -> list:
    """Capability ids in dependency order. Raises on a cycle."""
    deps = {cid: {p for p, cons, _, _ in edges(caps) if cons == cid} for cid in caps}
    done, result = set(), []
    while len(done) < len(caps):
        ready = sorted(cid for cid in caps
                       if cid not in done and deps[cid] <= done)
        if not ready:
            stuck = sorted(set(caps) - done)
            raise SystemExit(f"cycle or unresolvable dependency among: {', '.join(stuck)}")
        for cid in ready:
            done.add(cid)
            result.append(cid)
    return result


def as_order(caps: dict) -> str:
    out, seen = [], set()
    for cid in order(caps):
        c = caps[cid]
        waits = sorted({p for p, cons, _, _ in edges(caps) if cons == cid})
        tier = "entry point" if not waits else "after " + ", ".join(waits)
        stages = len(c.get("stages", [])) or 1
        fan = "  fans out" if c["resources"].get("fans_out") else ""
        rng = "" if not c["determinism"]["consumes_rng"] else (
            "  seedable" if c["determinism"].get("seed_env") else "  UNSEEDABLE")
        out.append(f"{len(seen)+1:>2}. {cid:<44} level {c.get('level','?')}  "
                   f"{stages} stage{'s' if stages > 1 else ' '}{fan}{rng}")
        out.append(f"    {tier}")
        seen.add(cid)
    return "\n".join(out)


def as_dot(caps: dict) -> str:
    out = ["digraph capabilities {", '  rankdir=LR;',
           '  node [shape=box, style=rounded, fontname="Helvetica"];']
    for cid, c in caps.items():
        shape = ', peripheries=2' if c["resources"].get("fans_out") else ''
        style = ', style="rounded,dashed"' if (
            c["determinism"]["consumes_rng"] and not c["determinism"].get("seed_env")) else ''
        out.append(f'  "{cid}" [label="{cid}\\nlevel {c.get("level","?")}"{shape}{style}];')
    for producer, consumer, what, kind in edges(caps):
        out.append(f'  "{producer}" -> "{consumer}" [label="{what}", fontsize=9];')
    out.append('  label="double border fans out; dashed cannot be seeded";')
    out.append("}")
    return "\n".join(out)


def as_workflow(caps: dict) -> str:
    """A Nextflow workflow block wiring the generated processes together.

    Each process takes one tuple per sample, so wiring is a series of joins on
    the sample identifier. A capability drawing inputs from two producers joins
    their channels; one drawing only from the samplesheet reads it directly.

    Nothing here is a scheduling decision. The order and the joins both fall out
    of what the contracts declare about who produces what.
    """
    seq = order(caps)
    # A samplesheet column is an input nothing upstream produces and that is
    # not gathered across the cohort. Aggregates are excluded because they
    # describe a whole cohort rather than one row of it.
    columns = sorted({i["name"] for c in caps.values() for i in c["inputs"]
                      if not i.get("produced_by") and not i.get("aggregates")})

    out = ["// generated from the capability contracts — do not edit by hand",
           "// process definitions come from: render.py <contract> --as nextflow",
           "",
           "// The samplesheet carries one row per sample, with these columns:",
           "//   sample_id, " + ", ".join(columns),
           "// Only the columns a given capability needs are read for it.",
           "",
           "workflow {",
           "  samples = Channel",
           "    .fromPath(params.samples)",
           "    .splitCsv(header: true)",
           ""]

    for name in columns:
        out.append(f"  ch_{name} = samples.map {{ r -> tuple(r.sample_id, "
                   f"file(r.{name})) }}")
    out.append("")

    for cid in seq:
        c = caps[cid]
        # The names this block writes have to be the names render.py declares,
        # so they come from render.py rather than from a second derivation here.
        # `within` is the domain this entry sits in, which is what a bare
        # `produced_by` is relative to; resolving it is what edges() already does
        # and what this block did not, so it named a producer that no process
        # here is called.
        proc = render.process_name(cid)
        chan = render.channel_name(cid)
        within = cid.rsplit("/", 1)[0]

        srcs = sorted({p for p, cons, _, _ in edges(caps) if cons == cid})
        gathers = [i for i in c["inputs"] if i.get("aggregates")]

        if gathers:
            # A cross sample capability runs once for the whole cohort, so its
            # channel is a gather rather than a join: wait for every sample,
            # collect, and call the process a single time. The sample identifier
            # is replaced by a cohort label, because the result belongs to the
            # set and not to any member of it.
            waited = sorted({C.resolve_ref(p, within)
                             for i in gathers for p in i["aggregates"]})
            out.append(f"  // {cid}: runs once over the whole cohort, after every "
                       f"sample has finished {', '.join(waited)}")
            out.append(f"  //   the cohort directory is assembled outside this "
                       f"workflow; what is gathered here is the barrier")
            barrier = "\n      .mix(".join(
                f"{render.channel_name(p)}_out.manifest" for p in waited
            ) + ")" * (len(waited) - 1)
            out.append(f"  {chan}_ready = {barrier}")
            out.append(f"    .collect()")
            args = ", ".join(
                f"params.{i['name']}" if i.get("aggregates") else f"ch_{i['name']}"
                for i in c["inputs"])
            out.append(f"  // {chan}_out = {proc}({args})   // needs a cohort "
                       f"directory; see the note in its contract")
            out.append("")
            continue

        # Build the channel this process consumes: start from the first input's
        # source, join the rest on sample_id, then flatten to one tuple.
        # What the producer calls the output, which is not always what the
        # consumer calls the input: `tree_bundle` takes slab's `scores` as
        # `slab_scores`, because a bundle drawing from six capabilities needs
        # names that stay distinct. `produced_output` records that, plan.py has
        # always read it, and this block did not — so it asked slab to emit a
        # channel named after the consumer's input, which slab does not declare.
        parts = []
        for i in c["inputs"]:
            if i.get("produced_by"):
                producer = render.channel_name(C.resolve_ref(i["produced_by"], within))
                parts.append(f"{producer}_out.{i.get('produced_output') or i['name']}")
            else:
                parts.append(f"ch_{i['name']}")

        if not parts:
            # Reads no files, so there is nothing to join and nothing to take a
            # sample identifier from. It still runs once per sample and its
            # output is still filed under one, so the identifier alone is the
            # channel. Without this branch parts[0] raised IndexError and no
            # pipeline could be emitted at all while such a capability existed.
            channel = "samples.map { r -> r.sample_id }"
        elif len(parts) == 1:
            channel = parts[0]
        else:
            channel = parts[0] + "".join(f"\n      .join({p})" for p in parts[1:])

        why = ("reads nothing; runs once per sample" if not parts else
               "reads the samplesheet" if not srcs else "after " + ", ".join(srcs))
        out.append(f"  // {cid}: {why}")
        out.append(f"  {chan}_out = {proc}(")
        out.append(f"    {channel}")
        out.append(f"  )")
        out.append("")

    out.append("}")
    return "\n".join(out)


def as_pipeline(caps: dict, profile_name: str) -> str:
    """Every process plus the workflow that wires them, in one runnable file.

    Emitted together because they have to agree: the workflow calls processes by
    a name derived from the capability id, and passes them a tuple shaped by that
    capability's inputs. Generating the two halves separately and expecting a
    person to reconcile them is how the two drift.
    """
    profile = P.load_profile(profile_name)
    out = ["#!/usr/bin/env nextflow",
           "",
           "// generated from contracts/capabilities/*.json",
           f"//                + contracts/profiles/{profile_name}.json",
           "// do not edit by hand: regenerate with",
           f"//   graph.py --as pipeline --profile {profile_name}",
           "",
           "nextflow.enable.dsl = 2",
           "",
           "// Where the runner lives on this machine. Every process calls it",
           "// rather than reimplementing the staging. Groovy does not expand",
           "// shell syntax, so an overridable path becomes an explicit lookup.",
           "//",
           "// These are plain defaults, not `params.x ?: default`. Reading a",
           "// param before assigning it warns about an undefined parameter, and",
           "// Nextflow already lets the command line and the config override a",
           "// script level default.",
           f"params.runner  = {render._groovy_env(render._on_site(profile, RUNNER))}",
           f"params.catalog = {render._groovy_env(render._on_site(profile, CATALOG))}",
           "params.outdir    = 'results'",
           "params.samples   = 'samples.csv'",
           ""]

    # Every parameter any capability accepts, declared null so that a process
    # can test it without Nextflow warning about an undefined parameter. Null
    # means "not given", and run.py then applies the contract's own default,
    # so the default lives in one place rather than being copied into here.
    knobs = sorted({p["name"] for c in caps.values()
                    for p in c.get("parameters", [])})
    out.append("// Left null, each capability's own declared default applies.")
    width = max(len(k) for k in knobs)
    out += [f"params.{k.ljust(width)} = null" for k in knobs]
    out.append("")

    for cid in order(caps):
        out.append(render.as_nextflow(caps[cid], profile))

    out.append(as_workflow(caps))
    return "\n".join(out)


def as_check(caps: dict) -> str:
    out, problems = [], 0
    ids = set(caps)

    for cid, c in caps.items():
        for dep in c.get("consumes", []):
            if dep not in ids:
                out.append(f"  {cid}: consumes '{dep}', which has no contract")
                problems += 1
        resolved = {i["produced_by"] for i in c.get("inputs", []) if i.get("produced_by")}
        resolved |= {p for i in c.get("inputs", []) for p in i.get("aggregates", [])}
        for dep in set(c.get("consumes", [])) - resolved:
            out.append(f"  {cid}: names '{dep}' in consumes but no input says "
                       f"produced_by or aggregates it, so the edge is a claim "
                       f"rather than a wiring")
            problems += 1
        for i in c.get("inputs", []):
            # Only a join has to name a real output. A gather is a directory
            # assembled from many runs, so there is no single output to name;
            # what it must do instead is come from a capability that exists.
            pb = i.get("produced_by")
            if pb and pb in ids:
                names = {o["name"] for o in caps[pb].get("outputs", [])}
                if i["name"] not in names:
                    out.append(f"  {cid}.{i['name']}: says it comes from '{pb}', whose "
                               f"outputs are {sorted(names)}")
                    problems += 1
            for producer in i.get("aggregates", []):
                if producer not in ids:
                    out.append(f"  {cid}.{i['name']}: aggregates '{producer}', "
                               f"which has no contract")
                    problems += 1
            if i.get("aggregates") and c.get("scope") != "cross_sample":
                out.append(f"  {cid}.{i['name']}: aggregates across runs, but the "
                           f"capability is scoped '{c.get('scope')}'")
                problems += 1

    produced = {p for p, _, _, _ in edges(caps)}
    for cid in sorted(ids - produced):
        if caps[cid].get("level", 1) > 1:
            out.append(f"  {cid}: level {caps[cid]['level']} but nothing consumes its output")

    head = "no problems" if not problems else f"{problems} problem(s)"
    return f"dependency check: {head}\n" + "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--as", dest="target", required=True,
                    choices=["order", "dot", "workflow", "pipeline", "check"])
    ap.add_argument("--profile", default=os.environ.get("ANALYSIS_SITE", "randi"),
                    help="Site profile, for --as pipeline.")
    args = ap.parse_args()
    caps = load_all()
    if args.target == "pipeline":
        print(as_pipeline(caps, args.profile))
        return 0
    print({"order": as_order, "dot": as_dot,
           "workflow": as_workflow, "check": as_check}[args.target](caps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
