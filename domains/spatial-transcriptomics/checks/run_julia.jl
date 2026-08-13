#!/usr/bin/env julia
#
# Run the retired Julia Ripley's K over the same nodes the R step ran over.
#
# Usage: julia --project=workflows/tumorspace_core/julia run_julia.jl \
#            <allnodes_leaves.tsv> <out.tsv>
#
# Writes the same three columns the R step writes, so the two files can be
# compared directly: Node, RipleySum, NodeSize.

using CSV, DataFrames, Distances

include(joinpath(@__DIR__, "disabled_julia_ripley.jl"))

if length(ARGS) != 2
    println("usage: run_julia.jl <allnodes_leaves.tsv> <out.tsv>")
    exit(1)
end

leaves = CSV.read(ARGS[1], DataFrame, delim='\t')
println("nodes: ", length(unique(leaves.Node)), "   rows: ", nrow(leaves))

result = tree_ripley(leaves)
CSV.write(ARGS[2], sort(result, :Node), delim='\t')
println("wrote ", nrow(result), " nodes to ", ARGS[2])
