#!/usr/bin/env python3
"""Render a capability contract into a specific interface.

The point of this script is to be boring. Every interface below is a mechanical
translation of the same contract, and none of them contain a decision about the
science. Adding a fourth interface means adding a function here, not touching a
kernel.

    render.py <contract.json> --as cli               a person at a terminal
    render.py <contract.json> --as mcp               an LLM driven platform
    render.py <contract.json> --as openapi           a platform speaking HTTP
    render.py <contract.json> --as nextflow          a workflow engine process
    render.py <profile>       --as nextflow-config   that engine's site config
    render.py <contract.json> --as slurm             a scheduler submission script
    render.py <contract.json> --as verify            has the frozen math moved

The last three are the executor axis. All of them read the same contract and the
same site profile, so a machine is described once and a capability is described
once, whichever thing ends up driving them.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

# The catalog reader lives with the schema it reads; profiles live with sites.
_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_ROOT / "interfaces" / "catalog"))
sys.path.insert(0, str(_ROOT / "infrastructure" / "sites"))
import entry as C
import profile as P

REPO = C.REPO
TREE = Path(__file__).resolve().parents[2]
RUNNER = TREE / "infrastructure" / "runner" / "run.py"
CATALOG = TREE / "domains"
load = C.load

# A contract says what bounds it; Nextflow wants a label. Every class a site can
# declare needs one, and `io` did not have one — so rendering a config for either
# Randi profile died on a KeyError. It went unnoticed because the render check
# walks catalog entries, and this is the one target that takes a site instead, so
# nothing ever ran it.
LABEL = {"memory": "big_mem", "cpu": "cpu_bound", "walltime": "long_run",
         "trivial": "small", "io": "io_bound"}


# --------------------------------------------------------------------------
# cli: the invocation a person types, plus the staging an adapter must perform
# --------------------------------------------------------------------------

def as_cli(c: dict) -> str:
    out = [f"# {c['id']} {c['version']} — {c['title']}", ""]
    out.append("Usage:")
    named = " ".join(f"--{i['name']} <path>" for i in c["inputs"])
    params = " ".join(
        f"[--{p['name']} <{'|'.join(map(str, p['values'])) if p.get('values') else p['type']}>]"
        for p in c.get("parameters", []))
    out.append(f"  {c['id']} {named} --outdir <path> {params}".rstrip())
    out.append("")

    if C.staging(c) == "directory":
        out.append("Staging (the kernel reads fixed filenames, so an adapter must place them):")
        for i in c["inputs"]:
            req = "" if i.get("required", True) else "   [optional]"
            out.append(f"  --{i['name']:<18} ->  {i['staged_as']}{req}")
        out.append("")

    stages = C.stages(c)
    if len(stages) > 1:
        out.append(f"Then run {len(stages)} stages in order, each kernel unchanged:")
        for n, s in enumerate(stages, 1):
            fan = f"   [repeated over {s['fan_out_over']}]" if s.get("fan_out_over") else ""
            rng = "   [draws from the RNG]" if s.get("consumes_rng") else ""
            out.append(f"  {n}. {s['id']:<18} {s.get('title','')}{fan}{rng}")
            out.append(f"     {s['template']}")
    else:
        out.append("Then invoke, unchanged:")
        out.append(f"  {stages[0]['template']}")
    out.append("")
    out.append("Collect:")
    for o in c["outputs"]:
        out.append(f"  {o['staged_as']:<58} ->  --outdir/{o['name']}")

    env = c["environment"].get("pinned_env") or {}
    if env:
        out.append("")
        out.append("Environment that must be pinned:")
        for k, v in env.items():
            out.append(f"  {k}={v}")
    if c["determinism"]["consumes_rng"]:
        seed = c["determinism"].get("seed_env")
        out.append(f"  {seed}=<int>   # required for a reproducible run")
    return "\n".join(out)


# --------------------------------------------------------------------------
# mcp: a tool definition an LLM-facing platform can register
# --------------------------------------------------------------------------

_JSON_TYPE = {"integer": "integer", "number": "number",
              "string": "string", "boolean": "boolean", "array": "array"}


def as_mcp(c: dict) -> str:
    props: dict = {}
    required: list = []

    for i in c["inputs"]:
        props[i["name"]] = {"type": "string", "description": C.input_note(i)}
        if i.get("required", True):
            required.append(i["name"])

    for p in c.get("parameters", []):
        entry = {"type": _JSON_TYPE[p["type"]], "description": p.get("description", "")}
        if "default" in p:
            entry["default"] = p["default"]
        # A fixed set of values is an enum here, which is the one thing a tool
        # schema can say that a description cannot: a caller reading prose can
        # still pass anything, and finds out it could not by starting a run that
        # fails on its first line.
        if p.get("values"):
            entry["enum"] = list(p["values"])
        props[p["name"]] = entry
        if p.get("required"):
            required.append(p["name"])

    props["workspace"] = {"type": "string", "default": "default",
                          "description": C.WORKSPACE_NOTE}

    tool = {
        # Qualified, because two domains can offer the same analysis and both of
        # ours do. A dot would be read as a namespace by some hosts and rejected
        # by others, so the separator is an underscore.
        "name": f"{_domain_of(c)}_{c['id']}",
        "description": C.describe(c),
        "inputSchema": {
            "type": "object",
            "properties": props,
            "required": required,
        },
    }
    return json.dumps(tool, indent=2)


# --------------------------------------------------------------------------
# nextflow: emit a process, rather than adopting nextflow as the abstraction
# --------------------------------------------------------------------------

def _resolve(text: str, c: dict, param_ref) -> str:
    """Nextflow runs inside its own work directory, so roles map to relative paths."""
    return C.resolve(text, c, C.DEFAULT_LAYOUT, param_ref)


def _domain_of(c: dict) -> str:
    """Which domain owns this entry, read from where the entry sits."""
    return C.code_root(c).name


def process_name(qualified: str) -> str:
    """The Nextflow process name for a qualified capability id.

    From the qualified name rather than the bare one, because two domains can
    hold a capability with the same id and both of ours do: microbiome and
    spatial transcriptomics each have `differential_abundance`. Named from the
    bare id, one pipeline file declares that process twice and Nextflow refuses
    the file rather than the process.

    Here rather than in each caller because `graph.py` calls processes by name
    and this file declares them, so a name derived in two places is a name that
    drifts. It had already drifted: the workflow block wrote the qualified id
    through unchanged, giving `Microbiome/assemble`, which is a division rather
    than an identifier. Neither target is rendered by the checks, so nothing said
    so.
    """
    return "".join(w.capitalize() for w in re.split(r"[/_-]+", qualified) if w)


def channel_name(qualified: str) -> str:
    """A Groovy variable standing for one capability's channel.

    Same reasoning as `process_name`, and the same failure: a slash in a
    variable name parses as division.
    """
    return re.sub(r"[/-]+", "_", qualified)


def _on_site(profile: dict, path: Path) -> str:
    """A path in this tree, as it will read on the machine the script runs on.

    A rendered script usually executes somewhere other than the host that wrote
    it, so an absolute path from here would be wrong there. The site says where
    the tree is installed; everything below it is the same on every machine.
    """
    root = profile.get("install_root")
    rel = Path(path).resolve().relative_to(TREE)
    return f"{root}/{rel}" if root else str(Path(path).resolve())


def as_nextflow(c: dict, profile: dict) -> str:
    """A Nextflow process that calls the adapter, rather than reimplementing it.

    The earlier version of this function inlined the kernel commands and rebuilt
    the staging in bash. That produces a second implementation of the argument
    construction and the fixed-filename layout, which then drifts from the first.
    This repository already shows where that ends: one spatial statistic exists
    in two implementations that disagree on five percent of node selections, and
    nobody noticed because both were plausible.

    So the process calls run.py. A result from Nextflow, from a scheduler, and
    from a person at a shell are then provably the same command, and each task
    still emits the manifest that makes it attributable.

    The process declares no container on purpose. run.py applies the site
    profile's launcher itself, so letting Nextflow also containerise would nest
    one inside the other. It also could not work for a capability like the region
    finder, which spans two images and one stage that deliberately runs outside
    both. Nextflow keeps scheduling, retries, caching and fan out across samples;
    the runtime axis stays with the profile, where the rest of this design puts
    it.
    """
    name = process_name(f"{_domain_of(c)}/{c['id']}")
    res = c["resources"]
    label = LABEL.get(res["bound_by"], "small")

    # Every capability is per sample, so the identifier travels with the data as
    # one tuple rather than as parallel channels. Without it a cohort run cannot
    # tell whose result is whose; without the tuple, a downstream capability
    # drawing inputs from two producers has nothing to join them on.
    #
    # A capability that reads no files still runs once per sample and still emits
    # a tuple carrying the identifier, so the identifier alone is the input. The
    # tuple form cannot express that: with nothing to join to it, it renders as
    # `tuple val(sample_id), ` and the trailing comma is a syntax error. That is
    # what `toolchain_report` produced, and it went unseen because this target is
    # checked by whether render.py exits zero rather than by whether Nextflow
    # will parse what it wrote.
    if c["inputs"]:
        ins = ["    tuple val(sample_id), "
               + ", ".join(f"path({i['name']})" for i in c["inputs"])]
    else:
        ins = ["    val sample_id"]

    outs = [f'    tuple val(sample_id), path("out/{o["name"]}"), emit: {o["name"]}'
            + ("" if o.get("required", True) else ", optional: true")
            for o in c["outputs"]]
    outs.append('    path "out/run_manifest.json", emit: manifest')

    # ${name}, not name. Nextflow stages an input under its source basename and
    # binds the declared variable to it, so the sample directory arrives as
    # "input_data" and the matrix as "M.txt". Writing the bare word passes the
    # literal text through to the adapter, which then looks for a file that was
    # never there. Inputs whose upstream output happens to share the declared
    # name would work either way, which is exactly what made this survive the
    # first four capabilities and fail on the fifth.
    args = [f"        --{i['name']} ${{{i['name']}}}" for i in c["inputs"]]
    for p in c.get("parameters", []):
        # Left unset, the contract's own default applies. Passing the Groovy
        # null through would override it with the string "null".
        #
        # The value is quoted because a Groovy list renders as [5, 50, 150],
        # spaces included, which unquoted would reach argparse as three separate
        # words and be read as stray positional arguments.
        args.append(f'        ${{params.{p["name"]} != null ? '
                    f"\"--{p['name']} '${{params.{p['name']}}}'\" : \"\"}}")

    preamble = "\n".join(f"    {line}" for line in profile.get("preamble", []))
    body = " \\\n".join(
        [f'    python3 ${{params.runner}} '
         f'${{params.catalog}}/{_domain_of(c)}/catalog/{c["id"]}.json'] + args
        + [f"        --profile {profile['id']} --stage-dir stage --outdir out"])

    notes = [f"// cost basis: {res['basis']}; scales with {res['scales_with']}"]
    if res.get("fans_out"):
        notes.append(f"// fans out internally over {res['fan_out_over']}; "
                     f"run.py walks that inside the one task")
    if c["determinism"]["consumes_rng"]:
        notes.append("// draws random numbers; set params.seed or results will "
                     "not reproduce")

    return f"""// generated from domains/{_domain_of(c)}/catalog/{c['id']}.json
//                + contracts/profiles/{profile['id']}.json — do not edit by hand
{chr(10).join(notes)}
process {name} {{
    label '{label}'
    tag "${{sample_id}}"
    publishDir {{ "${{params.outdir}}/${{sample_id}}/{c['id']}" }}, mode: 'copy'

    input:
{chr(10).join(ins)}

    output:
{chr(10).join(outs)}

    script:
    \"\"\"
{preamble}

{body}
    \"\"\"
}}
"""


# --------------------------------------------------------------------------
# verify: has the frozen math moved
# --------------------------------------------------------------------------

def as_verify(c: dict, root=None):
    lines, ok = C.kernel_check(c, root)
    out = [f"kernel freeze check — {c['id']} {c['version']}", ""] + lines
    out.append("")
    out.append("PASS: the computation is unchanged." if ok else
               "FAIL: something that decides the numbers has moved.")

    # A second, independent question: the kernel has not moved, but is this
    # contract still calling it the way it asks to be called. A digest cannot
    # answer that, because the mistake lives in the contract rather than the
    # kernel.
    shape, shape_ok = C.schema_check(c)
    out += ["", "contract shape", ""] + shape

    holes, holes_ok = C.placeholder_check(c)
    call, call_ok = C.arity_check(c)
    paths, paths_ok = C.staging_check(c)
    wire, wire_ok = C.wiring_check(c)
    vals, vals_ok = C.parameter_check(c)
    if call or holes or paths or wire or vals:
        out += ["", "calling convention", ""] + holes + call + paths + wire + vals
        out.append("")
        if not holes_ok:
            out.append("FAIL: a template contains a placeholder nothing substitutes, "
                       "which reaches the kernel as literal text.")
        elif not paths_ok:
            out.append("FAIL: a staged path names no directory role, so it resolves "
                       "relative to whatever the runner's working directory is.")
        elif not call_ok:
            out.append("FAIL: a stage passes the wrong number of arguments.")
        elif not vals_ok:
            out.append("FAIL: a parameter's default is not one of the values it "
                       "offers, so the value it starts at cannot be chosen again.")
        elif not wire_ok:
            out.append("FAIL: an input is staged somewhere the invocation never reads.")
        else:
            out.append("PASS: every stage calls its kernel as declared.")
    if not shape_ok:
        out.append("")
        out.append("FAIL: the contract does not match the schema.")
    # paths_ok was reported in the text above and left out of this answer, so a
    # staged path that resolved to nowhere printed FAIL and exited 0.
    return "\n".join(out), (ok and call_ok and holes_ok and shape_ok
                            and paths_ok and wire_ok)


# --------------------------------------------------------------------------
# nextflow-config: the executor axis, generated from a site profile
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# openapi: a request/response contract for a platform that speaks HTTP
# --------------------------------------------------------------------------

def as_openapi(c: dict) -> str:
    """Render the capability as an OpenAPI path.

    A platform driving this over HTTP needs the same four answers as every other
    interface, so the schema is built from the same fields the MCP tool uses.
    The one addition is that a capability here is long running, so the operation
    is modelled as submit-and-poll rather than a synchronous call.
    """
    props, required = {}, []
    for i in c["inputs"]:
        props[i["name"]] = {
            "type": "string",
            "description": (i.get("description", "") +
                            (f" Produced by '{i['produced_by']}'." if i.get("produced_by") else "")),
        }
        if i.get("required", True):
            required.append(i["name"])
    for p in c.get("parameters", []):
        entry = {"type": _JSON_TYPE[p["type"]], "description": p.get("description", "")}
        if "default" in p:
            entry["default"] = p["default"]
        if p.get("values"):
            entry["enum"] = list(p["values"])
        if p["type"] == "array":
            entry["items"] = {"type": "integer"}
        props[p["name"]] = entry

    res = c["resources"]
    notes = [f"Scales with {res['scales_with']}; bound by {res['bound_by']}."]
    if res.get("fans_out"):
        notes.append(f"Fans out over {res['fan_out_over']}, so cost grows with its length.")
    if c["determinism"]["consumes_rng"]:
        notes.append("Draws random numbers. " + (
            f"Set '{c['determinism']['seed_env'].lower()}' for a reproducible run."
            if c["determinism"].get("seed_env") else
            "No seed can be supplied, so repeat calls differ."))

    spec = {
        "openapi": "3.1.0",
        "info": {"title": c["title"], "version": c["version"],
                 "description": c.get("summary", "") + " " + " ".join(notes)},
        "paths": {
            f"/capabilities/{c['id']}/runs": {
                "post": {
                    "operationId": f"start_{c['id']}",
                    "summary": c.get("summary", c["title"]),
                    "description": " ".join(notes),
                    "requestBody": {
                        "required": True,
                        "content": {"application/json": {"schema": {
                            "type": "object", "properties": props, "required": required}}},
                    },
                    "responses": {
                        "202": {"description": "Accepted. The capability runs asynchronously.",
                                "content": {"application/json": {"schema": {"type": "object",
                                    "properties": {"run_id": {"type": "string"}}}}}},
                        "409": {"description": "Refused: the kernel or a pinned dependency "
                                               "no longer matches the contract."},
                    },
                }
            },
            f"/capabilities/{c['id']}/runs/{{run_id}}": {
                "get": {
                    "operationId": f"get_{c['id']}_run",
                    "summary": "Status and, once finished, the outputs and provenance.",
                    "responses": {"200": {"description": "Run state.",
                        "content": {"application/json": {"schema": {"type": "object", "properties": {
                            "state": {"type": "string",
                                      "enum": ["queued", "running", "succeeded", "failed"]},
                            "outputs": {"type": "object", "properties": {
                                o["name"]: {"type": "string",
                                            "description": o.get("description", "")}
                                for o in c["outputs"]}},
                            "run_manifest": {"type": "object", "description":
                                "Kernel digests, image digests, parameters, and every input by "
                                "content hash. What makes a result attributable."},
                        }}}}}},
                }
            },
        },
    }
    return json.dumps(spec, indent=2)


def _groovy_env(value: str) -> str:
    """Turn a shell style ${VAR:-default} into a Groovy environment lookup."""
    m = re.match(r"^\$\{([A-Za-z_][A-Za-z0-9_]*):-(.*)\}$", value)
    if m:
        var, default = m.groups()
        return f"(System.getenv('{var}') ?: {_expand_user(default)})"
    return _expand_user(value)


def _expand_user(value: str) -> str:
    """Turn a ${VAR} inside a path into a Groovy expression, not a literal.

    Resolving it at generation time was wrong: this file is written on one
    machine and read on another, so baking in the generating host's username
    produced a scratch path belonging to nobody. Nextflow evaluates the config
    on the machine that runs it, which is where the answer actually is.
    """
    parts = re.split(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", value)
    if len(parts) == 1:
        return f"'{value}'"
    out = []
    for i, part in enumerate(parts):
        if i % 2:
            out.append(f"System.getenv('{part}')")
        elif part:
            out.append(f"'{part}'")
    return " + ".join(out)


def as_nextflow_config(profile: dict) -> str:
    """Render a site profile as Nextflow configuration.

    A Nextflow config file is one rendering of a site profile, in the same way a
    singularity command line is another. Generating it keeps the site as the
    single source of truth, so nobody hand-maintains two descriptions of one
    machine that then drift apart.
    """
    ex = profile.get("executor") or {}
    runtime = profile.get("runtime", "none")
    out = [f"// generated from infrastructure/sites/{profile['id']}.json, do not edit by hand",
           f"// site: {profile['description']}", ""]

    if runtime == "singularity":
        # Deliberately not enabling singularity here. The processes this pairs
        # with call run.py, which applies the profile's launcher itself, so
        # letting Nextflow also containerise would put one container inside
        # another. It also could not express a capability like the region
        # finder, which spans two images and one stage that runs outside both,
        # because Nextflow allows a single container per process.
        #
        # The division: Nextflow schedules, retries, caches and fans out across
        # samples. The runtime axis stays with the profile.
        out += ["// Containers are not Nextflow's job here. Each process calls",
                "// run.py, which applies this site's launcher from the same",
                "// profile that generated this file. Enabling singularity below",
                "// would nest a container inside a container.",
                f"// images live at: {profile.get('image_root')}",
                ""]

    if ex:
        out.append("process {")
        out.append(f"  executor = '{ex.get('scheduler', 'local')}'")
        if ex.get("scratch"):
            # Deliberately not applied. The site profile records it because it
            # is real knowledge about this machine, but it cannot be used with
            # processes that call run.py: Nextflow stages a task's inputs into
            # the work directory and then runs the task in the scratch
            # directory, so with symlink staging the inputs are not where the
            # task looks for them. Measured, not assumed — every task failed
            # with a missing input naming a path under this directory.
            #
            # Nothing is lost. The point of scratch is to compute on fast node
            # local storage, and run.py already assembles its working tree under
            # this site's stage_root, which is that same storage.
            out.append(f"  // scratch = {_groovy_env(ex['scratch'])}")
            out.append(f"  // left off: run.py stages under the profile's "
                       f"stage_root, and enabling both relocates a task away "
                       f"from its own staged inputs")
        for key, field in (("stage_in", "stageInMode"), ("stage_out", "stageOutMode"),
                           ("cache", "cache")):
            if ex.get(key):
                out.append(f"  {field} = '{ex[key]}'")
        if ex.get("max_forks"):
            out.append(f"  maxForks = {ex['max_forks']}")
        if ex.get("retries"):
            out.append(f"  errorStrategy = {{ task.attempt <= {ex['retries']} ? "
                       f"'retry' : 'terminate' }}")
            out.append(f"  maxRetries = {ex['retries']}")
        if ex.get("exclude_nodes"):
            # Nodes found to fail in practice. Losing this list costs real time.
            out.append(f"  clusterOptions = '--exclude={','.join(ex['exclude_nodes'])}'")
        out.append("}")
        if ex.get("queue_size"):
            out += ["", f"executor.queueSize = {ex['queue_size']}"]

    classes = {k: v for k, v in (profile.get("resource_classes") or {}).items()
               if not k.startswith("_")}
    if classes:
        out += ["", "// resource classes, keyed to a contract's resources.bound_by.",
                "// The same table drives --as slurm; neither executor owns these numbers.",
                "process {"]
        unknown = sorted(set(classes) - set(LABEL))
        if unknown:
            raise SystemExit(
                f"site '{profile['id']}' declares resource class(es) "
                f"{', '.join(unknown)}, which no label in render.py covers. A "
                f"capability bound by one of those would render with no limits "
                f"at all. Add it to LABEL.")
        for name in sorted(classes):
            spec = classes[name]
            out.append(f"  withLabel: {LABEL[name]:<9} {{ "
                       f"memory = '{spec['memory']}'; cpus = {spec['cpus']}; "
                       f"time = '{spec['time']}' }}")
        out.append("}")
    out += ["",
            "trace   { enabled = true }",
            "report  { enabled = true }",
            "timeline{ enabled = true }"]
    return "\n".join(out)


# --------------------------------------------------------------------------
# slurm: the third executor, from the same two files as the other two
# --------------------------------------------------------------------------

def as_slurm(c: dict, profile: dict) -> str:
    """Render a capability as a submission script for a scheduler.

    Nothing here decides how the capability runs. The script requests an
    allocation and hands over to run.py, which is the same adapter a person
    invokes by hand and the same one a Nextflow process would call. What the
    scheduler adds is the allocation and the queue, so that is all this emits.

    The numbers come from the profile's resource classes rather than from the
    contract, because how much memory to ask for is a property of the site. The
    contract only says what bounds the capability.
    """
    res = c["resources"]
    classes = profile.get("resource_classes") or {}
    spec = classes.get(res["bound_by"])
    if not spec:
        raise SystemExit(
            f"profile '{profile['id']}' has no resource class for "
            f"bound_by '{res['bound_by']}'. Add one, or pick a profile that "
            f"describes a scheduler.")

    ex = profile.get("executor") or {}
    out = [f"#!/bin/bash",
           f"# generated from domains/{_domain_of(c)}/catalog/{c['id']}.json"
           f" + infrastructure/sites/{profile['id']}.json, do not edit by hand",
           f"# {c['title']}",
           f"#",
           f"# Bound by {res['bound_by']}; scales with {res['scales_with']}.",
           f"# Allocation basis: {spec.get('basis', 'unstated')}",
           ""]

    out += [f"#SBATCH --job-name={c['id']}",
            f"#SBATCH --nodes=1",
            f"#SBATCH --ntasks=1",
            f"#SBATCH --cpus-per-task={spec['cpus']}",
            f"#SBATCH --mem={spec['memory']}",
            f"#SBATCH --time={spec['time']}"]
    if ex.get("exclude_nodes"):
        # Machines found to fail in practice. The same list the Nextflow
        # rendering uses, so neither executor has to rediscover them.
        out.append(f"#SBATCH --exclude={','.join(ex['exclude_nodes'])}")
    out += [f"#SBATCH --output=%x_%j.out",
            f"#SBATCH --error=%x_%j.out",
            "",
            "set -euo pipefail",
            ""]

    if profile.get("preamble"):
        out += ["# " + profile["id"] + " needs these loaded, in this order"]
        out += list(profile["preamble"])
        out.append("")

    if res.get("fans_out"):
        out += [f"# Fans out over {res['fan_out_over']}, which run.py walks serially",
                f"# inside this one allocation. Spreading them over a job array would",
                f"# mean one job per stage instead of one per capability: a scheduling",
                f"# choice, and not a change to the computation.",
                ""]

    if c["determinism"]["consumes_rng"]:
        out += ["# Draws random numbers. Without --seed this run cannot be reproduced."
                if c["determinism"].get("seed_env") else
                "# Draws random numbers and cannot be seeded, so repeat runs differ.",
                ""]

    # Where the code lives follows the catalog entry, so nothing here has to be
    # told and no machine has to know which project an entry came from.
    out += [f"cd {_on_site(profile, C.code_root(c))}",
            f"export ANALYSIS_SITE={profile['id']}",
            "",
            "# Arguments pass straight through, so this script never needs editing",
            "# when inputs or parameters change.",
            f"exec python3 {_on_site(profile, RUNNER)} catalog/{c['id']}.json \"$@\""]
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("contract", help="A capability contract, or a site profile for "
                                     "--as nextflow-config")
    ap.add_argument("--as", dest="target", default=None,
                    choices=["cli", "mcp", "openapi", "nextflow", "nextflow-config",
                             "slurm", "verify"],
                    help="Which interface to render. Required unless --repin, which "
                         "rewrites the contract rather than rendering anything.")
    ap.add_argument("--profile", default=os.environ.get("ANALYSIS_SITE", "randi"),
                    help="Site profile for --as slurm, which needs to know the "
                         "machine before it can request anything from it. Also "
                         "supplies the code root for --as verify and --repin.")
    ap.add_argument("--repin", action="store_true",
                    help="Recompute every digest this contract records and write them "
                         "back, reporting what moved. Accepting a deliberate kernel "
                         "change should be one command; hand-copying digests is how "
                         "they end up stale, and a stale pin still claims a run was "
                         "verified.")
    args = ap.parse_args()
    if not args.target and not args.repin:
        ap.error("one of --as or --repin is required")

    if args.target == "nextflow-config":
        print(as_nextflow_config(P.load_profile(args.contract)))
        return 0

    c = load(args.contract)

    def code_root():
        """Where this contract's files live: the domain that owns the entry."""
        return C.code_root(c, args.contract)

    if args.repin:
        print(f"repinning {c['id']} {c['version']}\n")
        print("\n".join(C.repin(c, args.contract, code_root())))
        return 0

    if args.target in ("slurm", "nextflow"):
        # Both need to know the machine before they can ask anything of it.
        emit = as_slurm if args.target == "slurm" else as_nextflow
        print(emit(c, P.load_profile(args.profile)))
        return 0

    if args.target == "verify":
        text, ok = as_verify(c, code_root())
        print(text)
        return 0 if ok else 1

    print({"cli": as_cli, "mcp": as_mcp, "openapi": as_openapi,
       }[args.target](c))
    return 0


if __name__ == "__main__":
    sys.exit(main())
