#!/usr/bin/env nextflow



params.CONTAINER_FOLDER = "/scratch/ckwoodson/tumorspace_project/new_test/nextflow/premade_containers" // this should be the path to the folder containing the premade singularity containers for the tree building step, this is used in the container directive for the tree building process
params.OUT = "/scratch/ckwoodson/tumorspace_project/new_test/results"

 // this should be a comma separated list of values for the SVD dimensionality reduction step, 
 // each value will be run with the number of bootstraps specified in params.BOOT
 // and is also used to check if a given SVD value has already been completed 
 // (if the .done file exists for all bootstraps for that SVD value, that SVD value is skipped)
params.SVD_VALUES = "5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100, 105, 110, 115, 120, 125, 130, 135, 140, 145, 150"
// params.BOOT = 0 // AKA BOOTSTRAPS in orginal workflow this should be the number of bootstraps we want to run, this is used to determine the array job size for the tree building step, and is also used to check if a given bootstrap has already been completed (if the .done file exists, that bootstrap is skipped)
params.INPUT_DIR = "/gpfs/data/dfi-cores/CW_temp/new_test/nextflow/input_data/harmonized" // where the input data of the params.DATASET is located
 params.DATASET = "" // name of the dataset being analyzed
params.WORKFLOW_SCRIPTS_DIR = "/gpfs/data/dfi-cores/CW_temp/new_test/nextflow/workflow_scripts"
params.FIXED_SEED = 1 // set to true to use a fixed seed for testing, false to use random seeds
params.TEST_MODE = false
params.RUN_DATE = ""
params.JULIA_DEPOT=""
params.BOOTSTRAPS=10 // default 10 bootstraps
params.KEEP_ALL_SVD = true // keep all svds
params.NUM_SHUFFLE=20 // Number of permutations for FDR (default: 20)
params.NPCs=15 // default 15
// in the future input 


// # Pipeline Steps with Dependencies:
// #   Step 1:  phylo_tree_build.jl     (job array 1-N)     Independent
// #   Step 1b: phylo_bootstrap_support (job array 1-N)     after Step 1 (REQUIRED)
// #   Step 2:  phylo_node_extract.jl   (job array 1-N)     after Step 1b
// #   Step 3:  spatial_optimize.jl     (job array 1-N)     after Step 2
// #   Step 4:  phylo_tree_prune.jl     (job array 1-N)     after Step 3
// #   Step 5:  SVD selection           (single job)        after Step 4
// #   Step 6:  sg_identify_pairs.R     (single job)        after Step 5
// #   Step 7:  sg_diff_abundance.jl    (single job)        after Step 6
// #   Step 8:  sg_slab_score.jl        (single job)        after Step 7
// #   Step 9:  pipeline_completion     (single job)        after Step 8
// #   Step 10: bayesspace              (single job)        after Step 9
// #            Auto-enabled when BAYESSPACE_*_AVAILABLE=true in config/capabilities.sh
// #            Override: --bayesspace (force on) or --no-bayesspace (skip)
// #   Step 11: pipeline_report          (single job)        after Step 10 (or Step 9 if BayesSpace skipped)
// #            Consolidates outputs from all features into Pipeline_Report.pdf + pipeline_summary.md
// #

def selectQueue(memory, cpus) {
    def memPerCpu = memory.toGiga() / cpus
    if (memPerCpu >= 32 || memory.toGiga() > 512 ) return "tier3q"
    else if (memPerCpu >= 8 || memory.toGiga() > 128 ) return "tier2q" // change this to be 8gb when the cluster is stable
    else return "tier1q"
}


workflow {
    // if the run date isnt provided, use the current date and time with the format YYYYMMDD_HHMMSS as a default value
    if (!params.RUN_DATE) {
        params.RUN_DATE = params.RUN_DATE ?: new Date().format('yyyyMMdd_HHmmss')
    }


    if (params.TEST_MODE == true) {
        // params.SVD_VALUES = "5,25,55,150"
        FIXED_SEED = 1
        SVD_LIST = "5,25,55"
            .split(',')
            .collect { it.trim().toInteger() }
    } else {
        FIXED_SEED = 1
        SVD_LIST = params.SVD_VALUES
            .split(',')
            .collect { it.trim().toInteger() }
    }

    params.NUM_SVD = params.SVD_VALUES.split(',')*.toInteger().size()



    // make the chanel with the tuple of your input params: DATASET, INPUT_DIR, SVD_VALUES, OUT_DIR, CONTAINER_FOLDER, WORKFLOW_SCRIPTS_DIR, RUN_DATE 
    // and also include the index of the SVD value in the tuple, this is used to determine the output directory for each SVD value and to check if a given 
    // SVD value has already been completed (if the .done file exists for all bootstraps for that SVD value, that SVD value is skipped)

    Channel
        .fromPath("${params.INPUT_DIR}/*", type: 'dir')   // returns only directories
        .map { dir -> tuple(dir.getName(), dir) }
        .set { harmonized_ch }

    workflow_input = harmonized_ch.flatMap { dataset_tuple ->
        def DATASET = dataset_tuple[0]
        def INPUT_DIR = dataset_tuple[1]

    SVD_LIST.withIndex().collectMany { svd_value, svd_index ->
            // Use svd_value as the value, and use the loop index as svd_index
            (0..<params.BOOTSTRAPS.toInteger()).collect { boot ->
                tuple(
                    "$DATASET",
                    INPUT_DIR,
                    svd_value,          // svd_value is the actual value
                    svd_index,
                    boot,               // or use something else as index? your call
                    params.OUT,
                    params.WORKFLOW_SCRIPTS_DIR,
                    params.RUN_DATE,
                    params.FIXED_SEED
                )
            }
        }
    }




    println "Configuration:"
    println "  Dataset folder: ${params.INPUT_DIR}"
    println "  SVD values: $SVD_LIST"
    println "  Number of SVDs: $params.NUM_SVD"
    println "  Bootstrap Tests: $params.BOOTSTRAPS"
    println "Pipeline started at: $params.RUN_DATE"


    julia_ready = JULIA_SETUP(params.WORKFLOW_SCRIPTS_DIR, params.JULIA_DEPOT)

    // workflow_input.view { "Sending to Phylo_tree_build: $it" }

 // Ensure no grouping
    // workflow_input
    //     .view { "One task per tuple: $it" }
    //     .set { ready_for_phylo }

    phylo = Phylo_tree_build(workflow_input, julia_ready)
    // phylo.view { "RAW phylo: $it" }
    //   phylo output  tuple val(DATASET), val(SVD_INDEX) path("TREE_${BOOTSTRAP}.nw")
    // params.bootstrap has the number of expected bootstrap trees to collect for each svd

    // // Convert channel to list, then count
    // phylo
    //     .map { dataset, svd_index, tree -> [dataset, svd_index] }
    //     .toList()
    //     .view { list ->
    //         def counts = list.countBy { it }  // now it's a Groovy list
    //         "Actual trees per key: $counts"
    //     }


    // phylo
    //     .map { dataset, svd_index, tree -> [dataset, svd_index] }
    //     .reduce([:]) { map, key ->
    //         map[key] = (map[key] ?: 0) + 1
    //         map
    //     }
    //     .view { "Final counts per key: $it" }

    phylo_grouped = phylo
        .map { dataset, svd_index, tree ->
            tuple("${dataset}::${svd_index}", tree)
        }
        .groupTuple(size: params.BOOTSTRAPS.toInteger(), remainder: false)
        .map { key, trees -> tuple(key, trees) }
        // .view { "PHYLO group (size=${it[1].size()}): key=${it[0]}" }

    

    workflow_keyed_tuple = workflow_input
        .map { DATASET, INPUT_DIR, SVD_VALUE, SVD_INDEX, boot, OUT, WORKFLOW_SCRIPTS_DIR, RUN_DATE, FIXED_SEED_arg ->
            tuple(
                "${DATASET}::${SVD_INDEX}",   // <-- same string key
                DATASET, 
                INPUT_DIR, 
                SVD_VALUE, 
                SVD_INDEX,
                "$OUT/${DATASET}_results", 
                WORKFLOW_SCRIPTS_DIR,
                RUN_DATE, 
                FIXED_SEED_arg,
                file("$INPUT_DIR/barcodes_positions.txt"),
                file("$INPUT_DIR/barcodes.txt"),
                file("$INPUT_DIR/features.txt"),
                file("$INPUT_DIR/genes.txt"), // If this does not exist genes file will be created later as a copy of the features file 
                file("$INPUT_DIR/M.txt")
            )
        }.unique { it[0] }

    // DATASET,        // index 0
    // INPUT_DIR,      // index 1
    // SVD_VALUE,      // index 2
    // SVD_INDEX,      // index 3
    // OUT,            // index 4
    // WORKFLOW_SCRIPTS_DIR, // 5
    // BARCODE_POSITIONS,    // 6
    // BARCODES,             // 7
    // FEATURES,             // 8
    // GENES,                // 9
    // M,                    // 10
    // RUN_DATE,             // 11
    // FIXED_SEED,           // 12

    // workflow_keyed_tuple
    //     .view { "WF key: ${it[0]}  (types: ${it[0][0].class}, ${it[0][1].class})" }

    // phylo_grouped
    //     .view { "PHYLO key: ${it[0]}  (types: ${it[0][0].class}, ${it[0][1].class})" }

    combined = workflow_keyed_tuple.join(phylo_grouped, by: 0)
    // workflow_keyed emits: [key, DATASET, INPUT_DIR, ...]
    // phylo_grouped emits: [key, trees]  (after simplifying above)
    // combined = workflow_keyed.join(phylo_grouped, by: 0)   // join on first element

    finaldata = combined
        .map { key, dataset, input_dir, svd_value, svd_index, out, scripts_dir, run_date, fixed_seed, barcodes_pos, barcodes, features, genes, matrix, trees ->
            tuple(
                dataset,            // DATASET
                input_dir,          // INPUT_DIR
                svd_value,          // SVD_VALUE
                svd_index,          // SVD_INDEX
                out,                // OUT
                scripts_dir,        // WORKFLOW_SCRIPTS_DIR
                barcodes_pos,       // BARCODE_POSITIONS
                barcodes,           // BARCODES
                features,           // FEATURES
                genes,              // GENES
                matrix,             // M
                run_date,           // RUN_DATE
                fixed_seed,         // FIXED_SEED
                trees               // TREE (list of files)
            )
        }
    support = Phylo_bootstrap_support(finaldata, params.BOOTSTRAPS)
    
    // support.view()

    node_extraction = Phylo_node_extract(support, julia_ready)

    // node_extraction.view() 

    spatial_optimization = Spatial_optimization(node_extraction)

    phylo_prunning = Phylo_prune(spatial_optimization)

    // DATASET,        // index 0
    // INPUT_DIR,      // index 1
    // SVD_INDEX,      // index 2
    // OUT,            // index 3
    // WORKFLOW_SCRIPTS_DIR, // 4
    // BARCODE_POSITIONS,    // 5
    // BARCODES,             // 6
    // FEATURES,             // 7
    // GENES,                // 8
    // M,                    // 9
    // SVD_DIR,              // 10
    // RUN_DATE,             // 11
    // FIXED_SEED,           // 12
    // JULIA_DEPOT_PATH      // 13


    max_per_dataset_stream = phylo_prunning
        .map { tuple ->
            def dataset = tuple[0]
            def key = groupKey(dataset, params.NUM_SVD)
            [key, tuple]
        }
        .groupTuple()
        .map { key, listOfTuples ->
            def maxTuple = listOfTuples.max { it[2] }  // SVD_INDEX at index 2
            return maxTuple   // ← explicitly return the tuple with max SVD
        }


    // max_per_dataset_stream.view { tuple ->
    // println "Dataset: ${tuple[0]}, max SVD: ${tuple[2]}, input dir: ${tuple[1]}"
    // }

    svd_selection = svd_selection(max_per_dataset_stream, params.KEEP_ALL_SVD)

    sg_identify_pairs = SG_identify_pairs(svd_selection)

    sg_diff_abundance = SG_diff_abundance(sg_identify_pairs, params.NUM_SHUFFLE)

    SLAB_score_ch = SLAB_score(sg_diff_abundance)

    SLAB_completion_ch = SLAB_completion(SLAB_score_ch)

    bayesspace = Bayesspace(max_per_dataset_stream)


}

process Harmonize_input {
    tag "Harmonize input data"
    scratch true
    cpus { 2 }
    memory { 2.GB * task.attempt }
    time { task.attempt * 5.min }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    container "julia_1.9_with_gotree.sif"


    input:
    val workflow_scripts_dir

    output:
    path("${params.INPUT_DIR}/${params.DATASET}_harmoinized_input", followLinks: false)
    script:
    """

    mkdir -p "${params.INPUT_DIR}/harmoinized_input"

    python3 ${workflow_scripts_dir}/acquisition/python/geo_harmonize.py \
        --input-dir "${params.INPUT_DIR}" \
        --output-dir "${params.INPUT_DIR}/${params.DATASET}_harmoinized_input" 

    """
}

process JULIA_SETUP {
    tag "Initialize Julia environment"
    scratch false
    cpus { 4 }
    memory { 2.GB * task.attempt }
    time { task.attempt * 5.min }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    container "julia_1.9_with_gotree.sif"


    input:
    val workflow_scripts_dir
    val JULIA_DEPOT

    output:
    env 'JULIA_DEPOT'

    script:
    """
    JULIA_DEPOT="$JULIA_DEPOT"
    rm -r $JULIA_DEPOT/* || true
    mkdir -p $JULIA_DEPOT
    export JULIA_DEPOT_PATH="${JULIA_DEPOT}:/opt/julia_depot"

    julia -e 'import Pkg; Pkg.Registry.add("General")'


    julia --project=${workflow_scripts_dir}/tumorspace_core/julia -e '
        using Pkg
        Pkg.activate("${workflow_scripts_dir}/tumorspace_core/julia")
        Pkg.resolve()
        Pkg.instantiate()
        Pkg.precompile()
    '

    """
}

process Phylo_tree_build { 
    tag "$DATASET TREE BOOTSTRAP: $BOOTSTRAP SVD: $SVD_VALUE"
    cpus { Math.min(3 + (1 * task.attempt), 32) }
    memory { 7.GB }
    time { task.attempt < 2 ? 20.min : task.attempt < 4 ? (40.min * task.attempt) : (80.min * task.attempt)}
    errorStrategy { task.attempt <= 10 ? 'retry' : 'terminate' }
    queue { selectQueue(task.memory, task.cpus) }
    container "julia_1.9_with_gotree.sif"

    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_VALUE), 
            val(SVD_INDEX),
            val(BOOTSTRAP),  
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            val(RUN_DATE), 
            val(FIXED_SEED)
    val(JULIA_DEPOT_PATH)
    

    output:
    tuple val(DATASET), val(SVD_INDEX), path("Tree_${BOOTSTRAP}.nw", followLinks: false)
    

    script: 

    """
        echo "=========================================="
        echo "TumorSPACE Step 1: Tree Building"
        echo "=========================================="
        echo "Start: $RUN_DATE"
        echo "=========================================="

        dataset_dir="$OUT/${DATASET}_results"
        mkdir -p \$dataset_dir

        # Parse task ID
        NUM_BOOTSTRAPS=${params.NUM_SVD}

        JULIA_SCRIPT="$WORKFLOW_SCRIPTS_DIR/tumorspace_core/julia/phylo_tree_build.jl"

        echo "Configuration:"
        echo "  Dataset: $DATASET"
        echo "  SVD run: ${SVD_INDEX} (value=$SVD_VALUE)"
        echo "  Bootstrap: $SVD_INDEX"
        echo "  Julia depot path(s): $JULIA_DEPOT_PATH"
        BOOT=$BOOTSTRAP
        SVD_RUN=${SVD_INDEX}
        OUTPUT_DIR="\$dataset_dir/svd_run_\$SVD_RUN"
        
        mkdir -p "\$OUTPUT_DIR"

        # Check if already completed
        # if [ -f "\$OUTPUT_DIR/Tree_\${BOOT}.done" ]; then
        #     echo "Already complete - skipping"
        #     exit 0
        # fi

        # Run tree building
        echo "Running tree_build.jl..."
        echo ""

        export JULIA_DEPOT_PATH="/opt/julia_depot:${JULIA_DEPOT_PATH}"
        
        SEED_FLAG=""
        if [ "$FIXED_SEED" = "true" ]; then SEED_FLAG="--test-seed"; fi


        
        julia --heap-size-hint=${task.memory.toGiga()}G \
            $WORKFLOW_SCRIPTS_DIR/tumorspace_core/julia/phylo_tree_build.jl \
            --dataset "$DATASET" \
            --input-dir "$INPUT_DIR" \
            --output-dir "\$OUTPUT_DIR" \
            --svd-run "\$SVD_RUN" \
            --svd-value "$SVD_VALUE" \
            --boot "\$BOOT" \
            \$SEED_FLAG

        ln -sf "\$(realpath \$OUTPUT_DIR/Tree_${BOOTSTRAP}.nw)" "Tree_${BOOTSTRAP}.nw"

    """
} 

process Phylo_bootstrap_support { 
    tag "$DATASET SVD: $SVD_VALUE Bootstrap Support Calculation"
    cpus { 1 }
    memory { 700.MB * task.attempt }
    time { task.attempt < 2 ? 20.min : task.attempt < 4 ? (90.min * task.attempt) : (2.hour * task.attempt)}
    errorStrategy { task.attempt <= 4 ? 'retry' : 'terminate' }
    queue { selectQueue(task.memory, task.cpus) }
    container "julia_1.9_with_gotree.sif"


    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_VALUE), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            val(GENES), 
            path(M), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            path(TREE) // from phylo_grouped collection of trees for each svd. last value is a list of files
    val BOOTSTRAPS

    // DATASET,        // index 0
    // INPUT_DIR,      // index 1
    // SVD_VALUE,      // index 2
    // SVD_INDEX,      // index 3
    // BOOTSTRAP,      // index 4
    // OUT,            // index 5
    // WORKFLOW_SCRIPTS_DIR, // 6
    // BARCODE_POSITIONS,    // 7
    // BARCODES,             // 8
    // FEATURES,             // 9
    // GENES,                // 10
    // M,                    // 11
    // RUN_DATE,             // 12
    // FIXED_SEED,           // 13


    output:
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_VALUE), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            path("genes.txt", followLinks: false), 
            path(M), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            path("Tree_support.nw", followLinks: false)

    script:
    """
        echo "=========================================="
        echo "Bootstrap Support Calculation (Container)"
        echo "=========================================="
        echo "SVD INDEX: $SVD_INDEX  Value: ${SVD_VALUE}"
        echo "Start: $RUN_DATE"
        echo "=========================================="
        SVD_DIR="$OUT/svd_run_${SVD_INDEX}"
        SVD_RUN=${SVD_INDEX}
        ln -sf "\$(realpath "$OUT/svd_run_${SVD_INDEX}")" SVD_DIR


        echo "SVD run: ${SVD_INDEX}"
        echo "Directory: \$SVD_DIR"
        echo ""


        # Validate all bootstrap trees exist (Tree_0.nw through Tree_N.nw)
        BOOTSTRAPS=$BOOTSTRAPS
        MISSING_TREES=()
        for ((i=0; i<BOOTSTRAPS; i++)); do
            if [ ! -f "Tree_\${i}.nw" ]; then
                MISSING_TREES+=("Tree_\${i}.nw")
            fi
        done

        if [ ! -e "$GENES" ]; then
            ln -sf "\$(realpath $FEATURES)" "genes.txt"
        else
            ln -sf "\$(realpath $INPUT_DIR/genes.txt)" "genes.txt"
        fi
    

        if [ \${#MISSING_TREES[@]} -gt 0 ]; then
            echo "ERROR: Missing \${#MISSING_TREES[@]} bootstrap tree(s):"
            for tree in "\${MISSING_TREES[@]}"; do
                echo "  - \$tree"
            done
            echo ""
            echo "Expected: Tree_0.nw through Tree_${BOOTSTRAPS}.nw ($BOOTSTRAPS bootstrap replicates)"
            echo "Found: $((BOOTSTRAPS - \${#MISSING_TREES[@]})) trees"
            echo ""
            echo "Ensure Step 1 completed successfully for all bootstrap jobs."
            exit 1
        fi

        echo "✓ Validated all $BOOTSTRAPS bootstrap trees present"

        # Concatenate bootstrap trees
        BOOT_FILE="SVD_DIR/Tree_Bootstrap.nw"
        echo "[1/2] Concatenating bootstrap trees..."
        rm -f "\$BOOT_FILE"
        for ((i=0; i<BOOTSTRAPS; i++)); do
            cat "Tree_\${i}.nw" >> "\$BOOT_FILE"
        done

        echo "  ✓ Created Tree_Bootstrap.nw (\$(wc -l < "\$BOOT_FILE") trees)"

        # Calculate TBE support values using gotree in container
        SUPPORT_FILE="SVD_DIR/Tree_support.nw"
        echo "[2/2] Computing TBE support values..."
        echo "  Using: gotree (inside container)"
        echo "  Reference tree: Tree_0.nw"
        echo "  Bootstrap trees: Tree_Bootstrap.nw"
        echo "  Output: Tree_support.nw"
        echo ""

        LD_LIBRARY_PATH=/usr/local/julia/lib/julia:\$LD_LIBRARY_PATH 
                gotree \
                -i Tree_0.nw \
                -b \$BOOT_FILE \
                -o \$SUPPORT_FILE \
                -@ ${task.cpus} \
                -a tbe


       ln -sf "\$(realpath "SVD_DIR/Tree_support.nw")" "Tree_support.nw"


        if [ \$? -eq 0 ]; then
            echo ""
            echo "=========================================="
            echo "✓ Bootstrap support calculation complete"
            echo "=========================================="
            echo "Output: \$SUPPORT_FILE"
            echo "Size: \$(du -h "\$SUPPORT_FILE" | cut -f1)"
            echo "End: \$(date)"
            echo "=========================================="
        else
            echo ""
            echo "=========================================="
            echo "✗ Bootstrap support calculation FAILED"
            echo "=========================================="
            echo "End: \$(date)"
            echo "=========================================="
            exit 1
        fi
    """
}

process Phylo_node_extract { 
    tag "$DATASET Tree Node Extraction - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    cpus { 1 }
    memory { 2.GB + 6.GB * task.attempt }
    time { task.attempt < 2 ? 20.min : task.attempt < 4 ? (90.min * task.attempt) : (2.hour * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    container "julia_1.9_with_gotree.sif"

    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_VALUE), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            path(GENES), 
            path(M), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            path(TREE_SUPPORT)
    val JULIA_DEPOT_PATH




    output:
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_VALUE), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            path(GENES), 
            path(M), 
            path("SVD_DIR", followLinks: false),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH)


    script:

    """
    # Get SVD number from array task ID
    SVD_NUM=$SVD_INDEX
    export JULIA_DEPOT_PATH="/opt/julia_depot:${JULIA_DEPOT_PATH}"

    # Directories for this SVD
    # Note: node_extract.jl reads AND writes to the same directory
    
    ln -sf "\$(realpath "$OUT/svd_run_${SVD_INDEX}")" SVD_DIR
    
    
    JULIA_SCRIPT=$WORKFLOW_SCRIPTS_DIR/tumorspace_core/julia/phylo_node_extract.jl
    
    # Required input files
    # Use Tree_support.nw (with bootstrap support values) instead of Tree_0.nw
    TREE_FILE=$TREE_SUPPORT
    #$BARCODE_POSITIONS
    DISTANCE_FILE=""

    # Print job information
    echo "=============================================================================="
    echo "Step 2: Node Extraction - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    echo "=============================================================================="
    echo "Node:         \$(hostname)"
    echo "Started:      \$(date)"
    echo "SVD Dir:      $OUT/svd_run_${SVD_INDEX}"
    echo "Tree File:    \$TREE_FILE"
    echo "Barcodes:     $BARCODE_POSITIONS"
    echo "CPUs:         ${task.cpus}"
    echo "=============================================================================="
    echo

    # Record start time
    START_TIME=\$(date +%s)

    julia --heap-size-hint=${task.memory.toGiga()}G \
     \$JULIA_SCRIPT SVD_DIR \$TREE_FILE $BARCODE_POSITIONS
    
    # Record completion
    END_TIME=\$(date +%s)
    ELAPSED=\$((END_TIME - START_TIME))



    echo
    echo "=============================================================================="
    echo "Step 2 Complete - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    echo "=============================================================================="
    echo "Elapsed time: \${ELAPSED}s"
    echo "Outputs written to: \$(realpath SVD_DIR)"
    echo "  - tree_nodes.tsv"
    echo "  - tree_edges.tsv"
    echo "  - allnodes_leaves.tsv"
    echo "  - allnodes_parents.tsv"
    echo "  - spectral_dist_melt.tsv"
    echo "=============================================================================="
    """
}

process Spatial_optimization { 
    tag "$DATASET Spatial Optimization - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    cache 'lenient'
    cpus { 2 }
    memory { 
        def estimated_spots = BARCODES.size() / 20
        def mem = (estimated_spots * 0.0035).GB + (4.GB * task.attempt) // gives you estimated mem per spot plus overhead
        [mem, 1280.GB].min()
    }
    time { task.attempt < 2 ? 120.min * task.attempt : task.attempt < 4 ? (90.min * task.attempt) : (2.hour * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'terminate' }
    queue { selectQueue(task.memory, task.cpus) }
    container "julia_1.9_with_gotree.sif"

    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_VALUE), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            path(GENES), 
            path(M), 
            path(SVD_DIR), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 

    output:
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_VALUE), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            path(GENES), 
            path(M), 
            path(SVD_DIR), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 

    script:
    """
    echo "=============================================================================="
    echo "Step 3: Spatial Optimization - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    echo "=============================================================================="
    echo "SVD Dir:          $SVD_DIR"
    echo "Input Data Dir:   $INPUT_DIR"
    echo "Barcodes:         $BARCODE_POSITIONS"
    echo "CPUs:             ${task.cpus}"
    echo "Memory:           ${task.memory.toGiga()}"
    echo "=============================================================================="
    



    export JULIA_DEPOT_PATH="/opt/julia_depot:${JULIA_DEPOT_PATH}"

    # Record start time
    START_TIME=\$(date +%s)

    # Directories for this SVD
    # Note: spatial_optimize.jl reads from step2_output_dir and writes to output_dir
    # We use the same directory for both

    # Required input files (from Steps 1-2)
    # Use Tree_support.nw (with bootstrap support values) for spatial optimization
    TREE_FILE="$SVD_DIR/Tree_support.nw"
    ALLNODES_LEAVES="$SVD_DIR/allnodes_leaves.tsv"
    ALLNODES_PARENTS="$SVD_DIR/allnodes_parents.tsv"
    SPECTRAL_DIST="$SVD_DIR/spectral_dist_melt.tsv"
    TREE_NODES="$SVD_DIR/tree_nodes.tsv"
    BARCODE_POSITIONS=$BARCODE_POSITIONS
    
    julia --heap-size-hint=${task.memory.toGiga()}G \
        "${WORKFLOW_SCRIPTS_DIR}/tumorspace_core/julia/spatial_optimize_gc_memory.jl" \
        $SVD_DIR \
        $INPUT_DIR \
        $SVD_DIR
    
    # Record completion
    END_TIME=\$(date +%s)
    ELAPSED=\$((END_TIME - START_TIME))

    echo
    echo "=============================================================================="
    echo "Step 3 Complete - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    echo "=============================================================================="
    echo "Elapsed time: \${ELAPSED}s"
    echo "Outputs written to: $SVD_DIR"
    echo "  - allnodes_ripley.tsv"
    echo "  - cor_dat_all.tsv (NodeCor = correlation metric)"
    echo "  - allnodes_leaves_passingNodes.tsv"
    echo "  - predicted_spot_locations.tsv"
    echo "  - OptimalTree_labelpreprune.nw"
    echo "  - SG_depths.txt"
    echo "=============================================================================="
    
    """
}

process Phylo_prune { 
    tag "Tree Pruning $DATASET - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    
    cache 'lenient'
    cpus { 1 }
    memory { 800.MB * task.attempt }
    time { task.attempt < 2 ? 20.min : task.attempt < 4 ? (90.min * task.attempt) : (2.hour * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    
    container "julia_1.9_with_gotree.sif"

    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_VALUE), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            path(GENES), 
            path(M), 
            path(SVD_DIR), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 
            

    output:
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            path(GENES), 
            path(M), 
            path(SVD_DIR), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 

    // DATASET,        // index 0
    // INPUT_DIR,      // index 1
    // SVD_INDEX,      // index 2
    // OUT,            // index 3
    // WORKFLOW_SCRIPTS_DIR, // 4
    // BARCODE_POSITIONS,    // 5
    // BARCODES,             // 6
    // FEATURES,             // 7
    // GENES,                // 8
    // M,                    // 9
    // SVD_DIR,              // 10
    // RUN_DATE,             // 11
    // FIXED_SEED,           // 12
    // JULIA_DEPOT_PATH      // 13

    script:
    """

    export JULIA_DEPOT_PATH="/opt/julia_depot:${JULIA_DEPOT_PATH}"

    # This script prunes phylogenetic trees based on optimal support thresholds
    # determined in Step 3. Uses SLURM job arrays to process multiple SVD runs in parallel.
    #
    # The support threshold is automatically extracted from cor_dat_all.tsv (first data row,
    # "Prune" column), which contains the optimal hyperparameters from Step 3.


    # Get SVD number from array task ID
    SVD_NUM=$SVD_INDEX

    # Directories for this SVD

    # Required input files (from Step 3)
    TREE_LABELPREPRUNE="$SVD_DIR/OptimalTree_labelpreprune.nw"
    COR_DAT_ALL="$SVD_DIR/cor_dat_all.tsv"

    # Verify inputs
    if [ ! -f "\$TREE_LABELPREPRUNE" ]; then
        echo "ERROR: Tree file not found: \$TREE_LABELPREPRUNE"
        echo "Ensure Step 3 has completed for SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
        exit 1
    fi

    if [ ! -f "\$COR_DAT_ALL" ]; then
        echo "ERROR: Hyperparameter file not found: \$COR_DAT_ALL"
        echo "Ensure Step 3 has completed for SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
        exit 1
    fi

    # Extract optimal support threshold from cor_dat_all.tsv
    # First data row (row 2), column 5 (Prune)
    SUPPORT_THRESHOLD=\$(head -2 "\$COR_DAT_ALL" | tail -1 | cut -f5)

    if [ -z "\$SUPPORT_THRESHOLD" ]; then
        echo "ERROR: Could not extract support threshold from \$COR_DAT_ALL"
        exit 1
    fi
    JULIA_SCRIPT="$WORKFLOW_SCRIPTS_DIR/tumorspace_core/julia/phylo_tree_prune.jl"

    echo "=============================================================================="
    echo "Step 4: Tree Pruning - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    echo "=============================================================================="
    echo "SVD Dir:              $SVD_DIR"
    echo "Data Dir:             $INPUT_DIR"
    echo "Barcodes:             $BARCODE_POSITIONS"
    echo "Support Threshold:    \$SUPPORT_THRESHOLD"
    echo "CPUs:                 ${task.cpus}"
    echo "Memory:               ${task.memory.toGiga()}"
    echo "=============================================================================="
    # Record start time
    START_TIME=\$(date +%s)


    julia "\$JULIA_SCRIPT" "$SVD_DIR" "$SVD_DIR" "\$SUPPORT_THRESHOLD"

    # Record completion
    END_TIME=\$(date +%s)
    ELAPSED=\$((END_TIME - START_TIME))


    echo
    echo "=============================================================================="
    echo "Step 4 Complete - SVD #${SVD_INDEX} Value: ${SVD_VALUE}"
    echo "=============================================================================="
    echo "Elapsed time: \${ELAPSED}s"
    echo "Outputs written to: $SVD_DIR"
    echo "  - OptimalTree_preprune.nw (before pruning)"
    echo "  - OptimalTree.nw (after pruning)"
    echo "=============================================================================="
    """
}

process svd_selection { 
    tag "$DATASET Find optimal SVD by maximum NodeCor"
    
    cpus 1
    memory 500.MB
    time { task.attempt < 2 ? 5.min : task.attempt < 4 ? (5.min * task.attempt) : (5.min * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    
    // container "julia_1.9_with_gotree.sif"


    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR), 
            val(SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES), 
            path(FEATURES), 
            path(GENES), 
            path(M), 
            path(SVD_DIR), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 
    val KEEP_ALL


    output: 
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path("OPTIMAL_DIR", followLinks: false),
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 


    script:
    """
    echo "=============================================================================="
    echo "SVD Selection: Find Optimal SVD by Maximum NodeCor"
    echo "=============================================================================="
    echo "Data Dir:     $OUT"
    echo "Num SVDs:     ${params.NUM_SVD}"
    echo "Keep All:     $KEEP_ALL"
    echo "CPUs:         ${task.cpus}"
    echo "=============================================================================="



    # SVD Selection: Find optimal SVD by maximum NodeCor value
    #
    # This script reads cor_dat_all.tsv from all SVD runs, identifies the SVD with
    # the highest NodeCor (correlation between predicted and actual spot locations),
    # and creates a symlink to enable downstream steps to process only the optimal SVD.

    # Record start time
    START_TIME=\$(date +%s)

    # Find optimal SVD by maximum NodeCor
    echo "[1/3] Scanning SVD runs for NodeCor values..."
    BEST_SVD=""
    BEST_NODECOR=-1
    BEST_SUPPORT=""
    BEST_SPATIAL=""
    BEST_KNN=""


    for ((i=0; i<=$SVD_INDEX; i++)); do
        COR_FILE="$OUT/svd_run_\${i}/cor_dat_all.tsv"
        
        if [ ! -f "\$COR_FILE" ]; then
            echo "Searching for "$OUT/svd_run_\${i}/cor_dat_all.tsv"  
            ⚠ Warning: cor_dat_all.tsv not found for SVD \$i, skipping"
            continue
        fi
        
        # Extract first data row (row 2): NodeCor, Run, SVD_end, KNN_spatial_run, Prune, Spatial, KNN
        DATA_ROW=\$(head -2 "\$COR_FILE" | tail -1)
        NODECOR=\$(echo "\$DATA_ROW" | cut -f1)
        SUPPORT=\$(echo "\$DATA_ROW" | cut -f5)
        SPATIAL=\$(echo "\$DATA_ROW" | cut -f6)
        KNN=\$(echo "\$DATA_ROW" | cut -f7)
        
        echo "  SVD \$i: NodeCor = \$NODECOR"
        
        # Compare NodeCor values (using bc for floating point comparison)
        if (( \$(echo "\$NODECOR > \$BEST_NODECOR" | bc -l) )); then
            BEST_SVD=\$i
            BEST_NODECOR=\$NODECOR
            BEST_SUPPORT=\$SUPPORT
            BEST_SPATIAL=\$SPATIAL
            BEST_KNN=\$KNN
        fi
    done

    if [ -z "\$BEST_SVD" ]; then
        echo "ERROR: No valid SVD runs found with cor_dat_all.tsv"
        exit 1
    fi

    echo ""
    echo "Selected optimal SVD: \$BEST_SVD"
    echo "  NodeCor (correlation):    \$BEST_NODECOR"
    echo "  Support threshold:        \$BEST_SUPPORT"
    echo "  Spatial threshold:        \$BEST_SPATIAL"
    echo "  K nearest neighbors:      \$BEST_KNN"
    echo ""

    # Copy outputs from optimal SVD to optimal/ directory
    echo "[2/3] Copying outputs from optimal SVD to optimal directory..."
    OPTIMAL_DIR="$OUT/optimal"
    SOURCE_DIR="$OUT/svd_run_\$BEST_SVD"

    # Remove existing optimal directory if present
    if [ -e "\$OPTIMAL_DIR" ]; then
        echo "  Removing existing optimal directory"
        rm -rf "\$OPTIMAL_DIR"
    fi
    
    # Create fresh optimal directory
    mkdir -p "\$OPTIMAL_DIR"


    # Copy key output files needed by downstream steps (only if they exist)
    # From spatial analysis steps (always present)
    cp "\$SOURCE_DIR/OptimalTree.nw" "\$OPTIMAL_DIR/" || true
    cp "\$SOURCE_DIR/OptimalTree_preprune.nw" "\$OPTIMAL_DIR/" || true
    cp "\$SOURCE_DIR/SPI_Dist_mtx.txt" "\$OPTIMAL_DIR/" || true

    # From node analysis steps (usually present)
    [ -f "\$SOURCE_DIR/OptimalTree_labelpreprune.nw" ] && cp "\$SOURCE_DIR/OptimalTree_labelpreprune.nw" "\$OPTIMAL_DIR/" || true
    [ -f "\$SOURCE_DIR/tree_edges.tsv" ] && cp "\$SOURCE_DIR/tree_edges.tsv" "\$OPTIMAL_DIR/" || true
    [ -f "\$SOURCE_DIR/tree_nodes.tsv" ] && cp "\$SOURCE_DIR/tree_nodes.tsv" "\$OPTIMAL_DIR/" || true
    [ -f "\$SOURCE_DIR/allnodes_leaves.tsv" ] && cp "\$SOURCE_DIR/allnodes_leaves.tsv" "\$OPTIMAL_DIR/" || true
    [ -f "\$SOURCE_DIR/allnodes_parents.tsv" ] && cp "\$SOURCE_DIR/allnodes_parents.tsv" "\$OPTIMAL_DIR/" || true

    # From tree pruning step (optional, only exists if prune step was run)
    [ -f "\$SOURCE_DIR/OptimalTree_pruned.nw" ] && cp "\$SOURCE_DIR/OptimalTree_pruned.nw" "\$OPTIMAL_DIR/" || true
    [ -f "\$SOURCE_DIR/OptimalTree_pruned_node_compare_list.txt" ] && cp "\$SOURCE_DIR/OptimalTree_pruned_node_compare_list.txt" "\$OPTIMAL_DIR/" || true
    [ -f "\$SOURCE_DIR/OptimalTree_pruned_node_compare_leaves.txt" ] && cp "\$SOURCE_DIR/OptimalTree_pruned_node_compare_leaves.txt" "\$OPTIMAL_DIR/" || true
    [ -f "\$SOURCE_DIR/OptimalTree_pruned_node_info.txt" ] && cp "\$SOURCE_DIR/OptimalTree_pruned_node_info.txt" "\$OPTIMAL_DIR/" || true

    echo "  ✓ Copied outputs from svd_run_\${BEST_SVD} to \$OPTIMAL_DIR"

    # Write optimal SVD info to file
    OPTIMAL_INFO="$OUT/optimal_svd.txt"
    cat > "\$OPTIMAL_INFO" << EOF
    # Optimal SVD Selection Results
    # Generated: \$(date)
    # Dataset: DATASET_PLACEHOLDER

    SVD_Number: \$BEST_SVD
    NodeCor: \$BEST_NODECOR
    Support_Threshold: \$BEST_SUPPORT
    Spatial_Threshold: \$BEST_SPATIAL
    KNN: \$BEST_KNN

    # NodeCor represents the correlation between predicted and actual spot locations.
    # Higher values indicate better spatial clustering performance.
    # Range: 0.0 (no correlation) to 1.0 (perfect correlation)
    EOF

    echo "  ✓ Wrote: \$OPTIMAL_INFO"



    # Record completion
    END_TIME=\$(date +%s)
    ELAPSED=\$((END_TIME - START_TIME))


    ln -sf "\$(realpath \$OPTIMAL_DIR)" "OPTIMAL_DIR"
    echo ""
    echo "=============================================================================="
    echo "SVD Selection Complete"
    echo "=============================================================================="
    echo "Elapsed time: \${ELAPSED}s"
    echo "Optimal SVD:  \$BEST_SVD (NodeCor = \$BEST_NODECOR)"
    echo "Output dir:   \$OPTIMAL_DIR"
    echo "Info file:    \$OPTIMAL_INFO"
    echo ""
    echo "Next steps:"
    echo "  - Use optimal/ directory for downstream analysis (Steps 6-8)"
    echo "  - Read optimal_svd.txt for selected hyperparameters"
    echo "=============================================================================="


    """
}

process SG_identify_pairs { 
    tag "$DATASET Spatial Group (SG) Identification"
    cpus { 2 }
    memory { 500.MB * task.attempt }
    time { task.attempt < 2 ? 5.min : task.attempt < 4 ? (5.min * task.attempt) : (5.min * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    
    container "tumorspace_r.sif"


    input:
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path(OPTIMAL_DIR), // may need to be a val, its an env export from the sv_selection step
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 


    output:
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path(OPTIMAL_DIR), // may need to be a val
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 

    // # Workspace and script locations
    // R_SCRIPT="$WORKSPACE_ROOT/tumorspace_core/R/sg_identify_pairs.R"
    // CONTAINER_R_SCRIPT="/opt/workflows/R/sg_identify_pairs.R"


    script:
    """
    echo "=============================================================================="
    echo "TumorSPACE Step 6: SG Identification"
    echo "=============================================================================="
    echo "Data Dir:             $OUT"
    echo "Num SVDs:             ${params.NUM_SVD}"
    echo "CPUs:                 ${task.cpus}"
    echo "Optimal Directory:    $OPTIMAL_DIR"
    echo "=============================================================================="

    # Identifies sibling node pairs in the pruned phylogenetic tree that meet minimum
    # size thresholds. Each pair represents a spatial group (SG) - phylogenetically-related
    # clusters with spatial proximity.
    #
    # SG = Spatial Group: Phylogenetically-related cell clusters with shared spatial context

    echo "Optimal directory: $OPTIMAL_DIR"
    echo "Tree file: $OPTIMAL_DIR/OptimalTree.nw"
    echo ""

    # Verify input file exists
    if [ ! -f "$OPTIMAL_DIR/OptimalTree.nw" ]; then
        echo "ERROR: OptimalTree.nw not found"
        exit 1
    fi

    echo "Starting SG identification..."
    echo ""

    # Set R library path inside container (SINGULARITYENV_ prefix passes to container)
    # R_LIBS_USER must be non-empty: empty string triggers R's ~/R/... fallback which resolves
    # to the NFS-mounted host path, causing .so load failures (libRblas.so absent on RHEL).
    export SINGULARITYENV_R_LIBS_USER="/usr/local/lib/R/site-library"
    export SINGULARITYENV_R_LIBS="/usr/local/lib/R/site-library:/usr/lib/R/site-library:/usr/lib/R/library"
    CONTAINER_R_SCRIPT="/opt/workflows/R/sg_identify_pairs.R"

    Rscript "\$CONTAINER_R_SCRIPT" \
        "$OPTIMAL_DIR" \
        "$OPTIMAL_DIR"

    echo ""
    echo "SG identification completed"
    echo "End time: $(date)"
    echo ""

    # Verify outputs were created
    if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_list.txt" ]; then
        NUM_PAIRS=\$(tail -n +2 "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_list.txt" | wc -l)
        echo "✓ Created node_compare_list.txt (\$NUM_PAIRS SG pairs)"
    else
        echo "✗ WARNING: node_compare_list.txt not created"
    fi

    if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_leaves.txt" ]; then
        NUM_LEAVES=\$(tail -n +2 "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_leaves.txt" | wc -l)
        echo "✓ Created node_compare_leaves.txt (\$NUM_LEAVES barcode assignments)"
    else
        echo "✗ WARNING: node_compare_leaves.txt not created"
    fi

    if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_info.txt" ]; then
        echo "✓ Created node_info.txt"
    else
        echo "✗ WARNING: node_info.txt not created"
    fi

    if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_skip_list.txt" ]; then
        echo "✓ Created node_skip_list.txt"
    else
        echo "✗ WARNING: node_skip_list.txt not created"
    fi

    echo ""
    echo "=========================================="
    """
}

process SG_diff_abundance { 
    tag "$DATASET Differential Gene Expression Analysis"
    
    cpus { 1 }
    memory { 
        def estimated_lines = BARCODES.size() / 20
        def mem = (estimated_lines * 0.004).GB + (2.GB * task.attempt) // gives you estimated mem per line plus overhead
        [mem, 1280.GB].min()
    }    
    time { task.attempt < 2 ? 120.min : task.attempt < 4 ? (60.min * task.attempt) : (80.min * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    container "julia_1.9_with_gotree.sif"


    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path(OPTIMAL_DIR), // may need to be a val
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 
    val(NUM_SHUFFLE) // params.NUM_SHUFFLE

    output:
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path(OPTIMAL_DIR), // may need to be a val
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 


    // NEED TO INCORPERATE SEED
    // # Workspace and script locations
    // JULIA_SCRIPT="$WORKFLOW_SCRIPTS_DIR/julia/sg_diff_abundance.jl"


    script:
    """
    echo "=========================================="
    echo "TumorSPACE Step 7: Differential Abundance"
    echo "=========================================="
    echo "Data Dir:             $OUT"
    echo "Num SVDs:             ${params.NUM_SVD}"
    echo "CPUs:                 ${task.cpus}"
    echo "Optimal Directory:    $OPTIMAL_DIR"
    echo "=========================================="

    # Identifies differentially abundant (DA) genes between spatial group (SG) pairs using
    # Wilcoxon rank-sum tests with permutation-based FDR correction.
    #
    # Tests for genes that show significantly different expression levels between sibling
    # node pairs in the phylogenetic tree, indicating spatial localization patterns.

    export JULIA_DEPOT_PATH="/opt/julia_depot:${JULIA_DEPOT_PATH}"
    JULIA_SCRIPT="$WORKFLOW_SCRIPTS_DIR/tumorspace_core/julia/sg_diff_abundance.jl"

    echo "Optimal directory: $OPTIMAL_DIR"
    echo "Tree file: $OPTIMAL_DIR/OptimalTree.nw"
    echo ""

    # Copy data files to optimal directory (required by Julia script)
    echo "Copying data files to optimal directory..."
    cp "$M" "$OPTIMAL_DIR/"
    cp "$BARCODES" "$OPTIMAL_DIR/"
    cp "$GENES" "$OPTIMAL_DIR/" || cp "$FEATURES" "$OPTIMAL_DIR/genes.txt"
    echo "✓ Data files copied"
    echo ""

    # Verify input files exist
    echo "Checking input files..."
    for file in OptimalTree_pruned_node_compare_list.txt OptimalTree_pruned_node_compare_leaves.txt M.txt barcodes.txt genes.txt; do
        if [ -f "$OPTIMAL_DIR/\$file" ]; then
            echo "✓ \$file"
        else
            echo "✗ ERROR: \$file not found"
            exit 1
        fi
    done
    echo ""

    echo "Starting differential abundance analysis..."
    echo ""

    julia --heap-size-hint=${task.memory.toGiga() - 1}G \
        "\$JULIA_SCRIPT" \
        "$OPTIMAL_DIR" \
        "$NUM_SHUFFLE"

    echo ""
    echo "Differential abundance analysis completed"
    echo "End time: \$(date)"
    echo ""

    # Verify outputs were created
    if [ -f "$OPTIMAL_DIR/DA_results.txt" ]; then
        NUM_TESTS=\$(tail -n +2 "$OPTIMAL_DIR/DA_results.txt" | wc -l)
        echo "✓ Created DA_results.txt (\$NUM_TESTS tests)"
    else
        echo "✗ WARNING: DA_results.txt not created"
    fi

    if [ -f "$OPTIMAL_DIR/DA_significant.txt" ]; then
        NUM_SIG=\$(tail -n +2 "$OPTIMAL_DIR/DA_significant.txt" | wc -l)
        echo "✓ Created DA_significant.txt (\$NUM_SIG significant DA genes)"
    else
        echo "✗ WARNING: DA_significant.txt not created"
    fi

    echo ""
    echo "=========================================="
    """
}

process SLAB_score { 
    tag "$DATASET Spatially Localized Abundance Bias"
    cpus { 1 }
    memory { 
        def estimated_lines = BARCODES.size() / 20
        def mem = (estimated_lines * 0.006).GB + (2.GB * task.attempt) // gives you estimated mem per line plus overhead
        [mem, 1280.GB].min()
    }
    cache false
    time { task.attempt < 2 ? 40.min : task.attempt < 4 ? (40.min * task.attempt) : (80.min * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    
    container "julia_1.9_with_gotree.sif"


    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path(OPTIMAL_DIR), // may need to be a val
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 


    output:
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path(OPTIMAL_DIR), // may need to be a val
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 

    // NEED TO INCORPERATE SEED
    // # Workspace and script locations
    // JULIA_SCRIPT="$WORKFLOW_SCRIPTS_DIR/julia/sg_diff_abundance.jl"


    script:
    """
    echo "=========================================="
    echo "TumorSPACE Step 8: SLAB (Spatially Localized Abundance Bias) Scoring"
    echo "=========================================="
    echo "Data Dir:             $OUT"
    echo "Num SVDs:             ${params.NUM_SVD}"
    echo "CPUs:                 ${task.cpus}"
    echo "CPUs:                 ${task.memory.toGiga()}"
    echo "Optimal Directory:    $OPTIMAL_DIR"
    echo "Barcode positions:    $BARCODE_POSITIONS"
    echo "=========================================="

    # Computes spatial localization scores for differentially abundant genes based on
    # which barcodes (spots) show DA changes across the spatial hierarchy.
    #
    # SLAB score = (# spots with DA change) / (total # spots)
    #
    # Higher SLAB scores indicate genes with stronger spatial localization patterns.
    
    export JULIA_DEPOT_PATH="/opt/julia_depot:${JULIA_DEPOT_PATH}"
    JULIA_SCRIPT="$WORKFLOW_SCRIPTS_DIR/tumorspace_core/julia/sg_slab_score.jl"

    ln -sf "\$(realpath $BARCODE_POSITIONS)" "$OPTIMAL_DIR/barcodes_positions.txt" || true

    echo " made a symbolic link in $OPTIMAL_DIR/barcodes_positions.txt"
    # Verify input files exist (CW REMOVED BARCODES CHECK, ITS IN THE NEXTFLOW PROCESS INPUTS)
    echo "Checking input files..."
    for file in DA_significant.txt OptimalTree_pruned_node_compare_list.txt OptimalTree_pruned_node_compare_leaves.txt; do
        if [ -f "$OPTIMAL_DIR/\$file" ]; then
            echo "✓ \$file"
        else
            echo "✗ ERROR: \$file not found"
            exit 1
        fi
    done
    echo ""

    echo "Starting SLAB score calculation..."
    echo ""


    julia --heap-size-hint=${task.memory.toGiga() - 1}G \
        "\$JULIA_SCRIPT" \
        "$OPTIMAL_DIR"

    echo ""
    echo "SLAB score calculation completed"
    echo "End time: \$(date)"
    echo ""

    echo "Making the gene directory and moving the gene results into it"

    mkdir -p "$OPTIMAL_DIR/gene"
    mv $OPTIMAL_DIR/DA_significant.txt $OPTIMAL_DIR/gene/DA_significant.txt

    # Verify outputs were created
    if [ -f "$OPTIMAL_DIR/SLAB_scores.txt" ]; then
        NUM_SCORES=\$(tail -n +2 "$OPTIMAL_DIR/SLAB_scores.txt" | wc -l)
        mkdir -p "$OPTIMAL_DIR/gene"
        mv $OPTIMAL_DIR/SLAB_scores.txt $OPTIMAL_DIR/gene/SLAB_scores.txt
        echo "✓ Created SLAB_scores.txt (\$NUM_SCORES gene-direction pairs)"
    else
        echo "✗ WARNING: SLAB_scores.txt not created"
    fi

    if [ -f "$OPTIMAL_DIR/SLAB_barcodes.txt" ]; then
        NUM_BARCODES=\$(tail -n +2 "$OPTIMAL_DIR/SLAB_barcodes.txt" | wc -l)
        echo "✓ Created SLAB_barcodes.txt (\$NUM_BARCODES barcode entries)"
    else
        echo "✗ WARNING: SLAB_barcodes.txt not created"
    fi

    echo ""
    echo "=========================================="
    """
}

process SLAB_completion { 
    tag "$DATASET Completion Marker & Summary Generator"
    scratch false
    cpus { 1 }
    memory { task.attempt < 2 ? 2.GB + (2.GB * task.attempt) : 8.GB + 8.GB * task.attempt }
    time { task.attempt < 2 ? 40.min : task.attempt < 4 ? (40.min * task.attempt) : (80.min * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    
    // container "julia_1.9_with_gotree.sif"


    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path(OPTIMAL_DIR), // may need to be a val
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 


    output:
    tuple   val(DATASET), 
            path(INPUT_DIR),
            path(OPTIMAL_DIR), // may need to be a val
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 

    // NEED TO INCORPERATE SEED
    // # Workspace and script locations
    // JULIA_SCRIPT="$WORKFLOW_SCRIPTS_DIR/julia/sg_diff_abundance.jl"


    script:
    """
    echo "=========================================="
    echo "TumorSPACE Step 9: SLAB Completion Marker & Summary Generator"
    echo "=========================================="
    echo "Data Dir:             $OUT"
    echo "Num SVDs:             ${params.NUM_SVD}"
    echo "CPUs:                 ${task.cpus}"
    echo "Optimal Directory:    $OPTIMAL_DIR"
    echo "Barcode positions:    $BARCODE_POSITIONS"
    echo "=========================================="


    OUTPUT_DIR="$OUT"
    OPTIMAL_DIR="$OPTIMAL_DIR"
    COMPLETION_FILE="$OPTIMAL_DIR/PIPELINE_COMPLETE.txt"

    # TumorSPACE AWS Pipeline - Completion Marker & Summary Generator
    # This is Step 9 in the pipeline - marks successful completion and generates summary

    # Count outputs from each step
    echo "================================================================================" >> "\$COMPLETION_FILE"
    echo "Pipeline Outputs Summary" >> "\$COMPLETION_FILE"
    echo "================================================================================" >> "\$COMPLETION_FILE"
    echo "" >> "\$COMPLETION_FILE"

    # Step 1: Tree files
    TREE_FILES=\$(ls -1 $OPTIMAL_DIR/Tree_*.nw 2>/dev/null | wc -l)
    echo "Step 1 (Tree Building):" >> "\$COMPLETION_FILE"
    echo "  Tree files: \${TREE_FILES}" >> "\$COMPLETION_FILE"
    echo "" >> "\$COMPLETION_FILE"

    # Step 2: Node extraction files
    NODE_FILES=\$(ls -1 $OPTIMAL_DIR/*nodes*.txt $OPTIMAL_DIR/*leaves*.txt 2>/dev/null | wc -l)
    echo "Step 2 (Node Extraction):" >> "\$COMPLETION_FILE"
    echo "  Node relationship files: \${NODE_FILES}" >> "\$COMPLETION_FILE"
    echo "" >> "\$COMPLETION_FILE"

    # Step 3: Spatial optimization
    if [ -f "$OPTIMAL_DIR/Tree_support.nw" ]; then
        echo "Step 3 (Spatial Optimization):" >> "\$COMPLETION_FILE"
        echo "  Tree support file: ✓" >> "\$COMPLETION_FILE"
        echo "" >> "\$COMPLETION_FILE"
    fi

    # Step 4: Tree pruning
    if [ -f "$OPTIMAL_DIR/OptimalTree.nw" ]; then
        echo "Step 4 (Tree Pruning):" >> "\$COMPLETION_FILE"
        echo "  Optimal tree: ✓" >> "\$COMPLETION_FILE"
        echo "" >> "\$COMPLETION_FILE"
    fi

    # Step 6: SG identification
    SG_FILES=\$(ls -1 $OPTIMAL_DIR/OptimalTree_pruned_node_*.txt 2>/dev/null | wc -l)
    echo "Step 6 (SG Identification):" >> "\$COMPLETION_FILE"
    echo "  SG definition files: \${SG_FILES}" >> "\$COMPLETION_FILE"
    if [ -f "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_list.txt" ]; then
        SG_PAIRS=\$(tail -n +2 "$OPTIMAL_DIR/OptimalTree_pruned_node_compare_list.txt" | wc -l)
        echo "  SG pairs identified: \${SG_PAIRS}" >> "\$COMPLETION_FILE"
    fi
    echo "" >> "\$COMPLETION_FILE"

    # Step 7: Differential abundance
    if [ -f "$OPTIMAL_DIR/gene/DA_significant.txt" ]; then
        DA_GENES=\$(tail -n +2 "$OPTIMAL_DIR/gene/DA_significant.txt" | wc -l)
        echo "Step 7 (Differential Abundance):" >> "\$COMPLETION_FILE"
        echo "  Significant DA genes: \${DA_GENES}" >> "\$COMPLETION_FILE"
        echo "" >> "\$COMPLETION_FILE"
    fi

    # Step 8: SLAB scoring
    if [ -f "$OPTIMAL_DIR/gene/SLAB_scores.txt" ]; then
        # Check file size to catch empty files from race conditions
        SLAB_SIZE=\$(stat -c%s "$OPTIMAL_DIR/gene/SLAB_scores.txt" 2>/dev/null || echo "0")
        if [ "\$SLAB_SIZE" -gt 100 ]; then
            SLAB_ENTRIES=\$(tail -n +2 "$OPTIMAL_DIR/gene/SLAB_scores.txt" | wc -l)
            echo "Step 8 (SLAB Scoring):" >> "\$COMPLETION_FILE"
            echo "  SLAB score entries: \${SLAB_ENTRIES}" >> "\$COMPLETION_FILE"
        else
            echo "Step 8 (SLAB Scoring):" >> "\$COMPLETION_FILE"
            echo "  ⚠ WARNING: SLAB_scores.txt is empty or incomplete (\${SLAB_SIZE} bytes)" >> "\$COMPLETION_FILE"
            echo "  This may indicate a race condition or Step 8 failure" >> "\$COMPLETION_FILE"
        fi
        echo "" >> "\$COMPLETION_FILE"
    else
        echo "Step 8 (SLAB Scoring):" >> "\$COMPLETION_FILE"
        echo "  ⚠ ERROR: SLAB_scores.txt not found" >> "\$COMPLETION_FILE"
        echo "" >> "\$COMPLETION_FILE"
    fi

    # File sizes
    echo "================================================================================" >> "\$COMPLETION_FILE"
    echo "Output File Sizes" >> "\$COMPLETION_FILE"
    echo "================================================================================" >> "\$COMPLETION_FILE"
    echo "" >> "\$COMPLETION_FILE"

    du -sh $OPTIMAL_DIR/*.txt $OPTIMAL_DIR/*.nw 2>/dev/null | \
        awk '{printf "  %-40s %10s\\n", \$2, \$1}' >> "\$COMPLETION_FILE"


    echo "" >> "\$COMPLETION_FILE"
    echo "Total size: \$(du -sh $OPTIMAL_DIR | cut -f1)" >> "\$COMPLETION_FILE"
    echo "" >> "\$COMPLETION_FILE"
    """
}

process Bayesspace { 
    tag "$DATASET BayesSpace spatial clustering"
    scratch false
    cpus { 1 }
    memory { (2.GB + (2.GB * task.attempt) * 0.8) }
    time { task.attempt < 2 ? 40.min : task.attempt < 4 ? (40.min * task.attempt) : (80.min * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    
    container "tumorspace_r.sif"


    input: 
    tuple   val(DATASET), 
            path(INPUT_DIR),
            val(FINAL_SVD_INDEX), 
            path(OUT), 
            path(WORKFLOW_SCRIPTS_DIR), 
            path(BARCODE_POSITIONS), 
            path(BARCODES),
            path(FEATURES),
            path(GENES),
            path(M),
            path(SVD_DIR), 
            val(RUN_DATE), 
            val(FIXED_SEED), 
            val(JULIA_DEPOT_PATH) 



    script:
    """
    echo "=========================================="
    echo "Runs BayesSpace spatial clustering on Visium data"
    echo "=========================================="
    echo "Data Dir:             $OUT"
    echo "Num SVDs:             ${params.NUM_SVD}"
    echo "CPUs:                 ${task.cpus}"
    echo "Barcode positions:    $BARCODE_POSITIONS"
    echo "=========================================="

    #10x Visium data. Runs independently of `tumorspace_core` — consumes the same
    #Visium input data and produces complementary cluster assignments.

    mkdir -p data/
    
    #

    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    R_LIBS_USER="/usr/local/lib/R/site-library" \
    Rscript $WORKFLOW_SCRIPTS_DIR/bayesspace/R/run_bayesspace.R \
      --datapath '$INPUT_DIR' \
      --nPCs '${params.NPCs}' \
      --q '8' \
      --outdir '$OUT'
      # if multiple add '--theta' argument default of 2

    """
}
