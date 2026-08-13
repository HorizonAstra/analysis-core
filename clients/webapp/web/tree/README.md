# The Tree Viewer

PhyD3, vendored. It draws a phylogenetic tree in a browser and computes nothing,
which is why it can be handed a region tree and used as it is.

## What Is Here

| Path | What it is |
| --- | --- |
| `js/phyd3.min.js` | PhyD3's whole distribution: the Newick parser, the phyloXML parser and the drawing. Not ours, not modified. |
| `css/phyd3.min.css` | Its stylesheet, likewise. |
| `libs/` | jQuery 2.2.4, Bootstrap 3.3.7 and d3 3.5.17, which it needs and does not ship. |
| `fonts/` | The Bootstrap icon font, used by its zoom buttons. |
| `index.html` | Ours. Its page, pointed at a bundle. |
| `LICENSE.txt` | PhyD3's licence, GPL v3. |

Taken from `github.com/vibbits/phyd3` at tag `v1.3`, commit `27b2491`, which is
the version the tool was published as. Only `dist/` was taken, because that is
the built application; the rest of that repository is the source it was built
from and a PHP site for submitting trees, neither of which is wanted here.

The three libraries were fetched from the addresses PhyD3's own pages name and
checked against the hashes those pages declare, so what is here is byte for byte
what it expects to run against.

## What Was Changed

Three things, all in `index.html`, which is our page rather than theirs:

* **The libraries are local.** Theirs loads them from public content delivery
  networks. A cluster is often on a closed network, where that page does not
  open at all.
* **The analytics are gone.** Theirs reports every visit to a third party.
* **It reads a bundle.** Theirs reads one file sitting beside it. This one asks
  which samples the bundle holds and reads the tree of whichever is chosen,
  which is what lets several runs be looked at as one study.

Nothing that draws a tree was touched.

## Newick Now, phyloXML Later

The bundle holds one Newick file per sample, which carries the tree and its
branch lengths and nothing else. That is the tree itself and it is most of what
there is to see.

PhyD3 draws more than that. Heat maps, bars, pie charts and box plots along the
tips are its reason for existing, and the paper's figure is full of them. None of
that fits in Newick, which has nowhere to put a number that is not a branch
length. It comes from phyloXML instead, and the statistics a spatial group run
already produces are what would fill it. So the format the bundle writes is where
that work goes, and this page is ready for it: the parser is already in the
bundle above, and PhyD3's controls for those tracks are the part of its panel
this page currently leaves out.

## Licence

GPL v3, which is a different arrangement from the spatial viewer's. That one is
academic and non-transferable, so it cannot be distributed and each deployment
installs its own copy. This one may be copied, changed and passed on, so it lives
in this repository and anyone the product serves can open it. The condition is
that it stays under the same licence and travels with its source, so
`LICENSE.txt` stays where it is and this file records where the copy came from.
