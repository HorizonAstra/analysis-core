# The standing brief

What the model is told before a conversation starts. Everything here is loaded
into the system prompt in filename order and is never read by the model as a
file, so a line that is wrong is not a stale document: it is behaviour.

This folder holds the part that is true of every conversation, whatever data is
in scope. The part that is true of one kind of data lives with that data's
domain, in `domains/<name>/context/`, beside the catalog entries and the study
declaration. A domain describes itself here for the same reason it describes
itself everywhere else in this tree: adding one should not mean editing a
client.

    clients/context/*.md          every conversation
    domains/<name>/context/*.md   conversations that work in that domain

## What belongs here, and what does not

The brief carries what the model cannot work out from the tools it is holding:
what this system is, how work happens in it, where judgment is required rather
than a default, how to talk, and what is not disclosed. It is principles, and it
says why, because a rule whose reason is given survives a situation its author
did not imagine.

Three things deliberately stay out.

**Anything that varies with the data.** Which studies exist, what columns they
have, how large they are. That is read with tools every time. A brief that
recalls it is a brief that is wrong the first time the data changes.

**Anything a capability already says at the point of use.** Every catalog entry
carries how to read its own output, and the model sees that when it sees the
capability. Repeating it here means two copies that drift.

**Worked examples over invented data.** An example written around a data shape
we happen to have seen today reads as a description of what data is like. We do
not own the data and cannot know what arrives next.

## Changing it

Small edits here move behaviour more than large edits to code do, and there is
no test that catches a brief that is subtly worse. Read the whole file after
changing a line in it: the sections are short on purpose, and a sentence added
in isolation is usually one that contradicts a neighbour.

The one mechanical check is that the loader still finds everything, which
`system_prompt.build_system_prompt(domains)` will show by returning it.
