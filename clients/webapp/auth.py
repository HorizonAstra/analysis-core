"""Authentication — structured to mirror symbiote, so its real backend swaps in later.

Symbiote (symbiote-api) does: POST username/password -> a JWT `{username, expires_at}`
signed HS256 with JWE_SECRET; the identity is verified against an LDAP provider for an
authorized domain, with an env admin bypass for local dev, an optional ACL, and a DB user
row created on first login.

We mirror the *shape* with a local, in-code account backend (we have no LDAP/DB here):
  * the token is the same `{username, expires_at}` HS256 token, so pointing
    SESSION_SECRET/JWE_SECRET at the same value lets the two share sessions;
  * `authenticate()` is the single seam — to integrate symbiote, implement an
    `LdapBackend.authenticate` (LDAP bind + ACL + user upsert) and set `backend` to it;
    nothing downstream changes.

This is intentionally minimal for now (fixed accounts, no sign-up). It is not a real
identity system; its job is to separate users and gate the server-side LLM key.
"""

from __future__ import annotations

import hmac
import time

import jwt

import config

# Only these domains may sign in (admin excepted). Mirrors symbiote's AUTHORIZED_DOMAINS.
AUTHORIZED_DOMAINS = {"bsd.uchicago.edu"}
_ALG = "HS256"


def _normalize(username: str) -> str:
    return (username or "").strip().lower()


def domain_allowed(username: str) -> bool:
    """Sign-up / login is restricted to the authorized domains, except `admin`."""
    u = _normalize(username)
    return u == "admin" or any(u.endswith("@" + d) for d in AUTHORIZED_DOMAINS)


class LocalAccountsBackend:
    """The current backend: fixed accounts in code, no sign-up. Replace with an LdapBackend
    (symbiote) by implementing authenticate() against the directory + a user store. The
    only contract: return the canonical username on success, else None."""

    ACCOUNTS = {
        "aml@bsd.uchicago.edu": "aml",
        "mb@bsd.uchicago.edu": "mb",
        "ts@bsd.uchicago.edu": "ts",
        "mgx@bsd.uchicago.edu": "mgx",
        "admin": "ad",
    }

    def authenticate(self, username: str, password: str) -> str | None:
        u = _normalize(username)
        if not domain_allowed(u):
            return None
        expected = self.ACCOUNTS.get(u)
        if expected and hmac.compare_digest(expected, password or ""):
            return u
        return None


# The active backend. Swap this single line to integrate symbiote's directory auth.
backend = LocalAccountsBackend()


def authenticate(username: str, password: str) -> str | None:
    """Verify credentials; return the canonical username on success, else None."""
    return backend.authenticate(username, password)


# -- sessions: a JWT, same shape as symbiote ({username, expires_at}, HS256) ----
def make_session(username: str) -> str:
    expires_at = int(time.time()) + config.SESSION_TTL
    return jwt.encode({"username": username, "expires_at": expires_at},
                      config.SESSION_SECRET, algorithm=_ALG)


def read_session(token: str | None) -> str | None:
    """The username from a valid, unexpired, correctly-signed token (accepts both our and
    symbiote's payload keys). None if missing/expired/forged."""
    if not token:
        return None
    try:
        payload = jwt.decode(token, config.SESSION_SECRET, algorithms=[_ALG],
                             options={"verify_exp": False})
    except Exception:  # noqa: BLE001 - any decode/signature failure means not logged in
        return None
    exp = payload.get("expires_at") or payload.get("exp")
    if exp is not None and float(exp) < time.time():
        return None
    return payload.get("username") or payload.get("sub")
