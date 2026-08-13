#!/usr/bin/env python3
"""Assemble a spatial group run's tree, and what is known about it, for viewing.

The spatial group step produces a tree and there was no way to look at it. A tree
is the one result here whose shape is the finding: which parts of a tissue split
from which, and how far apart they are. Reading that from a Newick string is not
reading it.

Two views of the same run, written together:

    tree.xml           region_finder's tree, unchanged. One leaf per spot.
    tree-regions.xml   the same tree with the spatial groups as its leaves.

The first is the tree the run reported. region_finder has already pruned it,
collapsing branches whose bootstrap support fell below its threshold, so the
shape is the one its parameters produced and nothing here second-guesses that.

The second is a different tree, and that is why it is a second file rather than
an option on the first: everything between the groups is lifted away and its
branch lengths summed, so what is drawn keeps the run's distances but not its
shape. Both are built every time and the viewer switches between them, because
which one to look at is a question asked while looking, not one worth waiting on
a cluster to answer twice.

What rides along, none of it computed here beyond arranging it:

    Spatial groups   Which nodes the run compared against the rest of their
                     split. A mark beside those nodes, so the finding is shown on
                     the tree rather than replacing it.

    Expression       On the tree of spots: one row per spot, one column per gene,
                     straight out of the matrix. No averaging, no scaling.

    Regions          On the tree of regions, each row is a group rather than a
                     spot, so it says what fraction of that group's spots carry a
                     local bias for the gene — read from the per-spot assignment
                     the SLAB step writes. This is deliberately not called a SLAB
                     score and is not one: a SLAB score divides by the spots of
                     the whole tissue, and averaging fractions with different
                     denominators would mean nothing. Without that file it falls
                     back to the mean expression of the group's spots, which is a
                     summary and is labelled as one.

    Gene choice      Which genes are worth a column. The spatially widespread
                     biases, ranked by their SLAB score, when a SLAB run is
                     given. Otherwise the genes that vary most across the spots,
                     which is a way of picking something to look at rather than a
                     result, and the legend says which of the two was used.

phyloXML rather than Newick. Newick holds a tree and branch lengths and has
nowhere to put a number that is not a branch length, so everything above would be
dropped on the floor. The viewer parses both and draws whichever it is handed.

A folder per sample rather than a file at the root, because a study is looked at
as a study: the viewer is served every bundle a conversation built as one, and a
sample is what tells them apart.

Nothing is imported. Standard library only, including the Newick parsing and the
XML writing, which is less code than a dependency would cost here.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape


class Tree:
    """One node of a parsed tree."""

    __slots__ = ("name", "length", "children", "ref")

    def __init__(self, name: str = "", length: float = 0.0):
        self.name = name
        self.length = length
        self.children: list = []
        self.ref = -1                 # assigned once the tree is final


def parse_newick(text: str) -> Tree:
    """A Newick string, as a tree.

    Recursive descent over the four things Newick has: parentheses for nesting,
    commas between siblings, a colon before a branch length, and a name
    otherwise. Named internal nodes matter here, since those names are the region
    identifiers everything else is keyed by, and named leaves matter too, since
    those are the spot barcodes the expression matrix is keyed by.
    """
    s = text.strip()
    if s.endswith(";"):
        s = s[:-1]
    pos = 0

    def take_label() -> tuple:
        nonlocal pos
        start = pos
        while pos < len(s) and s[pos] not in "(),:;":
            pos += 1
        name = s[start:pos].strip().strip("'\"")
        length = 0.0
        if pos < len(s) and s[pos] == ":":
            pos += 1
            start = pos
            while pos < len(s) and s[pos] not in "(),;":
                pos += 1
            try:
                length = float(s[start:pos])
            except ValueError:
                length = 0.0
        return name, length

    def node() -> Tree:
        nonlocal pos
        children = []
        if pos < len(s) and s[pos] == "(":
            pos += 1
            while True:
                children.append(node())
                if pos < len(s) and s[pos] == ",":
                    pos += 1
                    continue
                break
            if pos < len(s) and s[pos] == ")":
                pos += 1
        name, length = take_label()
        t = Tree(name, length)
        t.children = children
        return t

    return node()


def _table(path: Path) -> tuple:
    """A table, read by what is in it rather than by what it is called."""
    with open(path, newline="") as fh:
        first = fh.readline()
    sep = "," if first.count(",") > first.count("\t") else "\t"
    with open(path, newline="") as fh:
        rows = list(csv.reader(fh, delimiter=sep))
    return (rows[0], rows[1:]) if rows else ([], [])


def _column(header: list, *words: str) -> int:
    """The first column whose name mentions one of these, or the first column.

    Which column holds a node, a feature or a score differs between the steps
    that produce these tables, so it is found rather than assumed.
    """
    low = [h.lower() for h in header]
    for w in words:
        for i, h in enumerate(low):
            if w in h:
                return i
    return 0


def _named(path: Path | None) -> set:
    """Which nodes a table names."""
    if path is None or not path.exists():
        return set()
    header, rows = _table(path)
    if not header:
        return set()
    key = _column(header, "node")
    return {r[key] for r in rows if len(r) == len(header)}


def _there(named: str) -> bool:
    """Whether an optional input was actually supplied."""
    return bool(named) and Path(named).exists()


def _lines(path: Path) -> list:
    """A one-column file, without its header. Row labels and feature names."""
    got = [ln.strip() for ln in path.read_text().splitlines() if ln.strip()]
    return got[1:] if got else got


# ── reducing the tree, only when asked ──────────────────────────────────────
def collapse(node: Tree, keep: set) -> Tree | None:
    """The tree of named nodes alone, with everything between them lifted away.

    Branch lengths are summed across what was lifted, so the distance between two
    survivors is still the distance the tree recorded. This is a different tree
    from the one the run reported and is only built when it is asked for.
    """
    kept = _kept_below(node, keep)
    if node.name in keep:
        out = Tree(node.name, node.length)
        out.children = kept
        return out
    return None


def _kept_below(node: Tree, keep: set) -> list:
    out = []
    for child in node.children:
        found = collapse(child, keep)
        if found is not None:
            out.append(found)
        else:
            for deeper in _kept_below(child, keep):
                deeper.length += child.length
                out.append(deeper)
    return out


def spots_below(node: Tree, out: dict | None = None) -> dict:
    """Every node, as the set of leaf names beneath it.

    Worked out on the tree as the run reported it, before anything is collapsed,
    because that is the only place the membership exists: once the nodes between
    a spatial group and its spots are lifted away, the spots are gone with them.
    """
    out = {} if out is None else out
    if not node.children:
        out[node.name] = {node.name}
        return out
    under: set = set()
    for child in node.children:
        spots_below(child, out)
        under |= out[child.name]
    out[node.name] = under
    return out


def grouped(per_spot: dict, members: dict, wanted: list) -> dict:
    """A per-spot value per gene, averaged over the spots of each group.

    The mean of the group's spots, which is the plain reading of "what this
    region looks like" and is what a heat map row of a region should say. Not a
    statistic the pipeline computes and not claimed to be one: it is the same
    numbers the spot-level map draws, summarised over a set of spots so that a
    row of the region tree has something in it.
    """
    out = {}
    for name, spots in members.items():
        rows = [per_spot[s] for s in spots if s in per_spot]
        if not rows:
            continue
        out[name] = [round(sum(r[i] for r in rows) / len(rows), 4)
                     for i in range(len(wanted))]
    return out


def bias_fraction(path: Path, members: dict, wanted: list) -> dict:
    """What fraction of each group's spots carries a local bias, per gene.

    Deliberately not called a SLAB score, and it is not one. A SLAB score
    divides by the spots of the whole tissue; this divides by the spots of one
    region. Averaging the first over regions would be meaningless — they are
    fractions of different denominators — so the aggregation is done from the
    thing both are built out of, which is the per-spot assignment the SLAB step
    already writes: for each feature and direction, exactly which spots carry it.

    Streamed and filtered to the genes that have a column, because this file
    holds a row per gene per spot per direction and runs to millions of lines.
    Directions are pooled, matching how the genes were chosen.
    """
    want = {g: i for i, g in enumerate(wanted)}
    carriers: dict = {g: set() for g in wanted}
    with open(path) as fh:
        header = fh.readline().rstrip("\n").split("\t")
        gene_at = _column(header, "da_object", "object", "feature", "gene")
        spot_at = _column(header, "barcode", "spot", "observation")
        if gene_at < 0 or spot_at < 0:
            return {}
        for line in fh:
            row = line.rstrip("\n").split("\t")
            if len(row) <= max(gene_at, spot_at):
                continue
            gene = row[gene_at]
            if gene in want:
                carriers[gene].add(row[spot_at])
    out = {}
    for name, spots in members.items():
        if not spots:
            continue
        out[name] = [round(len(carriers[g] & spots) / len(spots), 4) for g in wanted]
    return out


# ── choosing what to show ───────────────────────────────────────────────────
def by_slab(path: Path, most: int) -> list:
    """The most spatially widespread biases, by SLAB score, highest first.

    A SLAB score is one number per feature per direction for the whole sample, so
    it cannot hang on a node. What it can do is decide which features are worth a
    column, which is what it is used for. Directions are pooled by keeping a
    feature's best score, since a gene up in one part of a tissue and down in
    another is interesting for both reasons.
    """
    header, rows = _table(path)
    if not header:
        return []
    gene = _column(header, "gene", "feature", "name")
    score = _column(header, "slab", "score", "fraction")
    best: dict = {}
    for r in rows:
        if len(r) != len(header):
            continue
        try:
            value = abs(float(r[score]))
        except ValueError:
            continue
        if value > best.get(r[gene], -1.0):
            best[r[gene]] = value
    return [g for g, _ in sorted(best.items(), key=lambda kv: -kv[1])][:most]


def by_spread(matrix: Path, features: list, most: int) -> list:
    """The genes that vary most across the spots, highest first.

    The fallback when no SLAB run was given. This picks something to look at
    rather than reporting a finding, which is why the legend says so on the
    picture: a gene is here because it moves, not because anything decided it
    matters. One streaming pass, holding two running totals per column rather
    than the matrix.
    """
    n = len(features)
    total = [0.0] * n
    squares = [0.0] * n
    seen = 0
    with open(matrix) as fh:
        for line in fh:
            values = line.rstrip("\n").split("\t")
            if len(values) != n:
                continue
            seen += 1
            for i, v in enumerate(values):
                try:
                    x = float(v)
                except ValueError:
                    continue
                total[i] += x
                squares[i] += x * x
    if seen < 2:
        return []
    spread = []
    for i in range(n):
        mean = total[i] / seen
        var = max(squares[i] / seen - mean * mean, 0.0)
        spread.append((math.sqrt(var), features[i]))
    spread.sort(key=lambda p: -p[0])
    return [name for _, name in spread[:most]]


def expression(matrix: Path, features: list, spots: list, wanted: list) -> dict:
    """One row of values per spot, for the chosen genes only.

    Streamed, taking only the columns wanted, so the size of this is the number
    of spots times the number of genes shown rather than the whole matrix.
    """
    where = {g: i for i, g in enumerate(features)}
    columns = [where[g] for g in wanted if g in where]
    out: dict = {}
    with open(matrix) as fh:
        for row, line in enumerate(fh):
            if row >= len(spots):
                break
            values = line.rstrip("\n").split("\t")
            if len(values) != len(features):
                continue
            out[spots[row]] = [values[c] for c in columns]
    return out


# ── writing it out ──────────────────────────────────────────────────────────
def _number(tree: Tree) -> list:
    """Every node, numbered. The identifier the graphs are keyed by."""
    order: list = []

    def walk(t: Tree) -> None:
        t.ref = len(order)
        order.append(t)
        for c in t.children:
            walk(c)

    walk(tree)
    return order


def _clade(t: Tree, depth: int, out: list) -> None:
    pad = "  " * depth
    out.append(f"{pad}<clade>")
    out.append(f"{pad}  <id>{t.ref}</id>")
    if t.name:
        out.append(f"{pad}  <name>{escape(t.name)}</name>")
    if t.length:
        out.append(f"{pad}  <branch_length>{t.length:.6g}</branch_length>")
    for c in t.children:
        _clade(c, depth + 1, out)
    out.append(f"{pad}</clade>")


def _graph(kind: str, title: str, fields: list, data: dict,
           gradient: tuple | None = None) -> list:
    """One annotation track, in the shape the viewer reads.

    A track is a row of numbers per node and a legend naming what each column of
    that row is. The type decides how the row is drawn and nothing else.
    """
    out = [f'  <graph type="{kind}">', f"    <name>{escape(title)}</name>",
           '    <legend show="1">']
    for f in fields:
        out.append("      <field>")
        out.append(f"        <name>{escape(f['name'])}</name>")
        if f.get("color"):
            out.append(f"        <color>{f['color']}</color>")
        if f.get("shape"):
            out.append(f"        <shape>{f['shape']}</shape>")
        out.append("      </field>")
    if gradient:
        out.append(f"      <gradient><name>{gradient[0]}</name>"
                   f"<classes>{gradient[1]}</classes></gradient>")
    out.append("    </legend>")
    out.append("    <data>")
    for ref, values in data.items():
        inside = "".join(f"<value>{v}</value>" for v in values)
        out.append(f'      <values for="{ref}">{inside}</values>')
    out.append("    </data>")
    out.append("  </graph>")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tree", required=True)
    ap.add_argument("--node-info", required=True)
    ap.add_argument("--groups", default="",
                    help="The spatial group comparisons, which say which nodes "
                         "the run compared against the rest of their split.")
    ap.add_argument("--matrix", default="", help="Spots by genes, densified.")
    ap.add_argument("--features", default="", help="One gene name per column of the matrix.")
    ap.add_argument("--observations", default="", help="One spot label per row of the matrix.")
    ap.add_argument("--slab", default="", help="SLAB scores, which rank the genes.")
    ap.add_argument("--slab-barcodes", default="",
                    help="Which spots carry each bias, which is what lets a "
                         "region say how much of it carries one.")
    ap.add_argument("--genes", type=int, default=30,
                    help="How many genes get a column of the heat map.")
    ap.add_argument("--out", required=True)
    ap.add_argument("--sample", default="sample")
    a = ap.parse_args()

    root = parse_newick(Path(a.tree).read_text())
    groups = _named(Path(a.groups) if a.groups else None) or _named(Path(a.node_info))
    # Which spots sit under each node, taken now, while the tree still has the
    # nodes that connect the two.
    members = spots_below(root)

    # What the columns are, and how they were chosen. Decided once and used by
    # both trees, so the two are read against the same genes in the same order.
    wanted, how, per_spot, spots = [], "", {}, []
    if _there(a.matrix) and _there(a.features) and _there(a.observations):
        features = _lines(Path(a.features))
        spots = _lines(Path(a.observations))
        if _there(a.slab):
            wanted = by_slab(Path(a.slab), a.genes)
            how = "most spatially widespread, by SLAB score"
        else:
            wanted = by_spread(Path(a.matrix), features, a.genes)
            how = "most variable across the spots"
        wanted = [g for g in wanted if g in set(features)]
        if wanted:
            per_spot = expression(Path(a.matrix), features, spots, wanted)

    out = Path(a.out) / a.sample
    out.mkdir(parents=True, exist_ok=True)

    def write(tree: Tree, filename: str, values: dict, legend: str,
              gradient: tuple, inner: bool = False) -> tuple:
        """One tree, with its heat map, as a phyloXML file.

        `inner` says whether nodes with children carry a row too. On the tree of
        spots they cannot: a spot is a leaf and an inner node is not a spot. On
        the tree of regions every node is a region, including the ones that
        contain other regions, and leaving those blank would empty three
        quarters of the map — 112 groups, of which only 38 have no group inside
        them.
        """
        order = _number(tree)
        body: list = []
        _clade(tree, 1, body)
        graphs: list = []
        # Which nodes the run called spatial groups. A mark beside them rather
        # than a tree of them alone, so what is on screen is still the run's own
        # tree. Pointless once every leaf is one, so it is left off there.
        marked = {t.ref: [1] for t in order
                  if t.name in groups and (t.children or filename == "tree.xml")}
        if marked:
            graphs += _graph("binary", "Spatial group",
                             [{"name": "Compared against the rest of its split",
                               "color": "0xb91c1c", "shape": "circle"}], marked)
        at = {t.ref: values[t.name] for t in order
              if (inner or not t.children) and t.name in values}
        if at:
            graphs += _graph("heatmap", legend, [{"name": g} for g in wanted],
                             at, gradient=gradient)
        text = ['<?xml version="1.0" encoding="UTF-8"?>',
                '<phyloxml xmlns="http://www.phyloxml.org">',
                f'  <phylogeny rooted="true" id="{escape(a.sample)}">',
                f"    <name>{escape(a.sample)}</name>"]
        text += body
        # The tracks sit together under one element. Separately they are ignored
        # without complaint, which is a quiet way to lose everything beside the
        # tree.
        if graphs:
            text += ["  <graphs>"] + graphs + ["  </graphs>"]
        text += ["  </phylogeny>", "</phyloxml>"]
        (out / filename).write_text("\n".join(text) + "\n")
        leaves = sum(1 for t in order if not t.children)
        return len(order), leaves, len(at)

    # Both trees, every time. Which one to look at is a question asked while
    # looking, not one to be answered by re-running a job on a cluster and
    # waiting: they are the same nodes drawn two ways, and building the second
    # costs a second file.
    nodes, leaves, drawn = write(root, "tree.xml", per_spot,
                                 f"Expression ({how})", ("YlOrRd", 9))
    print(f"wrote {nodes} nodes ({leaves} leaves, {len(groups)} spatial groups) "
          f"for {a.sample}")
    if drawn:
        print(f"heat map: {len(wanted)} genes across {drawn} spots, {how}")

    # The same tree with the spatial groups as its leaves. A different tree from
    # the one the run reported, which is why it is a second file and not the
    # first: everything between the groups is lifted away and its branch lengths
    # summed, so what is drawn is the run's distances but not the run's shape.
    if groups:
        reduced = collapse(root, groups | {root.name})
        if reduced is None or not reduced.children:
            print("regions tree skipped: none of the named spatial groups appear "
                  "in the tree, so the two did not come from the same run")
        else:
            # What a region's row says. The bias fraction when the per-spot
            # assignment came along, because that is the question a region
            # answers and a mean of expression is not; the mean otherwise, so
            # there is always something to read.
            if _there(a.slab_barcodes) and wanted:
                values = bias_fraction(Path(a.slab_barcodes), members, wanted)
                legend = "Fraction of the group's spots carrying a local bias"
                gradient = ("PuBu", 9)
            else:
                values = grouped(per_spot, members, wanted) if per_spot else {}
                legend = f"Mean expression across the group's spots ({how})"
                gradient = ("YlOrRd", 9)
            nodes, leaves, drawn = write(reduced, "tree-regions.xml", values,
                                         legend, gradient, inner=True)
            print(f"wrote {nodes} nodes ({leaves} spatial groups as leaves) "
                  f"for {a.sample}, regions view")
            if drawn:
                print(f"regions heat map: {len(wanted)} genes across {drawn} "
                      f"groups, {legend.lower()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
