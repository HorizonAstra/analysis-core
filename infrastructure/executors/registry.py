"""A durable record of submitted runs.

An executor records a JobRecord on submit and overwrites it on every poll or
cancel. It is persisted as JSON because the whole point of the run interface is
that a run outlives the process that asked for it: submit now, poll much later,
possibly from a different session on a different machine. Writes go through a
temporary file and a rename, so a crash mid-write cannot leave a half-record.

More than one process reads and writes this at once. A server submitting a run
and a product polling an earlier one are separate processes sharing one file, and
every write is a read of all records followed by a write of all records. Without
a lock held across processes the two interleave and one loses the other's run
entirely, which surfaces as a submitted analysis that no longer exists.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import sys
import tempfile
import threading
from dataclasses import asdict, fields
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "interfaces" / "run"))
from protocol import JobRecord, JobSpec, JobState


class JobRegistry:
    def __init__(self, path: str):
        self.path = path
        self._lock = threading.Lock()
        self._lock_path = str(path) + ".lock"
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)

    @contextlib.contextmanager
    def _exclusive(self):
        """Held across processes for one read-modify-write, not just this one.

        The threading lock keeps two of our own threads apart; it says nothing
        to the other process sharing the file. A separate lock file rather than
        the registry itself, because the registry is replaced by a rename and a
        lock on the old inode would guard nothing after the first write.
        """
        with self._lock:
            with open(self._lock_path, "w") as fh:
                fcntl.flock(fh, fcntl.LOCK_EX)
                try:
                    yield
                finally:
                    fcntl.flock(fh, fcntl.LOCK_UN)

    def _load_all(self) -> dict[str, JobRecord]:
        if not os.path.exists(self.path):
            return {}
        with open(self.path) as fh:
            raw = json.load(fh)
        out: dict[str, JobRecord] = {}
        spec_fields = {f.name for f in fields(JobSpec)}
        rec_fields = {f.name for f in fields(JobRecord)} - {"spec", "state"}
        for jid, d in raw.items():
            # A record on disk may have been written by an older version of this
            # tree, and a field that has since been dropped is not a reason to
            # refuse to answer what a run is doing. The whole point of persisting
            # a handle is that it outlives the code that made it.
            spec = {k: v for k, v in d["spec"].items() if k in spec_fields}
            rest = {k: v for k, v in d.items() if k in rec_fields}
            try:
                out[jid] = JobRecord(spec=JobSpec(**spec), state=JobState(d["state"]), **rest)
            except (TypeError, ValueError):
                continue     # unreadable beyond repair: skip it rather than fail the listing
        return out

    def _write_all(self, records: dict[str, JobRecord]) -> None:
        data = {}
        for jid, rec in records.items():
            d = asdict(rec)                 # recurses into the nested JobSpec
            d["state"] = rec.state.value
            data[jid] = d
        dirn = os.path.dirname(self.path) or "."
        fd, tmp = tempfile.mkstemp(dir=dirn, suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(data, fh, indent=2)
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)

    def put(self, rec: JobRecord) -> None:
        with self._exclusive():
            recs = self._load_all()
            recs[rec.job_id] = rec
            self._write_all(recs)

    def get(self, job_id: str) -> JobRecord | None:
        return self._load_all().get(job_id)

    def all(self) -> list[JobRecord]:
        return list(self._load_all().values())

    def forget(self, job_ids) -> int:
        """Drop these runs from the record. Returns how many were dropped.

        For work that has been retired: its outputs have been moved out of the
        results tree on purpose, and a registry that still lists it is claiming
        something that is not there. That is not merely untidy. A finished run
        is what re-use hands back instead of doing the work again, so a retired
        one left here is offered as the answer to a question whose answer has
        been put away, and the caller gets a handle to nothing.

        The record is not lost by this. A run's manifest is retired alongside
        its outputs, and the manifest is the account of what happened; this file
        is the list of what can still be reached.
        """
        wanted = set(job_ids)
        if not wanted:
            return 0
        with self._exclusive():
            recs = self._load_all()
            gone = [j for j in wanted if j in recs]
            for j in gone:
                del recs[j]
            if gone:
                self._write_all(recs)
            return len(gone)
