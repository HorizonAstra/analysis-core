#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --time=16:00:00
#SBATCH --mem=48gb


module load go/1.24.6
module load singularity/4.3.6

export SINGULARITY_TMPDIR="/scratch/$USER/tumorspace_build/tmp"
export SINGULARITY_CACHEDIR="/scratch/$USER/tumorspace_build/tmp"

mkdir -p $SINGULARITY_TMPDIR


# Clone repository

bash setup.sh --scratch $SINGULARITY_TMPDIR
