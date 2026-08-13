#!/usr/bin/env julia
#
# spatial_optimize.jl
#
# Step 4: Hyperparameter Optimization
#
# Performs random grid search to find optimal hyperparameters (support threshold,
# spatial clustering threshold, K nearest neighbors) that maximize correlation between
# predicted and actual spot locations.
#
# Ripley's K spatial statistics are read from allnodes_ripley.tsv, which must be
# produced by Step 3 (run_ripley_k.sh / compute_ripley_k.R) before this script runs.
#
# Usage:
#   julia spatial_optimize.jl <step2_output_dir> <data_dir> <tree_support_file> <output_dir>
#
# Inputs:
#   step2_output_dir: Directory containing Step 2 outputs (TSV files)
#   data_dir: Directory with original data (barcodes_positions.txt)
#   tree_support_file: Tree with bootstrap support values (Tree_support.nw)
#   output_dir: Directory to write outputs
#
# Outputs:
#   - allnodes_ripley.tsv: Ripley's K statistics for all nodes
#   - cor_dat_all.tsv: Hyperparameter search results (sorted by correlation)
#   - allnodes_leaves_passingNodes.tsv: Annotated node filtering results
#   - predicted_spot_locations.tsv: Spot location predictions at optimal hyperparameters
#   - OptimalTree_labelpreprune.nw: Tree relabeled with ParentPass values
#
# Dependencies: Install via Project.toml in workflows/julia/
#   julia --project=. -e 'using Pkg; Pkg.instantiate()'
#

# Activate portable framework
using Pkg
Pkg.activate(joinpath(@__DIR__))

# Load portable functions
include("tumorspace_core.jl")

using PhyloNetworks: readTopology, writeTopology

# Parse command line arguments
if length(ARGS) != 3
    println("Usage: julia spatial_optimize.jl <step2_output_dir> <data_dir> <output_dir>")
    println("Example: julia spatial_optimize.jl ./output ./data ./output")
    exit(1)
end

step2_output_dir = ARGS[1]
data_dir = ARGS[2]
output_dir = ARGS[3]

# Create output directory if it doesn't exist
mkpath(output_dir)

# Tree file MUST be Tree_support.nw (with bootstrap support values)
tree_file = joinpath(step2_output_dir, "Tree_support.nw")
if !isfile(tree_file)
    # Try alternative location
    tree_file = joinpath(output_dir, "Tree_support.nw")
    if !isfile(tree_file)
        println("")
        println("ERROR: Tree_support.nw not found in Step 2 output directory")
        println("       Searched: $(joinpath(step2_output_dir, "Tree_support.nw"))")
        println("       Searched: $(joinpath(output_dir, "Tree_support.nw"))")
        println("")
        println("Tree_support.nw is REQUIRED for spatial optimization because:")
        println("  - It contains bootstrap support values (0.0-1.0) for each internal node")
        println("  - The Prune hyperparameter filters nodes by bootstrap confidence")
        println("  - Without it, all nodes default to Support=1.0, making Prune ineffective")
        println("")
        println("To generate Tree_support.nw, run Step 1b (bootstrap support computation):")
        println("  1. Verify Tree_0.nw and Tree_1.nw...Tree_N.nw exist in directory")
        println("  2. Concatenate: cat Tree_{{1..N}}.nw > Tree_Bootstrap.nw")
        println("  3. Run gotree: gotree -i Tree_0.nw -b Tree_Bootstrap.nw -o Tree_support.nw -@ 4 -a tbe")
        println("")
        println("If running end-to-end pipeline, Step 1b may have failed silently. Check:")
        println("  - Step 1b logs for booster/gotree errors")
        println("  - Bootstrap trees exist and are non-empty")
        println("  - gotree binary is in PATH inside container")
        println("  - Sufficient disk space available")
        println("")
        error("Tree_support.nw not found - cannot proceed with spatial optimization")
    end
end

# Verify input files exist
required_files = [
    (joinpath(step2_output_dir, "allnodes_leaves.tsv"), "allnodes_leaves.tsv"),
    (joinpath(step2_output_dir, "allnodes_parents.tsv"), "allnodes_parents.tsv"),
    (joinpath(step2_output_dir, "spectral_dist_melt.tsv"), "spectral_dist_melt.tsv"),
    (joinpath(step2_output_dir, "tree_nodes.tsv"), "tree_nodes.tsv"),
    (tree_file, "Tree_support.nw"),
    (joinpath(data_dir, "barcodes_positions.txt"), "barcodes_positions.txt")
]

for (filepath, name) in required_files
    if !isfile(filepath)
        error("Required file not found: $name at $filepath")
    end
end

println("="^80)
println("Step 4: Hyperparameter Optimization")
println("="^80)
println("Step 2 output: $step2_output_dir")
println("Data dir:      $data_dir")
println("Tree file:     $tree_file")
println("Output dir:    $output_dir")
flush(stdout)
println()

# Read input files
println("[1/5] Loading input data...")
flush(stdout)
allnodes_leaves = CSV.read(joinpath(step2_output_dir, "allnodes_leaves.tsv"), DataFrame, delim='\t')
allnodes_parents = CSV.read(joinpath(step2_output_dir, "allnodes_parents.tsv"), DataFrame, delim='\t')
spectral_dist_melt = CSV.read(joinpath(step2_output_dir, "spectral_dist_melt.tsv"), DataFrame, delim='\t')
tree_nodes = CSV.read(joinpath(step2_output_dir, "tree_nodes.tsv"), DataFrame, delim='\t')
barcodes_positions = CSV.read(joinpath(data_dir, "barcodes_positions.txt"), DataFrame, delim='\t')
tree = readTopology(tree_file)

println("  Loaded $(nrow(allnodes_leaves)) node-leaf relationships")
println("  Loaded $(nrow(spectral_dist_melt)) KNN pairs")
println("  Loaded $(nrow(barcodes_positions)) spots")
flush(stdout)

# Create SVD list
svd_list_loc = DataFrame(Run = [1], SVD_end = [50])  # Assuming SVD=50 from Step 1

# Read pre-computed Ripley's K results from Step 3 (R/spatstat)
# NOTE: Ripley's K computation has been moved to compute_ripley_k.R (Step 3).
# The R/spatstat implementation is substantially faster than the prior Julia version,
# which is required for larger datasets. Step 3 (run_ripley_k.sh) MUST complete
# before this script runs. If you need to restore the Julia fallback, see
# ripleyK_compute / tree_ripley in tumorspace_core.jl (currently commented out).
println("[1/5] Loading pre-computed Ripley's K from Step 3...")
flush(stdout)

ripley_file = joinpath(output_dir, "allnodes_ripley.tsv")
if !isfile(ripley_file)
    println()
    println("ERROR: allnodes_ripley.tsv not found: $ripley_file")
    println()
    println("Step 3 (Ripley's K, run_ripley_k.sh) must complete before Step 4.")
    println("Run: bash run_ripley_k.sh --dataset <DATASET> --account <ACCOUNT> ...")
    println()
    error("Missing Step 3 output: allnodes_ripley.tsv")
end

allnodes_ripley = CSV.read(ripley_file, DataFrame, delim='\t')
println("  ✓ Loaded Ripley's K for $(nrow(allnodes_ripley)) nodes")
flush(stdout)

# Perform hyperparameter optimization
println("[2/5] Starting hyperparameter optimization...")
println("  Searching over:")
println("    - Support threshold: 0.0 - 0.5")
println("    - K nearest neighbors: 5 - 300")
println("    - Spatial quantile: 0.0 - 1.0")
println("  Convergence: Top 2 scores within 0.05")
println("  Minimum iterations: 100")
flush(stdout)
println()

# Generate seed for test mode if needed (extract from environment if set by orchestrator)
seed_val = nothing
if haskey(ENV, "TUMORSPACE_FIXED_SEED") && !isempty(ENV["TUMORSPACE_FIXED_SEED"])
    seed_val = parse(Int, ENV["TUMORSPACE_FIXED_SEED"])
    println("Using fixed seed for reproducibility: $seed_val")
    flush(stdout)
end

cor_dat_all, allnodes_leaves_passingNodes, predicted_spot_locations, tree_labeled = model_optimize(
    svd_list_loc,
    barcodes_positions,
    spectral_dist_melt,
    tree,
    tree_nodes,
    allnodes_leaves,
    allnodes_parents,
    allnodes_ripley;
    seed=seed_val
)

println()
println("[3/5] Optimization complete!")
  println("  Iterations: $(nrow(cor_dat_all))")
  println("  Best correlation: $(round(cor_dat_all.NodeCor[1], digits=4))")
  println("  Optimal hyperparameters:")
  println("    - Support: $(round(cor_dat_all.Prune[1], digits=4))")
  println("    - KNN: $(cor_dat_all.KNN[1])")
  println("    - Spatial: $(round(cor_dat_all.Spatial[1], digits=4))")
flush(stdout)

# Write outputs
println("[4/5] Writing outputs...")
flush(stdout)

output_files = [
    (cor_dat_all, "cor_dat_all.tsv", "Hyperparameter search results"),
    (allnodes_leaves_passingNodes, "allnodes_leaves_passingNodes.tsv", "Annotated node filtering"),
    (predicted_spot_locations, "predicted_spot_locations.tsv", "Predicted spot locations")
]

for (df, filename, description) in output_files
    outfile = joinpath(output_dir, filename)
    CSV.write(outfile, df, delim='\t')
    println("  ✓ $filename ($(nrow(df)) rows) - $description")
    flush(stdout)
end

# Write labeled tree
tree_outfile = joinpath(output_dir, "OptimalTree_labelpreprune.nw")
writeTopology(tree_labeled, tree_outfile)
println("  ✓ OptimalTree_labelpreprune.nw - Tree with ParentPass labels")
flush(stdout)

# Summary statistics
println()
println("[5/5] Summary statistics:")
println("  Nodes passing Ripley's K: $(sum(allnodes_leaves_passingNodes.RipPass))")
println("  Nodes passing Support: $(sum(allnodes_leaves_passingNodes.SupportPass))")
println("  Nodes passing both: $(sum(allnodes_leaves_passingNodes.BothPass))")
println("  Parent nodes selected: $(sum(allnodes_leaves_passingNodes.ParentPass))")
println("  Spots with predictions: $(nrow(predicted_spot_locations))")
flush(stdout)

# Export SG depth distribution for Pipeline Report
println()
println("Exporting pipeline report data...")
sg_nodes = filter(row -> row.ParentPass == 1, allnodes_leaves_passingNodes)
if nrow(sg_nodes) > 0 && "Depth" in names(sg_nodes)
    sg_depth_counts = combine(groupby(sg_nodes, :Depth), nrow => :Count)
    sort!(sg_depth_counts, :Depth)
    sg_depth_file = joinpath(output_dir, "SG_depths.txt")
    CSV.write(sg_depth_file, sg_depth_counts, delim='\t')
    println("  ✓ SG_depths.txt (SG depth distribution for QC)")
else
    println("  ⚠ Skipping SG_depths.txt (no passing nodes or Depth column not available)")
end
flush(stdout)

println()
println("="^80)
println("Step 4 complete!")
println("="^80)
