"""What a run is.

Four operations, and the shapes they carry. Nothing here names a science, a
machine, or a language, and nothing here imports anything from the rest of the
tree. That is the whole point: a client speaks this to ask for work, an executor
implements it to perform work, and neither has to know what the other is.

    submit   a capability, its inputs and its parameters, returning at once
    poll     what state a run is in, cheap enough to call repeatedly
    cancel   stop it where the site allows
    collect  the outputs the catalog declares, and the record of what made them

A run is long. `submit` returns a handle rather than a result, and nothing here
ever blocks waiting.

A run writes only where it is permitted to. `submit` validates every write path,
canonicalized against `..` and symlink escape, before anything with a side
effect happens. Inputs are read-only. See `WriteScope`.

What a capability *is* lives in the catalog, not here. This file used to carry a
`Launcher`, so that each pipeline could contribute its own argument list; a
catalog entry supplies that now, so the concept is gone rather than moved.
"""

from __future__ import annotations

import os
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Mapping


class JobState(str, Enum):
    SUBMITTED = "submitted"   # accepted and queued
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    UNKNOWN = "unknown"       # the executor cannot tell, e.g. aged out of the scheduler

    @property
    def terminal(self) -> bool:
        return self in (JobState.COMPLETED, JobState.FAILED, JobState.CANCELLED)


@dataclass(frozen=True)
class WriteScope:
    """The only directories a run may write under.

    Everything else, most of all the inputs, is read-only. `check` canonicalizes
    first, so `..` and a symlink pointing outside are both caught.
    """
    roots: tuple[str, ...]

    def contains(self, path: str) -> bool:
        rp = os.path.realpath(path)
        return any(
            rp == root or rp.startswith(root + os.sep)
            for root in (os.path.realpath(r) for r in self.roots)
        )

    def check(self, **labelled_paths: str) -> None:
        bad = {name: p for name, p in labelled_paths.items()
               if p is not None and not self.contains(p)}
        if bad:
            offenders = "; ".join(f"{name}={p}" for name, p in bad.items())
            raise PermissionError(
                f"write path(s) outside allowed roots {self.roots}: {offenders}"
            )


@dataclass(frozen=True)
class JobSpec:
    """One request to run one capability.

    `capability` is qualified, as in `microbiome/metaphlan`, because two domains
    can name the same analysis and both of ours do. Input names are the ones the
    catalog entry declares; this side does not invent them and does not know
    what any of them mean.
    """
    capability: str
    version: str
    inputs: Mapping[str, str]
    site: str
    parameters: Mapping[str, Any] = field(default_factory=dict)
    seed: int | None = None
    # Runs that must finish first, by their job ids. An input naming an output of
    # one of them is legitimate, because a reference is resolved when the work
    # starts rather than when it is submitted. That is what lets a chain be
    # submitted in one go instead of a caller sitting in a poll loop between the
    # steps, and it is why this belongs here rather than in a client: only the
    # site can make one run wait for another, and each site does it differently.
    #
    # A predecessor that fails takes the rest of the chain with it. A step that
    # ran anyway would resolve its input against a run that produced nothing.
    after: tuple[str, ...] = ()
    # Which shelf of the store the result belongs on. Not where on disk: a
    # caller that names its own destination is how results end up scattered
    # across whatever directory someone happened to be in.
    workspace: str = "default"
    # Do this even if it has been done. A site is allowed to hand back a finished
    # run whose every input, parameter and pinned digest matches, because that
    # run is the answer; this is how a caller says it wants the work performed
    # anyway.
    #
    # It exists because "I already have that" and "I want it computed again" are
    # different requests that are otherwise indistinguishable. Someone who
    # suspects a stored result, or who has changed a kernel without the entry
    # recording it, is asking the second, and there was no way to say so.
    #
    # It does not make a new answer. Identical work produces identical output,
    # so what comes back is the same result recorded twice — and if it is not,
    # that difference is the finding.
    fresh: bool = False
    # Filled in by the executor once the store has allocated a directory, so a
    # record can be read back later. Never supplied by a caller.
    output_path: str | None = None
    scratch_path: str | None = None

    def __post_init__(self) -> None:
        # Every executor writes inputs and then parameters into one `--name`
        # flag namespace, so a parameter sharing an input's name overwrites it
        # and the run reads something other than what was asked for. Checked on
        # the spec rather than in each executor because it is a property of the
        # request: a spec that cannot be submitted correctly anywhere should not
        # be constructible. Callers that know the contract reject this earlier
        # and say more; this is what catches everything else.
        both = sorted(set(self.inputs) & set(self.parameters or {}))
        if both:
            raise ValueError(
                f"{self.capability}: {', '.join(both)} given as both an input and a "
                f"parameter. On the command line the parameter would replace the "
                f"input, so the run would not read what was asked for.")


@dataclass
class JobRecord:
    """What an executor persists about a submitted run, and what `poll` returns."""
    job_id: str                       # stable here, whatever the scheduler calls it
    spec: JobSpec
    executor: str
    native_id: str | None = None      # e.g. the SLURM job id
    state: JobState = JobState.SUBMITTED
    submitted_at: str | None = None   # ISO-8601
    updated_at: str | None = None     # ISO-8601
    log_path: str | None = None
    detail: str | None = None         # last human-readable status or error line


@dataclass(frozen=True)
class Result:
    """What `collect` returns: the declared outputs, and what produced them."""
    job_id: str
    outputs: Mapping[str, str]        # declared output name -> path
    manifest_path: str                # the run record: digests, parameters, seed


class Executor(ABC):
    """A place work can run.

    An implementation owns one execution model and nothing else. A local
    subprocess, a scheduler reached directly, a scheduler reached over a
    network: three implementations, one interface, no capability named in any of
    them.
    """

    name: str

    # How long work started here is worth waiting on before it is fair to call
    # it long-running, in seconds. Zero means never wait.
    #
    # This exists because "started" and "finished" are different things to say
    # and the caller was only ever able to say the first. A capability run on a
    # workstation finishes in under a second, and the answer still read "this
    # runs on a machine, leave it and come back" — so a result that was already
    # sitting there was described as being in progress, and nobody went back for
    # it. Waiting a moment and saying which of the two actually happened is the
    # whole fix.
    #
    # A property of the execution model rather than of a site or a capability: a
    # scheduler queues, and how long a queue takes is not something the thing
    # submitting to it can know, so it does not wait at all. A subprocess on this
    # machine is either quick or it is genuinely long work, and a couple of
    # seconds tells them apart.
    settles_in: float = 0.0

    @abstractmethod
    def submit(self, spec: JobSpec) -> JobRecord:
        """Start a run and return at once, in state SUBMITTED.

        Must validate every write path against this executor's WriteScope before
        anything with a side effect happens.
        """

    @abstractmethod
    def poll(self, job_id: str) -> JobRecord:
        """Current state of a run. Cheap, and safe to call repeatedly."""

    @abstractmethod
    def cancel(self, job_id: str) -> JobRecord:
        """Stop a run where the site allows it, and return the updated record."""

    @abstractmethod
    def collect(self, job_id: str) -> Result:
        """The declared outputs of a finished run, with the record of what made them."""

    def list_jobs(self) -> list[JobRecord]:
        """Every run this executor knows about. A convenience, not part of the four."""
        raise NotImplementedError

    # --- what this place can do -------------------------------------------
    # Only an executor knows its own machine, so only an executor can answer
    # these. A caller that works them out itself is reading someone else's
    # filesystem to decide what a second machine can do.

    def available(self) -> bool:
        """Whether this executor can be used at all right now.

        A machine reached over a network can be down or unreachable, and a
        capability offered on a site that cannot be contacted fails minutes
        later for a reason that has nothing to do with the science.
        """
        return True

    def can_run(self, contract: Mapping[str, Any]) -> tuple[bool, str]:
        """Whether this site can run this capability, and why not if it cannot.

        `contract` is a catalog entry as plain data. Nothing is imported to read
        it, because an interface depends on nothing.
        """
        return True, ""

    def datasets(self) -> list[dict]:
        """What data this machine holds.

        Asked of each site for the same reason `can_run` is: only a machine can
        say what is on it. A caller that reads one filesystem and reports the
        result as the whole world both hides the data that is really there and
        offers data the work will never reach.
        """
        return []

    def runs(self, workspace: str | None = None, capability: str | None = None,
             limit: int = 50) -> list[dict]:
        """What results this machine already holds.

        Not the same question as "what did I submit". A machine's store outlives
        any one client's memory of it, and it holds results that arrived by
        other routes: a run from a session that has since ended, or work done
        before this system existed and recorded afterwards. Asking the machine
        is the only way to learn about those, and they are exactly the ones
        worth learning about, because nothing else can point at them.
        """
        return []

    def can_reach(self, reference: str) -> bool:
        """Whether this machine can resolve a reference a caller is about to pass.

        Being able to run something and being able to read what it runs on are
        two questions, and only asking the first sends work to a machine that
        cannot see its own inputs. That is not a failure anyone can read: the
        run starts, and dies resolving a name that exists somewhere else.

        Answered True by default, because a literal path is not this layer's to
        second-guess and a machine that cannot tell should not veto the work.
        """
        return True

    # --- getting an answer back -------------------------------------------
    # `collect` gives paths, and a path on a machine the caller cannot see is
    # not an answer. These two are how a result becomes readable wherever the
    # run happened.

    def read(self, job_id: str, name: str | None = None,
             rows: int = 20) -> list[dict]:
        """Enough of a finished run's returnable outputs to read.

        One entry per output: a table as columns and its first rows, text as
        lines, an image as a reference to fetch. Naming one output asks for
        that one alone, which is how a caller gets more of the table it cares
        about without dragging the rest along.
        """
        raise NotImplementedError

    def fetch(self, job_id: str, name: str, dest: str) -> str:
        """Copy one returnable output to `dest` on the caller's machine.

        For anything that has to be shown rather than summarised: a figure, or
        a table someone wants to download. Returns the local path.
        """
        raise NotImplementedError

    def manifest(self, job_id: str) -> dict:
        """The record of what produced a run, as plain data.

        Separate from `collect`, which answers where the outputs are. This is
        what was run, with what, and whether it can be relied on, and a caller
        that has to show a result needs it wherever the work happened. Reading
        the file directly only works when the run was here.
        """
        raise NotImplementedError
