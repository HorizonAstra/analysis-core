## What is being measured

A community, profiled per sample. What comes back is the makeup of that
community rather than how much of it there was, and two properties of that
follow into almost every analysis.

**The values close within a sample.** They describe proportions of a whole, so
one feature rising forces others to fall whether or not anything happened to
them. A correlation between two features of the same sample is partly an
consequence of that closure rather than of anything biological, and a method
that ignores it will report structure that is arithmetic. Which transform a number has already had
decides what may be done to it: a threshold means something on an abundance and
nothing on a log-ratio, and distances and correlations want the transformed
values rather than the raw ones.

**A community is described at a chosen level of resolution.** Coarsening it
merges distinctions, so a summary of the whole community, diversity in
particular, is a statement about the level it was computed at. Say which. Do not
build a coarser level by adding up a finer one when the data already carries it,
and never by adding up values that are not additive.

Names for diversity indices are used inconsistently in the literature, several
of them for more than one quantity. Use the one the question names and the exact
column that holds it; a cutoff meant for one index means nothing on another, and
converting between them by hand is a way to be confidently wrong.

**Independence is usually the subject, not the sample.** Where subjects give
more than one sample, treating samples as independent inflates significance.
Establish which it is before the first analysis, and where it is the subject,
use a method that accounts for it and lead with that estimate.
