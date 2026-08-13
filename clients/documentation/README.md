# Documentation

What is here is what has no home in the code. Everything else was removed.

This folder arrived as a copy of another project's documentation and was never
revised, so it described modules that had been rewritten, tools that no longer
exist and a layout that had changed. A document that restates a module is a
second copy of the same explanation, and the second copy is the one that goes
quietly wrong. Every module in this tree carries its own explanation in its
docstring, next to the code it is about, where it cannot drift.

    clients-and-context.md          the standing brief, and where each part of it comes from
    deployment.md                   what is decided at build time and what at run time, and why
    future-work.md                  directions the design is meant to grow into
    secondary-analysis-roadmap.md   running shotgun pipelines on the cluster
    tertiary-stats-roadmap.md       adding bioBakery's statistics as a second engine

For everything else:

    README.md                       what this tree is, and the rule that holds it together
    MAP.md                          which machine holds the code, the data and the results
    clients/context/README.md       what belongs in the model's standing brief
    <module>.py                     what that module does and why it is shaped that way

Removed in August 2026: architecture, data-format, data-layer, errors, features,
mcp-server, primitives, provenance, visualization, web-app, workflows. All eleven
are unchanged in the `llm-analysis-toolkit` repository if any of them is wanted
back, where they correctly describe that project.
