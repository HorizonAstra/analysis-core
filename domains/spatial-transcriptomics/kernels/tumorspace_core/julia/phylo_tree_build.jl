#!/usr/bin/env julia
"""
TumorSPACE Step 1: Tree Building
Computes spatial phylogenetic trees from gene expression data using spectral inference.
Creates both the original tree (boot=0) and bootstrapped trees (boot=1 to boot_num).
"""

# Activate project environment to use our installed dependencies
using Pkg
Pkg.activate(joinpath(@__DIR__))

# Load core TumorSPACE functions from portable module
include(joinpath(@__DIR__, "tumorspace_core.jl"))
using Dates
# Note: DataFrame and CSV are exported by tumorspace_core.jl

# Simple argument parser without external dependencies
function parse_commandline()
    args = Dict{String,Any}()
    i = 1
    while i <= length(ARGS)
        if startswith(ARGS[i], "--")
            key = ARGS[i][3:end]  # Remove "--"
            if i < length(ARGS) && !startswith(ARGS[i+1], "--")
                val = ARGS[i+1]
                # Try to convert to Int if it looks like a number
                if occursin(r"^\d+$", val)
                    args[key] = parse(Int, val)
                elseif val == "true"
                    args[key] = true
                elseif val == "false"
                    args[key] = false
                else
                    args[key] = val
                end
                i += 2
            else
                # Flag without value
                args[key] = true
                i += 1
            end
        else
            i += 1
        end
    end
    return args
end

function pad_to_square(A::Matrix)
    m, n = size(A)
    max_dim = max(m, n)
    B = zeros(eltype(A), max_dim, max_dim)
    B[1:m, 1:n] .= A
    return B
end

function to_hermitian(A::Matrix)
    if size(A, 1) != size(A, 2)
        error("Matrix must be square.")
    end
    return (A + A') / 2
end

function main()
    args = parse_commandline()
    
    println("[$(now())] DEBUG: All args: $args")
    println("[$(now())] Starting tree_build for $(args["dataset"]), svd_run=$(args["svd-run"]), boot=$(args["boot"])")
    flush(stdout)
    
    try
        # Read input data
        println("[$(now())] Reading input files from $(args["input-dir"])")
        flush(stdout)
        matrix = Matrix(CSV.read(joinpath(args["input-dir"], "M.txt"), DataFrame, header=false))
        barcodes_df = CSV.read(joinpath(args["input-dir"], "barcodes.txt"), DataFrame)
        barcodes = barcodes_df.barcode

        # Filter to QC-passing barcodes (barcodes_positions.txt is post-QC subset)
        positions_file = joinpath(args["input-dir"], "barcodes_positions.txt")
        if isfile(positions_file)
            positions_df = CSV.read(positions_file, DataFrame)
            qc_barcodes = Set(positions_df.barcode)
            keep_idx = findall(b -> b in qc_barcodes, barcodes)
            barcodes = barcodes[keep_idx]
            matrix = matrix[keep_idx, :]
            println("[$(now())] QC filter: kept $(length(barcodes)) of $(length(barcodes_df.barcode)) barcodes")
        end

        println("[$(now())] Matrix dimensions: $(size(matrix)), Barcodes: $(length(barcodes))")
        println("[$(now())] SVD dimension: $(args["svd-value"])")
        flush(stdout)
        
        # Compute TumorSPACE model
        println("[$(now())] Computing spectral distance matrix and phylogenetic tree...")
        flush(stdout)
        
        # Generate seed for reproducible test mode (base seed offset by SVD run AND bootstrap number)
        # The offset may be supplied as --test-seed <n>. A bare --test-seed or --test parses
        # to true, and Bool is a subtype of Integer here, so it is excluded explicitly rather
        # than by an isa Integer test that would silently make the offset 1.
        seed_val = nothing
        if haskey(args, "test-seed") || haskey(args, "test")
            requested = get(args, "test-seed", true)
            seed_offset = (requested isa Integer && !(requested isa Bool)) ? requested : 1000
            seed_val = seed_offset + args["svd-run"] * 100 + args["boot"] * 1000
        end
        
        obs_dij, nwtreestring = model_calc(matrix, barcodes, args["svd-value"], args["boot"]; seed=seed_val)
        
        # Create output directory if it doesn't exist
        mkpath(args["output-dir"])
        
        # Write distance matrix (only for boot=0)
        if args["boot"] == 0
            dist_file = joinpath(args["output-dir"], "SPI_Dist_mtx.txt")
            println("[$(now())] Writing distance matrix to $dist_file")
            flush(stdout)
            # Convert matrix to DataFrame for CSV writing
            dist_df = DataFrame(obs_dij, :auto)
            CSV.write(dist_file, dist_df, writeheader=false, delim='\t')
        end
        
        # Write tree file
        tree_file = joinpath(args["output-dir"], "Tree_$(args["boot"]).nw")
        println("[$(now())] Writing tree to $tree_file")
        flush(stdout)
        open(tree_file, "w") do io
            println(io, nwtreestring)
        end
        
        # Write completion marker
        done_file = joinpath(args["output-dir"], "Tree_$(args["boot"]).done")
        open(done_file, "w") do io
            println(io, "[$(now())] tree_build completed successfully")
            println(io, "Dataset: $(args["dataset"])")
            println(io, "SVD run: $(args["svd-run"])")
            println(io, "Bootstrap: $(args["boot"])")
            println(io, "SVD value: $(args["svd-value"])")
        end
        
        println("[$(now())] ✓ tree_build completed successfully")
        println("[$(now())] Output: $tree_file")
        flush(stdout)
        
    catch e
        # Write error file
        error_file = joinpath(args["output-dir"], "Tree_$(args["boot"]).error")
        mkpath(args["output-dir"])
        open(error_file, "w") do io
            println(io, "[$(now())] ERROR in tree_build")
            println(io, "Dataset: $(args["dataset"])")
            println(io, "SVD run: $(args["svd-run"])")
            println(io, "Bootstrap: $(args["boot"])")
            println(io, "\nError message:")
            println(io, sprint(showerror, e))
            println(io, "\nStack trace:")
            println(io, sprint(Base.show_backtrace, catch_backtrace()))
        end
        
        println(stderr, "[$(now())] ✗ ERROR: tree_build failed")
        println(stderr, "Error details written to: $error_file")
        rethrow(e)
    end
end

# Run main function
main()
