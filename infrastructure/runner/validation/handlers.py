"""Execution-error handling: turn a raw library failure into a readable
AnalysisError tagged with the analysis name, while letting validation problems and
NotImplementedError pass through unchanged.

This replaces the dozens of ``try: ... except Exception as e: raise
Exception(f"Error performing X: {e}")`` blocks that were scattered through the old
router and the primitive cores.
"""

from __future__ import annotations

import functools
from contextlib import contextmanager

from .exceptions import AnalysisError, ValidationError


@contextmanager
def wrap_errors(analysis: str):
    """Wrap a block so any unexpected failure becomes
    AnalysisError("Error performing <analysis>: ..."). ValidationError (a bad
    request) and NotImplementedError (an intentional stub) propagate untouched."""
    try:
        yield
    except (ValidationError, NotImplementedError):
        raise
    except AnalysisError:
        raise
    except Exception as e:  # noqa: BLE001 - deliberately broad: this is the boundary
        raise AnalysisError(f"Error performing {analysis}: {e}", analysis=analysis) from e


def guard(analysis: str):
    """Decorator form of wrap_errors for a whole function."""
    def decorator(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            with wrap_errors(analysis):
                return fn(*args, **kwargs)
        return wrapper
    return decorator
