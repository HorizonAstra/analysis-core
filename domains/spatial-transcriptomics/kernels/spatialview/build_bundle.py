"""Assemble what a spatial viewer reads, from what this domain produces.

The viewer computes nothing. It reads a directory of files in a published
layout and draws them, so what belongs here is producing that directory. The
decisions in it are this domain's: which clustering to paint, which genes are
that cluster's markers, which spots are in tissue at all. That is why this is a
capability rather than something a client assembles on the way to a browser.

Layout written, one directory per sample:

    <out>/<sample>/
        expression_matrix_sparse.txt   Matrix Market, genes by barcodes
        genes.csv                      row labels of that matrix
        barcodes.csv                   column labels of that matrix
        metadata.csv                   one row per spot: position and cluster
        cluster_info.csv               cluster, colour, name, marker genes
        sample_info.csv                one row of sample-level metadata
        scalefactors_json.json         from the Space Ranger spatial folder
        tissue_hires_image.png         from the same place

Nothing here is imported. Standard library only, and the matrix is streamed
rather than held, because a Visium sample is thousands of spots by tens of
thousands of genes and the dense form of that does not belong in memory to be
written out sparse.

The two files taken from Space Ranger are the reason a bundle can only be built
while the original run directory is still readable. `harmonize` links that
directory rather than copying it, so nothing downstream keeps a copy of the
tissue image, and without the image there is nothing to draw spots on.
"""

from __future__ import annotations

import argparse
import colorsys
import csv
import gzip
import json
import shutil
import sys
import tempfile
from pathlib import Path


def _one_column(path: Path) -> list[str]:
    """A one-column file written with a header, which is how this domain writes them."""
    rows = path.read_text().splitlines()
    return [r.strip() for r in rows[1:] if r.strip()]


def _symbols(path: Path | None) -> dict:
    """Identifier to symbol, from the instrument's own feature list.

    Everything downstream carries the stable identifier, which is right for
    computing on and unreadable to look at: nobody searches a tissue for
    ENSG00000242019. The instrument writes both, side by side, and it is the
    only place the pairing exists, so it is read from there rather than guessed
    or looked up over a network.

    Symbols are not unique and are not made unique here. Two rows sharing a name
    is what the biology says, and renaming one of them would invent a gene.
    """
    if path is None or not path.exists():
        return {}
    opener = gzip.open if path.suffix == ".gz" else open
    out = {}
    with opener(path, "rt") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0] and parts[1]:
                out[parts[0]] = parts[1]
    return out


def _table(path: Path) -> tuple[list[str], list[list[str]]]:
    """A table, read by what is in it rather than by what it is called.

    The name is not evidence. Every input here arrives under a name the catalog
    entry chose for it, so a comma separated file declared as tsv is staged as
    `.tsv` and read with the wrong separator: one column, no header matched, and
    a bundle that builds cleanly with every marker list empty. Nothing fails,
    which is why it survived a run.

    So the header line decides. Whichever separator splits it into more fields
    is the one the file uses, and a single column file is unambiguous either way.
    """
    with open(path, newline="") as fh:
        first = fh.readline()
    sep = "," if first.count(",") > first.count("\t") else "\t"
    with open(path, newline="") as fh:
        rows = list(csv.reader(fh, delimiter=sep))
    return (rows[0], rows[1:]) if rows else ([], [])


def _dir_name(sample: str) -> str:
    """A sample name the viewer will accept as a directory.

    Its own exporter enforces these three, and a name it rejects is a sample
    that silently does not appear rather than an error anyone sees.
    """
    name = sample.replace(" ", "")
    if name[:1].isdigit():
        name = "X" + name
    if len(name) == 1:
        name = "X" + name
    return name


def write_registry(bundle: Path) -> list[str]:
    """The list of samples, as the viewer's own loader expects to find it.

    A page served as static files cannot list a directory, so the set of samples
    has to be written down. The viewer reads it from an HTML table at this path,
    which is what its exporter produces, so a bundle carries its own registry and
    works wherever it is unpacked rather than only behind our own server.
    """
    samples = sorted(p.name for p in bundle.iterdir() if p.is_dir())
    rows = "\n".join(
        f'  <tr> <td align="right"> {i} </td> <td> {s} </td> </tr>'
        for i, s in enumerate(samples, start=1))
    (bundle / "config").mkdir(exist_ok=True)
    (bundle / "config" / "data_location.html").write_text(
        "<table border=1>\n"
        "  <tr> <th>  </th> <th> Samples </th> </tr>\n"
        f"{rows}\n"
        "</table>\n")
    return samples


def _palette(n: int) -> list[str]:
    """Evenly spaced hues, the same idea as the reference exporter's default.

    Colour here is presentation and carries no meaning, so it only has to be
    distinguishable and stable for a given number of clusters.
    """
    out = []
    for i in range(max(n, 1)):
        r, g, b = colorsys.hls_to_rgb(i / max(n, 1), 0.62, 0.62)
        out.append("#%02X%02X%02X" % (int(r * 255), int(g * 255), int(b * 255)))
    return out


def write_matrix(matrix: Path, out: Path, n_genes: int, decimals: int) -> int:
    """Spots by genes, densely, becomes genes by barcodes, sparsely.

    Written column by column without sorting afterwards: a column of the result
    is a row of the input, so reading the input in order already produces the
    column-major order the format expects.
    """
    body = tempfile.NamedTemporaryFile("w", delete=False, suffix=".mtx")
    nnz = n_spots = 0
    with open(matrix) as fh:
        for spot, line in enumerate(fh, start=1):
            values = line.rstrip("\n").split("\t")
            if len(values) == 1 and not values[0]:
                continue
            n_spots += 1
            for gene, raw in enumerate(values, start=1):
                v = round(float(raw), decimals)
                if v:
                    # The separator goes before each entry rather than after, so
                    # the file ends without a trailing newline. The reader on the
                    # other side streams this a row at a time and turns a final
                    # empty line into an entry with no gene and no barcode, which
                    # then appears as a spot called "undefined" holding nothing.
                    body.write(f"\n{gene} {spot} {v:g}" if nnz else f"{gene} {spot} {v:g}")
                    nnz += 1
    body.close()

    with open(out, "w") as fh:
        # Two header lines, banner then dimensions, and no comment line between
        # them. This is what R's writeMM produces and what the reader on the
        # other side assumes: it drops exactly two lines before parsing. A third
        # would leave the dimensions to be read as a matrix entry, which is a
        # plausible one, so nothing would report an error.
        fh.write("%%MatrixMarket matrix coordinate real general\n")
        fh.write(f"{n_genes} {n_spots} {nnz}\n")
        with open(body.name) as src:
            shutil.copyfileobj(src, fh)
    Path(body.name).unlink()
    return n_spots


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--matrix", required=True)
    ap.add_argument("--observations", required=True)
    ap.add_argument("--features", required=True)
    ap.add_argument("--positions", required=True)
    ap.add_argument("--clusters", required=True)
    ap.add_argument("--spatial-dir", required=True)
    ap.add_argument("--markers", default="")
    ap.add_argument("--gene-names", default="",
                    help="The instrument's own feature list, which pairs each "
                         "identifier with its symbol. Without it the bundle "
                         "shows identifiers, because nothing else carries the "
                         "pairing.")
    ap.add_argument("--gene-labels", default="symbol", choices=("symbol", "id"),
                    help="Which of the two to show, in the searchable list and "
                         "in the marker lists alike. They have to agree: a "
                         "search that finds a gene the marker list calls "
                         "something else reads as two different genes.")
    ap.add_argument("--out", required=True)
    ap.add_argument("--sample", default="sample")
    ap.add_argument("--cluster-column", default="",
                    help="Column in the clusters file holding the assignment. "
                         "Defaults to the last column, which is where every "
                         "clustering capability here puts it.")
    ap.add_argument("--decimals", type=int, default=3)
    a = ap.parse_args()

    bundle = Path(a.out)
    out = bundle / _dir_name(a.sample)
    out.mkdir(parents=True, exist_ok=True)

    genes = _one_column(Path(a.features))
    barcodes = _one_column(Path(a.observations))

    # One naming, applied to the searchable list and to every marker list. An
    # identifier with no symbol keeps the identifier rather than becoming blank,
    # since a row of the matrix has to be called something.
    naming = ({} if a.gene_labels == "id"
              else _symbols(Path(a.gene_names) if a.gene_names else None))
    def named(gene: str) -> str:
        return naming.get(gene, gene)
    genes = [named(g) for g in genes]

    # --- the two files only Space Ranger has ------------------------------
    spatial = Path(a.spatial_dir)
    for name, pattern in (("scalefactors_json.json", "scalefactors*json"),
                          ("tissue_hires_image.png", "tissue_hires_image.png")):
        found = sorted(spatial.glob(pattern))
        if not found:
            raise SystemExit(
                f"{name} is not in {spatial}. A bundle needs the tissue image and "
                f"its scale factors, and only the Space Ranger run directory has "
                f"them. Point --spatial-dir at that run's spatial/ folder.")
        shutil.copyfile(found[0], out / name)

    # --- spot table: position from harmonize, cluster from a clustering ----
    pos_header, pos_rows = _table(Path(a.positions))
    cl_header, cl_rows = _table(Path(a.clusters))
    if not cl_header:
        raise SystemExit(f"{a.clusters} is empty, so no spot has a cluster.")
    col = a.cluster_column or cl_header[-1]
    if col not in cl_header:
        raise SystemExit(f"{a.clusters} has no column '{col}'. It has: "
                         f"{', '.join(cl_header)}")
    key = cl_header[0]
    assignment = {r[cl_header.index(key)]: r[cl_header.index(col)]
                  for r in cl_rows if r}

    # The assignment is written twice, under both names the viewer reads it by,
    # because it reads it by two. Its configuration names the column, and the
    # group-level views honour that; the code that paints spots onto the tissue
    # asks for `cluster` directly and ignores the setting. A bundle carrying
    # only the configured name draws every spot fully transparent: correctly
    # placed, correctly sized, invisible, and with nothing logged anywhere.
    # Writing both costs one column and satisfies both readers.
    with open(out / "metadata.csv", "w", newline="") as fh:
        w = csv.writer(fh, quoting=csv.QUOTE_ALL)
        w.writerow(pos_header + ["cluster", "seurat_clusters"])
        placed = 0
        for row in pos_rows:
            if not row:
                continue
            cluster = assignment.get(row[0], "")
            placed += bool(cluster)
            w.writerow(row + [cluster, cluster])
    if not placed:
        raise SystemExit(
            "no spot in the positions file has a cluster. The barcodes in "
            f"{a.clusters} do not match those in {a.positions}, which usually "
            "means the two came from different samples.")

    # --- clusters, with their markers where a differential run supplied them
    markers: dict[str, list[str]] = {}
    if a.markers and Path(a.markers).exists():
        m_header, m_rows = _table(Path(a.markers))
        low = [h.lower() for h in m_header]
        gi = next((i for i, h in enumerate(low) if h in ("gene", "feature", "symbol")), None)
        ci = next((i for i, h in enumerate(low) if "cluster" in h or "node" in h), None)
        if gi is not None and ci is not None:
            for r in m_rows:
                if len(r) > max(gi, ci):
                    markers.setdefault(r[ci], []).append(named(r[gi]))

    present = sorted({c for c in assignment.values() if c},
                     key=lambda v: (0, int(v)) if v.lstrip("-").isdigit() else (1, v))
    colours = _palette(len(present))
    with open(out / "cluster_info.csv", "w", newline="") as fh:
        w = csv.writer(fh, quoting=csv.QUOTE_ALL)
        w.writerow(["cluster", "color", "name", "genes"])
        for cluster, colour in zip(present, colours):
            named = ", ".join(markers.get(cluster, [])[:20]) or "undefined"
            w.writerow([cluster, colour, cluster, named])

    with open(out / "sample_info.csv", "w", newline="") as fh:
        w = csv.writer(fh, quoting=csv.QUOTE_ALL)
        w.writerow(["sample", "spots", "clusters"])
        w.writerow([a.sample, len(pos_rows), len(present)])

    # --- expression --------------------------------------------------------
    for name, values in (("genes.csv", genes), ("barcodes.csv", barcodes)):
        with open(out / name, "w") as fh:
            fh.write("x\n")
            fh.writelines(f"{v}\n" for v in values)

    spots = write_matrix(Path(a.matrix), out / "expression_matrix_sparse.txt",
                         len(genes), a.decimals)
    if spots != len(barcodes):
        raise SystemExit(f"the matrix has {spots} rows but {len(barcodes)} barcodes "
                         f"were given, so the two do not describe the same sample.")

    samples = write_registry(bundle)

    print(f"bundle: {out}")
    print(f"  {spots} spots, {len(genes)} genes, {len(present)} clusters")
    print(f"  registry lists {len(samples)}: {', '.join(samples)}")
    print("BUNDLE_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
