#!/usr/bin/env nextflow
// initial non nextflow version of the pipeline created by Huaiying (Eddi) Lin and the rest of the bioinformatics team at DFI

// log.info """\
//     S H O T G U N  P I P E L I N E
//     ===================================
//     Raw Reads             : ${params.rawreads}/*_R{1,2}*.fastq{,.gz}
//     outdir                : ${params.out}
//     Metaphlan database    : ${params.metaphlan_db}
//     """
//     .stripIndent()


// At the top of the file, add:
params.params_label = params.stat_q == '0.2' ? "${params.metaphlan_db}_statq_${params.stat_q}" : "${params.metaphlan_db}_statq_${params.stat_q}"
params.baqlava_params_label = params.params_label.replaceAll("[^a-zA-Z0-9]", "_")
params.check_statq = params.stat_q == '0.2' ? "_statq_${params.stat_q}" : "_statq_${params.stat_q}"
/* Pipeline Parameters */
params.megahit = 'true'
params.dehost_input = false // are you giving data that has already had host removal?
params.biobakery_only = false // do you only want to run the biobakery pipeline
params.humann = true // do you want to run humann
params.baqlava = false // do you want to run baqlava on metaphlan output
params.shortBRED = true // do you want to run shortbred (this option has limited DB options)
params.clinical_rename = false // If this is clincal fastqs right off the sequencer, this will rename them
params.run_kraken = true // do you want to run kraken and braken on the data
params.megahit_analysis = true // do you want to run assemble genomes to contigs and run further downstream analysis
params.diamond = true // this requires megahit_analysis to be true in order to run
params.prodigal_analysis = true // this requires megahit_analysis to be true in order to run 
params.trf = false // this is a flag to bypass the tandem repeat finder in kneaddata
params.bmtagger = false // this is a flag to run bmtagger in kneaddata
params.metaphlan_analysis = true // Run metaphlan?
params.resistance_genes = true // do you want to run resistance gene analysis with rgi and amrfinder? this requires megahit_analysis and prodigal_analysis to be true in order to run
/* General Parameters */
params.rawreads = "/gpfs/data/dfi-cores/biobakery/shotgun/fastq/homelander/*" /* 7 files for analysis here, in subdirectories */
params.combine_metaphlan_results = '/gpfs/data/dfi-cores/biobakery/databases/python_tools/combine_metaphlan_results_list.py' /* adds columns and combines output of multiple nextflow samples into one csv file for db upload */
params.sgb2gtdb = 'python /gpfs/data/dfi-cores/biobakery/databases/metaphlan/util_scripts/sgb2gtdb.py'
params.tool_ver = '/home/ckwoodson/DFI-Pipelines/shotgun/versions.txt'  /* this will be in the container eventually */
params.out = "" // where the combined metaphlan and kneaddata results will go



/* Trimmomatic parameters */
params.trimmomatic_location = '/usr/local/lib/Trimmomatic-0.39'
params.ILLUMINACLIP_params = '2:30:10:1:TRUE'


/* database files for kneaddata */
params.humankneaddatadb = "/gpfs/data/dfi-cores/biobakery/databases/kneaddata/human_ref_hg37dec_v0.1"
params.mousekneaddatadb = "/gpfs/data/dfi-cores/biobakery/databases/kneaddata/mouse_ref_C57BL_6NJ"
params.kneaddata_stats = "/gpfs/data/dfi-cores/biobakery/databases/python_tools/nextflow_produceShotgunQual.r" // this creates the trimstats data, this is currently run manually but will be used in the future 
params.bmtagger_db = "/gpfs/data/dfi-cores/biobakery/databases/bmtagger/Homo_sapiens_BMTagger_v0.1" // this is the location of the bmtagger database

/* Metaphlan parameters */
params.metaphlandb_folder = "/gpfs/data/dfi-cores/biobakery/databases/metaphlan" // this is where the metaphlan databases are stored
params.stat_q = "0.2" // this is the detection threshold for metaphlan
// println "Debug: params.stat_q = ${params.stat_q}"

// Derived labels (no closures)
// params.check_statq = params.stat_q == '0.2' ? '' : "_${params.stat_q}"



// Database versions //

/* 5 options for database available:
1. "mpa_vJan21_CHOCOPhlAnSGB_202103" (this will require the old version of the container that has outdated metaphlan and humann versions to work)
2. "mpa_vOct22_CHOCOPhlAnSGB_202212" (this will require the old version of the container that has outdated metaphlan and humann versions to work)
3. "mpa_vJun23_CHOCOPhlAnSGB_202307" (this will require the newest version of the container to work)
4. "mpa_vJun23_CHOCOPhlAnSGB_202403" (this will require the newest version of the container to work)
5. "mpa_vOct22_CHOCOPhlAnSGB_202403" (this will require the old version of the container that has outdated metaphlan and humann versions to work) 
6. "mpa_vJan25_CHOCOPhlAnSGB_202503" (this will require the newest version of the container to work) */

params.metaphlan_db = "mpa_vJun23_CHOCOPhlAnSGB_202403" // defualt metaphlan database

/* path to Diamond databases */
params.diamonddb_folder = "/gpfs/data/dfi-cores/biobakery/databases/blast"

/* Hashes of all the databases */
params.database_ver_file = "/gpfs/data/dfi-cores/biobakery/databases/db_version_list.txt"

/* Humann Database */
params.humann_nucleotide_db = '/gpfs/data/dfi-cores/biobakery/databases/humann/chocophlan'
params.humann_protein_db = '/gpfs/data/dfi-cores/biobakery/databases/humann/uniref'

/* Emapper Database */
params.emapper_protein_db = '/gpfs/data/dfi-cores/biobakery/databases/eggnog_emapper'

/* shortBRED Marker Database DB must have .faa extention */
params.shortbred_marker_db = '/gpfs/data/dfi-cores/biobakery/shotgun/fastq/fasta_test/card_protien_homolog_uniref90_ref.faa'

/* kraken database */
params.krakendb = "/gpfs/data/dfi-cores/Bioinfo/databases/kraken2/20240501" // "/gpfs/data/dfi-cores/biobakery/databases/kraken/20240501" // this database will be moved to our current w

// Add this function in the top section of your workflow file then in the proccess use  queue = { selectQueue(task.memory, task.cpus) }

def selectQueue(memory, cpus) {
    def memPerCpu = memory.toGiga() / cpus
    if (memPerCpu >= 32 || memory.toGiga() > 512 ) return "tier3q"
    else if (memPerCpu >= 8 || memory.toGiga() > 128 ) return "tier2q" // change this to be 8gb when the cluster is stable
    else return "tier1q"
}

// BIOBAKERY PROCESSES //

process clinical_rename {
    tag "Renaming $sample_id fastq files"
    memory 24.GB
    cpus 6
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }

    input:
    tuple val(sample_id), path(reads), val(rename_dir)

    output:
    tuple val(sample_id), val("${rename_dir}/${sample_id}_R1.fastq.gz"), val("${rename_dir}/${sample_id}_R2.fastq.gz")

    script:
    """
    set -x
    mkdir -p renamed

    actual_file_R1=\$(readlink -f "${reads[0]}")
    echo "The actual file is: \$actual_file_R1"
    actual_file_R2=\$(readlink -f "${reads[1]}")
    echo "The actual file is: \$actual_file_R2"



    if file "\$actual_file_R1" | grep -q 'gzip compressed data'; then
        echo "${reads[0]} is gzipped."
        cp ${reads[0]} renamed/${sample_id}_R1.fastq.gz
    else
        echo "${reads[0]} is not gzipped."
        cp ${reads[0]} renamed/${sample_id}_R1.fastq
        cd renamed
        pigz ${sample_id}_R1.fastq
        cd..
    fi

    if file "\$actual_file_R2" | grep -q 'gzip compressed data'; then
        echo "${reads[1]} is gzipped."
        cp ${reads[1]} renamed/${sample_id}_R2.fastq.gz
    else
        echo "${reads[1]} is not gzipped."
        cp ${reads[1]} renamed/{sample_id}_R2.fastq
        cd renamed
        pigz ${sample_id}_R2.fastq
        cd..
    fi


    rsync -hvir --chmod=Dg=rwx,Fg=rwx renamed/${sample_id}_R*.fastq.gz $rename_dir


    """
}
process Kneaddata_new { 
    tag "Kneaddata on $sample_id"
    memory { 8.GB + 24.GB * task.attempt }
    cpus { task.attempt <= 3 ? 8 + (2 * task.attempt) : (4 * task.attempt) }
    time { task.attempt <= 3 ? (90.min * task.attempt) : (8.hour * task.attempt) }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.6beta"
    queue { selectQueue(task.memory, task.cpus) }

    input: 
    tuple val(sample_id), path(reads)
    path mousekneaddatadb
    path humankneaddatadb

    output: 
    tuple val(sample_id), path(reads), path("*${sample_id}*kneaddata.fastq.gz"), path("deHost/${sample_id}/*${sample_id}*_paired_1.fastq.gz"), path("deHost/${sample_id}/*${sample_id}*_paired_2.fastq.gz"), file("deHost/${sample_id}/*${sample_id}*_kneaddata.log"), path("deHost/${sample_id}/fastqc_files.tar.gz"), path("root_dir"), emit: knead_tuple
    tuple val(sample_id), path("deHost/${sample_id}/*${sample_id}*_kneaddata.log"), emit: kneaddata_log
    tuple val(sample_id), path("root_dir"), emit: root_dir 
    
    script: 
    """
    set -x

    actual_file_R1=\$(readlink -f "${reads[0]}")
    echo "The actual file is: \$actual_file_R1"
    actual_file_R2=\$(readlink -f "${reads[1]}")
    echo "The actual file is: \$actual_file_R2"


    mkdir -p deHost/${sample_id}/
    kneaddata \
    --input1 ${reads[0]} \
    --input2 ${reads[1]} \
    --reference-db ${mousekneaddatadb} \
    --reference-db ${humankneaddatadb} \
    --sequencer-source TruSeq3 \
    --trimmomatic-options="LEADING:3" \
    --trimmomatic-options="TRAILING:3" \
    --trimmomatic-options="SLIDINGWINDOW:4:15" \
    --trimmomatic-options="MINLEN:50" \
    --max-memory ${task.memory.toGiga() - 1} \
    --run-fastqc-start \
    --run-fastqc-end \
    --output \$PWD \
    --cat-final-output \
    -t ${task.cpus} -p 1 ${params.trf == false ? "--bypass-trf" : ""} ${params.bmtagger == true ? "--bmtagger $params.bmtagger_db" : ""} 

    pigz --best *${sample_id}*kneaddata.fastq
    pigz --best *${sample_id}*_paired_1.fastq
    pigz --best *${sample_id}*_paired_2.fastq

    mv *${sample_id}*_kneaddata.log deHost/${sample_id}/
    mv *${sample_id}*_paired_1.fastq.gz deHost/${sample_id}/
    mv *${sample_id}*_paired_2.fastq.gz deHost/${sample_id}/
    tar -czvf fastqc_files.tar.gz fastqc/* 
    mv fastqc_files.tar.gz deHost/${sample_id}/


    actual_file_R1=\$(readlink -f "${reads[0]}")
    echo "The actual file is: \$actual_file_R1"
    actual_file_R2=\$(readlink -f "${reads[1]}")
    echo "The actual file is: \$actual_file_R2"

    # get the parent dir of the files 
    parent_dir=\$(dirname "\$actual_file_R1")
    echo "The parent dir is: \$parent_dir"
    grandparent_dir=\$(dirname "\$parent_dir")
    echo "The grandparent dir is: \$grandparent_dir"
    echo "\$grandparent_dir" > root_dir
    export root_dir="\$grandparent_dir"

    mkdir -p \$grandparent_dir/
    grep "READ COUNT:" \$grandparent_dir/deHost/*/*.log > trim.stats.txt || true

    rsync -hvir --chmod=Dg=rwx,Fg=rwx deHost \$grandparent_dir/
    # create a symbolic link to the file in the grandparent directory to save space downstream

    rm deHost/${sample_id}/* || true
    ln -s \$grandparent_dir/deHost/${sample_id}/* deHost/${sample_id}/

    """
} 

process Kneaddata { 
    tag "Kneaddata on $sample_id"
    memory { 8.GB + 24.GB * task.attempt }
    cpus { task.attempt <= 3 ? 8 + (2 * task.attempt) : (4 * task.attempt) }
    time { task.attempt <= 3 ? (90.min * task.attempt) : (8.hour * task.attempt) }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

    input: 
    tuple val(sample_id), path(reads)
    path mousekneaddatadb
    path humankneaddatadb

    output: 
    tuple val(sample_id), path(reads), path("*${sample_id}*kneaddata.fastq.gz"), path("deHost/${sample_id}/*${sample_id}*_paired_1.fastq.gz"), path("deHost/${sample_id}/*${sample_id}*_paired_2.fastq.gz"), file("deHost/${sample_id}/*${sample_id}*_kneaddata.log"), path("deHost/${sample_id}/fastqc_files.tar.gz"), path("root_dir"), emit: knead_tuple
    tuple val(sample_id), path("deHost/${sample_id}/*${sample_id}*_kneaddata.log"), emit: kneaddata_log
    tuple val(sample_id), path("root_dir"), emit: root_dir 
    
    script: 
    """
    set -x

    actual_file_R1=\$(readlink -f "${reads[0]}")
    echo "The actual file is: \$actual_file_R1"
    actual_file_R2=\$(readlink -f "${reads[1]}")
    echo "The actual file is: \$actual_file_R2"

    mkdir -p deHost/${sample_id}/
    kneaddata \
    --input1 ${reads[0]} \
    --input2 ${reads[1]} \
    --reference-db ${mousekneaddatadb} \
    --reference-db ${humankneaddatadb} \
    --sequencer-source TruSeq3 \
    --trimmomatic-options="ILLUMINACLIP:TruSeq3-PE-2.fa:${params.ILLUMINACLIP_params}" \
    --trimmomatic-options="LEADING:3" \
    --trimmomatic-options="TRAILING:3" \
    --trimmomatic-options="SLIDINGWINDOW:4:15" \
    --trimmomatic-options="MINLEN:50" \
    --max-memory ${task.memory.toGiga() - 1} \
    --run-fastqc-start \
    --run-fastqc-end \
    --output \$PWD \
    --cat-final-output \
    -t ${task.cpus} ${params.trf == false ? "--bypass-trf" : ""} ${params.bmtagger == true ? "--bmtagger $params.bmtagger_db" : ""} 

    pigz --best *${sample_id}*kneaddata.fastq
    pigz --best *${sample_id}*_paired_1.fastq
    pigz --best *${sample_id}*_paired_2.fastq

    mv *${sample_id}*_kneaddata.log deHost/${sample_id}/
    mv *${sample_id}*_paired_1.fastq.gz deHost/${sample_id}/
    mv *${sample_id}*_paired_2.fastq.gz deHost/${sample_id}/
    tar -czvf fastqc_files.tar.gz fastqc/* 
    mv fastqc_files.tar.gz deHost/${sample_id}/


    actual_file_R1=\$(readlink -f "${reads[0]}")
    echo "The actual file is: \$actual_file_R1"
    actual_file_R2=\$(readlink -f "${reads[1]}")
    echo "The actual file is: \$actual_file_R2"

    # get the parent dir of the files 
    parent_dir=\$(dirname "\$actual_file_R1")
    echo "The parent dir is: \$parent_dir"
    grandparent_dir=\$(dirname "\$parent_dir")
    echo "The grandparent dir is: \$grandparent_dir"
    echo "\$grandparent_dir" > root_dir
    export root_dir="\$grandparent_dir"

    mkdir -p \$grandparent_dir/
    grep "READ COUNT:" \$grandparent_dir/deHost/*/*.log > trim.stats.txt || true

    rsync -hvir --chmod=Dg=rwx,Fg=rwx deHost \$grandparent_dir/
    # create a symbolic link to the file in the grandparent directory to save space downstream

    rm deHost/${sample_id}/* || true
    ln -s \$grandparent_dir/deHost/${sample_id}/* deHost/${sample_id}/

    """
} 


process kneaddata_qc { 
    tag "Storing logs kneaddata"
    memory 6.GB
    cpus 2
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

    input:
    tuple val(sample_id), path(kneaddata_log)

    output:
    path ("${sample_id}_kneaddata_QC_Chart.tsv")

    script:
    """
    printf "SampleID\tReadCountRawR1\tReadCountRawR2\tTrimmedReadCountR1\tTrimmedReadCountR2\tTrimmedReadCountUnmatchedR1\tTrimmedReadCountUnmatchedR2\tDeconHumanReadCountR1\tDeconHumanReadCountR2\tDeconMouseReadCountR1\tDeconMouseReadCountR2\tFinalReadCountR1\tFinalReadCountR2\tFinalUnmatchedReadCountR1\tFinalUnmatchedReadCountR2\n" > ${sample_id}_kneaddata_QC_Chart.tsv

    sample_id="${sample_id}"
    read_count_raw_R1=\$(grep "READ COUNT: raw pair1" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    read_count_raw_R2=\$(grep "READ COUNT: raw pair2" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    trimmed_read_count_R1=\$(grep "READ COUNT: trimmed pair1 : Total reads after trimming" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    trimmed_read_count_R2=\$(grep "READ COUNT: trimmed pair2 : Total reads after trimming" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    trimmed_read_count_unmatched_R1=\$(grep "READ COUNT: trimmed orphan1 : Total reads after trimming" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    trimmed_read_count_unmatched_R2=\$(grep "READ COUNT: trimmed orphan2 : Total reads after trimming" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    decon_human_read_count_R1=\$(grep "READ COUNT: decontaminated hg37dec_v0.1 pair1 : Total reads after removing those found in reference database" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    decon_human_read_count_R2=\$(grep "READ COUNT: decontaminated hg37dec_v0.1 pair2 : Total reads after removing those found in reference database" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    decon_mouse_read_count_R1=\$(grep "READ COUNT: decontaminated mouse_C57BL_6NJ pair1 : Total reads after removing those found in reference database" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    decon_mouse_read_count_R2=\$(grep "READ COUNT: decontaminated mouse_C57BL_6NJ pair2 : Total reads after removing those found in reference database" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    final_read_count_R1=\$(grep "READ COUNT: final pair1 : Total reads after merging results from multiple databases" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    final_read_count_R2=\$(grep "READ COUNT: final pair2 : Total reads after merging results from multiple databases" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    final_unmatched_read_count_R1=\$(grep "READ COUNT: final orphan1 : Total reads after merging results from multiple databases" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    final_unmatched_read_count_R2=\$(grep "READ COUNT: final orphan2 : Total reads after merging results from multiple databases" ${kneaddata_log} | awk -F': ' '{print \$NF}')
    
    echo "\$sample_id \$read_count_raw_R1 \$read_count_raw_R2 \$trimmed_read_count_R1 \$trimmed_read_count_R2 \$trimmed_read_count_unmatched_R1 \$trimmed_read_count_unmatched_R2 \$decon_human_read_count_R1 \$decon_human_read_count_R2 \$decon_mouse_read_count_R1 \$decon_mouse_read_count_R2 \$final_read_count_R1"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "\$sample_id" "\$read_count_raw_R1" "\$read_count_raw_R2" "\$trimmed_read_count_R1" "\$trimmed_read_count_R2" "\$trimmed_read_count_unmatched_R1" "\$trimmed_read_count_unmatched_R2" "\$decon_human_read_count_R1" "\$decon_human_read_count_R2" "\$decon_mouse_read_count_R1" "\$decon_mouse_read_count_R2" "\$final_read_count_R1" "\$final_read_count_R2" "\$final_unmatched_read_count_R1" "\$final_unmatched_read_count_R2" >> ${sample_id}_kneaddata_QC_Chart.tsv

    """
}
process shortbred_Prep { 
    tag "prepping $sample_id for shortbred"
    memory 32.GB
    cpus 8
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

    input: 
    tuple val(sample_id), path(reads), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from kneaddata output

    output: 
    tuple val(sample_id), path(reads), file(knead_cat_reads), file("${sample_id}_knead_cat.fasta"), path(root_dir) 

    script: 
    """
    seqtk seq -A ${knead_cat_reads} > ${sample_id}_knead_cat.fasta
    """
} 

process shortbred {
    tag "shortbred on $sample_id"
    memory 32.GB
    cpus 8
    container "docker://dfiuchicago/shotgun:shortbredv0.9.5"
    publishDir "${params.out}/shortbred", mode: 'copy'
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }

    input: 
    tuple val(sample_id), path(reads), file(knead_cat_reads), file(knead_cat_fasta), path(root_dir) 
    
    output:
    path ("shortBRED/*/${sample_id}*_shortBRED_results.txt")

    script: 
    """
    mkdir -p shortbred_tmp

    ### DB NAME MUST HAVE .faa EXTENSION ####
    micromamba deactivate
    micromamba activate -n shortbred

    marker_db_name=\$(basename CARD_protein_homolog_model_May_2025_ref_uniref90_markers.filt.95.faa .faa)
    mkdir -p shortBRED/\$marker_db_name

   
    shortbred_quantify.py \
        --markers /gpfs/data/dfi-cores/biobakery/databases/shortBRED/CARD_protein_homolog_model_May_2025_ref_uniref90_markers.filt.95.faa \
        --wgs ${knead_cat_fasta}  \
        --results shortBRED/\$marker_db_name/${sample_id}_\${marker_db_name}_shortBRED_results.txt \
        --tmp shortbred_tmp \
        --threads ${task.cpus} 

    marker_db_name=\$(basename NCBI_AMR_Jul_2025_ref_uniref90_markers.filt.95.faa .faa)
    mkdir -p shortBRED/\$marker_db_name
    shortbred_quantify.py \
        --markers /gpfs/data/dfi-cores/biobakery/databases/shortBRED/NCBI_AMR_Jul_2025_ref_uniref90_markers.filt.95.faa \
        --wgs ${knead_cat_fasta}  \
        --results shortBRED/\$marker_db_name/${sample_id}_\${marker_db_name}_shortBRED_results.txt \
        --tmp shortbred_tmp \
        --threads ${task.cpus} 

        
    marker_db_name=\$(basename NCBI_AMR_CARD_Aug_2025_dantas.ref_uniref90_markers.filt.95.faa .faa)
    mkdir -p shortBRED/\$marker_db_name
    shortbred_quantify.py \
        --markers /gpfs/data/dfi-cores/biobakery/databases/shortBRED/NCBI_AMR_CARD_Aug_2025_dantas.ref_uniref90_markers.filt.95.faa \
        --wgs ${knead_cat_fasta}  \
        --results shortBRED/\$marker_db_name/${sample_id}_\${marker_db_name}_shortBRED_results.txt \
        --tmp shortbred_tmp \
        --threads ${task.cpus} 


    cp shortbred_tmp/\$marker_db_name.faa.log shortBRED/\$marker_db_name

    grandparent_dir=\$(cat ${root_dir})

    mkdir -p \$grandparent_dir
    rsync -hvir --chmod=Dg=rwx,Fg=rwx shortBRED \$grandparent_dir/
    """
} 

process combined_keaddata_QC { 
    tag "combining kneaddata QC logs"
    memory 6.GB
    cpus 2
    errorStrategy 'terminate'
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    publishDir "${params.out}/kneaddata_qc", mode: 'copy'
    queue { selectQueue(task.memory, task.cpus) }

    input:
    path(kneaddata_log_list) // from kneaddata_qc output

    output:
    path ("combined_keaddata_QC.tsv")

    script:
    """
    # Define the list of TSV files
    tsv_file_string="${kneaddata_log_list}"

    read -a tsv_files <<< "\$tsv_file_string"

    # Get the first file
    first_file=\${tsv_files[0]}
    echo "First file: \$first_file"

    # Print the header from the first file
    sed -n '1p' \$first_file  > combined_keaddata_QC.tsv

    # Loop over each TSV file
    for tsv_file in "\${tsv_files[@]}"; do
        sed -n '2p' \$tsv_file  >> combined_keaddata_QC.tsv
    done
    
    pwd
    ls
    """
}

process Metaphlan { 
    tag "$sample_id with database: ${database}"
    time { task.attempt < 5 ? (90.min * task.attempt) : (8.hour * task.attempt) }
    memory { 48.GB + 4.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    cpus 8
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

    input: 
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from db_logging output
    val metaphlandb_folder
    val database

    output: 
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file("taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt"), val(database), file(kneaddata_log), path(fastqc_folder), path(root_dir), emit: meta_tuple
    path ("taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt"), emit: meta_tax_profile
    tuple val(sample_id), path("taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt"), path("taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt"), emit: meta_tax_profile_bowtie

    
    script: 
    """
    grandparent_dir=\$(cat ${root_dir})


    if [ -f \$grandparent_dir/taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome_gtdb.txt ]; then
        mkdir -p taxonomy/metaphlan/${params.params_label}
        echo "Prior analysis exists in target folder, skipping analysis."
        rsync -hpvir --no-times --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/taxonomy/metaphlan/${params.params_label}/${sample_id}*_profiled_metagenome.txt taxonomy/metaphlan/${params.params_label}/
    else
        mkdir -p taxonomy/metaphlan/${params.params_label}
        metaphlan ${knead_cat_reads} --input_type fastq \
        -t rel_ab_w_read_stats \
        --profile_vsc \
        -s taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}.sam.bz2 \
        --vsc_out taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}.vsc.txt \
        --mapout taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}.bowtie2.bz2 \
        --index ${database} \
        --db_dir $metaphlandb_folder/${database}/ \
        --stat_q ${params.stat_q} \
        --nproc ${task.cpus} -o taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt

        if [ ! -s \$grandparent_dir/taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome_gtdb.txt ]; then
            echo "Converting Metaphlan species to GTDB"
            ${params.sgb2gtdb} -i taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt -o taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome_gtdb.txt -d ${params.metaphlan_db}
        fi

        samfile="taxonomy/metaphlan/${params.params_label}/${sample_id}.sam"
        vsc_out="taxonomy/metaphlan/${params.params_label}/${sample_id}.vsc.txt"
        bowtie2out="taxonomy/metaphlan/${params.params_label}/${sample_id}.bowtie2.bz2"
        bamfile="\${samfile%.sam}.bam"
        temp_bam="\${bamfile}.temp"

        rm \$grandparent_dir/\$vsc_out || true
        rm \$grandparent_dir/\$bowtie2out || true
        rm \$grandparent_dir/\$samfile || true
        rm \$grandparent_dir/\${samfile%.sam}.bam || true
        rm \$grandparent_dir/\${samfile%.sam}.bai || true
    fi
    grandparent_dir=\$(cat ${root_dir})
    mkdir -p \$grandparent_dir

    rsync -hvir --chmod=Dg=rwx,Fg=rwx taxonomy \$grandparent_dir
    """
}

process Combine_metaphlan {

    tag "Combining Metaphlan results"
    memory 16.GB
    cpus 4
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    publishDir "${params.out}/taxonomy", mode: 'copy'
    queue { selectQueue(task.memory, task.cpus) }

    input:
    file(meta_tax_profile)

    output:
    path ("combined_metaphlan.csv")
    
    script:
    """
        current_date=\$(date +"%Y-%m-%d_%H-%M-%S")
        mkdir -p ${params.out}/${params.params_label}/
        python ${params.combine_metaphlan_results} ${meta_tax_profile} combined_metaphlan.csv
    """
}

process HUMAnN { 
    tag "HUMAnN on cat reads for $sample_id"
    cpus { task.attempt < 2 ? 2 : task.attempt <= 3 ? Math.min(5 + (3 * task.attempt), 32) : Math.min((4 * task.attempt), 32) }
    memory { task.attempt < 2 ? 2.GB : 48.GB + 24.GB * task.attempt }
    time { task.attempt < 2 ? 20.min : task.attempt < 4 ? (90.min * task.attempt) : (2.hour * task.attempt)}
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    publishDir "${params.out}", mode: 'copy'
    maxRetries 9
    
    container { params.metaphlan_db == "mpa_vJun23_CHOCOPhlAnSGB_202403" ? "docker://dfiuchicago/shotgun:2.3" : "docker://dfiuchicago/shotgun:2.7_mamba" }
    // } else {
    //     container = "docker://dfiuchicago/shotgun:OlderDB"
    // }

        
    input: 
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file(meta_tax_profile), val(database), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from metaphlan meta_tuple

    output:
    path ("humann/${sample_id}/${params.params_label}/*.tsv")    

    script: 
    """
    grandparent_dir=\$(cat ${root_dir})
    if [ -f \$grandparent_dir/humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm_GO.tsv  ]; then
        echo "Prior analysis exists in target folder, skipping analysis."
        mkdir -p humann/${sample_id}/${params.params_label}
        rsync -hvir --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/humann/${sample_id}/${params.params_label}/* humann/${sample_id}/${params.params_label}/
    else
        echo "Starting analysis. No prior analysis not found in target folder."
        humann --version
        time \$(awk -F'\t' 'NR==1 {print \$1}' ${hash_metadata})
        echo "time is \$time"
        mkdir -p humann/${sample_id}/${params.params_label}

        humann \
            --threads ${task.cpus} \
            --nucleotide-database ${params.humann_nucleotide_db} \
            --protein-database ${params.humann_protein_db} \
            --input ${knead_cat_reads} \
            --verbose \
            --memory-use maximum \
            --taxonomic-profile ${meta_tax_profile} \
            --output-basename ${sample_id}_${params.params_label} \
            --remove-temp-output \
            --output humann/${sample_id}/${params.params_label} --threads ${task.cpus} \
            --resume \
            -v

        ## humann \
        ##     --threads ${task.cpus} \
        ##     --nucleotide-database ${params.humann_nucleotide_db} \
        ##     --protein-database ${params.humann_protein_db} \
        ##     --input ${knead_cat_reads} \
        ##     --verbose \
        ##     --memory-use maximum \
        ##     --taxonomic-profile ${meta_tax_profile} \
        ##     --output-basename ${sample_id}_${params.params_label} \
        ##     --remove-temp-output \
        ##     --output humann/${sample_id}/${params.params_label} --threads ${task.cpus} \
        ##     --pathways unipathway \
        ##     --resume \
        ##     -v

        echo "Renormalizing gene families to CPM"
        humann_renorm_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies.tsv \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm.tsv \
            --units cpm \
            --update-snames


        echo "Renormalizing path abundance to CPM"
        humann_renorm_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_pathabundance.tsv \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_pathabundance-cpm.tsv \
            --units cpm \
            --update-snames

        echo "Converting gene families to KEGG Orthologs"
        humann_regroup_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm.tsv \
            -c /gpfs/data/dfi-cores/biobakery/databases/humann/utility_mapping/utility_mapping/map_ko_uniref90.txt.gz \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm_KO.tsv 

        echo "Converting gene families to Level4 EC"
        humann_regroup_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm.tsv \
            -c /gpfs/data/dfi-cores/biobakery/databases/humann/utility_mapping/utility_mapping/map_level4ec_uniclust90.txt.gz \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm_level4EC.tsv 

        echo "Converting gene families to GO terms"
        humann_regroup_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm.tsv \
            -c /gpfs/data/dfi-cores/biobakery/databases/humann/utility_mapping/utility_mapping/map_go_uniref90.txt.gz \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm_GO.tsv 

        grandparent_dir=\$(cat ${root_dir})

        mkdir -p \$grandparent_dir
        rsync -hvir --chmod=Dg=rwx,Fg=rwx humann \$grandparent_dir
    fi
    """
} 

process BAQLaVa { 
    tag "BAQLaVa on cat reads for $sample_id"
    cpus 12
    memory { 34.GB + 8.GB * task.attempt }
    time { task.attempt < 5 ? (90.min * task.attempt) : (6.hour * task.attempt) }
    errorStrategy { task.attempt <= 6 ? 'retry' : 'ignore' }
    publishDir "${params.out}", mode: 'copy'
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

        
    input: 
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file(meta_tax_profile), val(database), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from metaphlan meta_tuple

    output:
    path ("taxonomy/baqlava/${sample_id}/${params.params_label}/*_BAQLaVa_profile.txt")    

    script: 
    """
    grandparent_dir=\$(cat ${root_dir})
    echo "\$grandparent_dir"
    echo "${params.params_label}"
    flattened_name="${sample_id.replaceAll('[^a-zA-Z0-9_]', '_')}"
    echo "Flattened name is: \$flattened_name"
    meta_tax="\${flattened_name}_meta_tax.txt"
    cp $meta_tax_profile \$meta_tax
    mv $knead_cat_reads \${flattened_name}_knead_cat.fastq.gz
    knead_cat_reads=\${flattened_name}_knead_cat.fastq.gz
    mkdir -p taxonomy/baqlava/\${flattened_name}/${params.baqlava_params_label} || true

    if [ -f "\$grandparent_dir/taxonomy/baqlava/${sample_id}/${params.params_label}/*_BAQLaVa_profile.txt" ]; then
        echo "Prior analysis exists in target folder, skipping analysis."
        pigz -9 \$grandparent_dir/taxonomy/baqlava/${sample_id}/*/*.fa || true

        mkdir -p taxonomy/baqlava/${sample_id}/${params.params_label} || true
        rsync -hvir --no-times --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/taxonomy/baqlava/${sample_id}/${params.params_label}/* taxonomy/baqlava/${sample_id}/${params.params_label}/ || true
        mv \$knead_cat_reads $knead_cat_reads 
    else

        baqlava -i \$knead_cat_reads -o taxonomy/baqlava/\${flattened_name}/${params.baqlava_params_label} \
        --taxonomic-profile \$meta_tax \
        --threads ${task.cpus} \
        --nucdb /gpfs/data/dfi-cores/biobakery/databases/baqlava/data/BAQLaVa.V0.5.nucleotide \
        --protdb /gpfs/data/dfi-cores/biobakery/databases/baqlava/data/BAQLaVa.V0.5.protein
        mv taxonomy/baqlava/\${flattened_name} taxonomy/baqlava/${sample_id} || true
        mv taxonomy/baqlava/${sample_id}/${params.baqlava_params_label} taxonomy/baqlava/${sample_id}/${params.params_label} || true

        # check if there is uncompressed fa files and compress them
        if ls taxonomy/baqlava/${sample_id}/*/*.fa 1> /dev/null 2>&1; then
            pigz -9 \$grandparent_dir/taxonomy/baqlava/${sample_id}/*/*.fa || true
        fi
        mv \$knead_cat_reads $knead_cat_reads || true


        rsync -hvir --chmod=Dg=rwx,Fg=rwx taxonomy \$grandparent_dir
        pigz -9 \$grandparent_dir/taxonomy/baqlava/${sample_id}/*/*.fa || true
    fi
    """
} 


process kraken_bracken { 
    tag "kracken $sample_id with database: $krakendb"
    cpus 8
    memory { 64.GB + 24.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    publishDir "${params.out}", mode: 'copy'
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }
    
    input: 
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from db_logging output
    val krakendb

    output: 
    tuple path("taxonomy/readLevel/${sample_id}_report.txt"), path("taxonomy/readLevel/bracken/${sample_id}*.txt")

    script: 
    """
    mkdir -p taxonomy/readLevel/bracken

    micromamba deactivate
    micromamba activate -n old_tools
    
    kraken2 \
        --use-names \
        --confidence 0.1 \
        --report taxonomy/readLevel/${sample_id}_report.txt \
        --paired \
        -threads ${task.cpus} \
        --db $krakendb \
        --output taxonomy/readLevel/${sample_id}.standard.txt \
        $knead_paired_reads_1 $knead_paired_reads_2

    bracken \
        -d $krakendb \
        -i taxonomy/readLevel/${sample_id}_report.txt \
        -r 100 \
        -t 10 \
        -l S \
        -o taxonomy/readLevel/bracken/${sample_id}_report_species.txt

    bracken \
        -d $krakendb \
        -i taxonomy/readLevel/${sample_id}_report.txt \
        -r 100 \
        -t 10 \
        -l G \
        -o taxonomy/readLevel/bracken/${sample_id}_report_genus.txt

    bracken \
        -d $krakendb \
        -i taxonomy/readLevel/${sample_id}_report.txt \
        -r 100 \
        -t 10 \
        -l F \
        -o taxonomy/readLevel/bracken/${sample_id}_report_family.txt

    bracken \
        -d $krakendb \
        -i taxonomy/readLevel/${sample_id}_report.txt \
        -r 100 \
        -t 10 \
        -l O \
        -o taxonomy/readLevel/bracken/${sample_id}_report_order.txt

    bracken \
        -d $krakendb \
        -i taxonomy/readLevel/${sample_id}_report.txt \
        -r 100 \
        -t 10 \
        -l P \
        -o taxonomy/readLevel/bracken/${sample_id}_report_phylum.txt

    bracken \
        -d $krakendb \
        -i taxonomy/readLevel/${sample_id}_report.txt \
        -r 100 \
        -t 10 \
        -l C \
        -o taxonomy/readLevel/bracken/${sample_id}_report_class.txt
    
    grandparent_dir=\$(cat ${root_dir})
    mkdir -p \$grandparent_dir
    echo "Copying taxonomy files to \$grandparent_dir"
    rsync -hvir --chmod=Dg=rwx,Fg=rwx taxonomy \$grandparent_dir
    """
} 



// META DATA PROCESSES //

process Database_log_calc { // update with the new metaphlan and humann dbs
    cpus 2
    memory 8.GB
    queue { selectQueue(task.memory, task.cpus) }
    time { 10.min * task.attempt }

    output:
    tuple path("DBValues.tsv"), path("time.txt")
    /* if this breaks take out -P 8 from  xargs -0 -P 8 md5sum */
    script: 
    """
    time=\$(date +"%Y-%m-%d_%H-%M-%S")
    echo \$time > time.txt
    find ${params.mousekneaddatadb}/ -type f -print0 | sort -z | xargs -0 -P 8 md5sum | awk '{print \$1}' | md5sum | awk -v dir=${params.mousekneaddatadb}/ '{print \$1 "	" dir}' >> DBValues.tsv
    find ${params.humankneaddatadb}/ -type f -print0 | sort -z | xargs -0 -P 8 md5sum | awk '{print \$1}' | md5sum | awk -v dir=${params.humankneaddatadb}/ '{print \$1 "	" dir}' >> DBValues.tsv
    echo -e "test_value\tcontainer" >> DBValues.tsv
    find ${params.metaphlandb_folder}/${params.metaphlan_db}/ -type f -print0 | sort -z | xargs -0 -P 8 md5sum | awk '{print \$1}' | md5sum | awk -v dir=${params.metaphlandb_folder}/${params.metaphlan_db}/ '{print \$1 "\t" dir}' >> DBValues.tsv
    find ${params.humann_nucleotide_db}/ -type f -print0 | sort -z | xargs -0 -P 8 md5sum | awk '{print \$1}' | md5sum | awk -v dir=${params.humann_nucleotide_db}/ '{print \$1 "	" dir}' >> DBValues.tsv
    find ${params.humann_protein_db}/ -type f -print0 | sort -z | xargs -0 -P 8 md5sum | awk '{print \$1}' | md5sum | awk -v dir=${params.humann_protein_db}/ '{print \$1 "	" dir}' >> DBValues.tsv
    """
}
process DB_Add { 
    tag "Adding contigs for $sample_id to database"
    maxForks 1
    cpus 4
    memory 16.GB
    container "docker://dfiuchicago/shotgun:2.7_mamba"

    input: 
    tuple val(sample_id), path(reads), path(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(megahit_contigs) // from megahit.tuple
    

    output:
    tuple val(sample_id), path(reads), path(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log)


    script:
    """
    time \$(awk -F'\t' 'NR==1 {print \$1}' ${hash_metadata})

    mkdir -p ${params.out}/blastDB/all_contigs_from_\$time
    output_file="${params.out}/blastDB/all_contigs_from_\$time/database_megahit.fa"

    while IFS= read -r line
    do
        if [[ \$line == ">"* ]]; then
            echo ">${sample_id} | \${line:1}" >> \$output_file
        else
            echo "\$line" >> \$output_file
        fi
    done < ${megahit_contigs}
    """
}
process Database_logging {
    tag "Kneaddata logging $sample_id" /* this process hashes the databases that were used for kneaddata and metaphlan, this will be compared to a table of our DB hashes to confirm our DB hasn't changed */
    cpus 2
    memory 8.GB
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }



    input: 
    tuple val(sample_id), path(reads), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir)
    tuple path(database_log_calc), path(time)

    output: 
    tuple val(sample_id), path(reads), path("*.md5"), file(knead_cat_reads), path(knead_paired_reads_1), path(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir)

    script: 
    """
    cat ${time} > ${sample_id}.md5
    echo -e '${sample_id}' >> ${sample_id}.md5 
    md5sum ${reads[0]} ${reads[1]} | awk '{print \$1 "\t" \$2}' >> ${sample_id}.md5
    cat ${database_log_calc} >> ${sample_id}.md5
    """
}



// CONTIG PROCESSES // GENOME ASSEMBLY & QC //

process Megahit { 
    tag "Megahit on reads for $sample_id"
    cpus 16
    time { task.attempt < 5 ? (90.min * task.attempt) : (6.hour * task.attempt) }
    memory { 64.GB + 8.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }



    input: 
    tuple val(sample_id), path(reads), path(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // database_logging_ch output

    output: 
    tuple val(sample_id), path(reads), path(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path("${sample_id}_megahit_contig.tar.gz"), path(fastqc_folder), emit: megahit_tuple
    tuple val(sample_id), path("contigs/megahit/${sample_id}.contigs.fa"), path(root_dir),  emit: contig_file
    tuple val(sample_id), path("${sample_id}_megahit_contig.tar.gz"), emit: contig_folders

    script: 
    """
    mkdir -p contigs/megahit

    ### this command breaks if the output directory already exists, so we need to remove it first
    megahit \
        -1 ${knead_paired_reads_1} \
        -2 ${knead_paired_reads_2} \
        -t ${task.cpus} \
        --out-prefix ${sample_id} \
        -o ${sample_id}_megahit/

    mv ${sample_id}_megahit/${sample_id}.contigs.fa contigs/megahit
    tar -cf - ${sample_id}_megahit/ | pigz > ${sample_id}_megahit.tar.gz
    mv ${sample_id}_megahit.tar.gz contigs/megahit
    tar -cf - contigs/ | pigz > ${sample_id}_megahit_contig.tar.gz

    grandparent_dir=\$(cat ${root_dir})
    mkdir -p \$grandparent_dir
    rsync -hvir --chmod=Dg=rwx,Fg=rwx contigs \$grandparent_dir
    pigz -f \$grandparent_dir/contigs/megahit/${sample_id}.contigs.fa 
    """
}
process Quast { 
    tag "Quast on reads for $sample_id"
    memory { 64.GB + 8.GB * task.attempt }
    cpus 8
    errorStrategy { task.attempt <= 6 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }


    input: 
    tuple val(sample_id), path(contigs), path(root_dir) // from emit: megahit.contig_file
    
    output: 
    tuple val(sample_id), path("${sample_id}_quast_contigs.tar.gz") // final megahits/quast output tar.gz


    script: 
    """
    mkdir -p megahit/quast
    quast.py ${contigs} \
        --no-plots \
        --no-html \
        --no-icarus \
        -o megahit/quast/${sample_id} \
        -t ${task.cpus}
    tar cf - megahit/ | pigz > ${sample_id}_quast_contigs.tar.gz

    grandparent_dir=\$(cat ${root_dir})
    mkdir -p \$grandparent_dir
    rsync -hvir --chmod=Dg=rwx,Fg=rwx megahit \$grandparent_dir
    """
}

// GENE PREDICTION & ANNOTATION //

process Prodigal {
    tag "Prodigal on contigs for $sample_id"
    memory { 24.GB + 8.GB * task.attempt }
    errorStrategy { task.attempt <= 6 ? 'retry' : 'ignore' }
    cpus 8
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

    input:
    tuple val(sample_id), path(contigs), path(root_dir) // from emit: megahit.contig tuple

    output:
    tuple val(sample_id), path(contigs), path("${sample_id}.pr"), path("${sample_id}.fna"), path("${sample_id}.faa"), path(root_dir), emit: prodigal_tuple  // to emapper contigs, gbk file, nucleotide mrna file, amino acid protein file, summary file
    tuple val(sample_id), path("${sample_id}_prodigal_contigs.tar.gz"), emit: prodigal_folders // final contigs/prodigal output tar.gz
    
    script: 
    """
    grandparent_dir=\$(cat ${root_dir})

    micromamba deactivate
    micromamba activate -n annotation

    # check for existing prodigal output
    if [ -f \$grandparent_dir/contigs/prodigal/${sample_id}.faa ] || [ -f \$grandparent_dir/contigs/prodigal/${sample_id}.faa.gz ]; then
        echo "Prodigal output already exists for ${sample_id}, skipping prodigal step."
        mkdir -p contigs/prodigal/
        rsync -hvir --no-times --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/contigs/prodigal/${sample_id}* contigs/prodigal/
        
        pigz -df -7 contigs/prodigal/${sample_id}*.{faa.gz,fna.gz,pr.gz} || true  
        mv contigs/prodigal/${sample_id}*.{faa,fna,pr} .
        pigz -f -7 \$grandparent_dir/contigs/prodigal/${sample_id}*.{faa,fna,pr} || true
        tar cf - contigs | pigz > ${sample_id}_prodigal_contigs.tar.gz

    else
        echo "No existing prodigal output found for ${sample_id}, running prodigal."
        mkdir -p contigs/prodigal/   
        prodigal -i ${contigs} \
            -c -m -p meta \
            -o contigs/prodigal/${sample_id}.pr \
            -d contigs/prodigal/${sample_id}.fna \
            -a contigs/prodigal/${sample_id}.faa 

        cp contigs/prodigal/${sample_id}* .

        tar cf - contigs | pigz > ${sample_id}_prodigal_contigs.tar.gz

        mkdir -p \$grandparent_dir
        rsync -hvir --chmod=Dg=rwx,Fg=rwx contigs \$grandparent_dir
        pigz -f -7 \$grandparent_dir/contigs/prodigal/${sample_id}*.{faa,fna,pr} || true
    fi
    """
}



process AMRfinder {
    tag "AMRfinder on contigs for $sample_id"
    cpus 8
    queue { selectQueue(task.memory, task.cpus) }
    memory { 32.GB + 8.GB * task.attempt }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

    
    input:
    tuple val(sample_id), path(contigs), path(protein_coding_genes), path(mrna_file), path(protein_file), path(root_dir) // from Prodigal_tuple

    output:
    tuple val(sample_id), path("${sample_id}_contigs_amrfinder.tar.gz") // from Prodigal

    script: 
    """
    mkdir -p contigs/amrfinder/
    grandparent_dir=\$(cat ${root_dir})

    micromamba deactivate
    micromamba activate -n amr_analysis

    # check for existing amrfinder output
    if [ -f \$grandparent_dir/contigs/amrfinder/${sample_id}.amr.out ]; then
        echo "AMRfinder output already exists for ${sample_id}, skipping AMRfinder step."
        mkdir -p contigs/amrfinder
        rsync -hvir --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/contigs/amrfinder/${sample_id}* contigs/amrfinder
        tar cf - contigs | pigz > ${sample_id}_contigs_amrfinder.tar.gz
    else
        echo "No existing AMRfinder output found for ${sample_id}, running AMRfinder."
        
        amrfinder -p ${protein_file} \
            --threads ${task.cpus} > contigs/amrfinder/${sample_id}.amr.out

        tar cf - contigs | pigz > ${sample_id}_contigs_amrfinder.tar.gz

        grandparent_dir=\$(cat ${root_dir})
        mkdir -p \$grandparent_dir
        rsync -hvir --chmod=Dg=rwx,Fg=rwx contigs \$grandparent_dir
    fi
    """
}

process  Resistance_Gene_Identifier {
    tag "emapper on contigs for $sample_id"
    cpus 8
    queue { selectQueue(task.memory, task.cpus) }
    memory { 32.GB + 8.GB * task.attempt }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

    
    input:
    tuple val(sample_id), path(contigs), path(protein_coding_genes), path(mrna_file), path(protein_file), path(root_dir) // from Prodigal_tuple

    output:
    tuple val(sample_id), path("${sample_id}_contigs_rgi.tar.gz") // from Prodigal

    script: 
    """
    mkdir -p contigs/rgi/
    grandparent_dir=\$(cat ${root_dir})

    micromamba deactivate
    micromamba activate -n amr_analysis

    # check for existing emapper output
    if [ -f \$grandparent_dir/contigs/rgi/${sample_id}.rgi.* ]; then
        echo "RGI output already exists for ${sample_id}, skipping RGI step."
        mkdir -p contigs/rgi
        rsync -hvir --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/contigs/rgi/${sample_id}* contigs/rgi
        pigz -f -7 \$grandparent_dir/contigs/rgi/${sample_id}* || true
        tar cf - contigs | pigz > ${sample_id}_contigs_rgi.tar.gz
    else
        echo "No existing RGI output found for ${sample_id}, running RGI."
        
        rgi main \
            --input_sequence ${protein_file} \
            --output_file contigs/rgi/${sample_id}.rgi \
            --include_loose \
            -t protein -n ${task.cpus} --clean

        tar cf - contigs | pigz > ${sample_id}_contigs_rgi.tar.gz

        pigz -f -7 contigs/rgi/${sample_id}*
        mkdir -p \$grandparent_dir
        rsync -hvir --chmod=Dg=rwx,Fg=rwx contigs \$grandparent_dir
    fi
    """
}

process Emapper {
    tag "emapper on contigs for $sample_id"
    cpus 8
    queue { selectQueue(task.memory, task.cpus) }
    memory { 32.GB + 8.GB * task.attempt }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }

    
    input:
    tuple val(sample_id), path(contigs), path(protein_coding_genes), path(mrna_file), path(protein_file), path(root_dir) // from Prodigal_tuple

    output:
    tuple val(sample_id), path("${sample_id}_contigs_emapper.tar.gz") // from Prodigal

    script: 
    """
    mkdir -p contigs/emapper/
    grandparent_dir=\$(cat ${root_dir})

    micromamba deactivate
    micromamba activate -n annotation

    # check for existing emapper output
    if [ -f \$grandparent_dir/contigs/emapper/${sample_id}.emapper.annotations ]; then
        echo "emapper output already exists for ${sample_id}, skipping emapper step."
        mkdir -p contigs/emapper
        rsync -hvir --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/contigs/emapper/${sample_id}* contigs/emapper
        tar cf - contigs | pigz > ${sample_id}_contigs_emapper.tar.gz
    else
        echo "No existing emapper output found for ${sample_id}, running emapper."
        
        emapper.py \
            -i ${protein_file} \
            --cpu ${task.cpus} \
            --output contigs/emapper/${sample_id} \
            -m diamond \
            --data_dir ${params.emapper_protein_db} 

        tar cf - contigs | pigz > ${sample_id}_contigs_emapper.tar.gz

        grandparent_dir=\$(cat ${root_dir})
        mkdir -p \$grandparent_dir
        rsync -hvir --chmod=Dg=rwx,Fg=rwx contigs \$grandparent_dir
    fi
    """
}
process prokka_wgs { 
    tag "Prokka Gene Annotation for $sample_id"
    cpus 16
    memory { 64.GB + 8.GB * task.attempt }
    queue { selectQueue(task.memory, task.cpus) }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    publishDir "${params.out}", mode: 'copy'



    input: 
    tuple val(sample_id), path(reads)
    output: 
    tuple val(sample_id), path(reads), path("contigs/prokka/$sample_id") // final prokka output folder


    script: 
    """

    mkdir -p contigs/prokka/$sample_id

    micromamba activate
    micromamba activate -n old_tools

    prokka --version

    prokka \
        --compliant \
        --kingdom \
        --addgenes \
        --cpus ${task.cpus} \
        --outdir contigs/prokka/$sample_id \
        --prefix ${sample_id} \
        ${reads}
    """
}
process bakta_wgs { 
    tag "Bakta Gene Annotation for $sample_id"
    cpus 4
    memory { 8.GB + 16.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    // container = "docker://dfiuchicago/shotgun:2.2.0-beta"
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    // container = "docker://yingeddi2008/bakta-full:0.1" nmendozam/gutsmash
    publishDir "${params.out}", mode: 'copy', overwrite: true

    input: 
    tuple val(sample_id), path(contigs)

    output: 
    tuple val(sample_id), path("contigs/${sample_id}/bakta") // final prokka output folder


    script: 
    """
    micromamba deactivate
    micromamba activate -n old_tools

    mkdir -p contigs/$sample_id/bakta

    bakta --version

    bakta \
        --db /gpfs/data/dfi-cores/biobakery/databases/bakta/db_v6xx/db \
        --verbose \
        --compliant \
        --output contigs/$sample_id/bakta \
        --prefix $sample_id \
        --keep-contig-headers \
        --force \
        --threads ${task.cpus} \
        $contigs
    """
}


process gutsmash_wgs {
    tag "Gutsmash Gene Annotation for $sample_id"
    cpus 4
    queue { selectQueue(task.memory, task.cpus) }
    containerOptions "--writable-tmpfs --cleanenv  -B /gpfs/data/dfi-cores/biobakery/databases/gutsmash:/usr/share/gutsmash:rw" 
    memory { 8.GB + 8.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    publishDir "${params.out}", mode: 'copy', overwrite: true

    input: 
    tuple val(sample_id), path(bakta_annotation_folder) // from bakta_wgs

    output:
    tuple val(sample_id), path("contigs/${sample_id}/gutsmash") // final prokka output folder

    script: 
    """
    micromamba deactivate
    micromamba activate -n gutsmash
    
    mkdir -p contigs/$sample_id/gutsmash
    run_gutsmash.py --help
    run_gutsmash.py --check-prereqs
    run_gutsmash.py \
        -c ${task.cpus} \
        --cb-knownclusters \
        --smcog-trees \
        --genefinding-gff3 $bakta_annotation_folder/${sample_id}.gff3 \
        --enable-genefunctions $bakta_annotation_folder/${sample_id}.fna 

    cp -r $sample_id/* contigs/$sample_id/gutsmash

    """
}


process antismash_wgs {
    tag "Antismash Gene Annotation for $sample_id"
    cpus 4
    queue { selectQueue(task.memory, task.cpus) }
    containerOptions "--writable-tmpfs --cleanenv " // try '--cleanenv' flag if this doesnt work
    memory { 8.GB + 8.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    publishDir "${params.out}", mode: 'copy', overwrite: true

    input: 
    tuple val(sample_id), path(bakta_annotation_folder) // from bakta_wgs

    output:
    tuple val(sample_id), path("contigs/${sample_id}/antismash") // final prokka output folder

    script: 
    """
    micromamba deactivate
    micromamba activate -n annotation

    mkdir -p contigs/$sample_id/antismash
    antismash --help
    antismash \
        -c ${task.cpus} \
        -t bacteria \
        --cb-knownclusters \
        --cb-subclusters \
        --cb-general \
        --smcog-trees \
        --genefinding-gff3 $bakta_annotation_folder/${sample_id}.gff3 \
        --enable-genefunctions $bakta_annotation_folder/${sample_id}.fna

    cp -r $sample_id/* contigs/$sample_id/antismash

    """
}

process pyrodigal_wgs {
    tag "Prodigal on contigs for $sample_id"
    memory { 24.GB + 8.GB * task.attempt }
    queue { selectQueue(task.memory, task.cpus) }
    errorStrategy { task.attempt <= 3 ? 'retry' : 'ignore' }
    cpus 4
    container "docker://dfiuchicago/shotgun:2.2.0-beta"
    publishDir "${params.out}", mode: 'copy', overwrite: true

    input:
    tuple val(sample_id), path(contigs) // from emit: megahit.contig tuple

    output:
    tuple val(sample_id), path("contigs/${sample_id}/prodigal/${sample_id}.faa")
    // tuple val(sample_id), path(contigs) // to emapper contigs, gbk file, nucleotide mrna file, amino acid protein file, summary file
    // tuple val(sample_id), path("contigs/prodigal/${sample_id}.pr"), path("contigs/prodigal/${sample_id}.fna"), path("contigs/prodigal/${sample_id}.faa") // final contigs/prodigal output tar.gz
    
    script: 
    """
    mkdir -p contigs/${sample_id}/prodigal/ 
    pyrodigal -i ${contigs} \
        -c -m -p meta -j ${task.cpus}\
        -o contigs/${sample_id}/prodigal/${sample_id}.pr \
        -d contigs/${sample_id}/prodigal/${sample_id}.fna \
        -a contigs/${sample_id}/prodigal/${sample_id}.faa 
    """
}
process emapper_wgs {
    tag "emapper on contigs for $sample_id"
    errorStrategy { task.attempt <= 3 ? 'retry' : 'ignore' }
    cpus 8
    memory { 32.GB + 8.GB * task.attempt }
    queue { selectQueue(task.memory, task.cpus) }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    publishDir "${params.out}", mode: 'copy', overwrite: true

    
    input:
    tuple val(sample_id), path(bakta_output_folder)

    output:
    tuple val(sample_id), path("contigs/${sample_id}/emapper") // from Bakta

    script: 
    """
    micromamba deactivate
    micromamba activate -n annotation

    # The output folder from bakta contains the gene predictions in fasta format
    gene_predictions=$bakta_output_folder/${sample_id}.faa

    mkdir -p contigs/${sample_id}/emapper/
    emapper.py \
        -i \$gene_predictions \
        --cpu ${task.cpus} \
        --output contigs/${sample_id}/emapper/${sample_id} \
        -m diamond \
        --data_dir ${params.emapper_protein_db} 
    """
}

process Sylph {
    tag "Sylph on reads for $sample_id"
    errorStrategy { task.attempt <= 3 ? 'retry' : 'ignore' }
    cpus 8
    memory { 32.GB + 8.GB * task.attempt }
    queue { selectQueue(task.memory, task.cpus) }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    publishDir "${params.out}", mode: 'copy', overwrite: true

    input:
    tuple val(sample_id), path(reads)
    path(reference_db)

    output:
    tuple val(sample_id), path("taxonomy/sylph/$sample_id/*") // from Bakta

    script: 
    """
    mkdir -p taxonomy/sylph/$sample_id

    mkdir -p samples


    sylph sketch -1 *_R1*.fastq{,.gz} -2 *_R2*.fastq{,.gz} -d samples -t ${task.cpus}
    sylph profile ${reference_db} samples/*.sylsp -t ${task.cpus} -o taxonomy/sylph/$sample_id/${sample_id}_results.tsv

    """
}



// DIAMOND PROCESSES  MOTIF SEARCHES //

process Diamond_Blauticin_LCA { 
    tag "diamond on deHost for $sample_id"
    memory { 32.GB + 4.GB * task.attempt }
    cpus 8
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }


    input:
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from kneaddata output

    output:
    tuple val(sample_id), path("${sample_id}_diamond_Blauticin_LCA.tar.gz") // final diamond output tar.gz
    
    script: 
    """
    micromamba deactivate
    micromamba activate -n gutsmash

    mkdir -p targeted/Blauticin_LCA/
    diamond blastx --threads ${task.cpus} \
        --db ${params.diamonddb_folder}/exDB/Blauticin_LCA \
        --sensitive \
        -q ${knead_cat_reads} \
        -o targeted/Blauticin_LCA/${sample_id}_cat_knead.card_bai.dmnd \
        --log \
        --outfmt 6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qlen slen

    pigz -7 targeted/Blauticin_LCA/${sample_id}_cat_knead.card_bai.dmnd

    tar cf - targeted | pigz > ${sample_id}_diamond_Blauticin_LCA.tar.gz

    grandparent_dir=\$(cat ${root_dir})
    mkdir -p \$grandparent_dir
    rsync -hvir --chmod=Dg=rwx,Fg=rwx targeted \$grandparent_dir
    """

}

process Diamond_card_bai {  
    tag "diamond on deHost for $sample_id"
    memory { 32.GB + 4.GB * task.attempt }
    cpus 8
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }


    input:
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from kneaddata output

    output:
    tuple val(sample_id), path("${sample_id}_diamond_card_bai.tar.gz") // final diamond output tar.gz
    script: 
    """
    micromamba deactivate
    micromamba activate -n gutsmash

    mkdir -p targeted/card_bai/
    diamond blastx --threads ${task.cpus} \
        --db ${params.diamonddb_folder}/diamondDB/card_bai \
        --sensitive -q ${knead_cat_reads} \
        -o targeted/card_bai/${sample_id}_cat_knead.card_bai.dmnd \
        --log \
        --outfmt 6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qlen slen

    pigz -7 targeted/card_bai/${sample_id}_cat_knead.card_bai.dmnd

    tar cf - targeted | pigz > ${sample_id}_diamond_card_bai.tar.gz

    grandparent_dir=\$(cat ${root_dir})
    mkdir -p \$grandparent_dir
    rsync -hvir --chmod=Dg=rwx,Fg=rwx targeted \$grandparent_dir
    """
}

process Diamond_cazyme {  
    tag "diamond on deHost for $sample_id"
    cpus 16
    memory { 32.GB + 4.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }


    input:
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from kneaddata output

    output:
    tuple val(sample_id), path("${sample_id}_diamond_cazymeDB.tar.gz") // final diamond output tar.gz
    script: 
    """

    micromamba deactivate
    micromamba activate -n gutsmash

    mkdir -p targeted/cazyme/
    diamond blastx --threads ${task.cpus} \
        --db ${params.diamonddb_folder}/cazymeDB/CAZyDB.07312020 \
        --sensitive \
        -q ${knead_cat_reads} \
        -o targeted/cazyme/${sample_id}_cat_knead.cazyme.dmnd \
        --log \
        --outfmt 6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qlen slen

    pigz -7 targeted/cazyme/${sample_id}_cat_knead.cazyme.dmnd

    tar cf - targeted | pigz > ${sample_id}_diamond_cazymeDB.tar.gz

    grandparent_dir=\$(cat ${root_dir})
    mkdir -p \$grandparent_dir
    rsync -hvir --chmod=Dg=rwx,Fg=rwx targeted \$grandparent_dir
    """
}

process Diamond_VFDB {  
    tag "VFDB diamond $sample_id"
    memory { 32.GB + 4.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    cpus 8
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }


    input:
    tuple val(sample_id), path(reads), file(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // from kneaddata output

    output:
    tuple val(sample_id), path("${sample_id}_diamond_VFDB.tar.gz") // final diamond output tar.gz
    script: 
    """

    micromamba deactivate
    micromamba activate -n gutsmash

    mkdir -p targeted/VFDB/
    diamond blastx \
        --threads ${task.cpus} \
        --db ${params.diamonddb_folder}/VFDB/VFDB_setB_pro \
        --sensitive \
        -q ${knead_cat_reads} \
        -o targeted/VFDB/${sample_id}_cat_knead.VFDB.dmnd \
        --log \
        --outfmt 6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qlen slen


    pigz -7 targeted/VFDB/${sample_id}_cat_knead.VFDB.dmnd

    tar cf - targeted | pigz > ${sample_id}_diamond_VFDB.tar.gz
    grandparent_dir=\$(cat ${root_dir})
    mkdir -p \$grandparent_dir
    rsync -hvir --chmod=Dg=rwx,Fg=rwx targeted \$grandparent_dir
    """

}
process prep_for_download {

    tag "Preparing for download"
    memory { 4.GB + 4.GB * task.attempt }
    cpus 1
    queue { selectQueue(task.memory, task.cpus) }


    script:
    """
    mkdir -p results
    mv ${params.out}/* results
    zip -r results.zip results
    """
}



workflow {

    if(params.megahit == 'database') { // if the user wants to use megahit on each sample and turn it into one megahit database
        Channel
            .fromFilePairs("${params.rawreads}/*_R{1,2}*.fastq{,.gz}", checkIfExists:true)
            .set{read_pairs_ch}
        read_pairs_ch.view()
        knead_ch = Kneaddata(read_pairs_ch, params.mousekneaddatadb, params.humankneaddatadb) 
        knead_ch.knead_tuple.view()
        database_log_calc_ch = Database_log_calc()
        database_logging_ch = Database_logging(knead_ch.knead_tuple, database_log_calc_ch)
        database_logging_ch.view()
        megahit_ch = Megahit(database_logging_ch)
        final_megahit_ch = DB_Add(megahit_ch.megahit_tuple)
        // Megahit_DB_Move(final_megahit_ch.collect()) // build something to combine the contig files into one fasta file
    }
    
    if (params.dehost_input == true) {
        Channel
            .fromFilePairs("${params.rawreads}/*_kneaddata_paired_{1,2}.fastq.gz", checkIfExists:true)
            .set{read_pairs_ch}
        // modify the tuple so the sample id only contains the string before ${sample_id.split('_R1')[0]}
        read_pairs_ch = read_pairs_ch.map { tuple ->
            // Replace '_R1' and any text following it with an empty string
            def sample_id = tuple[0].toString().replaceAll(/_R1.*/, "")
            return [sample_id] + tuple[1..-1]
        }

        if (params.biobakery_only == true) {
            if (params.metaphlan_analysis == true) {

                meta_ch = Metaphlan_deHost(read_pairs_ch, params.metaphlan_db)
                combine_metaphlan_ch = Combine_metaphlan(meta_ch.meta_tax_profile.collect())
            }
            if (params.shortBRED == true) {
                shortbred_prep_ch = shortbred_Prep_dehost(meta_ch.meta_tuple)
                shortbred_prep_ch.view()
                shortbred_ch = shortbred_dehost(shortbred_prep_ch)
            }
            if (params.humann == true && params.metaphlan_db != "mpa_vJan25_CHOCOPhlAnSGB_202503") {
                humann_ch = HUMAnN_deHost(meta_ch.meta_tuple) 
                BAQLaVa_dehost(meta_ch.meta_tuple)
            } 
        
        } else { // replicate the workflow from below without the kneaddata process
            
            // get the root dir for the dehosted reads
            root_dir_ch = read_pairs_ch.map { tuple ->
                def path = tuple[1][1].toString()
                def basefolder = path.tokenize('/')[0..-3].join('/')
                return basefolder
            }
            // modify the tuple to have place holders for the following values:
            //   tuple val(sample_id), path(reads), path(hash_metadata), file(knead_cat_reads), file(knead_paired_reads_1), file(knead_paired_reads_2), file(kneaddata_log), path(fastqc_folder), path(root_dir) // database_logging_ch output

            megahit_ch = Megahit_dehost(read_pairs_ch)
            quast_ch = Quast(megahit_ch.contig_file)
            if (params.prodigal_analysis == true) {
                prodigal_ch = Prodigal(megahit_ch.contig_file)
                emapper_ch = Emapper(prodigal_ch.prodigal_tuple)
            }
            if (params.resistance_genes == true) {
                rgi_ch = Resistance_Gene_Identifier(prodigal_ch.prodigal_tuple)
                amrfinder_ch = AMRfinder(prodigal_ch.prodigal_tuple)
            }
        }

    } else {

        // new stuff // 
        if (params.clinical_rename == true) { // this is a new feature that renames the sampleid and fastqs to fit the clinical sample id naming convention
            Channel
                .fromFilePairs("${params.rawreads}/*_R{1,2}*.fastq{,.gz}", checkIfExists:true)
                .view{}
                .set{read_pairs_ch}
            // read_pairs_ch.view()
            read_pairs_ch = read_pairs_ch.map { tuple ->
                def firstElement = tuple[0].toString().toUpperCase()
                def path = tuple[1][1].toString()
                println "current first element: ${tuple[0]}"
                println "current second element: ${tuple[1]}"
                
                if (firstElement.contains("_CLIN_SSG_") || firstElement.contains("_CLIN_DSG_")) {
                    // pulling out the base name //
                    firstElement = firstElement.split("/").last()
                    // take everything before the last _S to remove the sequencing run info //
                    def lastElementIndex = firstElement.lastIndexOf('_S')
                    firstElement = firstElement.substring(0, lastElementIndex)
                    println "first element after removing _S info: ${firstElement}"
                    // firstElement = firstElement.tokenize('_').take(6).join('_')
                    // println "new first element: ${firstElement}"
                    firstElement = firstElement.toUpperCase()
                    def newSampleId = firstElement

                    // adding the rename path to the tuple //
                    println "current path: ${path}"

                    def basefolder = path.tokenize('/')[0..-3].join('/')

                    // beforeLastSlash = path.substring(0, lastSlashIndex)
                    // basefolder = beforeLastSlash.substring(0, lastSlashIndex)
                    def newpath = '/' + basefolder + "/" + "renamed"
                    println "new path: ${newpath}"

                    def newSampleIdTuple = [newSampleId] + tuple[1..-1] + [newpath]
                    return newSampleIdTuple
                } else {
                    return tuple
                }
            } 

        read_pairs_ch.view()

        clean_ch = clinical_rename(read_pairs_ch)
        read_pairs_ch = clean_ch.map { tuple ->
            def newSampleId = tuple[0]
            def newtuple = [newSampleId, [tuple[1], tuple[2]]]
            println "Old tuple: $tuple"
            println "New tuple: $newtuple"
            return newtuple
                }

        // read_pairs_ch.view()
        } else {
            Channel
                .fromFilePairs("${params.rawreads}/*_R{1,2}*.fastq{,.gz}", checkIfExists:true, followLinks:false)
                .set{read_pairs_ch}
        }
        
        knead_ch = Kneaddata(read_pairs_ch, params.mousekneaddatadb, params.humankneaddatadb)
        qc_list_ch = kneaddata_qc(knead_ch.kneaddata_log)
        combined_keaddata_QC(qc_list_ch.collect())

        if (params.biobakery_only == true) {
            database_log_calc_ch = Database_log_calc()
            database_logging_ch = Database_logging(knead_ch.knead_tuple, database_log_calc_ch)
            meta_ch = Metaphlan(database_logging_ch, params.metaphlandb_folder, params.metaphlan_db)
            if (params.humann == true && params.metaphlan_db != "mpa_vJan25_CHOCOPhlAnSGB_202503") {
                humann_ch = HUMAnN(meta_ch.meta_tuple)
                if (params.baqlava == true) {
                    BAQLaVa(meta_ch.meta_tuple)
                }

            }
            combine_metaphlan_ch = Combine_metaphlan(meta_ch.meta_tax_profile.collect())

            if (params.shortBRED == true) {
                shortbred_prep_ch = shortbred_Prep(knead_ch.knead_tuple)
                shortbred_prep_ch.view()
                shortbred_ch = shortbred(shortbred_prep_ch)
            }
        
        }  else {

            knead_ch.knead_tuple.view()
            database_log_calc_ch = Database_log_calc()
            database_logging_ch = Database_logging(knead_ch.knead_tuple, database_log_calc_ch)
            if (params.metaphlan_analysis == true) {
                meta_ch = Metaphlan(database_logging_ch, params.metaphlandb_folder, params.metaphlan_db)
                if (params.metaphlan_analysis == true && meta_ch != null) {
                    combine_metaphlan_ch = Combine_metaphlan(meta_ch.meta_tax_profile.collect())
                }
                if (params.humann == true && params.metaphlan_db != "mpa_vJan25_CHOCOPhlAnSGB_202503") {
                    humann_ch = HUMAnN(meta_ch.meta_tuple)
                    if (params.baqlava == true) {
                        BAQLaVa(meta_ch.meta_tuple)
                    }
                }
            }


            // optional workflows //
            if (params.shortBRED == true) {
                shortbred_prep_ch = shortbred_Prep(knead_ch.knead_tuple)
                shortbred_prep_ch.view()
                shortbred_ch = shortbred(shortbred_prep_ch)
            }

            if (params.run_kraken == true) {
                kraken_ch = kraken_bracken(database_logging_ch, params.krakendb)
            }
            
            if (params.megahit_analysis == true || params.prodigal_analysis == true || params.diamond == true) {
                megahit_ch = Megahit(database_logging_ch)
                quast_ch = Quast(megahit_ch.contig_file)
                if (params.prodigal_analysis == true) {
                    prodigal_ch = Prodigal(megahit_ch.contig_file)
                    emapper_ch = Emapper(prodigal_ch.prodigal_tuple)
                }
                if (params.resistance_genes == true) {
                    rgi_ch = Resistance_Gene_Identifier(prodigal_ch.prodigal_tuple)
                    amrfinder_ch = AMRfinder(prodigal_ch.prodigal_tuple)
                }
                if (params.diamond == true) {
                    diamond_ch_Blauticin_LCA = Diamond_Blauticin_LCA(database_logging_ch)
                    diamond_ch_card_bai = Diamond_card_bai(database_logging_ch)
                    diamond_cazyme_ch = Diamond_cazyme(database_logging_ch)
                    diamond_VFDB_ch = Diamond_VFDB(database_logging_ch)
                }

            }
        }
    } 
}

workflow WGS {

    Channel
        .fromPath("${params.rawreads}")
        .set{contigs_ch}

    contigs_ch
        .map { file -> 
            def sampleName = file.baseName
            return tuple(sampleName, file)
        }
        .set { fna_tuple_ch }
    bakta_ch = bakta_wgs(fna_tuple_ch)
    gutsmash_ch = gutsmash_wgs(bakta_ch)
    antismash_ch = antismash_wgs(bakta_ch)
    // pyrodigal_ch = pyrodigal_wgs(fna_tuple_ch)
    emapper_ch = emapper_wgs(bakta_ch)
}

workflow Sylph_workflow {
    Channel
        .fromFilePairs("${params.rawreads}/*_R{1,2}*.fastq{,.gz}", checkIfExists:true)
        .set{read_pairs_ch}
    read_pairs_ch.view()
    // reference_ch = Channel.fromPath(params.sylph_reference)
    // sylph_ch = Sylph(read_pairs_ch.collect(), reference_ch)
}



process Metaphlan_deHost { 
    tag "${sample_id.split('_R1')[0]} with database: ${params.metaphlan_db}"
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    cpus 8
    memory { 48.GB + 8.GB * task.attempt }
    time { task.attempt < 5 ? (30.min + (30.min * task.attempt)) : (8.hour * task.attempt) }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }


    input: 
    tuple val(sample_id), path(reads)
    val(database) // from params.metaphlan_db

    output: 
    tuple val("${sample_id}"), path(reads), file("taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt"), path("root_dir"), emit: meta_tuple
    path ("taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt"), emit: meta_tax_profile

    script: 
    """
    echo "The reads are: ${reads[0]} ${reads[1]}"
    found_files=\$(readlink -f ${reads[0]}) 
    printf "The found files are: \$found_files"
    parent_dir=\$(dirname "\$found_files") 
    echo "The parent dir is: \$parent_dir"
    grandparent_dir=\$(dirname "\$parent_dir") 
    greatgrandparent_dir=\$(dirname "\$grandparent_dir") # since we are starting from the dehosted reads nested in the deHost/{sample_id} folder we need to move up an extra level
    mkdir -p \$greatgrandparent_dir/
    echo "\$greatgrandparent_dir" > root_dir

    if [ -f \$greatgrandparent_dir/taxonomy/metaphlan/${params.params_label}/${sample_id}.sam.bz2 ]; then
        mkdir -p taxonomy/metaphlan/${params.params_label}
        echo "Prior analysis exists in target folder, skipping analysis."
        rsync -hpvir --no-times --chmod=Dg=rwx,Fg=rwx \$greatgrandparent_dir/taxonomy/metaphlan/${params.params_label}/${sample_id}*_profiled_metagenome.txt taxonomy/metaphlan/${params.params_label}/
    else
        echo "Starting analysis. No prior analysis not found in target folder."
        mkdir -p taxonomy/metaphlan/${params.params_label}
        metaphlan ${reads[0]},${reads[1]} --input_type fastq \
        -t rel_ab_w_read_stats \
        --profile_vsc \
        -s taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}.sam.bz2 \
        --vsc_out taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}.vsc.txt \
        --mapout taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}.bowtie2.bz2 \
        --index ${database} \
        --db_dir ${params.metaphlandb_folder}/${database}/ \
        --stat_q ${params.stat_q} \
        --nproc ${task.cpus} -o taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt


        if [ ! -s \$greatgrandparent_dir/taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome_gtdb.txt ]; then
            echo "Converting Metaphlan species to GTDB"
            ${params.sgb2gtdb} -i taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome.txt -o taxonomy/metaphlan/${params.params_label}/${sample_id}_${params.params_label}_profiled_metagenome_gtdb.txt -d ${params.metaphlan_db}
        fi

        samfile="taxonomy/metaphlan/${params.params_label}/${sample_id}.sam"
        bamfile="\${samfile%.sam}.bam"
        # remove any existing bam or bai files to avoid conflicts
        rm -f "\$greatgrandparent_dir/\$bamfile" || true
        rm -f "\$greatgrandparent_dir/\${bamfile}.bai" || true 
    
        rsync -hvir --chmod=Dg=rwx,Fg=rwx taxonomy \$greatgrandparent_dir
    fi
    """
} 


process BAQLaVa_dehost { 
    tag "Baqlava on cat reads for $sample_id"
    cpus 12
    // runOptions = "--writable-tmpfs --cleanenv -B /ess/scratch/scratch1/ckwoodson -B /scratch/ckwoodson" // try '--cleanenv' flag if this doesnt work
    memory { 34.GB + 16.GB * task.attempt }
    time { task.attempt < 5 ? (30.min + (30.min * task.attempt)) : (8.hour * task.attempt) }
    errorStrategy { task.attempt <= 3 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    maxForks 10
    container "docker://dfiuchicago/shotgun:2.7_mamba"
        
    input: 
    tuple val(sample_id), path(reads), file(meta_tax_profile), path(root_dir) // from metaphlan_dehost meta_tuple


    output: 
    tuple val(sample_id), path("taxonomy/baqlava/*/*/*_BAQLaVa_profile.txt"), emit: baqlava_tax_profile

    script: 
    """
    grandparent_dir=\$(cat ${root_dir})
    echo "\$grandparent_dir"
    echo "${params.params_label}"
    flattened_name="${sample_id.replaceAll('[^a-zA-Z0-9_]', '_')}"
    mv \$grandparent_dir/taxonomy/baqlava/\${flattened_name} \$grandparent_dir/taxonomy/baqlava/${sample_id} || true
    echo "catting the fastq files."
    ls -ltr

    # Calculate 85% of the allocated memory
    memory_85_percent=\$(awk "BEGIN {print int(${task.memory.toMega()} * 0.85)}")

    # This is using BBMap to reformat reads into one concatenated file
    reformat -Xmx\${memory_85_percent}m in1=${reads[0]} in2=${reads[1]} out=\$flattened_name.fastq
    baqlava -h 

    # if metaphlan_db = mpa_vJan25_CHOCOPhlAnSGB_202503 take the tax profile from mpa_vJun23_CHOCOPhlAnSGB_202403

    if [ -f "\$grandparent_dir/taxonomy/baqlava/${sample_id}/${params.baqlava_params_label}/\${flattened_name}_${params.baqlava_params_label}_BAQLaVa_profile.txt" ] || [ -f "\$grandparent_dir/taxonomy/baqlava/${sample_id}/${params.baqlava_params_label}/\${flattened_name}_${params.baqlava_params_label}_BAQLaVa_profile.txt" ]; then
        echo "Prior analysis exists in target folder, skipping analysis."
        pigz -9 taxonomy/baqlava/${sample_id}/*/*.fa || true

        mkdir -p taxonomy/baqlava/${sample_id}/${params.baqlava_params_label} || true
        rsync -hvir --no-times --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/taxonomy/baqlava/${sample_id}/*/*_BAQLaVa_profile.txt taxonomy/baqlava/${sample_id}/ || true
        rm \$flattened_name.fastq

    else
        echo "Starting analysis using existing ${params.baqlava_params_label}. No prior baqlava analysis found in target folder."
        if [ "${params.metaphlan_db}" == "mpa_vJan25_CHOCOPhlAnSGB_202503" ] && [ -f \$grandparent_dir/taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}_profiled_metagenome.txt ]; then
            mkdir -p taxonomy/baqlava/${sample_id}/${params.baqlava_params_label} || true
            echo "Using tax profile from ${params.params_label} instead of ${params.metaphlan_db} with no temp dir"
            alternative_tax_profile=\$grandparent_dir/taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}_profiled_metagenome.txt 
            mv "\$flattened_name.fastq" "\${flattened_name}_${params.baqlava_params_label}.fastq" || true

            baqlava -i "\${flattened_name}_${params.baqlava_params_label}.fastq" -o taxonomy/baqlava/\${flattened_name}/${params.baqlava_params_label} --taxonomic-profile \$alternative_tax_profile --threads ${task.cpus} \
            --nucdb /gpfs/data/dfi-cores/biobakery/databases/baqlava/data/BAQLaVa.V0.5.nucleotide \
            --protdb /gpfs/data/dfi-cores/biobakery/databases/baqlava/data/BAQLaVa.V0.5.protein
            rm \${flattened_name}_${params.baqlava_params_label}.fastq 
            mv taxonomy/baqlava/\${flattened_name} taxonomy/baqlava/${sample_id} || true
            mv taxonomy/baqlava/${sample_id}/${params.baqlava_params_label} taxonomy/baqlava/${sample_id}/${params.params_label} || true

            pigz -9 taxonomy/baqlava/${sample_id}/${params.baqlava_params_label}/*.fa
            rm -f taxonomy/baqlava/${sample_id}/${params.baqlava_params_label}/*.fa
            mv *fa.gz taxonomy/baqlava/${sample_id}/${params.baqlava_params_label}/ || true
            rsync -hvir --chmod=Dg=rwx,Fg=rwx taxonomy \$grandparent_dir
        elif [ "${params.metaphlan_db}" == "mpa_vJan25_CHOCOPhlAnSGB_202503" ]; then
            echo "Running metaphlan with: Using ${params.params_label} because alternative profile from ${params.metaphlan_db} not found!"
            mkdir -p taxonomy/baqlava/${sample_id}/${params.params_label} || true

            mkdir -p taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403 || true

            mv "\$flattened_name.fastq" "\${flattened_name}_mpa_vJun23_CHOCOPhlAnSGB_202403.fastq"


            metaphlan ${reads[0]},${reads[1]} --input_type fastq \
            -t rel_ab_w_read_stats \
            --profile_vsc \
            -s taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}.sam.bz2 \
            --vsc_out taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}.vsc.txt \
            --mapout taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}.bowtie2.bz2 \
            --index mpa_vJun23_CHOCOPhlAnSGB_202403 \
            --db_dir  ${params.metaphlandb_folder}/mpa_vJun23_CHOCOPhlAnSGB_202403/ \
            --stat_q ${params.stat_q} \
            --nproc ${task.cpus} -o taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}_profiled_metagenome.txt
            if [ ! -s \$greatgrandparent_dir/taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}_profiled_metagenome_gtdb.txt ]; then
                echo "Converting Metaphlan species to GTDB"
                ${params.sgb2gtdb} -i taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}_profiled_metagenome.txt -o taxonomy/metaphlan/mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}_profiled_metagenome_gtdb.txt -d ${params.metaphlan_db}
            fi

            samfile="taxonomy/metaphlan/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}.sam"
            bamfile="\${samfile%.sam}.bam"
            # remove any existing bam or bai files to avoid conflicts
            rm -f "\$greatgrandparent_dir/\$samfile" || true 
            rm -f "\$greatgrandparent_dir/\$bamfile" || true
            rm -f "\$greatgrandparent_dir/\${bamfile}.bai" || true 
    
            rsync -hvir --chmod=Dg=rwx,Fg=rwx taxonomy \$grandparent_dir


            echo "Using newly generated profile from mpa_vJun23_CHOCOPhlAnSGB_202403"
            baqlava -i "\${flattened_name}_mpa_vJun23_CHOCOPhlAnSGB_202403.fastq" -o taxonomy/baqlava/\${flattened_name}/mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq.replaceAll("[^a-zA-Z0-9]", "_")} \
            --taxonomic-profile taxonomy/metaphlan/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}/${sample_id}_mpa_vJun23_CHOCOPhlAnSGB_202403${params.check_statq}_profiled_metagenome.txt \
            --threads ${task.cpus} \
            --nucdb /gpfs/data/dfi-cores/biobakery/databases/baqlava/data/BAQLaVa.V0.5.nucleotide \
            --protdb /gpfs/data/dfi-cores/biobakery/databases/baqlava/data/BAQLaVa.V0.5.protein

            mv taxonomy/baqlava/\${flattened_name} taxonomy/baqlava/${sample_id} || true
            rm \${flattened_name}_mpa_vJun23_CHOCOPhlAnSGB_202403.fastq
            
            pigz -9 taxonomy/baqlava/${sample_id}/*/*.fa


            rsync -hvir --chmod=Dg=rwx,Fg=rwx taxonomy \$grandparent_dir

        else
            mkdir -p taxonomy/baqlava/\${flattened_name}/${params.baqlava_params_label} || true
            echo "Using standard tax profile for ${params.baqlava_params_label}"
            mv "\$flattened_name.fastq" "\${flattened_name}_${params.baqlava_params_label}.fastq"

            baqlava -i "\${flattened_name}_${params.baqlava_params_label}.fastq" -o taxonomy/baqlava/\${flattened_name}/${params.baqlava_params_label} --taxonomic-profile $meta_tax_profile --threads ${task.cpus} \
            --nucdb /gpfs/data/dfi-cores/biobakery/databases/baqlava/data/BAQLaVa.V0.5.nucleotide \
            --protdb /gpfs/data/dfi-cores/biobakery/databases/baqlava/data/BAQLaVa.V0.5.protein
            rm \${flattened_name}_${params.baqlava_params_label}.fastq
            mv taxonomy/baqlava/\${flattened_name} taxonomy/baqlava/${sample_id} || true
            mv taxonomy/baqlava/${sample_id}/${params.baqlava_params_label} taxonomy/baqlava/${sample_id}/${params.params_label} || true

            pigz -9 taxonomy/baqlava/${sample_id}/*/*.fa
            
            rsync -hvir --chmod=Dg=rwx,Fg=rwx taxonomy \$grandparent_dir

        fi
    fi
    """
} 


process HUMAnN_deHost { // humann reccomends using the cat reads
    tag "Humann on cat reads for ${sample_id} with database: ${params.metaphlan_db}"
    cpus 12
    memory { 48.GB + 32.GB * task.attempt }
    time { task.attempt < 3 ? (1.hour + (90.min * task.attempt)) : (3.hour * task.attempt) }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    queue { selectQueue(task.memory, task.cpus) }
    publishDir "${params.out}/humann", mode: 'copy'
    container "docker://dfiuchicago/shotgun:2.3"

    // if (params.metaphlan_db == "mpa_vJun23_CHOCOPhlAnSGB_202403") {
    //     container = "docker://dfiuchicago/shotgun:2.7_mamba"
    // } else {
    //     container = "docker://dfiuchicago/shotgun:OlderDB"
    // }
        
    input: 
    tuple val(sample_id), path(reads), file(meta_tax_profile), path(root_dir) // from metaphlan_dehost meta_tuple

    output:
    path ("humann/${sample_id}/${params.params_label}/*.tsv")    

    script: 
    """
    pwd
    grandparent_dir=\$(cat ${root_dir})
    if [ -f \$grandparent_dir/humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_pathabundance-cpm.tsv ]; then
        echo "Prior analysis exists in target folder, skipping analysis."
        mkdir -p humann/${sample_id}/${params.params_label}
        rsync -hvir --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/humann/${sample_id}/${params.params_label}/* humann/${sample_id}/${params.params_label}/
    else
        echo "Starting analysis. No prior analysis not found in target folder."
        echo "decompressing the fastq files."
        echo "catting the fastq files."
        ls -ltr

        # Calculate 85% of the allocated memory
        memory_85_percent=\$(awk "BEGIN {print int(${task.memory.toMega()} * 0.85)}")

        # This is using BBMap to reformat reads into one concatenated file
        reformat -Xmx\${memory_85_percent}m in1=${reads[0]} in2=${reads[1]} out=knead_cat_reads.fastq

        echo "Starting humann analysis."
        mkdir -p humann/${sample_id}/${params.params_label}

        humann \
        --threads ${task.cpus} \
        --nucleotide-database ${params.humann_nucleotide_db} \
        --protein-database ${params.humann_protein_db} \
        --input knead_cat_reads.fastq \
        --verbose \
        --taxonomic-profile ${meta_tax_profile} \
        --output-basename ${sample_id}_${params.params_label} \
        --remove-temp-output \
        --output humann/${sample_id}/${params.params_label} \
        --resume \
        -v

        echo "renormalizing the table."
        humann_renorm_table --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies.tsv \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm.tsv \
            --units cpm \
            --update-snames

        humann_renorm_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_pathabundance.tsv \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_pathabundance-cpm.tsv \
            --units cpm \
            --update-snames
            
        humann_regroup_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm.tsv \
            -c /gpfs/data/dfi-cores/biobakery/databases/humann/utility_mapping/utility_mapping/map_ko_uniref90.txt.gz \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm_KO.tsv 

        humann_regroup_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm.tsv \
            -c /gpfs/data/dfi-cores/biobakery/databases/humann/utility_mapping/utility_mapping/map_level4ec_uniclust90.txt.gz \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm_level4EC.tsv 

        humann_regroup_table \
            --input humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}_genefamilies-cpm.tsv \
            -c /gpfs/data/dfi-cores/biobakery/databases/humann/utility_mapping/utility_mapping/map_go_uniref90.txt.gz \
            --output humann/${sample_id}/${params.params_label}/${sample_id}_${params.params_label}-cpm_GO.tsv 

        rsync -hpvir --no-times --chmod=Dg=rwx,Fg=rwx humann \$grandparent_dir
    fi
    """
} 

process shortbred_Prep_dehost { 
    tag "prepping $sample_id for shortbred"
    memory 52.GB
    cpus 6
    queue { selectQueue(task.memory, task.cpus) }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    
    input: 
    tuple val(sample_id), path(reads), file(meta_tax_profile), path(root_dir) // from metaphlan_dehost meta_tuple

    output: 
    tuple val(sample_id), path(reads), file("${sample_id}_knead_cat.fasta.gz"), path(root_dir) 

    script: 
    """
    marker_db_name=\$(basename ${params.shortbred_marker_db} .faa)
    # check if the analysis has already been done
    grandparent_dir=\$(cat ${root_dir})
    if [ -f \$grandparent_dir/shortBRED/\$marker_db_name/${sample_id}*_shortBRED_results.txt ]; then
        echo "Prior analysis exists in target folder, skipping analysis."
        touch ${sample_id}_knead_cat.fasta.gz
    else
        echo "Starting analysis by decompressing and concatenating the reads."
        echo "decompressing the fastq files."
        echo "catting the fastq files."
        ls -ltr

        # Calculate 85% of the allocated memory
        memory_85_percent=\$(awk "BEGIN {print int(${task.memory.toMega()} * 0.85)}")

        # This is using BBMap to reformat reads into one concatenated file
        reformat -Xmx\${memory_85_percent}m in1=${reads[0]}  in2=${reads[1]} out=knead_cat_reads.fastq

        seqtk seq -A knead_cat_reads.fastq > ${sample_id}_knead_cat.fasta
        pigz -9 ${sample_id}_knead_cat.fasta
    fi
    """
} 

process Megahit_dehost { 
    tag "Megahit on reads for $sample_id"
    cpus 16
    time { task.attempt < 5 ? (90.min * task.attempt) : (6.hour * task.attempt) }
    memory { 64.GB + 8.GB * task.attempt }
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    container "docker://dfiuchicago/shotgun:2.7_mamba"
    queue { selectQueue(task.memory, task.cpus) }



    input: 
    tuple val(sample_id), path(knead_paired_reads)


    output: 
    tuple val(sample_id), path("contigs/megahit/${sample_id}.contigs.fa"), path("root_dir"),  emit: contig_file

    script: 
    """

    echo "The reads are: ${knead_paired_reads[0]} ${knead_paired_reads[1]}"
    found_files=\$(readlink -f ${knead_paired_reads[0]}) 
    printf "The found files are: \$found_files"
    parent_dir=\$(dirname "\$found_files") 
    echo "The parent dir is: \$parent_dir"
    grandparent_dir=\$(dirname "\$parent_dir") 
    greatgrandparent_dir=\$(dirname "\$grandparent_dir") # since we are starting from the dehosted reads nested in the deHost/{sample_id} folder we need to move up an extra level
    mkdir -p \$greatgrandparent_dir/
    echo "\$greatgrandparent_dir" > root_dir
    mkdir -p contigs/megahit

    if [ -f \$grandparent_dir/contigs/megahit/${sample_id}.contigs.fa.gz ] || [ -f \$grandparent_dir/contigs/megahit/${sample_id}.contigs.fa ]; then
        echo "Prior analysis exists in target folder, skipping analysis."
         
        mkdir -p contigs/megahit
        rsync -hvir --chmod=Dg=rwx,Fg=rwx \$greatgrandparent_dir/contigs/megahit/${sample_id}.contigs{.fa.gz,.fa} contigs/megahit
        pigz -df contigs/megahit/${sample_id}.contigs.fa.gz || true

    else
        ### this command breaks if the output directory already exists, so we need to remove it first
        megahit \
            -1 ${knead_paired_reads[0]} \
            -2 ${knead_paired_reads[1]} \
            -t ${task.cpus} \
        --out-prefix ${sample_id} \
        -o ${sample_id}_megahit/

        mv ${sample_id}_megahit/${sample_id}.contigs.fa contigs/megahit
        tar -cf - ${sample_id}_megahit/ | pigz > ${sample_id}_megahit.tar.gz
        mv ${sample_id}_megahit.tar.gz contigs/megahit
        tar -cf - contigs/ | pigz > ${sample_id}_megahit_contig.tar.gz


        mkdir -p \$greatgrandparent_dir
        rsync -hvir --chmod=Dg=rwx,Fg=rwx contigs \$greatgrandparent_dir
        pigz -f \$greatgrandparent_dir/contigs/megahit/${sample_id}.contigs.fa || true
    fi
    """
}

process shortbred_dehost {
    tag "shortbred on $sample_id"
    memory 48.GB
    cpus 8
    queue { selectQueue(task.memory, task.cpus) }
    container "docker://dfiuchicago/shotgun:shortbredv0.9.5"
    publishDir "${params.out}/shortbred", mode: 'copy'
    errorStrategy { task.attempt <= 8 ? 'retry' : 'ignore' }
    
    input: 
    tuple val(sample_id), path(reads), file(knead_cat_fasta), path(root_dir) // from shortbred_Prep_dehost
    
    // output:
    // path ("shortBRED/*/${sample_id}*_shortBRED_results.txt")

    script: 
    """

    marker_db_name=\$(basename ${params.shortbred_marker_db} .faa)
    mkdir -p shortBRED/\$marker_db_name
    grandparent_dir=\$(cat ${root_dir})

    if [ -f \$grandparent_dir/shortBRED/\$marker_db_name/${sample_id}_\${marker_db_name}_shortBRED_results.txt ]; then
        echo "Prior analysis exists in target folder, skipping analysis."
        rsync -hvir --chmod=Dg=rwx,Fg=rwx \$grandparent_dir/shortBRED/\$marker_db_name/${sample_id}_\${marker_db_name}_shortBRED_results.txt shortBRED/\$marker_db_name/

    else
        echo "Starting analysis. No prior analysis not found in target folder."
        mkdir -p shortbred_tmp

        gzip -fd ${knead_cat_fasta}
        ### DB NAME MUST HAVE .faa EXTENSION ####

        marker_db_name=\$(basename ${params.shortbred_marker_db} .faa)
        mkdir -p shortBRED/\$marker_db_name

    
        shortbred_quantify.py \
            --markers ${params.shortbred_marker_db} \
            --wgs ${sample_id}_knead_cat.fasta  \
            --results shortBRED/\$marker_db_name/${sample_id}_\${marker_db_name}_shortBRED_results.txt \
            --tmp shortbred_tmp \
            --threads ${task.cpus} 


        cp shortbred_tmp/\$marker_db_name.faa.log shortBRED/\$marker_db_name

        grandparent_dir=\$(cat ${root_dir})

        mkdir -p \$grandparent_dir
        rsync -hvir --chmod=Dg=rwx,Fg=rwx shortBRED \$grandparent_dir/
    fi
    """
}