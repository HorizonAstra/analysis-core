# Where everything is

One tree of code, one tree of data per machine, one tree of results per machine.
That is the whole layout. This file says where each of them sits and which
machine it sits on, because that is the thing you cannot read off the code.

## The code

There is **one** tree, `analysis-core`, and it exists in two places that are
kept identical:

    laptop      ~/Desktop/repos/work/analysis-core
    randi       /gpfs/data/dfi-cores/rijul/analysis-core

Work happens on the laptop; nothing is edited on randi. Both are complete, so
either can run the checks and either can run an analysis, which is how a
difference between the two gets noticed.

Randi's copy holds a checkout, and a branch is switched there the ordinary way.
Built environments are ignored by git and so survive a switch; the recipes that
describe them do not, so a branch that changes one changes the recipe without
rebuilding what it describes. Two branches cannot be current at once — whoever
checks out last wins — and a client whose catalog entry differs from randi's is
refused before anything is submitted, with a message naming what randi is
checked out at.

There were two roots here until 2026-08-16, `analysis-core` and
`analysis-core-main`, so that two branches could each have code on the cluster.
That meant a second copy of every fact about the machine, and the two were
already 96% the same file when the duplication was found.

Inside it, four directories and nothing else:

    interfaces/      what a runnable thing is, and what a run is
    domains/         the science, one directory per field
    infrastructure/  the machines, and what reads and writes files
    clients/         the ways of asking: the web app, the tool server

Who may depend on whom across those four is checked rather than remembered, by
`infrastructure/checks/all.py`. That one command runs every check there is.

### It is under version control

`analysis-core` is a git repository, on `main`, pushed to
`github.com:HorizonAstra/analysis-core`. There is history and there is a way
back from a mistaken delete.

This section used to say the opposite, at length, and went on saying it for ten
commits — which is the point worth keeping. A file that describes the ground
truth is the one file nothing checks, so it is also the one that can be
confidently wrong for months. Read it as a starting point and believe the tree
over it.

### Where it came from

    TumorSpace              the spatial transcriptomics pipeline
    llm-analysis-toolkit    the microbiome and statistics work, and the web app
    local-biobakery         the microbiome toolchain

All three are still at `~/Desktop/repos/work/` and were not modified. What was
copied from where is recorded in `_migration/manifest.tsv`.

## The data

Data is what an analysis reads. Each machine answers for its own, which is why
there is no single list.

**randi** holds the spatial transcriptomics data, under the root named in
`infrastructure/sites/randi.json`:

    /gpfs/data/dfi-cores/rijul/cancer/input-data/
        NSCLC-Neoadjuvant/            one study, 19 samples
            samples/<sample>/         one Space Ranger run each, counts and spatial

One study, because there is one study. It used to appear as three: the
instrument run, the prepared samples, and a small test copy were three folders
side by side, and each looked like a study of its own.

Every sample is the instrument's own output, and every one of them carries its
`spatial/` folder. That is what makes the tissue image available for all of
them: it exists nowhere else, and previously only one sample had it, so the
interactive view could be built for that one sample and no other.

Nothing is prepared ahead of time. A capability that needs the harmonised form
gets it by running the preparation step, which is worked out from the catalog
rather than asked for; see `infrastructure/graph/plan.py`.

### The lineage that was replaced

Space Ranger was run over this cohort twice. Everything here is the second run.
The first, and every result computed from it, is at

    /gpfs/data/dfi-cores/rijul/retired/

which is outside every root anything reads, so none of it can be discovered,
resolved or listed. It is kept rather than deleted: the two runs disagree about
the data itself, one sample going from 2277 spots to 2265, so a result from the
first is not a result about what we now hold.

**laptop** holds the microbiome studies, in this tree, at `data/microbiome/`:

    AROW  HealthyDonors  Leukemia  LiverDisease  MICU  Preset  WmgxTest

`DATA_ROOT` in `clients/.env` points at `data/`, so they are visible. They are
not committed and never will be — `data/` is the first rule in `.gitignore`,
because these are human subject exports and a git history keeps a copy even
after a file is deleted.

This paragraph used to say they were still in `llm-analysis-toolkit` and that
nothing pointed at them. Both stopped being true when they were copied across.

The spatial transcriptomics study that used to sit beside them has been removed.
It was a hand-picked subset of the results below, and keeping it meant a second,
lossier answer to a question that now has one.

## The results

Results are what an analysis writes. Same rule: each machine has its own.

    randi       /gpfs/data/dfi-cores/rijul/analysis-results/<user>/
    laptop      ~/.analysis-core/results/
    web app     clients/outputs/<user>/

Under each root the layout is the same:
`<workspace>/<domain>/<capability>/<run>/`, with the outputs and a manifest of
what produced them. There is no index; what has been run is derived by reading
the manifests, so the answer cannot drift from the thing it describes.

The `<user>` segment is how two people stay apart. A person at a terminal has no
user and writes at the root; the web app gives each of its users their own, on
every machine including the cluster. The client says whose work it is submitting
in `ANALYSIS_OWNER`, and the same idea covers the record of what was submitted,
one registry per user under `clients/.userdata/state/<user>/`.

### Results come back to the machine that shows them

A run on the cluster writes on the cluster. The results panel reads a store on
the machine the web app runs on, and the interactive viewer serves files from
one, so a finished run has to be copied here before either can show it. That
happens on its own once a run lands, and it is waited for when someone opens a
viewer. Only outputs the domain allows to leave their machine are copied; one
that must stay put is named in the panel rather than shown.

## How a reference maps onto all of this

Nothing above is ever typed into an analysis. Data and results are named, and
the machine that runs the work resolves the name:

    study:NSCLC-Neoadjuvant                 the study
    study:NSCLC-Neoadjuvant/1N              one sample
    study:NSCLC-Neoadjuvant/1N/matrix       one part of one sample
    study:NSCLC-Neoadjuvant/1N/raw/spatial  something inside a part that is a folder
    study:NSCLC-Neoadjuvant@2026-08-13/1N   that sample, in one version of the data
    run:<id>/<output>                       an output of an earlier run

That is the reason the paths in this file are worth writing down once and never
again. A path says which machine, which layout, and who may see it, and none of
those are things a client can know. Ask what data exists and you are handed
references; pass one straight to an analysis and it resolves wherever the work
lands.

## Data kept in versions

A study's data can be replaced — a Space Ranger run redone, a sample added, a
batch harmonised again — and replacing it in place makes every earlier result
unreadable in the only sense that matters, because nothing can say what any of
them were computed from. So a study may hold its versions as folders:

    data/<domain>/<study>/<version>/...     the study as it stood at some point

Optional, and nothing has to move. A study with no version layer is a study with
one version that was never named, which is what most of them are, and it is found
and resolved exactly as before. A study that has one resolves to its newest
unless a reference says which, which is the `@` above.

The version belongs in the reference and nowhere else. A reference is what the
far machine resolves and what a run records as having read, so two runs over
different data have to look different to anything comparing their inputs — which
is what stops a finished run being handed back for data that has since been
replaced. Which version each sample is read from is chosen in the versions grid,
and written into the reference when the job is built.
