# Clients and the standing brief

Every surface that drives the model builds the same prompt, from the same files,
through `clients/system_prompt.py`. That is the whole reason the assembly is not
inside any one of them: a guardrail that only reaches the web app is not a
guardrail.

## Where the brief comes from

    clients/context/*.md          every conversation, whatever is in scope
    domains/<name>/context/*.md   conversations that work with that kind of data

`build_system_prompt(domains)` returns the base frame, then the shared brief,
then one section per domain in scope, then a note if more than one is. A
conversation is never told about a kind of data it cannot reach, and passing no
domain yields the shared brief alone, which is the honest state before anything
has been chosen.

The split is the one the rest of the tree makes. What is true of every
conversation belongs to a client. What is true of one kind of data belongs to
the domain, beside its catalog and its study declaration, so that adding a
domain never means editing a client.

What belongs in the brief, and what deliberately does not, is documented in
[`clients/context/README.md`](../context/README.md). Read that before changing a
line of it: small edits there move behaviour further than large edits to code,
and nothing fails when one is wrong.

## What else the model is told

The standing brief is not the only thing in the prompt. Two things are added per
turn, because they are facts about this conversation rather than about the
system:

- **What is in scope.** The studies this chat may reach, so the model knows the
  shape of its world rather than discovering it through a not-found.
- **What has finished.** A run outlives the turn that started it, so outcomes
  are carried into the next turn as statements, once each. This is why the model
  is told not to poll: the answer was already sitting in a registry, and asking
  for it spends a turn to learn what the filesystem knew.

## What the model is told per capability

Everything else it knows comes from the catalog: a capability's description, its
arguments and their meanings, and how to read its output are generated from the
entry rather than written in any client. That is why the brief does not repeat
them. Two copies of a caveat drift, and the one at the point of use is the one
that gets read.
