"""Running work outside this process.

Sibling to `datasource/`, which answers where study data is read. This answers
where analysis is executed, and by what.

    reachable.py   which machines this deployment can reach, and what they hold
    local.py       this machine, as a detached process
    slurm_ssh.py   a machine with a scheduler, over ssh
    registry.py    what was submitted, on disk, so a handle survives a restart

What an executor is, and what it must answer, is in `interfaces/run/protocol.py`.
Nothing is re-exported here: each module is imported by name, because every
entry point puts what it needs on the path itself, and a package that re-exported
its siblings would make importing one of them import all of them.

This file described a `compute/` package that no longer exists and imported from
it, so `from executors import ...` had been failing outright for as long as the
package has been in this tree. Nothing noticed, because everything imported the
modules flat instead.
"""
