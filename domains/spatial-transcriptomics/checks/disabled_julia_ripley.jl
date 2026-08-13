# Extracted verbatim from workflows/tumorspace_core/julia/tumorspace_core.jl,
# lines 371-462, where these two functions sit commented out under the header
# 'BEGIN JULIA RIPLEY'"'"'S K — DISABLED (moved to compute_ripley_k.R, Step 3)'.
#
# The only edit is removing the leading '# ' from each line. Nothing else is
# changed, because the point of this file is to run what that code would run if
# it were re-enabled, and compare it against the R implementation that replaced
# it. Production code is untouched: this is a copy.

function ripleyK_compute(dat_in::DataFrame, x_vec::Vector, y_vec::Vector)
    npts = nrow(dat_in)
    x_length = maximum(x_vec) - minimum(x_vec)
    y_length = maximum(y_vec) - minimum(y_vec)

    # Handle degenerate geometries (collinear points or single point)
    if x_length <= 0 || y_length <= 0 || npts <= 1
        return 0.0
    end

    areaW = x_length * y_length
    lambda = npts / areaW

    # Compute boundary points
    point_num = 10
    X_sequence = Vector(range(minimum(x_vec), maximum(x_vec), step=x_length/point_num))
    Y_sequence = Vector(range(minimum(y_vec), maximum(y_vec), step=y_length/point_num))
    bottom_bound = Array(DataFrame(X=X_sequence, Y=fill(minimum(y_vec), length(X_sequence))))
    top_bound = Array(DataFrame(X=X_sequence, Y=fill(maximum(y_vec), length(X_sequence))))
    left_bound = Array(DataFrame(X=fill(minimum(x_vec), length(Y_sequence)), Y=Y_sequence))
    right_bound = Array(DataFrame(X=fill(maximum(x_vec), length(Y_sequence)), Y=Y_sequence))
    boundary_points = vcat(bottom_bound, top_bound, left_bound, right_bound)

    # Define r sequence
    rmax = min(min(x_length/4, y_length/4), sqrt(1000 / (pi * lambda)))

    # Handle edge case where rmax is too small
    if rmax <= 0 || isnan(rmax)
        return 0.0  # Return 0 for degenerate cases
    end

    rvec = Vector(range(0, rmax, step=rmax/512))
    k_dat = DataFrame(r = rvec, theo = pi * rvec.^2)

    # Compute distance to boundary for border correction
    border_mtx = pairwise(Euclidean(), vcat(Array(DataFrames.select(dat_in, [:X, :Y])), boundary_points), dims=1)[1:npts, (npts+1):(npts+size(boundary_points)[1])]

    # Compute spatial distance between points
    dist_mtx = pairwise(Euclidean(), Array(DataFrames.select(dat_in, [:X, :Y])), dims=1)

    # Minimum distance to border
    dat_in.BorderMin = vec(minimum(border_mtx, dims=2))

    function k_compute(r)
        n_elig = filter(row -> row.BorderMin >= r, dat_in)
        mask = ifelse.(dat_in.BorderMin .>= r, 1, 0)
        mask_mtx = reshape(repeat(mask, inner=size(mask)[1]), size(mask)[1], size(mask)[1])
        dist_mask = dist_mtx .* mask_mtx
        size(filter(n -> n <= r, filter(!iszero, dist_mask)))[1] / (lambda * nrow(n_elig))
    end

    # Calculate Kest for all r
    k_dat.border = k_compute.(k_dat.r)
    k_abs = abs.(k_dat.border .- k_dat.theo)
    k = sum(filter(!isnan, k_abs))
    return k
end

"""
    tree_ripley(allnodes_leaves::DataFrame)

Compute Ripley's K spatial clustering statistic for all internal nodes in the tree.

Args:
* allnodes_leaves: DataFrame with Node, Leaf, barcode, X, Y columns

Returns:
* DataFrame with columns: Node, RipleySum, NodeSize
"""
function tree_ripley(allnodes_leaves::DataFrame)
    # Columns: Node, Leaf, barcode, in_tissue, array_row, array_col,
    #          pxl_row_in_fullres, pxl_col_in_fullres, pxl_row_in_mm, pxl_col_in_mm
    if !("X" in names(allnodes_leaves))
        DataFrames.rename!(allnodes_leaves, 9 => :X)  # pxl_row_in_mm
    end
    if !("Y" in names(allnodes_leaves))
        DataFrames.rename!(allnodes_leaves, 10 => :Y)  # pxl_col_in_mm
    end

    node_count = sort(DataFrames.combine(DataFrames.groupby(allnodes_leaves, :Node, sort=true), nrow), :nrow, rev=true)
    noderip_dat = DataFrame(Node = Int64[], RipleySum = Float64[], NodeSize = Int64[])

    for n in 1:nrow(node_count)
        dat_node = sort(filter(row -> row.Node == node_count.Node[n], allnodes_leaves), :Leaf)
        push!(noderip_dat, (
            Node = node_count.Node[n],
            RipleySum = ripleyK_compute(dat_node, allnodes_leaves.X, allnodes_leaves.Y),
            NodeSize = node_count.nrow[n]
        ))
    end
    noderip_dat
end
