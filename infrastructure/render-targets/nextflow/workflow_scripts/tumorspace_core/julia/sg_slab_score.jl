#!/usr/bin/env julia
"""
Step 7: SLAB (Spatially Localized Abundance Bias) Scoring

Computes spatial localization scores for differentially abundant genes based on
which barcodes (spots) show DA changes across the spatial hierarchy.

SLAB score = (# spots with DA change) / (total # spots)

Usage:
    julia slab_score.jl <output_dir>

Arguments:
    output_dir: Directory containing Step 6 outputs

Inputs (in output_dir):
    - DA_significant.txt (from Step 6)
    - OptimalTree_pruned_node_compare_list.txt (from Step 5)
    - OptimalTree_pruned_node_compare_leaves.txt (from Step 5)
    - ../../benchmarks/GSE213688_GSM6592057/input_data/barcodes_positions.txt

Outputs (in output_dir):
    - SLAB_scores.txt (SLAB score per gene per direction)
    - SLAB_barcodes.txt (barcode-level details)
"""
# Activate portable framework
using Pkg
Pkg.activate(joinpath(@__DIR__))

# Load portable functions
include("tumorspace_core.jl")
Pkg.instantiate()


using DataFrames
using CSV

"""
    sg_slab(node_da, node_compare_leaves, node_compare_list, barcode_positions)

Compute SLAB scores for DA genes.

Args:
* node_da: DataFrame of significant DA genes (from sg_diff_abundance)
* node_compare_leaves: DataFrame of SG leaves
* node_compare_list: DataFrame of SG pairs
* barcode_positions: DataFrame of barcode spatial positions

Returns:
* Tuple of (slab_scores, slab_barcodes)
"""
function sg_slab(
    node_da::DataFrame,
    node_compare_leaves::DataFrame,
    node_compare_list::DataFrame,
    barcode_positions::DataFrame
)
    node_list_dat = DataFrame()
    node_list = combine(groupby(node_da, :Node), nrow => :N)
    
    for j in 1:nrow(node_list)
        node_sub = filter(row -> row.Node == node_list.Node[j], node_da)
        node_sub = leftjoin(node_sub, select(node_compare_list, :Node, :Node_Leaves), on=:Node)
        node_sub = leftjoin(node_sub, select(node_compare_list, :Sibling, :Sibling_Node_Leaves), on=:Sibling)
        
        # Direction: Up/Down based on mean expression
        d1 = leftjoin(
            transform(node_sub, 
                [:Mean_Node,:Mean_Sibling] => ByRow((x, y) -> x > y ? "Up" : "Down") => :Dir, 
                :Node => ByRow(string) => :Node
            ), 
            unique(select(node_compare_leaves, [:Node, :Barcode])), 
            on=:Node
        )
        
        d2 = leftjoin(
            transform(node_sub, 
                [:Mean_Node,:Mean_Sibling] => ByRow((x, y) -> x < y ? "Up" : "Down") => :Dir, 
                :Node => ByRow(x -> "$(x)_Sibling") => :Node
            ), 
            unique(select(node_compare_leaves, [:Node, :Barcode])), 
            on=:Node
        )
        
        node_sub_combined = vcat(d1, d2)
        transform!(node_sub_combined, 
            :Node => ByRow(x -> occursin("Sibling", x) ? "Sibling" : "Node") => :NodeType, 
            :Node => ByRow(x -> replace(x, "_Sibling" => "")) => :Node
        )
        transform!(node_sub_combined,
            [:Node_Leaves,:Sibling_Node_Leaves] => ByRow((x, y) -> x > y ? "Node" : "Sibling") => :LargerBranch
        )
        transform!(node_sub_combined,
            [:NodeType,:LargerBranch] => ByRow((x, y) -> x == y ? "Y" : "N") => :Is_LargerBranch
        )
        
        # Only keep smaller branch (to avoid double counting)
        append!(node_list_dat, filter(row -> row.Is_LargerBranch == "N", node_sub_combined))
    end
    
    # Identify barcodes with DA changes in both directions
    dir_both_barcodes = combine(groupby(node_list_dat, [:DA_Object, :Barcode, :Dir]), nrow => :N)
    dir_both_barcodes = combine(groupby(dir_both_barcodes, [:DA_Object, :Barcode]), nrow => :N)
    dir_both_barcodes = filter(row -> row.N == 2, dir_both_barcodes)
    dir_both_barcodes = semijoin(node_list_dat, dir_both_barcodes, on = [:DA_Object, :Barcode]) 
    
    dir_both_barcodes[:, :NodeChangeSize] .= ifelse.(
        dir_both_barcodes.NodeType .== "Sibling", 
        dir_both_barcodes.Sibling_Node_Leaves, 
        dir_both_barcodes.Node_Leaves
    )
    sort!(dir_both_barcodes, :NodeChangeSize, rev = true)
    dir_both_barcodes[:, :Dir] .= "Both"
    
    dir_both_barcodes_stats = combine(groupby(dir_both_barcodes, [:DA_Object, :Barcode]), nrow => :N)
    dir_both_barcodes_stats[:, :NumChangeNodes] .= dir_both_barcodes_stats[:, :N]
    dir_both_barcodes_stats = select(dir_both_barcodes_stats, Not(:N))
    
    dir_both_barcodes_collapsedsizes = combine(
        groupby(dir_both_barcodes, [:DA_Object, :Barcode]), 
        :NodeChangeSize => x -> join(x, "_")
    )
    rename!(dir_both_barcodes_collapsedsizes, :NodeChangeSize_function => :NodeSizesCollapsed)
    
    dir_both_barcodes = select(dir_both_barcodes, [:DA_Object, :Barcode, :Dir, :NodeChangeSize])
    dir_both_barcodes = unique(dir_both_barcodes, [:DA_Object, :Barcode])
    dir_both_barcodes = leftjoin(dir_both_barcodes, dir_both_barcodes_stats, on = [:DA_Object, :Barcode])
    dir_both_barcodes = leftjoin(dir_both_barcodes, dir_both_barcodes_collapsedsizes, on = [:DA_Object, :Barcode])
    dir_both = combine(groupby(dir_both_barcodes, [:DA_Object, :Dir]), nrow => :N)
    
    # Barcodes with DA changes in one direction only
    dir_single_barcodes = antijoin(node_list_dat, dir_both_barcodes, on = [:DA_Object, :Barcode])
    transform!(dir_single_barcodes, 
        [:NodeType,:Node_Leaves,:Sibling_Node_Leaves] => ByRow((x, y, z) -> x == "Sibling" ? z : y) => :NodeChangeSize
    )
    sort!(dir_single_barcodes, :NodeChangeSize, rev=true)
    
    dir_single_barcodes_stats = combine(groupby(dir_single_barcodes, [:DA_Object, :Barcode]), nrow => :N)
    rename!(dir_single_barcodes_stats, :N => :NumChangeNodes)
    
    dir_single_barcodes_collapsedsizes = combine(
        groupby(dir_single_barcodes, [:DA_Object, :Barcode]), 
        :NodeChangeSize => x -> join(x, "_")
    )
    rename!(dir_single_barcodes_collapsedsizes, :NodeChangeSize_function => :NodeSizesCollapsed)
    
    dir_single_barcodes = leftjoin(dir_single_barcodes, dir_single_barcodes_stats, on = [:DA_Object, :Barcode])
    dir_single_barcodes = leftjoin(dir_single_barcodes, dir_single_barcodes_collapsedsizes, on = [:DA_Object, :Barcode])
    dir_single_barcodes = select(dir_single_barcodes, [:DA_Object, :Barcode, :Dir, :NodeChangeSize])
    dir_single_barcodes = unique(dir_single_barcodes, [:DA_Object, :Barcode])
    dir_single = combine(groupby(dir_single_barcodes, [:DA_Object, :Dir]), nrow => :N)
    dir_single_barcodes.NumChangeNodes .= dir_single_barcodes.NodeSizesCollapsed .= "NA"
    
    # Compute SLAB scores
    slab_barcodes = vcat(dir_single_barcodes, dir_both_barcodes)
    slab_scores = vcat(dir_both, dir_single)
    slab_scores[!, :Spots] .= nrow(barcode_positions)
    sort!(transform!(slab_scores, [:N,:Spots] => ByRow((x, y) -> x/y) => :SLAB), :SLAB, rev=true)
    
    return (slab_scores, slab_barcodes)
end

# Main execution
function main()
    if length(ARGS) < 1
        println("Usage: julia slab_score.jl <output_dir>")
        println("Example: julia slab_score.jl benchmarks/output/step7_test")
        exit(1)
    end
    
    output_dir = ARGS[1]
    
    println("=" ^ 60)
    println("Step 7: SLAB Scoring")
    println("=" ^ 60)
    println("Output directory: $output_dir")
    println()
    
    # Load inputs
    println("Loading inputs...")
    node_da = CSV.read(joinpath(output_dir, "DA_significant.txt"), DataFrame; delim='\t')
    node_compare_list = CSV.read(joinpath(output_dir, "OptimalTree_pruned_node_compare_list.txt"), DataFrame; delim='\t')
    node_compare_leaves = CSV.read(joinpath(output_dir, "OptimalTree_pruned_node_compare_leaves.txt"), DataFrame; delim='\t')
    
    # Load barcode positions from optimal directory (copied by orchestrator)
    barcode_positions = CSV.read(joinpath(output_dir, "barcodes_positions.txt"), DataFrame; delim='\t')
    
    println("  Significant DA genes: $(length(unique(node_da.DA_Object)))")
    println("  SG pairs: $(nrow(node_compare_list))")
    println("  Total spots: $(nrow(barcode_positions))")
    println()
    
    # Compute SLAB scores
    println("Computing SLAB scores...")
    slab_scores, slab_barcodes = sg_slab(
        node_da,
        node_compare_leaves,
        node_compare_list,
        barcode_positions
    )
    
    println()
    println("Results:")
    println("  Genes with SLAB scores: $(nrow(slab_scores))")
    println("  Barcode-gene combinations: $(nrow(slab_barcodes))")
    println()
    
    # Save outputs
    println("Saving outputs...")
    CSV.write(joinpath(output_dir, "SLAB_scores.txt"), slab_scores; delim='\t')
    CSV.write(joinpath(output_dir, "SLAB_barcodes.txt"), slab_barcodes; delim='\t')
    
    println("  SLAB_scores.txt: $(nrow(slab_scores)) gene-direction combinations")
    println("  SLAB_barcodes.txt: $(nrow(slab_barcodes)) barcode assignments")
    
    # Show top SLAB scores
    if nrow(slab_scores) > 0
        println()
        println("Top 10 SLAB scores:")
        println(first(slab_scores, 10))
    end
    
    println()
    println("=" ^ 60)
    println("Step 7 Complete!")
    println("=" ^ 60)
end

main()
