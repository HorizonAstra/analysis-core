"""App configuration: secrets and the dev-chosen model, loaded once from the environment
(and an optional .env file), and kept server-side.

SECURITY — read this before touching anything here:
  * The LLM API key lives ONLY in the server process environment. It is read by the
    provider at call time and is never put into an HTTP response, a log line, a cookie,
    or anything the browser can see. Reverse-engineering the client reveals no key.
  * Keep `.env` out of version control (it is gitignored) and out of the Docker image
    (pass it at runtime via env / compose env_file, never COPY it in).
  * Access to the model is gated by login (see auth.py), so the key can't be spent by
    anyone who didn't authenticate.
"""

from __future__ import annotations

import os
import re
import secrets
from pathlib import Path


def _load_dotenv() -> None:
    """Minimal .env loader (KEY=VALUE lines). Does not override variables already set in
    the real environment, so container/CI env always wins over a checked-out file.

    A trailing comment is stripped only when whitespace precedes the '#', so a value that
    legitimately contains '#' (a key, a password) survives while `KEY=value  # note` does
    not silently become the string "value  # note".
    """
    for base in (Path.cwd(), Path(__file__).resolve().parent, Path(__file__).resolve().parents[1]):
        f = base / ".env"
        if not f.is_file():
            continue
        for line in f.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = re.split(r"\s+#", v, maxsplit=1)[0]
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
        break


_load_dotenv()

# The dev picks the single model the product serves. Default: Google's flash model.
os.environ.setdefault("LLM_PROVIDER", "google")
os.environ.setdefault("GEMINI_MODEL", "gemini-2.5-flash")

PROVIDER = os.environ["LLM_PROVIDER"].lower()

# Session signing secret (HS256). Set SESSION_SECRET in .env so sessions survive restarts;
# JWE_SECRET is accepted as an alias so the same secret as symbiote can be used to share
# JWT sessions. Otherwise a per-process random secret is used (sessions drop on restart).
SESSION_SECRET = os.environ.get("SESSION_SECRET") or os.environ.get("JWE_SECRET") or secrets.token_hex(32)
SESSION_TTL = int(os.environ.get("SESSION_TTL", str(7 * 24 * 3600)))   # 7 days
COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "0") in ("1", "true", "True")


def api_key() -> str | None:
    """The active provider's key, for redaction checks only — never returned to a client."""
    if PROVIDER in ("google", "gemini"):
        return os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    return os.environ.get("ANTHROPIC_API_KEY")
