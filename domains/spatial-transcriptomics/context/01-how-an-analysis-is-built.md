## How an analysis is built here

Work in this domain is layered, and each capability says which layer it sits at
and whether it reasons about one sample or many. What follows is what those
layers mean, so that a question can be placed before anything is run.

**Nothing is analysed where it lands.** The instrument's own output has to be
turned into a matrix with its labels and its spot positions first, and every
later step reads that rather than the original. A sample that has not been
through this cannot be analysed at all, whatever else exists for it.

**A sample is divided before anything is compared**, and there are two different
ways to divide it. They are not interchangeable and their labels have nothing to
do with each other.

One assigns every spot to one of a chosen number of groups, using position as
well as expression, and gives a flat partition of the tissue. How many groups is
something someone chose.

The other builds a nested tree of groups from expression similarity and physical
clumping, and pairs each group against the rest of its own split. The
comparisons come with it rather than being chosen afterwards, and the structure
is hierarchical rather than flat.

Nothing joins a label from one to a label from the other. Deciding which of the
two a question is about is the first real choice in most of this work, and
answering with the wrong one produces something that looks like an answer.

**What differs between groups depends on which division was used.** Off the flat
partition, the question is which features mark a group out. Off the tree, the
question is which features separate a group from its sibling, so the unit is a
pair rather than a group, and a feature can separate one pair and not another
within the same sample.

**Some steps describe a difference rather than adding evidence for it.** How
widely a feature's bias is spread across the tissue, and how deeply a group sits
inside the tree, both take a finding that has already been made and say more
about it. Neither makes it more significant, and neither is a substitute for the
test that found it.

**What is inside a spot is a separate line of work.** A spot is a mixture, so
estimating its composition reads the matrix directly and depends on no division
at all. It can be done whether or not anything has been divided.

**Almost everything here belongs to one sample.** Identifiers produced inside a
sample mean nothing outside it, so stacking per-sample results together by hand
does not make a cohort claim: the same label in two samples refers to unrelated
things. A claim about the cohort has to come from the step that reasons across
samples, which is the only one whose result does not belong to any single one of
them.

**Check what a result is keyed on before joining two of them.** A spot, a group,
a group against its sibling, a feature, a sample, the cohort. Two results keyed
differently do not join, and the fact that both have a column of feature names
is not enough to make them.
