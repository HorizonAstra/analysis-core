# Checks

Ten questions about the tree, asked in one command.

```sh
clients/.venv/bin/python infrastructure/checks/all.py
```

Fourteen seconds, no arguments, no setup beyond the environment `./setup.sh`
builds. `--quiet` prints only what failed.

Everything here is run by `all.py` and nothing else lives in this directory. A
check that nothing runs is not a check, and for a while this folder held nine
files that nothing ran — TumorSpace's benchmark harness, carried in by the
migration, described by a README about a different directory in a different
repository. They now sit beside the code that calls them, in
`domains/spatial-transcriptomics/checks/`.

## What each one catches

| Line | Script | The failure it exists for |
|---|---|---|
| four rules | `dependencies.py` | A partition reaching into another. This is the architecture; without it the four directories are a filing convention. |
| no duplication | `duplication.py` | One file existing twice, exactly or nearly. Imports cannot see a copy, because a copy imports nothing. |
| schema | `render.py --as verify` | An entry that does not satisfy the format it claims to. |
| renders | `render.py --as <target>` | An entry that cannot be rendered as some surface. 19 entries × 6 targets = 114. |
| site configs | `render.py --as nextflow-config` | A machine that cannot be rendered as a config. Separate because this target takes a site, not a capability. |
| graph | `graph.py --as order` | Capabilities that do not order into a runnable sequence. |
| methods | `methods.py` | A domain claiming to compute something it has no code for, or the reverse. |
| formats | `formats.py` | An output format no file can be named for. |
| surfaces | `surfaces.py` | What we render a capability as drifting from what we serve. |
| data layer | `data_layer.py` | A declared shape of data no longer being found. Builds its own studies. |

## Which of these earn their keep

Worth saying plainly, because a check nobody trusts is worse than no check: it
costs the same and gets ignored.

**`dependencies.py`** is load-bearing. It has caught real leaks in all three
forms it now looks for — an import across a partition, a domain named in a
string, and a domain's shell scripts sitting in `infrastructure/`. The third
form was added on 2026-08-16, after the first two held cleanly while nine
domain files sat in this very directory.

**`data_layer.py`** is the only one that builds data and reads it back. The
others read the tree, which is identical on every machine; data is not, and a
check that had only ever seen the seven flat studies on one laptop passed a
change that broke every per-sample study on the cluster.

**`formats.py`** is forty lines and exists because every TSV this repository
produced was arriving in a browser named `.tsv.bin`. It is cheap and narrow and
stops exactly that from returning.

**`surfaces.py`** is the most expensive: it starts the tool server in a
subprocess to ask what it serves. It earns that because a capability is
described twice — the renderer builds a JSON schema, the server builds a model —
and those two descriptions drifting is invisible until a model is confused by a
tool at run time.

**`duplication.py`** took three attempts to become real. The first hashed file
contents and reported nothing; four hand-made copies defeated it. The second
compared only files sharing a name, and missed `randi-main.json` sitting beside
`randi.json` at 96% for as long as it existed. It also read the migration
manifest and used it to *excuse* pairs, which was worse than not reading it: one
row's destination is a directory, so it excused everything ever written there.
Provenance is not an explanation. Knowing a file arrived by copy says nothing
about whether it exists twice, and no source in that manifest was ever copied to
two places, so the migration created no duplicate here at all. The manifest now
says where a side came from, printed beside the pair, and decides nothing.

**`methods.py`** guards a list written for a reader, which nothing else reads
back. Cheap, and the list is otherwise the first thing to go stale.

## The interpreter is checked first, and it is fatal

Run under a python without `jsonschema` and every entry reports "not validated";
without `pandas` the data layer check dies in its imports. That was eighteen
problems and a traceback from a tree with nothing wrong with it — a result
indistinguishable from real failure, which is worse than no result.

Exit 2 means this could not check. Exit 1 means it checked and found something.
Skipped is never passed.

## Accepted, rather than fixed

`dependencies.py` and `duplication.py` each hold a `KNOWN` list: things that are
true today, recorded with why, so that a *new* one cannot arrive unnoticed.
`--known` hides them. Nothing else is ever hidden — in particular, a file's
history is not a reason to stop reporting what is wrong with it now.
