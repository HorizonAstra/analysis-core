#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=2
#SBATCH --time=24:00:00
#SBATCH --mem=8gb
#SBATCH --exclude=cri22cn146
# run multiple in datasets in paralell

# manual testing interactive env: ssh cri22in001 > tmux a -t 10 > srun --ntasks-per-node=4 --partition=tier1q  --time=02:00:00 --mem=8gb --cpus-per-task=1 --pty bash -i

module load go/1.24.6
module load singularity/4.3.6
module load openjdk/17.0.2
module load nextflow/26.03.0
mkdir -p /scratch/rijulsareen/nextflow_singularity
export SINGULARITY_TMPDIR=/scratch/rijulsareen/nextflow_singularity
export SINGULARITY_CACHEDIR=/gpfs/data/dfi-cores/rijul/TumorSpace/containers
export NXF_SINGULARITY_CACHEDIR=/gpfs/data/dfi-cores/rijul/TumorSpace/containers
export NXF_SINGULARITY_TMPDIR=/scratch/rijulsareen/nextflow_singularity

# get the nextflow script location
nextflow_script="/gpfs/data/dfi-cores/rijul/TumorSpace/template_dir/tumorspace_subdir.nf"
nextflow_config="/gpfs/data/dfi-cores/rijul/TumorSpace/template_dir/nf.config"
julia_depot="/scratch/$USER/julia_depot"
mkdir -p $julia_depot

# get the date
date=$(date +%Y%m%d)
timestamp=$(date +%Y%m%d_%H%M%S)


cd /gpfs/data/dfi-cores/rijul
## The basename of your input data dir will be a project name of the results folder, so make sure to set it to something appropriate
input_data_dir="/gpfs/data/dfi-cores/rijul/input-data/harmonized"
project_name=$(basename $input_data_dir)

## output_dir="/gpfs/data/dfi-cores/rijul/output-data/$project_name"
output_dir="/scratch/rijulsareen/output-data/$project_name"
mkdir -p $output_dir/$timestamp

mkdir -p /scratch/rijulsareen/nextflow_temp


nextflow run $nextflow_script \
    -c $nextflow_config     \
    --CONTAINER_FOLDER "/gpfs/data/dfi-cores/rijul/TumorSpace/containers"     \
    --OUT "$output_dir/$timestamp"      \
    --INPUT_DIR "$input_data_dir"   \
    --TEST_MODE "false" \
    --WORKFLOW_SCRIPTS_DIR "/gpfs/data/dfi-cores/rijul/TumorSpace/template_dir/workflow_scripts"    \
    --RUN_DATE "$date"     \
    --JULIA_DEPOT "/scratch/$USER/julia_depot"     \
    -w "/scratch/rijulsareen/nextflow_temp"





#### NEXTFLOW VARIABLES TO DECLARE ####
# params.CONTAINER_FOLDER = "/scratch/ckwoodson/tumorspace_project/new_test/nextflow/premade_containers" // this should be the path to the folder containing the premade singularity containers for the tree building step, this is used in the container directive for the tree building process
# params.OUT = "/scratch/ckwoodson/tumorspace_project/new_test/results"

#  // this should be a comma separated list of values for the SVD dimensionality reduction step, 
#  // each value will be run with the number of bootstraps specified in params.BOOT, 
#  // this is used to determine the array job size for the tree building step, 
#  // and is also used to check if a given SVD value has already been completed 
#  // (if the .done file exists for all bootstraps for that SVD value, that SVD value is skipped)
# params.SVD_VALUES = "5, 25, 55, 150"
# // params.SVD_VALUES = "5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100, 105, 110, 115, 120, 125, 130, 135, 140, 145, 150"
# // params.BOOT = 0 // this should be the number of bootstraps we want to run, this is used to determine the array job size for the tree building step, and is also used to check if a given bootstrap has already been completed (if the .done file exists, that bootstrap is skipped)
# params.INPUT_DIR = "/gpfs/data/dfi-cores/CW_temp/new_test/TumorSpace/benchmarks/GSE213688_GSM6592057/input_data" // where the input data of the params.DATASET is located
# params.DATASET = "GSE213688_GSM6592057" // name of the dataset being analyzed
# params.WORKFLOW_SCRIPTS_DIR = "/gpfs/data/dfi-cores/CW_temp/new_test/nextflow/workflow_scripts"
# params.FIXED_SEED = true // set to true to use a fixed seed for testing, false to use random seeds
# params.run_date = ""


# [Step 1/5] Submitting phylogenetic tree building (job array 1-3)...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_phylo_tree_build.sh --account pi-araman --partition caslake --dataset GSE213688_GSM6592057 --workspace-root TumorSpace --input-dir TumorSpace/benchmarks/GSE213688_GSM6592057/input_data --output-dir TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --test
# [Step 1b/5] Submitting bootstrap support calculation...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_phylo_bootstrap_support.sh --account pi-araman --partition caslake --workspace-root TumorSpace --output-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --num-svd 3 --dependency 12345 --test


# [Step 2/5] Submitting node extraction...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_phylo_node_extract.sh --dataset GSE213688_GSM6592057 --account pi-araman --partition caslake --workspace-root TumorSpace --input-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --input-dir TumorSpace/benchmarks/GSE213688_GSM6592057/input_data --num-svd 3 --dependency 12346 --test
# [Step 3/5] Submitting spatial optimization...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_spatial_optimize.sh --dataset GSE213688_GSM6592057 --account pi-araman --partition caslake --workspace-root TumorSpace --input-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --input-dir TumorSpace/benchmarks/GSE213688_GSM6592057/input_data --num-svd 3 --dependency 12347 --test --fixed-seed 1000



# [Step 4/5] Submitting tree pruning...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_phylo_tree_prune.sh --dataset GSE213688_GSM6592057 --account pi-araman --partition caslake --workspace-root TumorSpace --input-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --num-svd 3 --dependency 12348 --test
# [Step 5/5] Submitting SVD selection...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_svd_selection.sh --dataset GSE213688_GSM6592057 --account pi-araman --partition caslake --workspace-root TumorSpace --input-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --num-svd 3  --dependency 12349 --test
# [Step 6/9] Submitting SG identification...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_sg_identify_pairs.sh --dataset GSE213688_GSM6592057 --account pi-araman --partition caslake --workspace-root TumorSpace --input-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --dependency 12350 --test
# [Step 7/9] Submitting differential abundance...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_sg_diff_abundance.sh --dataset GSE213688_GSM6592057 --account pi-araman --partition caslake --workspace-root TumorSpace --input-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --data-dir TumorSpace/benchmarks/GSE213688_GSM6592057/input_data --dependency 12351 --test --fixed-seed 1000
# [Step 8/9] Submitting SLAB scoring (371 spots, using 4G memory)...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_sg_slab_score.sh --dataset GSE213688_GSM6592057 --account pi-araman --partition caslake --workspace-root TumorSpace --input-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --data-dir TumorSpace/benchmarks/GSE213688_GSM6592057/input_data --dependency 12352 --mem 4G --test
# [Step 9/10] Submitting pipeline completion...
# bash TumorSpace/workflows/tumorspace_core/orchestration/run_pipeline_completion.sh --dataset GSE213688_GSM6592057 --account pi-araman --partition caslake --workspace-root TumorSpace --input-base TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454 --mode native_test --num-svd 3 --dependency 12353 --test
# [Step 10] Submitting BayesSpace spatial clustering (after Step 9)...
# sbatch --account pi-araman --partition caslake --mem=16G --time=30:00 --dependency=afterok:12354  --job-name=bayesspace_GSE213688_GSM6592057 --output=TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454/bayesspace/slurm_%j.out --error=TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454/bayesspace/slurm_%j.err --wrap="bash TumorSpace/workflows/bayesspace/orchestration/run_bayesspace.sh --datapath TumorSpace/benchmarks/GSE213688_GSM6592057/input_data --outdir TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454/bayesspace --test"
# [Step 11] Submitting pipeline report...
#   Test dataset: Will validate against reference baseline
# bash TumorSpace/workflows/pipeline_report/orchestration/run_pipeline_report_slurm.sh --output-dir TumorSpace/test_pipeline_output/GSE213688_GSM6592057_native_test_20260417_143454/optimal --account pi-araman --partition caslake --workspace-root TumorSpace --dependency 12354 --reference-dir TumorSpace/benchmarks/GSE213688_GSM6592057/expected_outputs

