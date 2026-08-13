"""What went wrong, taken out of a log.

A failed run used to report a path. On a cluster that path is on the cluster, so
the only thing that could read it was a person with an ssh session, and the model
holding the conversation could not. What it did instead was guess: one observed
run of submitted code failed eleven times in two minutes, each attempt a fresh
guess at a cause that was written down the whole time.

So the machine that holds the log reads it, and the run reports the reason rather
than the address of the reason. It costs one extra read, on failure only, once:
a record is terminal after this, and `poll` returns early on a terminal record
without asking anything.

What comes back is bounded on purpose. A log can be megabytes, this goes into a
registry file and from there into a conversation, and the useful part of a failure
is almost always short. Better a clipped traceback than a byte budget spent on
progress bars.

Nothing here interprets the failure. It selects lines and returns them verbatim,
so what the person reads is what the tool actually said.
"""

from __future__ import annotations

import re

# Where a failure usually starts saying what it is. Ordered by how definite each
# one is, not by language: the first marker found from the bottom wins, so a
# traceback under a wall of warnings is still what gets reported.
_STARTS = re.compile(
    r"^\s*(Traceback \(most recent call last\)"
    r"|Error in |Error:|ERROR:|FATAL|Fatal error"
    r"|Exception in |Caused by:"
    r"|slurmstepd: error:"
    r"|[A-Za-z_.]+(?:Error|Exception):"
    r")", re.MULTILINE)

# Lines that are output rather than explanation. A log that ends in these has
# said nothing about the failure, and showing them instead of what came before
# is worse than showing nothing.
_NOISE = re.compile(
    r"^\s*(\||\d+%|\[=*>?\s*\]|Loading required package|Warning message|"
    r"also installing|trying URL|content type|downloaded \d)", re.IGNORECASE)

TAIL_LINES = 14          # how much of a log with no marker in it is worth showing
LIMIT = 1400             # characters, so a registry entry stays a registry entry

# How much of a log to fetch back before looking for the reason in it. Enough to
# hold a traceback under a wall of progress output, bounded so a runaway log
# costs its last page rather than all of it.
#
# Here rather than in each executor. How the bytes are got differs — a local run
# seeks in a file, a cluster run runs `tail` over ssh — but how many to get is
# one decision, and two copies of a number like this drift silently.
TAIL_BYTES = 64_000


def reason(text: str, *, limit: int = LIMIT, tail: int = TAIL_LINES) -> str:
    """The part of a log that explains a failure, or "" when it explains nothing.

    Read from the bottom. A run that failed after doing a lot of work has the
    explanation at the end, and the top of the log is setup.
    """
    if not text or not text.strip():
        return ""
    lines = [ln.rstrip() for ln in text.replace("\r\n", "\n").split("\n")]
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return ""

    # The last place something started explaining itself, widened to the whole
    # explanation rather than the line that matched.
    #
    # Widening is the point. A Python traceback matches twice — once at
    # `Traceback (most recent call last)` and again at the exception that ends
    # it — and taking the later match alone reports what went wrong while
    # throwing away where, which is the half a person actually needs. The same
    # applies to a pair of `slurmstepd: error:` lines, where the first says
    # oom-kill and the second only says the limit was exceeded.
    #
    # So: find the last marker, then walk back over the lines it belongs with.
    # A line belongs with it when it is indented, which is how every language
    # here writes a continuation, or when it is a marker in its own right.
    starts = [i for i, ln in enumerate(lines) if _STARTS.match(ln)]
    if starts:
        i = starts[-1]
        while i > 0:
            above = lines[i - 1]
            # A blank line ends the block, and so does output that happens to be
            # indented. Progress bars are written with a leading space by more
            # than one of the tools here, and taking them for continuation lines
            # puts a half-drawn progress bar on top of the traceback.
            if not above.strip() or _NOISE.match(above):
                break
            if above[:1].isspace() or _STARTS.match(above):
                i -= 1
                continue
            break
        chosen = lines[i:]
    else:
        chosen = [ln for ln in lines if ln.strip() and not _NOISE.match(ln)][-tail:]

    out = "\n".join(chosen).strip()
    if len(out) > limit:
        # Keep the end. For a traceback that is the exception itself, which is
        # the one line somebody would keep if they could keep only one.
        out = "…\n" + out[-(limit - 2):]
    return out


def described(state: str, code: str = "", note: str = "", log: str = "") -> str:
    """One line for a finished run, with the reason if there is one.

    The scheduler's own word for it comes first, because "OUT_OF_MEMORY" and
    "TIMEOUT" are answers on their own and a traceback under them is a
    consequence rather than a cause.
    """
    head = " ".join(p for p in (state, f"({code})" if code and code not in ("0:0", "0") else "",
                                note) if p).strip()
    why = reason(log) if log else ""
    return f"{head}\n{why}" if why else head
