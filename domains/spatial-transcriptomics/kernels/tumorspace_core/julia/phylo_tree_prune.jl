#!/usr/bin/env julia
#
# Step 4: Tree Pruning
# Prunes tree nodes below support threshold using as_polytomy!
#

# Activate portable framework
using Pkg
Pkg.activate(joinpath(@__DIR__))

# Load portable functions
include("tumorspace_core.jl")

using PhyloNetworks: PhyloNetworks, writeTopology
using NewickTree: NewickTree, support
using SpectralInference: as_polytomy!

# Parse command line arguments
if length(ARGS) != 3
    println("Usage: julia tree_prune.jl <step3_output_dir> <output_dir> <support_threshold>")
    println("Example: julia tree_prune.jl ./step3_output ./step4_output 0.5")
    exit(1)
end

step3_output_dir = ARGS[1]
output_dir = ARGS[2]
support_threshold = parse(Float64, ARGS[3])

# Create output directory if it doesn't exist
mkpath(output_dir)

# Input tree file from Step 3
tree_input_file = joinpath(step3_output_dir, "OptimalTree_labelpreprune.nw")

println("=" ^ 80)
println("Step 4: Tree Pruning")
println("=" ^ 80)
println("Input tree:        $tree_input_file")
println("Output dir:        $output_dir")
println("Support threshold: $support_threshold")
println()

# Verify input file exists
if !isfile(tree_input_file)
    error("Required file not found: $tree_input_file")
end

# Read tree
println("[1/3] Loading tree...")
tree = PhyloNetworks.readTopology(tree_input_file)
println("  ✓ Tree loaded")

# Write to intermediate file (required for NewickTree format conversion)
temp_file = joinpath(output_dir, "temp_tree.nw")
PhyloNetworks.writeTopology(tree, temp_file)
tree_newick = NewickTree.readnw(readline(temp_file))
rm(temp_file)

# Save pre-pruning tree for Pipeline Report
prepruning_file = joinpath(output_dir, "OptimalTree_preprune.nw")
open(prepruning_file, "w") do io
    println(io, tree_newick)
end
println("  ✓ Saved pre-pruning tree: OptimalTree_preprune.nw")

# Define node removal function and prune
println("[2/3] Pruning nodes with support < $support_threshold...")
function node_remove(node)
    if NewickTree.support(node) < support_threshold
        return true
    else
        return false
    end
end

# Prune tree
as_polytomy!(node_remove, tree_newick)
println("  ✓ Tree pruned successfully")

# Write pruned tree
output_file = joinpath(output_dir, "OptimalTree.nw")
println("[3/3] Writing pruned tree...")
open(output_file, "w") do io
    println(io, tree_newick)
end
println("  ✓ Saved $output_file")

println()
println("=" ^ 80)
println("Step 4 complete!")
println("=" ^ 80)
