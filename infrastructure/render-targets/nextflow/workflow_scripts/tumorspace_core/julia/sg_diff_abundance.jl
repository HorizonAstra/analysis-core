#!/usr/bin/env julia
"""
Step 6: Differential Gene Expression Analysis

Identifies differentially abundant (DA) genes between spatial group (SG) pairs 
using Wilcoxon rank-sum tests with permutation-based FDR correction.

Usage:
    julia diff_abundance.jl <output_dir> [num_shuffle]

Arguments:
    output_dir: Directory containing Step 5 outputs and input data
    num_shuffle: Number of permutations for FDR (default: 20)

Inputs (in output_dir):
    - OptimalTree_pruned_node_compare_list.txt (from Step 5)
    - OptimalTree_pruned_node_compare_leaves.txt (from Step 5)
    - M.txt (gene expression matrix)
    - barcodes.txt (barcode names)
    - genes.txt (gene names)

Outputs (in output_dir):
    - DA_results.txt (all DA test results with p-values and q-values)
    - DA_significant.txt (subset with Q < 1/num_shuffle)
"""
# Activate portable framework
using Pkg
Pkg.activate(joinpath(@__DIR__))

# Load portable functions
include("tumorspace_core.jl")
Pkg.instantiate()

using DataFrames
using CSV
using HypothesisTests
using Random
using Statistics

# Set seed for reproducible permutation testing if provided via environment
if haskey(ENV, "TUMORSPACE_DA_SEED")
    seed_val = parse(Int, ENV["TUMORSPACE_DA_SEED"])
    Random.seed!(seed_val)
    println("=" ^ 60)
    println("REPRODUCIBILITY: Using fixed seed = $seed_val")
    println("All shuffle() operations will be deterministic")
    println("=" ^ 60)
    println()
end

"""
    wilcoxon_test(df::DataFrame, cols::UnitRange)

Compute column-wise Wilcoxon tests between two groups.

Args:
* df: DataFrame with 'Group' column ('Node' or 'Sibling')
* cols: Column range to test

Returns:
* Vector of p-values
"""
function wilcoxon_test(df::DataFrame, cols::UnitRange)
    return [pvalue(MannWhitneyUTest(
        df[df[!, :Group] .== "Node", col], 
        df[df[!, :Group] .== "Sibling", col]
    )) for col in cols]
end

"""
    sg_diff_abundance(node_compare_list, node_compare_leaves, mtx, 
                      barcodes, feat_list, num_shuffle)

Compute SG differential abundance for features.

Args:
* node_compare_list: DataFrame of SG pairs
* node_compare_leaves: DataFrame of SG leaves
* mtx: Feature matrix (rows=spots, cols=features)
* barcodes: Vector of barcode names
* feat_list: Vector of feature names
* num_shuffle: Number of permutations (default: 20)

Returns:
* DataFrame with DA results (DA_Object, Mean_Node, Mean_Sibling, P, Q, Node, Sibling)
"""
function sg_diff_abundance(
    node_compare_list::DataFrame,
    node_compare_leaves::DataFrame,
    mtx::Matrix{Float64},
    barcodes::Vector{String},
    feat_list::Vector{String},
    num_shuffle::Int64
)
    # Ensure Node and Sibling columns are strings
    node_compare_list.Node .= string.(node_compare_list.Node)
    node_compare_list.Sibling .= string.(node_compare_list.Sibling)
    node_compare_leaves.Node .= string.(node_compare_leaves.Node)
    
    # Initialize output
    da_out = DataFrame()
    barcodes_df = DataFrame(barcode = barcodes, Meta_Row = 1:length(barcodes))
    
    # Loop through SG pairs
    for node_id in node_compare_list.Node
        println("Processing SG pair: Node $node_id")
        
        # Get sibling ID
        sibling_id = node_compare_list[node_compare_list.Node .== node_id, :Sibling][1]
        
        # Get leaves for node and sibling
        node_leaves = node_compare_leaves[node_compare_leaves.Node .== node_id, :]
        sibling_leaves = node_compare_leaves[node_compare_leaves.Node .== sibling_id, :]
        
        # Get matrix indices (only keep barcodes that exist in the barcode list)
        node_barcodes_valid = filter(x -> x in barcodes_df.barcode, node_leaves.Barcode)
        sibling_barcodes_valid = filter(x -> x in barcodes_df.barcode, sibling_leaves.Barcode)
        
        node_meta_idx = barcodes_df[map(x -> x in node_barcodes_valid, barcodes_df.barcode), :Meta_Row]
        sibling_meta_idx = barcodes_df[map(x -> x in sibling_barcodes_valid, barcodes_df.barcode), :Meta_Row]
        
        node_m = mtx[node_meta_idx, :]
        sibling_m = mtx[sibling_meta_idx, :]
        
        println("  Node leaves: $(size(node_m, 1)), Sibling leaves: $(size(sibling_m, 1))")
        
        # Test each feature
        node_compare_wilc_permute = DataFrame()
        
        for feat_id in 1:length(feat_list)
            # Concatenate gene counts
            node_sibling_vec = vcat(node_m[:, feat_id], sibling_m[:, feat_id])
            
            # Generate shuffled permutations
            dt_j_shuffle = Matrix{Float64}(undef, length(node_sibling_vec), num_shuffle)
            for i in 1:num_shuffle
                dt_j_shuffle[:, i] = shuffle(node_sibling_vec)
            end
            
            # Combine actual + shuffled data
            dt_j = DataFrame(hcat(node_sibling_vec, dt_j_shuffle), :auto)
            dt_j.Group = vcat(
                repeat(["Node"], length(node_m[:, feat_id])), 
                repeat(["Sibling"], length(sibling_m[:, feat_id]))
            )
            
            # Wilcoxon tests
            result = wilcoxon_test(dt_j, 1:(num_shuffle+1))
            
            # Create one row per permutation run (0=actual, 1:num_shuffle=shuffled)
            new_rows = DataFrame(
                DA_Object = repeat([feat_list[feat_id]], num_shuffle+1),
                Mean_Node = repeat([mean(node_m[:, feat_id])], num_shuffle+1),
                Mean_Sibling = repeat([mean(sibling_m[:, feat_id])], num_shuffle+1),
                P = collect(result),
                Run = collect(0:num_shuffle)
            )
            append!(node_compare_wilc_permute, new_rows)
        end
        
        # Calculate Q values
        sort!(node_compare_wilc_permute, :P)
        
        run_dat_permute_top = node_compare_wilc_permute[node_compare_wilc_permute.Run .!= 0, :]
        run_dat_permute_top = combine(
            groupby(run_dat_permute_top, :Run), 
            :P => (x -> minimum(skipmissing(x))) => :minP
        )
        sort!(run_dat_permute_top, :minP)
        
        run_dat_q = node_compare_wilc_permute[node_compare_wilc_permute.Run .== 0, :]
        threshold_index = ceil(Int, nrow(run_dat_permute_top) / num_shuffle)
        threshold_P = run_dat_permute_top.minP[threshold_index]
        
        run_dat_q.Q .= ifelse.(
            run_dat_q.P .< threshold_P, 
            "< $(1 / num_shuffle)", 
            "N.S."
        )
        
        select!(run_dat_q, Not(:Run))
        sort!(run_dat_q, :P)
        
        run_dat_q.Node .= node_id
        run_dat_q.Sibling .= sibling_id
        
        append!(da_out, run_dat_q)
        
        println("  Completed: $(nrow(run_dat_q)) features tested")
    end
    
    return da_out
end

# Main execution
function main()
    if length(ARGS) < 1
        println("Usage: julia diff_abundance.jl <output_dir> [num_shuffle]")
        println("Example: julia diff_abundance.jl benchmarks/output/step6_test 20")
        exit(1)
    end
    
    output_dir = ARGS[1]
    num_shuffle = length(ARGS) >= 2 ? parse(Int64, ARGS[2]) : 20
    
    println("=" ^ 60)
    println("Step 6: Differential Gene Expression Analysis")
    println("=" ^ 60)
    println("Output directory: $output_dir")
    println("Permutations: $num_shuffle")
    println()
    
    # Load inputs
    println("Loading inputs...")
    node_compare_list = CSV.read(joinpath(output_dir, "OptimalTree_pruned_node_compare_list.txt"), DataFrame; delim='\t')
    node_compare_leaves = CSV.read(joinpath(output_dir, "OptimalTree_pruned_node_compare_leaves.txt"), DataFrame; delim='\t')
    
    # Load data files from optimal directory (copied by orchestrator)
    M = Matrix{Float64}(CSV.read(joinpath(output_dir, "M.txt"), DataFrame; header=false))
    barcodes = String.(vec(Matrix(CSV.read(joinpath(output_dir, "barcodes.txt"), DataFrame; header=true, skipto=2))))
    genes = String.(vec(Matrix(CSV.read(joinpath(output_dir, "genes.txt"), DataFrame; header=true, skipto=2))))
    
    println("  SG pairs: $(nrow(node_compare_list))")
    println("  Total leaves: $(nrow(unique(node_compare_leaves, :Barcode)))")
    println("  Matrix dimensions: $(size(M))")
    println("  Features (genes): $(length(genes))")
    println()
    
    # Run differential abundance
    println("Running differential abundance analysis...")
    da_results = sg_diff_abundance(
        node_compare_list,
        node_compare_leaves,
        M,
        barcodes,
        genes,
        num_shuffle
    )
    
    println()
    println("Results:")
    println("  Total tests: $(nrow(da_results))")
    
    sig_threshold = "< $(1/num_shuffle)"
    da_sig = filter(row -> row.Q == sig_threshold, da_results)
    println("  Significant (Q $sig_threshold): $(nrow(da_sig))")
    
    # Save outputs
    println()
    println("Saving outputs...")
    CSV.write(joinpath(output_dir, "DA_results.txt"), da_results; delim='\t')
    CSV.write(joinpath(output_dir, "DA_significant.txt"), da_sig; delim='\t')
    
    println("  DA_results.txt: All $(nrow(da_results)) test results")
    println("  DA_significant.txt: $(nrow(da_sig)) significant features")
    
    # Export DA gene counts by node for Pipeline Report
    println("\nExporting pipeline report data...")
    da_counts_by_node = combine(groupby(da_sig, :Node), nrow => :DA_Gene_Count)
    sort!(da_counts_by_node, :Node)
    da_counts_file = joinpath(output_dir, "DA_counts_by_node.txt")
    CSV.write(da_counts_file, da_counts_by_node, delim='\t')
    println("  ✓ DA_counts_by_node.txt (DA gene counts per SG for QC)")
    
    println()
    println("=" ^ 60)
    println("Step 6 Complete!")
    println("=" ^ 60)
end

main()
