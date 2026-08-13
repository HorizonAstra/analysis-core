"""
tumorspace_core.jl

Core TumorSPACE functions extracted for AWS pipeline portability.
This module contains only the functions needed across pipeline steps,
extracted from the private TumorSPACE.jl repository.

Source: https://github.com/aramanlab/TumorSPACE.jl (private)
License: As per TumorSPACE.jl repository

Dependencies:
Install by running from workflows/julia/ directory:
    julia --project=. -e 'using Pkg; Pkg.instantiate()'

Or activate the environment before running scripts:
    julia --project=/path/to/TumorSPACE_AWS/workflows/julia script.jl

Usage:
    include("tumorspace_core.jl")
    obs_dij, tree = model_calc(matrix, barcodes, svd_value, boot)
"""

using SpectralInference: SpectralInference, getintervals, hclust
using Noise: Noise
using PhyloNetworks: PhyloNetworks, HybridNetwork, writeTopology
using DataFrames: DataFrame, DataFrames, nrow
using CSV: CSV
using NewickTree: NewickTree
using Dates: Dates, now
using Statistics: Statistics
using Random: Random

# Re-export commonly used types for convenience
export DataFrame, CSV

#=============================================================================
Step 1: Tree Building Functions (from buildmodel.jl)
=============================================================================#

"""
    model_calc(matrix::Matrix, barcodes::Vector{<:AbstractString}, s::Int64, b::Int64; seed::Union{Nothing,Int}=nothing)

For a given bootstrap # and SVD-end parameter #, will compute SVD, Spectral Distance, 
and create hierarchical tree. Saves the computed SVD and distance matrix for bootstrap 0 
(non-augmented data) only. All additional bootstraps involve noise injection into the 
existing gene count matrix using a multiplicative Gaussian.

Args:
* matrix: ST-seq gene count matrix (spots in rows, genes in columns)
* barcodes: ST-seq barcode vector
* s: value of svd-end hyperparameter
* b: bootstrap number
* seed: optional fixed seed for reproducibility (if nothing, uses random RNG state)

Returns:
* Matrix{Float64} Obs_Dij is a distance adjacency matrix describing Spectral Distances between pairs of spots
* String nwtreestring is a newick string describing the hierarchical tree of spots
"""
function model_calc(matrix::Matrix, barcodes::Vector{<:AbstractString}, s::Int64, b::Int64; seed::Union{Nothing,Int}=nothing)
    # Check that matrix and barcode sizes match
    if size(matrix)[1] != size(barcodes)[1]
        throw(ArgumentError("Number of matrix rows ($(size(matrix)[1])) doesn't match number of barcodes ($(size(barcodes)[1]))!"))
    end
    
    # Apply noise injection for bootstraps
    mtx_boot = matrix_noiseinjection(matrix, b; seed=seed)
    
    # SVD calculation
    usv = SpectralInference.svd(mtx_boot)
    
    # Calculate spectral distance
    obs_dij = SpectralInference.spectraldistances(usv.U[:,1:s], usv.S[1:s], getintervals(usv.S[1:s]))
    
    # Calculate hierarchical tree
    obstree = hclust(obs_dij, linkage=:complete, branchorder=:optimal)
    nwtreestring = SpectralInference.newickstring(obstree, barcodes; labelinternalnodes=false)
    
    return obs_dij, nwtreestring
end

"""
    matrix_noiseinjection(matrix::Matrix, b::Int64, SD=0.2, Mean=1; seed::Union{Nothing,Int}=nothing)

For a given matrix and bootstrap value, will inject multiplicative Gaussian noise 
using the specified distribution parameters if the bootstrap value doesn't equal 0.

Args:
* matrix: ST-seq gene count matrix (spots in rows, genes in columns)
* b: bootstrap value (where 0 means it will not be a noise-injected bootstrap)
* SD: Gaussian distribution standard deviation, default 0.2
* Mean: Gaussian distribution mean, default 1
* seed: optional fixed seed for reproducibility (if nothing, uses random RNG state)

Returns:
* Matrix{Float64} a matrix with injected Gaussian noise if bootstrap != 0
"""
function matrix_noiseinjection(matrix::Matrix, b::Int64, SD=0.2, Mean=1; seed::Union{Nothing,Int}=nothing)
    # Set matrix type
    if matrix isa Array{<:Number,2}
        matrix = convert(Array{Float64}, matrix)
    else
        throw(ArgumentError("Gene expression matrix contains non-numeric values (perhaps barcode or feature names?)"))
    end
    
    # Seed RNG if fixed seed provided (seed should already include bootstrap offset from phylo_tree_build.jl)
    if seed !== nothing
        Random.seed!(seed)
    end
    
    # If Boot != 0 (actual bootstrap run), then do noise injection using multiplicative Gaussian
    if b == 0
        mtx_boot = matrix
    else
        # Multiply each array value by a random value from gaussian distribution with sd and mean as listed
        mtx_boot = Noise.mult_gauss(matrix, SD, Mean)
    end
    
    return mtx_boot
end

#=============================================================================
Step 2: Node Extraction Functions (from optimizemodel.jl)
==============================================================================#

"""
Helper function to convert string to integer, handling both String and numeric types.
"""
function toint(x::Any)
    x = String(x)
    x isa String ? tryparse(Int, x) : Int(x)
end

"""
    phylo_print_nodes(tree_in::HybridNetwork)

Extract node information from a PhyloNetworks tree object.

Args:
* tree_in: HybridNetwork tree object

Returns:
* DataFrame with columns: node (Int), leaf (Bool), name (String)
"""
function phylo_print_nodes(tree_in::HybridNetwork)
    dat_out = DataFrame(node = Int64[], leaf = Bool[], name = String[])
    tree_obj = tree_in.node
    for i in 1:size(tree_obj)[1]
        push!(dat_out, (node = tree_obj[i].number, leaf = tree_obj[i].leaf, name = tree_obj[i].name))
    end
    dat_out
end

"""
    phylo_print_edges(tree_edges_prelim::DataFrame)

Parse edge information from PhyloNetworks.printEdges output.

Args:
* tree_edges_prelim: DataFrame with single column 'edge' containing raw output lines

Returns:
* DataFrame with parsed edge information (edge, parent, child, length, etc.)
"""
function phylo_print_edges(tree_edges_prelim::DataFrame)
    # Skip header line and parse data lines
    rows_to_parse = tree_edges_prelim.edge[2:end]  # Skip first row (header)
    
    # Parse first data row to get column names from header
    col_names = filter(!isempty, split(tree_edges_prelim.edge[1], " "))
    if length(col_names) < 5
        col_names = ["edge", "parent", "child", "length", "hybrid"]
    else
        col_names = col_names[1:5]
    end
    
    dat_out = DataFrame([Any[] for i in 1:5], col_names)
    for edge_line in rows_to_parse
        parts = filter(!isempty, split(edge_line, " "))
        if length(parts) >= 5
            push!(dat_out, parts[1:5])
        end
    end
    dat_out
end

"""
    tree_nodedescendants(tree_in::HybridNetwork, tree_nodes::DataFrame, tree_edges::DataFrame)

Compute all descendant leaves for each internal node in the tree.

Args:
* tree_in: HybridNetwork tree object
* tree_nodes: DataFrame from phylo_print_nodes()
* tree_edges: DataFrame from phylo_print_edges()

Returns:
* DataFrame with columns: Node (Int), Leaf (Int), barcode (String)
"""
function tree_nodedescendants(tree_in::HybridNetwork, tree_nodes::DataFrame, tree_edges::DataFrame)
    tree_edges.child = string.(tree_edges.child)
    internal_nodes = filter(row -> row.leaf == false, tree_nodes)
    all_leafs = filter(row -> row.leaf == true, tree_nodes)
    nodedesc_dat = DataFrame(Node = Int64[], Leaf = Int64[], barcode = String[])
    
    for r in 1:nrow(internal_nodes)
        edgenode_match = filter(:child => ==(string.(internal_nodes.node[r])), tree_edges)
        if nrow(edgenode_match) > 0
            edge_num = toint(edgenode_match.edge[1])
            desc_num = PhyloNetworks.descendants(tree_in.edge[edge_num])
            leaf_dat = DataFrame(
                Node = internal_nodes.node[r],
                Leaf = desc_num,
                barcode = filter(row -> row.node in desc_num, tree_nodes).name
            )
            append!(nodedesc_dat, leaf_dat)
        elseif ismissing(internal_nodes.name[r]) || internal_nodes.name[r] == ""
            # Root node - add all leaves as descendants
            leaf_dat = DataFrame(
                Node = repeat([internal_nodes.node[r]], nrow(all_leafs)),
                Leaf = all_leafs.node,
                barcode = all_leafs.name
            )
            append!(nodedesc_dat, leaf_dat)
        else
            throw(ErrorException("tree_nodedescendants: Mismatch in Node IDs between tree_nodes and tree_edges DataFrames!"))
        end
    end
    nodedesc_dat
end

"""
    tree_nodeancestors(tree_nodes::DataFrame, tree_edges::DataFrame)

Compute all ancestor nodes for each internal node in the tree.

Args:
* tree_nodes: DataFrame from phylo_print_nodes()
* tree_edges: DataFrame from phylo_print_edges()

Returns:
* DataFrame with columns: Node (Int), ParentNode (Int), AncesGen (Int - ancestral generation)
"""
function tree_nodeancestors(tree_nodes::DataFrame, tree_edges::DataFrame)
    tree_edges.child = string.(tree_edges.child)
    internal_nodes = filter(row -> row.leaf == false, tree_nodes)
    nodeanc_dat = DataFrame(Node = Int64[], ParentNode = Int64[], AncesGen = Int64[])
    
    for r in 1:nrow(internal_nodes)
        parent_exists = true
        desc_node = internal_nodes.node[r]
        ag = 1
        
        while parent_exists
            parent_dat = filter(:child => ==(string.(desc_node)), tree_edges)
            if nrow(parent_dat) > 0
                parent = toint(parent_dat.parent[1])
                push!(nodeanc_dat, (Node = internal_nodes.node[r], ParentNode = parent, AncesGen = ag))
                desc_node = parent
                ag += 1
            else
                # Root node - add itself as parent with generation 0
                push!(nodeanc_dat, (Node = internal_nodes.node[r], ParentNode = internal_nodes.node[r], AncesGen = 0))
                parent_exists = false
            end
        end
    end
    nodeanc_dat
end

"""
    KNNcompute(obs_dij::DataFrame, barcodes_positions::DataFrame; max_knn::Int=300)

Create ranked spot matches based on spectral distance, truncated to the top max_knn
neighbors per spot. max_knn should match knn_max in model_optimize (default 300) so
that only rows that can ever be used by spot_location_prediction are written to disk.

Args:
* obs_dij: Distance matrix DataFrame (no headers, spot x spot)
* barcodes_positions: DataFrame with barcode column and spatial coordinates
* max_knn: Maximum number of nearest neighbors to retain per spot (default 300)

Returns:
* DataFrame with columns: Barcode_1, Barcode_2, Spectral_Distance, Rank
"""
function KNNcompute(obs_dij::DataFrame, barcodes_positions::DataFrame; max_knn::Int=300)
    spectral_dist = copy(obs_dij)
    DataFrames.rename!(spectral_dist, barcodes_positions.barcode)
    spectral_dist.Barcode_1 = barcodes_positions.barcode
    spectral_dist_melt = DataFrames.stack(spectral_dist, DataFrames.Not(:Barcode_1))
    DataFrames.rename!(spectral_dist_melt, [:Barcode_1, :Barcode_2, :Spectral_Distance])
    
    # Group by Barcode_1, order by distance, add rank, and truncate to top max_knn neighbors
    grouped = DataFrames.groupby(spectral_dist_melt, :Barcode_1)
    spectral_dist_melt = DataFrames.combine(grouped) do subdf
        sorted = sort(subdf, :Spectral_Distance)
        k = min(nrow(sorted), max_knn)
        sorted = sorted[1:k, :]
        sorted.Rank = 1:k
        sorted
    end
    
    spectral_dist_melt
end

"""
    model_extract(obs_dij::DataFrame, barcodes_positions::DataFrame, tree_in::HybridNetwork, 
                  tree_nodes::DataFrame, tree_edges::DataFrame)

Main orchestrator for Step 2: Extract all node/edge information and compute relationships.

Args:
* obs_dij: Distance matrix DataFrame
* barcodes_positions: DataFrame with barcode and spatial coordinates
* tree_in: HybridNetwork tree object
* tree_nodes: DataFrame from phylo_print_nodes()
* tree_edges: DataFrame from phylo_print_edges()

Returns:
* Tuple of (spectral_dist_melt, allnodes_leaves, allnodes_parents)
"""
function model_extract(obs_dij::DataFrame, barcodes_positions::DataFrame, tree_in::HybridNetwork,
                       tree_nodes::DataFrame, tree_edges::DataFrame)
    # Identify ranked KNN matches for each spot
    spectral_dist_melt = KNNcompute(obs_dij, barcodes_positions)
    
    # For any given node, identify all descendant leaves
    allnodes_leaves = tree_nodedescendants(tree_in, tree_nodes, tree_edges)
    allnodes_leaves = DataFrames.leftjoin(allnodes_leaves, barcodes_positions, on = :barcode)
    
    # For any given node, identify the parent chain of nodes
    allnodes_parents = tree_nodeancestors(tree_nodes, tree_edges)
    
    spectral_dist_melt, allnodes_leaves, allnodes_parents
end

#=============================================================================
Step 4: Hyperparameter Optimization (from optimizemodel.jl)
=============================================================================#

# NOTE: Ripley's K computation (ripleyK_compute, tree_ripley) has been moved to
# compute_ripley_k.R (R/spatstat) and is now Step 3 of the pipeline. The R
# implementation is substantially faster than the Julia version due to spatstat's
# C-backed vectorized implementation, which is required for larger datasets.
#
# The functions below are DISABLED. To restore the Julia fallback, uncomment
# the block from "# BEGIN JULIA RIPLEY'S K" to "# END JULIA RIPLEY'S K".
# Note: if restored, spatial_optimize.jl must also be reverted to call tree_ripley()
# and write allnodes_ripley.tsv directly (rather than reading the file from Step 3).

using Distances: Euclidean, pairwise
using StatsBase: StatsBase, quantile, sample, median
using Random: Random, seed!, shuffle

# BEGIN JULIA RIPLEY'S K — DISABLED (moved to compute_ripley_k.R, Step 3)
# Uncomment to restore if needed. See note above.
#
# """
#     ripleyK_compute(dat_in::DataFrame, x_vec::Vector, y_vec::Vector)
#
# Compute Ripley's K spatial clustering statistic for a single node using
# border-corrected K-function.
#
# Args:
# * dat_in: DataFrame with X, Y coordinates for spots in a node
# * x_vec: Vector of all X coordinates in dataset (for boundary calculation)
# * y_vec: Vector of all Y coordinates in dataset (for boundary calculation)
#
# Returns:
# * Float64: Sum of absolute deviations from theoretical K (spatial clustering metric)
# """
# function ripleyK_compute(dat_in::DataFrame, x_vec::Vector, y_vec::Vector)
#     npts = nrow(dat_in)
#     x_length = maximum(x_vec) - minimum(x_vec)
#     y_length = maximum(y_vec) - minimum(y_vec)
#
#     # Handle degenerate geometries (collinear points or single point)
#     if x_length <= 0 || y_length <= 0 || npts <= 1
#         return 0.0
#     end
#
#     areaW = x_length * y_length
#     lambda = npts / areaW
#
#     # Compute boundary points
#     point_num = 10
#     X_sequence = Vector(range(minimum(x_vec), maximum(x_vec), step=x_length/point_num))
#     Y_sequence = Vector(range(minimum(y_vec), maximum(y_vec), step=y_length/point_num))
#     bottom_bound = Array(DataFrame(X=X_sequence, Y=fill(minimum(y_vec), length(X_sequence))))
#     top_bound = Array(DataFrame(X=X_sequence, Y=fill(maximum(y_vec), length(X_sequence))))
#     left_bound = Array(DataFrame(X=fill(minimum(x_vec), length(Y_sequence)), Y=Y_sequence))
#     right_bound = Array(DataFrame(X=fill(maximum(x_vec), length(Y_sequence)), Y=Y_sequence))
#     boundary_points = vcat(bottom_bound, top_bound, left_bound, right_bound)
#
#     # Define r sequence
#     rmax = min(min(x_length/4, y_length/4), sqrt(1000 / (pi * lambda)))
#
#     # Handle edge case where rmax is too small
#     if rmax <= 0 || isnan(rmax)
#         return 0.0  # Return 0 for degenerate cases
#     end
#
#     rvec = Vector(range(0, rmax, step=rmax/512))
#     k_dat = DataFrame(r = rvec, theo = pi * rvec.^2)
#
#     # Compute distance to boundary for border correction
#     border_mtx = pairwise(Euclidean(), vcat(Array(DataFrames.select(dat_in, [:X, :Y])), boundary_points), dims=1)[1:npts, (npts+1):(npts+size(boundary_points)[1])]
#
#     # Compute spatial distance between points
#     dist_mtx = pairwise(Euclidean(), Array(DataFrames.select(dat_in, [:X, :Y])), dims=1)
#
#     # Minimum distance to border
#     dat_in.BorderMin = vec(minimum(border_mtx, dims=2))
#
#     function k_compute(r)
#         n_elig = filter(row -> row.BorderMin >= r, dat_in)
#         mask = ifelse.(dat_in.BorderMin .>= r, 1, 0)
#         mask_mtx = reshape(repeat(mask, inner=size(mask)[1]), size(mask)[1], size(mask)[1])
#         dist_mask = dist_mtx .* mask_mtx
#         size(filter(n -> n <= r, filter(!iszero, dist_mask)))[1] / (lambda * nrow(n_elig))
#     end
#
#     # Calculate Kest for all r
#     k_dat.border = k_compute.(k_dat.r)
#     k_abs = abs.(k_dat.border .- k_dat.theo)
#     k = sum(filter(!isnan, k_abs))
#     return k
# end
#
# """
#     tree_ripley(allnodes_leaves::DataFrame)
#
# Compute Ripley's K spatial clustering statistic for all internal nodes in the tree.
#
# Args:
# * allnodes_leaves: DataFrame with Node, Leaf, barcode, X, Y columns
#
# Returns:
# * DataFrame with columns: Node, RipleySum, NodeSize
# """
# function tree_ripley(allnodes_leaves::DataFrame)
#     # Columns: Node, Leaf, barcode, in_tissue, array_row, array_col,
#     #          pxl_row_in_fullres, pxl_col_in_fullres, pxl_row_in_mm, pxl_col_in_mm
#     if !("X" in names(allnodes_leaves))
#         DataFrames.rename!(allnodes_leaves, 9 => :X)  # pxl_row_in_mm
#     end
#     if !("Y" in names(allnodes_leaves))
#         DataFrames.rename!(allnodes_leaves, 10 => :Y)  # pxl_col_in_mm
#     end
#
#     node_count = sort(DataFrames.combine(DataFrames.groupby(allnodes_leaves, :Node, sort=true), nrow), :nrow, rev=true)
#     noderip_dat = DataFrame(Node = Int64[], RipleySum = Float64[], NodeSize = Int64[])
#
#     for n in 1:nrow(node_count)
#         dat_node = sort(filter(row -> row.Node == node_count.Node[n], allnodes_leaves), :Leaf)
#         push!(noderip_dat, (
#             Node = node_count.Node[n],
#             RipleySum = ripleyK_compute(dat_node, allnodes_leaves.X, allnodes_leaves.Y),
#             NodeSize = node_count.nrow[n]
#         ))
#     end
#     noderip_dat
# end
#
# END JULIA RIPLEY'S K

"""
    spot_location_prediction(allnodes_leaves, allnodes_parents, spectral_dist_melt,
                             barcodes_positions_coordonly, prune, knn, spatial,
                             knn_spatial_run, svd_list_loc; seed=nothing)

Predict spot locations using given hyperparameters and compute correlation with actual locations.

Args:
* allnodes_leaves: DataFrame with node/leaf relationships and Support, RipleySum columns
* allnodes_parents: DataFrame with ancestor relationships
* spectral_dist_melt: DataFrame with KNN rankings
* barcodes_positions_coordonly: DataFrame with barcode, X, Y columns
* prune: Support threshold (0-1)
* knn: K nearest neighbors (5-300)
* spatial: Ripley's K quantile threshold (0-1)
* knn_spatial_run: Random seed for reproducibility
* svd_list_loc: DataFrame with Run, SVD_end columns
* seed: optional fixed seed for reproducibility (if nothing, uses random RNG state)

Returns:
* Tuple of (allnodes_leaves_passingNodes, predicted_spot_locations, cor_dat) or (missing, missing, missing)
"""
function spot_location_prediction(allnodes_leaves::DataFrame, allnodes_parents::DataFrame,
                                   spectral_dist_melt::DataFrame, barcodes_positions_coordonly::DataFrame,
                                   prune::Float64, knn::Int64, spatial::Float64,
                                   knn_spatial_run::Int64, svd_list_loc::DataFrame; seed::Union{Nothing,Int}=nothing)
    # Identify nodes that pass thresholds
    rip_nodes_pass = unique(allnodes_leaves, :Node)
    rip_nodes_pass = filter(row -> row.RipleySum >= quantile(rip_nodes_pass.RipleySum, spatial), rip_nodes_pass)
    prune_nodes_pass = filter(row -> row.Support >= prune, unique(allnodes_leaves, :Node))
    nodes_pass = filter(row -> (row.Node in rip_nodes_pass.Node) & (row.Node in prune_nodes_pass.Node), unique(allnodes_leaves, :Node))
    
    if nrow(nodes_pass) > 0
        nodes_pass_parents = unique(filter(row -> row.Node in nodes_pass.Node, allnodes_parents), :ParentNode)
        
        # Annotate passing nodes
        allnodes_leaves.RipPass = [(t.Node in rip_nodes_pass.Node ? 1 : 0) for t in eachrow(allnodes_leaves)]
        allnodes_leaves.SupportPass = [(t.Node in prune_nodes_pass.Node ? 1 : 0) for t in eachrow(allnodes_leaves)]
        allnodes_leaves.BothPass = [((t.RipPass == 1) & (t.SupportPass == 1) ? 1 : 0) for t in eachrow(allnodes_leaves)]
        allnodes_leaves.ParentPass = [(t.Node in nodes_pass_parents.ParentNode ? 1 : 0) for t in eachrow(allnodes_leaves)]
        allnodes_leaves_passingNodes = copy(allnodes_leaves)
        
        # Filter to spatial clusters
        allnodes_leaves_spatial = filter(row -> row.Node in nodes_pass_parents.ParentNode, allnodes_leaves)
        smallest_allnodes_leaves = unique(sort(allnodes_leaves_spatial, :NodeSize), :Leaf)
        
        # Get KNN connections
        spectral_dist_melt_knnfilt = filter(row -> row.Rank <= knn, spectral_dist_melt)
        knnfilt_full = DataFrames.leftjoin(spectral_dist_melt_knnfilt,
                                           DataFrames.rename(smallest_allnodes_leaves, :barcode => :Barcode_2)[!, [:Barcode_2, :Node, :NodeSize]],
                                           on=:Barcode_2)
        
        # Attach actual locations
        knnfilt_full = DataFrames.leftjoin(knnfilt_full,
                                           DataFrames.rename(barcodes_positions_coordonly, :barcode => :Barcode_1, :X => :Actual_X, :Y => :Actual_Y),
                                           on=:Barcode_1)
        
        # Sample predicted locations
        knnfilt_full_count = sort(DataFrames.combine(DataFrames.groupby(knnfilt_full, :Node), nrow => :Count), :Count, rev=true)
        knnfilt_full_nodes_dat = DataFrame(Barcode_1 = String[], Barcode_2 = String[], Spectral_Distance = Float64[],
                                           Rank = Int64[], Node = Int64[], NodeSize = Int64[],
                                           Actual_X = Float64[], Actual_Y = Float64[],
                                           LeafNode_X = Float64[], LeafNode_Y = Float64[])
        
        allnodes_leaves_grouped = DataFrames.groupby(allnodes_leaves, :Node)
        knnfilt_full_grouped = DataFrames.groupby(knnfilt_full, :Node)
        
        for i in 1:nrow(knnfilt_full_count)
            # Seed RNG if fixed seed provided (offset by node index for variety)
            if seed !== nothing
                Random.seed!(seed + i * 100)
            end
            barc_sample = DataFrames.leftjoin(
                DataFrame(barcode = sample(allnodes_leaves_grouped[(knnfilt_full_count.Node[i],)].barcode,
                                          knnfilt_full_count.Count[i], replace=true)),
                DataFrames.rename(barcodes_positions_coordonly, :X => :LeafNode_X, :Y => :LeafNode_Y),
                on=:barcode)
            allnodes_leaves_sample = hcat(knnfilt_full_grouped[(knnfilt_full_count.Node[i],)], barc_sample[!, [:LeafNode_X, :LeafNode_Y]])
            append!(knnfilt_full_nodes_dat, allnodes_leaves_sample)
        end
        
        # Calculate median predicted locations
        knnfilt_full_nodes_median = DataFrames.combine(DataFrames.groupby(knnfilt_full_nodes_dat, [:Barcode_1, :Actual_X, :Actual_Y]),
                                                       [:LeafNode_X, :LeafNode_Y] .=> median)
        DataFrames.rename!(knnfilt_full_nodes_median, :LeafNode_X_median => :Predicted_X, :LeafNode_Y_median => :Predicted_Y)
        predicted_spot_locations = copy(knnfilt_full_nodes_median)
        
        # Compute correlation
        actual_dist = vec(pairwise(Euclidean(), Array(DataFrames.select(knnfilt_full_nodes_median, [:Actual_X, :Actual_Y])), dims=1))
        node_dist = vec(pairwise(Euclidean(), Array(DataFrames.select(knnfilt_full_nodes_median, [:Predicted_X, :Predicted_Y])), dims=1))
        dist_all = DataFrame(Dist_Actual = actual_dist, DistRand_Node = node_dist)
        
        # Sample if too large
        max_size = Int(1e7)
        if nrow(dist_all) > max_size
            dist_sample = dist_all[shuffle(1:nrow(dist_all))[1:max_size], :]
        else
            dist_sample = dist_all
        end
        
        cor_dat = DataFrame(NodeCor = Statistics.cor(dist_sample.Dist_Actual, dist_sample.DistRand_Node),
                           Run = svd_list_loc.Run[1], SVD_end = svd_list_loc.SVD_end[1],
                           KNN_spatial_run = knn_spatial_run, Prune = prune, Spatial = spatial, KNN = knn)
        
        return allnodes_leaves_passingNodes, predicted_spot_locations, cor_dat
    else
        return missing, missing, missing
    end
end

"""
    model_optimize(svd_list_loc, barcodes_positions, spectral_dist_melt, tree, tree_nodes,
                   allnodes_leaves, allnodes_parents, allnodes_ripley; seed=nothing)

Perform hyperparameter optimization via random grid search to maximize spatial correlation.

Args:
* svd_list_loc: DataFrame with Run, SVD_end columns
* barcodes_positions: DataFrame with barcode, pxl_row_in_fullres, pxl_col_in_fullres
* spectral_dist_melt: DataFrame with KNN rankings
* tree: HybridNetwork tree object
* tree_nodes: DataFrame with node information
* allnodes_leaves: DataFrame with node/leaf relationships
* allnodes_parents: DataFrame with ancestor relationships
* allnodes_ripley: DataFrame with Ripley's K statistics
* seed: optional fixed seed for reproducibility (if nothing, uses random RNG state)

Returns:
* Tuple of (cor_dat_all, allnodes_leaves_passingNodes, predicted_spot_locations, tree)
"""
function model_optimize(svd_list_loc::DataFrame, barcodes_positions::DataFrame,
                       spectral_dist_melt::DataFrame, tree::HybridNetwork,
                       tree_nodes::DataFrame, allnodes_leaves::DataFrame,
                       allnodes_parents::DataFrame, allnodes_ripley::DataFrame; seed::Union{Nothing,Int}=nothing)
    # Prepare data
    node_support = DataFrame(Node = tree_nodes.node, Support = tree_nodes.name)
    barcodes_positions_coordonly = DataFrame(barcode = barcodes_positions.barcode,
                                             X = barcodes_positions.pxl_row_in_fullres,
                                             Y = barcodes_positions.pxl_col_in_fullres)
    allnodes_leaves = DataFrames.leftjoin(DataFrames.leftjoin(allnodes_leaves, node_support, on=:Node),
                                         allnodes_ripley, on=:Node)
    
    # Handle missing support values
    d1 = filter(row -> row.Support != "", filter(row -> !ismissing(row.Support), allnodes_leaves))
    d1.Support = parse.(Float64, d1.Support)
    d2 = filter(row -> ismissing(row.Support) | (row.Support == ""), allnodes_leaves)
    d2.Support .= 1.0
    allnodes_leaves = vcat(d1, d2)
    
    # Hyperparameter bounds
    prune_min = 0
    prune_max = 0.5
    knn_min = 5
    knn_max = 300
    spat_min = 0
    spat_max = 1
    
    # Convergence parameters
    alpha_lim = 0.05
    min_runs = 100
    
    # Seed RNG if fixed seed provided
    if seed !== nothing
        Random.seed!(seed)
    end
    
    # Initialize
    alpha = 1
    knn_spatial_run = 1
    cor_dat_all = DataFrame(NodeCor = Float64[], Run = Int64[], SVD_end = Int64[],
                           KNN_spatial_run = Int64[], Prune = Float64[], Spatial = Float64[], KNN = Int64[])
    
    # Grid search
    while alpha > alpha_lim
        prune = 10 ^ (rand() * (log10(prune_max + 1) - log10(prune_min + 1)) + log10(prune_min + 1)) - 1
        knn = convert(Int64, round(10 ^ (rand() * (log10(knn_max + 1) - log10(knn_min + 1)) + log10(knn_min + 1))))
        spatial = rand() * (log10(spat_max + 1) - log10(spat_min + 1)) + log10(spat_min + 1)
        
        allnodes_leaves_passingNodes_tmp, predicted_spot_locations_tmp, cor_dat = spot_location_prediction(
            allnodes_leaves, allnodes_parents, spectral_dist_melt, barcodes_positions_coordonly,
            prune, knn, spatial, knn_spatial_run, svd_list_loc)
        
        if (!isnothing(cor_dat)) & (!ismissing(cor_dat))
            append!(cor_dat_all, cor_dat)
            cor_dat_all = sort(cor_dat_all, :NodeCor, rev=true)
            if knn_spatial_run > min_runs
                alpha = cor_dat_all.NodeCor[1] - cor_dat_all.NodeCor[2]
            end
            
            # Progress update and GC every 10 iterations
            if knn_spatial_run % 10 == 0
                println("    Iteration $(knn_spatial_run): Best score = $(round(cor_dat_all.NodeCor[1], digits=4)), α = $(round(alpha, digits=4))")
                flush(stdout)
                GC.gc()
            end
        end
        knn_spatial_run += 1
    end
    
    # Re-create optimal model
    prune = cor_dat_all.Prune[1]
    knn = cor_dat_all.KNN[1]
    spatial = cor_dat_all.Spatial[1]
    knn_spatial_run = cor_dat_all.KNN_spatial_run[1]
    
    allnodes_leaves_passingNodes, predicted_spot_locations, cor_dat = spot_location_prediction(
        allnodes_leaves, allnodes_parents, spectral_dist_melt, barcodes_positions_coordonly,
        prune, knn, spatial, knn_spatial_run, svd_list_loc)
    
    # Relabel tree for pruning
    allnodes_leaves_unique = unique(allnodes_leaves_passingNodes, :Node)
    for i in 1:nrow(tree_nodes)
        if !(tree_nodes.leaf[i])
            node = tree.node[i]
            node.name = string(filter(row -> row.Node == node.number, allnodes_leaves_unique).ParentPass[1])
        end
    end
    
    return cor_dat_all, allnodes_leaves_passingNodes, predicted_spot_locations, tree
end

#=============================================================================
Step 4+: Additional Functions (to be added)
=============================================================================#

# Future steps will add their required functions here

println("[tumorspace_core.jl] Loaded successfully at $(now())")
