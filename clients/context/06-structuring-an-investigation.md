## Structuring an investigation

A way to keep a piece of work rigorous and well ordered, from data to a claim
somebody else can act on. It is structural, so it holds whatever the science is:
the domain knowledge arrives separately, beside that domain's data.

This is a scaffold for thinking, not a script. Instantiate the parts that fit,
adapt them, and skip or add steps when the question calls for it. Nothing here
requires a fixed sequence.

### Three kinds of step

**Preparation.** A deterministic operation: some input becomes a form the next
step can use. No judgment, no inference. A transform, a filter, an aggregation,
a correction for multiple testing.

**Method.** A statistical procedure run against prepared data, returning a
structured result. A correlation, a rank test, a mixed model, an ordination, a
survival fit.

**Interpretation.** A judgment, formed by reading method results against what is
already established and against what is known about this kind of data. This is
the only kind of step that reasons, and the only one that adds to what is
established. It is you, and it is not something a capability does for you.

### How steps compose

A **module** is a cluster of steps that together answer **one question about the
world**. It is the unit of reasoning, and it usually runs find-then-challenge
inside itself: prepare, apply a method, interpret.

A **study shape** is the blueprint for a class of investigation — which modules
are wanted, in what order, depending on what. Walking one is conducting the
study. One shape covers many questions; a new class of study is a new shape,
not new machinery.

### The two things the graph does not produce

**What is known already.** Pathways, clinical priors, what an organism does, how
a platform behaves. It arrives with the domain rather than being derived, and
any step may draw on it.

**What this investigation has established.** The record of what is settled so
far, written only by interpretation and read by every interpretation after it.
Here that is the saved results and the conclusions attached to them. A result
saved without the conclusion it supports is half of an entry.

### The modules worth knowing

Each is defined by the question it answers, not by the method it uses. Marked
questions can branch — one of them can open several lines at once.

| Module | The question | When it applies |
|---|---|---|
| Discovery *(branches)* | Is there a signal worth pursuing? | Some layer has at least two variables |
| Characterization | What does the signal look like — direction, size, and whether its parts are independent? | A signal exists |
| Confound exclusion | Is it genuine, or explained by something else? | A signal exists, and other variables exist to control for |
| Attribution *(branches)* | What drives it, or is driven by it? | A signal survives confound exclusion |
| Mediation *(branches)* | What sits on the path between a driver and an impact? | A driver and an impact both exist |

Find, then challenge, is the backbone. Discover or attribute a signal, then
stress-test it before trusting it. A signal that crosses layers is not a
different kind of signal and follows the same path.

### What an association can turn out to be

Any association between A and B resolves into one of four things, and keeping
all four in view is what turns a correlation into a claim worth defending:

- **Driver** — A drives B.
- **Impact** — B drives A.
- **Confound** — some third thing drives both.
- **Mediation** — A drives something that drives B.

Confound exclusion rules out the third. Attribution separates the first two.
Mediation finds the thing on the path.

### Where this meets what you are holding

No new machinery is needed to work this way. Preparation is the transform and
correction capabilities. Method is the statistical ones and the opinionated
compositions built on them. Interpretation is yours, and saving a result with
its conclusion is how it gets recorded. What is known already is this brief plus
the domain's own. What has been established is the saved work.

So: take the shape that fits, walk its modules, and for each one choose the
preparation and the method that answer its question — then interpret and record
before moving on.
