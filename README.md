# analysis-core

One analysis service across scientific domains, machines and ways of asking.

Nothing here was moved. Every file was copied from `TumorSpace`,
`llm-analysis-toolkit` or `local-biobakery`, which remain untouched.
`_migration/manifest.tsv` records where each one came from, and
`_migration/copy.sh` re-runs the copy.

## Layout

    interfaces/     what a runnable thing is, and what a run is. Depends on nothing.
    domains/        the science. One directory per field, each with its own
                    catalog, kernels, environments and standing context.
    infrastructure/ the machines. Runs whatever it is handed, knows no science.
    clients/        ways of asking. Contains no science and no machine settings.

## Two things to know

**A capability is addressed by domain and name.** Both spatial transcriptomics
and microbiome have a capability called differential abundance, so the name on
its own is not enough. The qualified name is derived from where the entry sits,
not written inside it.

**A machine never names a project.** The runner resolves a kernel relative to
the domain that owns the catalog entry. A site file describes the machine and,
where a rendered script has to run elsewhere, where this tree is installed
there. Nothing else.

## What was deliberately not separated

A domain's kernels are treated as whole, even where general statistics are
visibly tangled up in them. Pulling Ripley's K or an SVD selection out of the
spatial kernels and into `statistics` is real work with no result to show for
it, and the risk of changing an answer while doing it is not worth taking. Those
kernels are treated the way a third-party package is treated: pinned, described,
and left alone.

The exception is code we wrote ourselves in the toolkit, where the seam is
already clean. Its general engines are in `domains/statistics`. Its
`differential.py` is not, because it is an opinionated composition of them with
domain decisions baked in, and that makes it microbiome.

## Running one thing

    python3 infrastructure/runner/run.py domains/<domain>/catalog/<id>.json \
        --<input> <path> --outdir <dir> --profile <site>

    python3 infrastructure/render-targets/render.py <entry> --as verify
    python3 infrastructure/graph/graph.py --as order
