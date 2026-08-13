"""Exception types for the analysis layer.

The primitives stay pure (they assume validated input and raise plain ValueError on
a broken contract). Everything user-facing — request validation and the wrapping of
a library failure into a readable message — happens in this errors package and
speaks in these two types.
"""

from __future__ import annotations


class AnalysisError(Exception):
    """Any analysis-layer failure surfaced to the caller (a validation problem or a
    wrapped execution failure). Carries the analysis label for context."""

    def __init__(self, message: str, *, analysis: str | None = None):
        self.analysis = analysis
        super().__init__(message)


class ValidationError(AnalysisError):
    """The request was malformed: a missing field, a wrong type, an out-of-range
    value, a length mismatch, or not enough usable data."""
