#!/usr/bin/env julia
#
# TumorSPACE: SG GrowChain Depth Analysis
#
# Computes spatial group (SG) nesting depth using the "GrowChain" metric
# from TME_SPI. This measures how many progressively larger spatial domains
# contain each SG node by walking up the phylogenetic tree.
#
# Algorithm:
#   For each SG node:
#     1. Check if parent node has larger interleaf distance
#     2. If YES (ParentNodeGrow=1) → move to parent, increment GrowChain
#     3. If NO (ParentNodeGrow=0) → STOP
#     4. Return GrowChain count
#
# GrowChain = 0 → Non-nested (peripheral, doesn't fit in larger structure)
# GrowChain = 1 → Nested once (fits inside 1 larger spatial domain)
# GrowChain = 2+ → Deeply nested (multiple nested spatial domains)
#
# Ported from: TME_SPI/Revisions/scripts_2/Revisions_Functions_v1.R
#   - leaf_dist() function (lines 140-148)
#   - node_depth() function (lines 152-170)

# Activate project environment to use our installed dependencies
using Pkg
Pkg.activate(joinpath(@__DIR__))

using DataFrames
using CSV
using Statistics
using Distances

"""
    leaf_dist(node_leaves::DataFrame, barcode_positions::DataFrame)

Compute mean pairwise Euclidean distance between spots (leaves) in a node.
This measures the spatial dispersion of barcodes belonging to a phylogenetic node.

Equivalent to R's leaf_dist function.
"""
function leaf_dist(node_leaves::DataFrame, barcode_positions::DataFrame)
    if nrow(node_leaves) == 0
        return missing
    end
    
    # Check if spatial positions already exist in node_leaves
    if !hasproperty(node_leaves, :pxl_row_in_fullres) || !hasproperty(node_leaves, :pxl_col_in_fullres)
        # Join with spatial positions
        leaves_with_pos = leftjoin(
            node_leaves,
            select(barcode_positions, :barcode, :pxl_row_in_fullres, :pxl_col_in_fullres),
            on = :barcode
        )
    else
        # Spatial positions already present
        leaves_with_pos = node_leaves
    end
    
    # Extract coordinates as matrix
    coords = Matrix(select(leaves_with_pos, :pxl_row_in_fullres, :pxl_col_in_fullres))
    
    # Compute mean pairwise distance
    if size(coords, 1) > 1
        dist_matrix = pairwise(Euclidean(), coords', dims=2)
        # Return mean of non-zero elements (excluding diagonal)
        return mean(dist_matrix[dist_matrix .> 0])
    else
        return missing
    end
end

"""
    node_depth(spot_hier_dat::DataFrame, parent_dat::DataFrame)

Compute GrowChain depth for each node by walking up the phylogenetic tree
while parent interleaf distance ≥ node interleaf distance.

Equivalent to R's node_depth function.

# Arguments
- `spot_hier_dat`: DataFrame with Node column for which to compute depth
- `parent_dat`: DataFrame with Node, ParentNode, and ParentNodeGrow columns
  where ParentNodeGrow = 1 if ParentInterleafDist >= NodeInterleafDist, else 0

# Returns
- DataFrame with added GrowChain column
"""
function node_depth(spot_hier_dat::DataFrame, parent_dat::DataFrame)
    spot_hier_dat.GrowChain = Vector{Int}(undef, nrow(spot_hier_dat))
    
    for i in 1:nrow(spot_hier_dat)
        nested = true
        node = spot_hier_dat.Node[i]
        grow_chain = 0
        
        while nested
            parent_rows = parent_dat[parent_dat.Node .== node, :]
            
            if nrow(parent_rows) == 0
                nested = false
            else
                if parent_rows.ParentNodeGrow[1] == 0
                    nested = false
                elseif parent_rows.ParentNodeGrow[1] == 1
                    node = parent_rows.ParentNode[1]
                    grow_chain += 1
                end
            end
        end
        
        spot_hier_dat.GrowChain[i] = grow_chain
    end
    
    return spot_hier_dat
end

# ============================================================================
# Main Execution
# ============================================================================

println("="^80)
println("TumorSPACE: SG GrowChain Depth Analysis")
println("="^80)

if length(ARGS) < 3
    println("ERROR: Insufficient arguments")
    println("Usage: julia sg_depth_growchain.jl <input_base> <output_base> <data_dir>")
    println()
    println("Arguments:")
    println("  input_base  - Directory containing optimal/ subdirectory with tree outputs")
    println("  output_base - Directory where optimal/ output will be written")
    println("  data_dir    - Directory containing barcodes_positions.txt")
    exit(1)
end

input_base = ARGS[1]
output_base = ARGS[2]
data_dir = ARGS[3]

optimal_dir = joinpath(input_base, "optimal")
output_dir = joinpath(output_base, "optimal")

println("Configuration:")
println("  Input base:  $input_base")
println("  Output base: $output_base")
println("  Data dir:    $data_dir")
println("  Optimal dir: $optimal_dir")
println()

# Validate input files exist
required_files = [
    joinpath(optimal_dir, "allnodes_parents.tsv"),
    joinpath(optimal_dir, "allnodes_leaves.tsv"),
    joinpath(optimal_dir, "OptimalTree_pruned_node_compare_list.txt"),
    joinpath(data_dir, "barcodes_positions.txt")
]

for file in required_files
    if !isfile(file)
        println("ERROR: Required file not found: $file")
        exit(1)
    end
end

# Read input files
println("Reading input files...")
allnodes_parents = CSV.read(joinpath(optimal_dir, "allnodes_parents.tsv"), DataFrame)
allnodes_leaves = CSV.read(joinpath(optimal_dir, "allnodes_leaves.tsv"), DataFrame)
sg_pairs = CSV.read(joinpath(optimal_dir, "OptimalTree_pruned_node_compare_list.txt"), DataFrame)
barcode_positions = CSV.read(joinpath(data_dir, "barcodes_positions.txt"), DataFrame)

println("  ✓ allnodes_parents: $(nrow(allnodes_parents)) rows")
println("  ✓ allnodes_leaves: $(nrow(allnodes_leaves)) rows")
println("  ✓ SG pairs: $(nrow(sg_pairs)) rows")
println("  ✓ barcodes_positions: $(nrow(barcode_positions)) rows")
println()

# Compute interleaf distance for all nodes
println("Computing interleaf distances for all nodes...")
flush(stdout)
unique_nodes = unique(allnodes_leaves.Node)
node_interleaf = DataFrame(Node = Int[], InterleafDist = Union{Float64, Missing}[])

for (idx, node) in enumerate(unique_nodes)
    if idx % 100 == 0
        println("  Progress: $idx / $(length(unique_nodes)) nodes")
        flush(stdout)
    end
    
    node_leaves = allnodes_leaves[allnodes_leaves.Node .== node, :]
    dist = leaf_dist(node_leaves, barcode_positions)
    push!(node_interleaf, (Node = node, InterleafDist = dist))
end
println("  ✓ Computed interleaf distances for $(nrow(node_interleaf)) nodes")
println()

# Join parent and child interleaf distances
println("Preparing parent data with interleaf distances...")
parent_dat = leftjoin(
    allnodes_parents,
    node_interleaf,
    on = :Node => :Node,
    makeunique = true
)
rename!(parent_dat, :InterleafDist => :NodeInterleafDist)

parent_dat = leftjoin(
    parent_dat,
    select(node_interleaf, :Node, :InterleafDist),
    on = :ParentNode => :Node,
    makeunique = true
)
rename!(parent_dat, :InterleafDist => :ParentInterleafDist)

# Compute ParentNodeGrow: 1 if parent interleaf >= node interleaf, else 0
parent_dat.ParentNodeGrow = [
    ismissing(p) || ismissing(n) ? 0 : (p >= n ? 1 : 0)
    for (p, n) in zip(parent_dat.ParentInterleafDist, parent_dat.NodeInterleafDist)
]

println("  ✓ Parent data prepared with $(nrow(parent_dat)) rows")
println("  ✓ ParentNodeGrow computed: $(sum(parent_dat.ParentNodeGrow)) nodes can grow")
println()

# Compute GrowChain for SG nodes
println("Computing GrowChain depths for SG nodes...")
sg_nodes = DataFrame(Node = sg_pairs.Node)
sg_with_depth = node_depth(sg_nodes, parent_dat)

# Join with original SG pair info
sg_with_depth = leftjoin(
    sg_with_depth,
    sg_pairs,
    on = :Node
)

# Add node and parent interleaf distance info
sg_with_depth = leftjoin(
    sg_with_depth,
    select(node_interleaf, :Node, :InterleafDist),
    on = :Node,
    makeunique = true
)
rename!(sg_with_depth, :InterleafDist => :NodeInterleafDist)

sg_with_depth = leftjoin(
    sg_with_depth,
    select(parent_dat, :Node, :ParentNode, :ParentInterleafDist),
    on = :Node,
    makeunique = true
)

# Reorder columns for clarity
col_order = [:Node, :GrowChain, :Node_Leaves, :NodeInterleafDist, :Parent, 
             :ParentNode, :ParentInterleafDist, :Sibling, :Num_Sibling_Nodes, 
             :Sibling_Node_Leaves, :Sibling_Leaves_Total]
available_cols = intersect(col_order, names(sg_with_depth))
other_cols = setdiff(names(sg_with_depth), available_cols)
sg_with_depth = select(sg_with_depth, vcat(available_cols, other_cols)...)

println("  ✓ GrowChain computed for $(nrow(sg_with_depth)) SG nodes")
println()

# Summary statistics
println("GrowChain Distribution:")
depth_counts = combine(groupby(sg_with_depth, :GrowChain), nrow => :Count)
sort!(depth_counts, :GrowChain)
for row in eachrow(depth_counts)
    println("  Depth $(row.GrowChain): $(row.Count) nodes")
end
println()

# Write output
mkpath(output_dir)
output_file = joinpath(output_dir, "SG_GrowChain_depths.txt")
CSV.write(output_file, sg_with_depth, delim='\t')
println("✓ Output written to: $output_file")
println("  Columns: $(names(sg_with_depth))")
println("  Rows: $(nrow(sg_with_depth))")
println()

println("="^80)
println("SG GrowChain Depth Analysis Complete")
println("="^80)
