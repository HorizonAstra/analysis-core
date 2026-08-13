"""Serve an interactive viewer over a bundle a run produced.

The viewer is third-party software that computes nothing. It reads a directory
of files laid out a particular way and draws them in a browser, and a capability
in the spatial domain writes exactly that directory. This is what joins the two.

How it works, and why it needs no change to a viewer's own code: a viewer asks
for its data with relative paths, next to its `index.html`. So the whole
application is mounted under a prefix naming the viewer and what to show,

    /viewer/<viewer>/<key>/            the viewer's own files, read only
    /viewer/<viewer>/<key>/data/...    the bundles that key names

and its relative requests land in the right place on their own. That matters
beyond convenience: one of these may not be modified or redistributed, so an
integration that required editing it would not be one we could use.

`<key>` is a run id, or `chat:<id>` for every bundle of that kind a conversation
has built. The second exists because a viewer only compares samples it loaded
together, while bundles are built one sample at a time.

Two rules, both enforced here rather than trusted to the caller:

  * A run is served only to someone entitled to it. The session says who is
    asking, and the run has to be one of theirs. Without this, a run id in a URL
    would be a password that anybody could guess.
  * Nothing outside the bundle is reachable. Every path is resolved and checked
    to be inside, so `..` in a request cannot walk out of it into the rest of
    the results directory.

Where a viewer itself comes from depends on its licence. The tree viewer is GPL
v3, which allows copying it, so it sits in `web/tree/`. The spatial one is
academic and non-transferable, so it is not in this repository at all and
SPATIALVIEW_ROOT names the copy the operator installed; unset, that one mounts
nothing and says so rather than half-working.
"""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse, HTMLResponse

VIEWER_ROOT = os.environ.get("SPATIALVIEW_ROOT", "")
# Where each viewer's own application lives, by the name a catalog entry uses
# for it. Two of them, and they arrive by different routes for one reason: the
# spatial one's licence is academic and non-transferable, so a deployment
# obtains its own copy and points at it, while the tree one may be copied and
# sits in this repository. Nothing else about them differs here.
VENDORED = Path(__file__).resolve().parent / "web" / "tree"

# What a bundle's directory is called inside a run, which is the output name the
# catalog entry declares. Named once here so a rename shows up as one change.
BUNDLE = "bundle"
# The one path a bundle is allowed to supply in place of the installed viewer's:
# the list of samples, which is per bundle and which a page served as static
# files cannot work out for itself. Kept to an explicit list rather than "the
# bundle wins wherever it has a file", so a bundle can never replace the
# application's own code with something that arrived as data.
OVERRIDES = {"config/data_location.html"}


def _app_root(kind: str) -> Path | None:
    """Where one viewer's own application lives, or None when it is not here."""
    if kind == "spatialview":
        return Path(VIEWER_ROOT).resolve() if VIEWER_ROOT else None
    if kind == "phyd3":
        return VENDORED if VENDORED.is_dir() else None
    return None

# Which viewers this deployment can actually serve, by the name a catalog entry
# uses for one. A domain can declare that an output opens in a viewer without
# the operator having installed it, and the two facts are different: the result
# exists, and there is nothing here to open it with. Offering it anyway gives a
# link to a blank page.
def installed() -> set:
    return {k for k in ("spatialview", "phyd3") if _app_root(k) is not None}


def _index(entries) -> HTMLResponse:
    """A directory listing in the shape a plain static file server emits.

    The viewer finds its samples by reading one, because its documented way of
    being run is a static file server and those generate listings for free. A
    framework serving named routes does not, so this supplies the same thing
    rather than requiring the viewer be changed to ask differently.

    The trailing slash on a directory is not decoration. The viewer's loader
    keeps only the links whose text ends in one, and treats the rest as files,
    so a listing without them offers it nothing at all.
    """
    links = "\n".join(
        '<li><a href="{0}{1}">{0}{1}</a></li>'.format(
            p.name, "/" if p.is_dir() else "")
        for p in entries)
    return HTMLResponse(f"<html><body><ul>\n{links}\n</ul></body></html>")


def _within(root: Path, *parts: str) -> Path:
    """A path under `root`, or a refusal.

    Resolved before comparing, so a link or a `..` that leaves the tree is
    caught by where it actually points rather than by how it was spelled.
    """
    target = (root / Path(*parts)).resolve()
    if root.resolve() not in target.parents and target != root.resolve():
        raise HTTPException(status_code=404, detail="not found")
    return target


def router(*, bundles_for, current_user) -> APIRouter:
    """The viewer routes.

    `current_user` is the session dependency. `bundles_for(user, key)` answers
    the only question this file has: which bundle directories that key names,
    for someone allowed to see them, newest first, and empty when either half of
    that fails.

    A list rather than one directory, because the viewer only compares samples
    it loaded together and bundles are built one sample at a time. Several runs
    are presented as one bundle here, which costs nothing: joining directories
    computes nothing, so a merged copy on disk would be a second copy of every
    sample that has to be rebuilt whenever any one of them changes.

    A function rather than a store and an ownership check, because the two ids
    involved are not the same. A caller holds the id `submit` returned; the store
    files a run under the directory it allocated. Only the product holds both, so
    the translation belongs there and not here.
    """
    api = APIRouter(prefix="/viewer", tags=["viewer"])

    def _roots(kind: str, run: str, user: str) -> list:
        """Every bundle a key names, as directories, newest first."""
        found = bundles_for(user, kind, run)
        if not found:
            # The same answer whether the run is missing or simply not theirs.
            # Telling those apart would confirm other people's runs exist.
            raise HTTPException(status_code=404, detail="no such run")
        roots = []
        for one in found:
            path = Path(one)
            if path.name != BUNDLE and (path / BUNDLE).is_dir():
                path = path / BUNDLE
            if path.is_dir():
                roots.append(path)
        if roots:
            return roots
        # Found, entitled, and holding no bundle. Either nothing built one, or
        # one was built somewhere this cannot read from and has not arrived yet.
        raise HTTPException(
            status_code=409,
            detail=(f"{run} has no viewer bundle here yet. If a bundle was built "
                    f"on another machine it is still on its way; otherwise build "
                    f"one with the spatialview_bundle capability."))

    def _samples(roots: list) -> list[Path]:
        """Every sample across every bundle, each named once.

        A sample prepared twice appears in two bundles. The newer one wins,
        which is what newest-first ordering means, and the viewer is shown one
        directory per sample name either way.
        """
        seen: dict = {}
        for root in roots:
            for p in sorted(root.iterdir(), key=lambda p: p.name):
                if p.is_dir() and p.name != "config" and p.name not in seen:
                    seen[p.name] = p
        return [seen[k] for k in sorted(seen)]

    def _find(roots: list, path: str) -> Path:
        """One path, from whichever bundle holds it. Newest first, so newest wins."""
        for root in roots:
            target = _within(root, path)
            if target.exists():
                return target
        return _within(roots[0], path)

    # Declared without `async`, and that is the whole point. Every handler here
    # is synchronous work — stat a path, read a manifest, hand back a file — and
    # a synchronous body on an async route runs on the event loop, where it
    # blocks every other request the server has. A viewer that asks for hundreds
    # of files then stops the whole app answering: a second tab sits empty, and
    # the person watching concludes the product is broken rather than busy.
    # Without `async`, these run in a threadpool and one slow view costs only
    # itself.

    @api.get("/{kind}/{run}/data")
    @api.get("/{kind}/{run}/data/")
    def data_index(kind: str, run: str, user: str = Depends(current_user)):
        """The sample listing the viewer reads to find out what it has."""
        return _index(_samples(_roots(kind, run, user)))

    @api.get("/{kind}/{run}/group_data/{sub}/")
    def group_index(kind: str, run: str, sub: str, user: str = Depends(current_user)):
        """Optional gene lists shown in the group tab, empty when none were built."""
        d = _find(_roots(kind, run, user), f"group_data/{sub}")
        return _index(sorted(d.iterdir(), key=lambda p: p.name) if d.is_dir() else [])

    # HEAD as well as GET, and not as a formality. The viewer asks whether the
    # sparse matrix exists by probing for it with HEAD, and reads a refusal as
    # absence: on 405 it falls back to a dense CSV that a bundle does not write,
    # and the sample loads with no expression at all and no error anywhere.
    @api.api_route("/{kind}/{run}/data/{path:path}", methods=["GET", "HEAD"])
    def data(kind: str, run: str, path: str, user: str = Depends(current_user)):
        """One file of the bundle. The viewer's own relative requests land here."""
        target = _find(_roots(kind, run, user), path)
        if target.is_dir():
            return _index(sorted(target.iterdir(), key=lambda p: p.name))
        if not target.is_file():
            raise HTTPException(status_code=404, detail="not found")
        return FileResponse(target)

    @api.get("/{kind}/{run}/samples")
    def samples(kind: str, run: str, user: str = Depends(current_user)):
        """Which samples the bundle holds, for a caller that has to name one."""
        return {"run": run, "samples": [p.name for p in _samples(_roots(kind, run, user))]}

    @api.get("/{kind}/{run}")
    @api.get("/{kind}/{run}/{path:path}")
    def app_files(kind: str, run: str, path: str = "", user: str = Depends(current_user)):
        """The viewer's own files, served read only from wherever it is installed."""
        if path in OVERRIDES:
            supplied = _find(_roots(kind, run, user), path)
            if supplied.is_file():
                return FileResponse(supplied)
        root = _app_root(kind)
        if root is None:
            raise HTTPException(
                status_code=503,
                detail=(f"No viewer called {kind} is installed here."
                        + (" Set SPATIALVIEW_ROOT to a copy of it. It is not "
                           "distributed with this repository: its licence is "
                           "academic and non-transferable, so each deployment "
                           "obtains its own." if kind == "spatialview" else "")))
        _roots(kind, run, user)                  # entitlement first, files after
        target = _within(root, path) if path else root
        if target.is_dir():
            target = target / "index.html"
        if not target.is_file():
            raise HTTPException(status_code=404, detail="not found")
        return FileResponse(target)

    return api
