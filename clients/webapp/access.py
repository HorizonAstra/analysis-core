"""Per-user access — by allowlist, not by copying data.

Two independent gates, both enforced in the data layer rather than in the UI:

  * **domain** (`DOMAIN_ACCESS`) — the families of data a user may reach at all
    (`data/<domain>/<study>/`, see datasource/domains.py). A chat runs in exactly one
    domain, which is also what decides the standing context the model is given.
  * **study** (`ACCESS`) — which studies within those domains.

Each user's MCP server is launched with ALLOWED_DOMAINS and ALLOWED_STUDIES set from
these, so the data layer itself refuses anything outside them (the model never learns
those studies exist). The same sets drive the UI, so users are never shown a domain,
study, omic, or feature they can't reach.

`None` means unrestricted on that gate. A user unrestricted on *both* is an admin. An
unknown user gets nothing.
"""

from __future__ import annotations

import os

# Studies a user may see. None = every study, subject to their domain access.
ACCESS: dict[str, list[str] | None] = {
    "aml@bsd.uchicago.edu": ["Leukemia"],
    "mb@bsd.uchicago.edu": ["Leukemia", "LiverDisease", "HealthyDonors"],
    "ts@bsd.uchicago.edu": None,   # every study in its domain (spatial only)
    "mgx@bsd.uchicago.edu": ["WmgxTest"],   # only the secondary-analysis test study
    "admin": None,                    # full access
}

# Domains a user may see. None = every domain.
DOMAIN_ACCESS: dict[str, list[str] | None] = {
    "aml@bsd.uchicago.edu": ["microbiome"],
    "mb@bsd.uchicago.edu": ["microbiome"],
    "ts@bsd.uchicago.edu": ["spatial-transcriptomics"],
    "mgx@bsd.uchicago.edu": ["microbiome"],
    "admin": None,                    # full access
}


def allowed_studies(user: str) -> list[str] | None:
    """The studies a user may see (None = all, within their domains). Unknown: none."""
    return ACCESS.get(user, [])


def allowed_domains(user: str) -> list[str] | None:
    """The domains a user may see (None = all). Unknown users get none."""
    return DOMAIN_ACCESS.get(user, [])


def is_admin(user: str) -> bool:
    """Unrestricted on both gates. Anything narrower is a scoped user."""
    return allowed_studies(user) is None and allowed_domains(user) is None


# ---------------------------------------------------------------------------------------
# What a user can actually reach: the allowlists above, intersected with what is on disk.
# These answer "what may this user see", which is this module's question — they were in
# engine.py, where they had nothing to do with running a model turn.


def _found(*, wait: bool = True) -> list[dict]:
    """Every dataset every machine this deployment reaches holds.

    Asked of the machines rather than read off this one. Data lives where the
    work runs, which is often not here: a deployment whose studies are on a
    cluster showed an empty product to everyone when this read a local
    filesystem. Each machine answers for itself and the answers are merged, so
    what a person is offered is what could actually be analysed.

    `wait=False` where an answer that is merely late is better than a page that
    does not come. Deciding what a chat may reach has to wait; decorating a panel
    does not.
    """
    from executors import reachable
    return reachable.datasets(wait=wait)


def accessible_domains(user: str, *, wait: bool = True) -> list[str]:
    """Every domain this user may reach that actually holds data. The menu a chat's
    domain is chosen from; one element means no choice to make."""
    allow = allowed_domains(user)
    found = sorted({d["domain"] for d in _found(wait=wait) if d.get("domain")})
    return found if allow is None else [d for d in found if d in allow]


def accessible_data(user: str, domains=None, *, wait: bool = True) -> list[dict]:
    """Every dataset this user may reach, as the machine holding it described it.

    The rows rather than the names, for callers that need what is in a study and
    not only that it exists. Both allowlists are applied here explicitly, because
    the web process itself is unrestricted.
    """
    allow = allowed_studies(user)
    domains_ok = (set(accessible_domains(user, wait=wait)) if not domains
                  else set(domains))
    return [d for d in _found(wait=wait)
            if (allow is None or d["study"] in allow)
            and d.get("domain") in domains_ok]


def accessible_studies(user: str, domains=None) -> list[str]:
    """Every study this user may reach, before any per-chat scoping. This is the same set
    the user's MCP server was launched with. `domains` narrows further to the domains a
    chat actually works in.
    """
    return sorted(d["study"] for d in accessible_data(user, domains))
