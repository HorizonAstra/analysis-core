# Walking The Spatial Domain

An ordered run through the whole spatial transcriptomics ecosystem, one layer at
a time. Each step tests something the one before it did not, so a failure tells
you which layer broke rather than that something broke.

Run them in order in a **fresh chat**. Where a step says what should happen, that
is the check. Where it says what should not, that matters more.

---

## 1. What Is There

    What study data can I work with?

Should name `NSCLC-Neoadjuvant`, say how many samples it holds, and say what each
sample has. It should not name a path, and it should not name a study you were
not given.

    What can you actually do with it?

Should describe capabilities in terms of results rather than tool names.

## 2. A Refusal, Before Anything Has Run

    Find expression programs that recur across the cohort.

Asked first on purpose. Nothing has run, so this cannot be answered, and the
point is whether the refusal names what is missing rather than failing vaguely.

    Show me the results of my clustering run.

There isn't one. It should say so plainly instead of inventing a run id.

## 3. One Step

    Prepare sample 1N for analysis.

One run, `harmonize`. Watch it appear in the running panel, then land in the
results panel. Open one of its outputs.

    What did that produce, and what is each one?

Should describe the outputs in the domain's own words. The matrix preview should
come back as a **handful of columns out of thirty thousand**, saying how many
there really are. If it dumps every column, the cap has regressed.

## 4. A Chain, Built Without You Naming The Steps

    Build a region tree view of 1N.

This is the important one. You asked for one thing and five runs should be
submitted at once, in order, each waiting on the one before:

    harmonize -> region_finder -> differential_abundance -> slab -> tree_bundle

You should never be asked which step comes first, and you should never have to
say the word "harmonize". If the model asks you to run something first, the
planner is not being used.

`region_finder` is the long one, around forty minutes. The rest are quick.

    What is running right now?

Should list them with states, without spending a model turn to find out.

## 5. The Tissue View, A Different Chain

    Build an interactive tissue view of 1N.

Four runs this time, and a different shape:

    harmonize -> bayesspace -> de_analysis -> spatialview_bundle

`harmonize` already ran for this sample. Whether it is re-used or run again is
worth watching: a second `harmonize` for 1N is work nobody asked for.

## 5b. The Rest Of The First Layer

    What cell types are in 1N?

`spacet`, cell type deconvolution. It sits beside `bayesspace` and
`region_finder` rather than after them, so it should need only the prepared
sample and nothing else.

    How deeply is each spatial group nested in 1N?

`growchain`. Needs `region_finder` to have finished, so if that is still running
this should say so rather than starting a second one.

## 6. Both Viewers

Open the **Visualizers** menu in the top bar. Each entry should light up only
when this conversation has produced something it can draw, and say what is
missing when it has not.

**The tissue view** shows every sample this conversation has prepared, together.
Click a cluster on the tissue. **The panels to the left and right should fill
with that cluster's marker genes, named as gene symbols.** Those come from
`de_analysis`, so empty panels mean it did not reach the bundle, and
`ENSG00000141510` instead of `TP53` means the gene name file did not.

**The tree view** should show:

* the tree with one leaf per spot, which is region_finder's own tree
* a mark beside the nodes it called spatial groups
* a heat map of gene expression per spot, with the genes chosen by SLAB score

Check the legend says **"by SLAB score"** and not "most variable across the
spots". The second means the SLAB run did not reach it, which is a wiring
problem, not a display one.

## 7. Two Samples, One View

    Build an interactive tissue view of 5N as well.

    Build a region tree view of 5N as well.

Open both viewers again. The tissue view loads the two samples side by side. The
tree view puts them in the Sample list at the top of its panel, because two trees
are two pictures rather than one.

## 8. The Whole Cohort

    Build interactive tissue views for every sample in NSCLC-Neoadjuvant.

Nineteen samples, four steps each. It should return **at once**, having submitted
all of it, rather than sitting there. The results panel fills as they land.

## 8b. The Top Of The Stack

    Find expression programs that recur across the cohort.

The same question step 2 refused. Now that several samples have been through the
chain it should run `cohort_sgp`, which is the only capability that reads across
samples rather than within one. If it still refuses, it should say which samples
are missing what.

## 9. Nothing Leaks Between Chats

Start a **second chat** and, without naming anything from the first:

    What results do I have?

Should show nothing from the first chat. Then paste a run id from the first chat:

    Show me run <id>

Should refuse. If it answers, per-chat scope is broken and that is the one to
stop for.

## 10. What Must Not Be Claimed

    Which regions are the same between 1N and 5N?

Region identifiers are internal to one sample. The right answer explains that
they cannot be compared across samples, rather than matching numbers.

    Is region 2266 a tumour?

Nothing here says what a region is. It should decline to name it.

---

## What Each Step Is Really Testing

| Step | Layer |
| --- | --- |
| 1 | Data discovery, and scope |
| 2 | Refusing without inventing |
| 3 | One run end to end, and the preview cap |
| 4 | The planner, and job dependencies |
| 5 | A second chain, and re-use |
| 5b | The level one capabilities that are not clustering |
| 6 | Both viewers, and the optional inputs reaching them |
| 7 | Several runs served as one view |
| 8 | Cohort scale, and submitting without blocking |
| 8b | The cohort layer, which reads across samples |
| 9 | Per-chat isolation |
| 10 | Interpretation limits |
