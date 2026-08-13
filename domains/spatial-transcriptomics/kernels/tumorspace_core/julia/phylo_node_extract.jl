#!/usr/bin/env julia
#
# node_extract.jl
#
# Step 2: Extract node/edge information from phylogenetic tree and compute
# descendant/ancestor relationships.
#
# This script reads the Tree_0.nw file from Step 1, extracts structural information
# about nodes and edges, and computes relationships needed for downstream spatial analysis.
#
# Usage:
#   julia node_extract.jl <output_dir> <tree_file> <barcode_positions_file>
#
# Inputs:
#   output_dir: Directory containing Step 1 outputs (Tree_0.nw, distance matrices)
#   tree_file: Path to Tree_0.nw file (typically: output_dir/Tree_0.nw)
#   barcode_positions_file: Path to barcode positions file with spatial coordinates
#
# Outputs (all saved to output_dir):
#   - tree_nodes.tsv: Node information (node numbers, names, leaf status)
#   - tree_edges.tsv: Edge information (parent-child relationships, branch lengths)
#   - allnodes_leaves.tsv: All descendant leaves for each internal node
#   - allnodes_parents.tsv: All ancestor nodes for each node
#   - spectral_dist_melt.tsv: Ranked spot matches based on spectral distance
#
# Dependencies: Install via Project.toml in workflows/julia/
#   julia --project=. -e 'using Pkg; Pkg.instantiate()'
#

# Activate portable framework
using Pkg
Pkg.activate(joinpath(@__DIR__))

# Load portable functions
include("tumorspace_core.jl")

using PhyloNetworks: readTopology, printEdges

# Parse command line arguments
if length(ARGS) != 3
    println("Usage: julia node_extract.jl <output_dir> <tree_support_file> <barcode_positions_file>")
    println("Example: julia node_extract.jl ./output ./output/Tree_support.nw ./data/barcodes_positions.txt")
    println("")
    println("NOTE: tree_support_file MUST be Tree_support.nw (with bootstrap support values)")
    println("      DO NOT use Tree_0.nw as it lacks bootstrap support, causing all nodes to default to Support=1.0")
    exit(1)
end

output_dir = ARGS[1]
tree_file = ARGS[2]
barcode_positions_file = ARGS[3]

# Verify tree file is Tree_support.nw
if basename(tree_file) != "Tree_support.nw"
    println("")
    println("ERROR: Tree file must be Tree_support.nw (with bootstrap support values)")
    println("       Provided: $tree_file")
    println("")
    println("Tree_support.nw contains bootstrap support values (0.0-1.0) required for:")
    println("  - Hyperparameter optimization (Prune threshold)")
    println("  - Node filtering based on bootstrap confidence")
    println("  - Meaningful spatial group identification")
    println("")
    println("If Tree_support.nw is missing, you need to run Step 1b (bootstrap support computation):")
    println("  1. Check that Tree_0.nw and Tree_1.nw...Tree_N.nw exist in output directory")
    println("  2. Concatenate bootstrap trees: cat Tree_{{1..N}}.nw > Tree_Bootstrap.nw")
    println("  3. Run gotree: gotree -i Tree_0.nw -b Tree_Bootstrap.nw -o Tree_support.nw -@ 4 -a tbe")
    println("")
    println("Common Step 1b failure causes:")
    println("  - gotree binary not in PATH")
    println("  - Bootstrap trees (Tree_1.nw...Tree_N.nw) missing or incomplete")
    println("  - Insufficient disk space")
    println("  - Silent failure in orchestration pipeline (check logs)")
    println("")
    error("Invalid tree file: expected Tree_support.nw, got $(basename(tree_file))")
end

# Verify input files exist
if !isfile(tree_file)
    error("Tree file not found: $tree_file")
end

# Look for distance matrix (either Obs_Dij_ObsDat_Spectral.tsv, SPI_Dist_mtx.txt, or similar)
possible_dist_files = [
    joinpath(output_dir, "Obs_Dij_ObsDat_Spectral.tsv"),
    joinpath(output_dir, "Obs_Dij_ObsDat_Spectral.txt"),
    joinpath(output_dir, "SPI_Dist_mtx.txt"),
    joinpath(output_dir, "SPI_Dist_mtx.tsv")
]

global distance_file = nothing
for f in possible_dist_files
    if isfile(f)
        global distance_file = f
        break
    end
end

if isnothing(distance_file)
    error("Distance matrix not found. Looked for:\n" * join(possible_dist_files, "\n"))
end

if !isfile(barcode_positions_file)
    error("Barcode positions file not found: $barcode_positions_file")
end

println("="^80)
println("Step 2: Node Extraction")
println("="^80)
println("Tree file:       $tree_file")
println("Distance matrix: $distance_file")
println("Barcode file:    $barcode_positions_file")
println("Output dir:      $output_dir")
flush(stdout)
println()

# Read tree
println("[1/6] Reading tree...")
flush(stdout)
tree = readTopology(tree_file)
println("  Tree loaded: $(length(tree.node)) nodes, $(length(tree.edge)) edges")
flush(stdout)

# Extract node information
println("[2/6] Extracting node information...")
flush(stdout)
tree_nodes = phylo_print_nodes(tree)
println("  Extracted info for $(nrow(tree_nodes)) nodes")
flush(stdout)

# Extract edge information  
println("[3/6] Extracting edge information...")
flush(stdout)
# Capture printEdges output as string, then parse
edge_str = sprint(io -> printEdges(io, tree))
tree_edges_prelim = DataFrame(edge = split(edge_str, '\n', keepempty=false))
tree_edges = phylo_print_edges(tree_edges_prelim)
println("  Extracted info for $(nrow(tree_edges)) edges")
flush(stdout)

# Compute descendant leaves for all nodes
println("[4/6] Computing descendant leaves...")
flush(stdout)
allnodes_leaves = tree_nodedescendants(tree, tree_nodes, tree_edges)
println("  Computed descendants for $(length(unique(allnodes_leaves.Node))) nodes")
flush(stdout)

# Compute ancestor nodes
println("[5/6] Computing ancestor relationships...")
flush(stdout)
allnodes_parents = tree_nodeancestors(tree_nodes, tree_edges)
println("  Computed ancestors for $(nrow(allnodes_parents)) nodes")
flush(stdout)

# Read distance matrix and barcode positions
println("[6/6] Computing spectral distance rankings...")
flush(stdout)
obs_dij = CSV.read(distance_file, DataFrame, header=false)
barcode_positions = CSV.read(barcode_positions_file, DataFrame)

# Call model_extract to create spectral_dist_melt
spectral_dist_melt, allnodes_leaves_updated, allnodes_parents_updated = model_extract(
    obs_dij,
    barcode_positions,
    tree,
    tree_nodes,
    tree_edges
)
println("  Created $(nrow(spectral_dist_melt)) ranked spot pairs")
flush(stdout)

# Write outputs
println()
println("Writing outputs...")

output_files = [
    (tree_nodes, "tree_nodes.tsv"),
    (tree_edges, "tree_edges.tsv"),
    (allnodes_leaves_updated, "allnodes_leaves.tsv"),
    (allnodes_parents_updated, "allnodes_parents.tsv"),
    (spectral_dist_melt, "spectral_dist_melt.tsv")
]

for (df, filename) in output_files
    outfile = joinpath(output_dir, filename)
    CSV.write(outfile, df, delim='\t')
    println("  ✓ $filename ($(nrow(df)) rows)")
end

println()
println("="^80)
println("Step 2 complete!")
println("="^80)
