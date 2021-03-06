import os
import subprocess
from snakemake.utils import min_version
import pandas as pd

from helpers import extract_hairpin_name_and_sequence
from helpers import collect_clusterfiles_path
from helpers import converts_list_of_sequence_dictionary_to_fasta
from helpers import add_blast_header_to_file
from helpers import add_sample_name_and_hairpin_seq_to_shortstack
from helpers import concatenate_shortstacks_and_assign_unique_cluster_ids
from helpers import extract_mature_micrornas_from_concatenated_shortstack_file
from helpers import extract_hairpins_from_concatenated_shortstack_file
from helpers import extract_mature_mirna_fasta_file_from_shortstack_file


###############################
# OS and related configurations
###############################

##### set minimum snakemake version #####
min_version("5.4.3")

# this container defines the underlying OS for each job when using the workflow
# with --use-conda --use-singularity
singularity: "docker://continuumio/miniconda3"

#########################
## Pipeline configuration
##########################
configfile: "config.yaml"

wildcard_constraints:
  dataset="[Aa-Zz0-9]+"

# directories
WORKING_DIR = config["temp_dir"]
RES_DIR = config["result_dir"]

# get list of samples
samples_df = pd.read_csv("samples.tsv", sep="\t").set_index("sample")
SAMPLES = samples_df.index.values.tolist()

# get fastq file
def get_fastq_file(wildcards):
    fastq_file = samples_df.loc[wildcards.sample,"fastq"]
    if fastq_file.endswith(".gz"):
        fastq_file = fastq_file.rstrip(".gz")
    return fastq_file

# to trim or not to trim
def get_trim_or_untrimmed(wildcards):
    if config["trim"]:
        return WORKING_DIR + "trimmed/{}.trimmed.fastq".format(wildcards.sample)
    else:
        return get_fastq_file(wildcards)

# ShortStack parameters
SHORTSTACK_PARAMS = " ".join(config["shortstack"].values())

####################
## Desired outputs
####################
SHORTSTACK = expand(RES_DIR + "shortstack/{sample}/Results.with_sample_name_and_hairpins.tsv",sample = SAMPLES)
SHORTSTACK_CONCAT = RES_DIR + "concatenated_shortstacks.tsv"

MIRNAS = [expand(RES_DIR + "fasta/{sample}.mature_mirnas.fasta",sample = SAMPLES), RES_DIR + "mature_mirnas.fasta"]
HAIRPINS = [expand(RES_DIR + "fasta/{sample}.hairpin.fasta",sample = SAMPLES), RES_DIR + "hairpins.fasta"]

MFEs = expand(RES_DIR + "hairpins.mfe", sample=SAMPLES) # minimal free energy secondary structures of hairpins

BLAST = expand(RES_DIR + "blast/{sample}.{type}_mirbase.header.txt",sample = SAMPLES, type = ["mature","hairpin"])

rule all:
    input:
        SHORTSTACK,
        SHORTSTACK_CONCAT,
        MIRNAS,
        HAIRPINS,
        BLAST,
        MFEs
    message:"All done! Removing intermediate files"
    shell:
        "rm -rf {WORKING_DIR}" # removes unwanted intermediate files

#######
# Rules
#######

##### GUNZIP ######

rule gunzip_fastq:
    input: "{sample}.fastq.gz"
    output: temp("{sample}.fastq")
    shell: "gunzip -c {input} > {output}"


#########################
# Folding of RNA hairpins
#########################

rule rna_fold:
    input:
        hairpins = RES_DIR + "hairpins.fasta"
    output:
        mfe = RES_DIR + "hairpins.mfe"
    message: "Calculate minimum free energy secondary structures of hairpins"
    conda:
        "envs/viennarna.yaml"
    params:
        temp_name = "hairpins.mfe"
    threads: 10
    shell:
        "RNAfold --jobs={threads} --infile={input.hairpins} --outfile={params.temp_name};"
        "mv {params.temp_name} {RES_DIR}{params.temp_name};"
        "rm cluster*"

#############################################
# Produce a concatenated Shortstack dataframe
#############################################

rule extract_fasta_files_for_hairpins_and_mature_miRNAs_from_concatenated_shortstack:
    input:
        RES_DIR + "concatenated_shortstacks.tsv"
    output:
        hairpins = RES_DIR + "hairpins.fasta",
        mature = RES_DIR + "mature_mirnas.fasta"
    message: "extract hairpins and mature miRNAs from {input}"
    run:
        extract_hairpins_from_concatenated_shortstack_file(input[0], output[0])
        extract_mature_micrornas_from_concatenated_shortstack_file(input[0], output[1])


rule concatenate_shorstacks_and_assign_unique_cluster_ids:
    input:
        expand(RES_DIR + "shortstack/{sample}/Results.with_sample_name_and_hairpins.tsv", sample=SAMPLES)
    output:
        RES_DIR + "concatenated_shortstacks.tsv"
    message: "Row-bind all Shortstacks and assign a unique id to each sRNA cluster"
    run:
        dfs = [pd.read_csv(f,sep="\t") for f in input]
        df = pd.concat(dfs)
        df["cluster_unique_id"] = ["cluster_" + str(i+1).zfill(10) for i in range(0,df.shape[0],1)]
        df.to_csv(output[0], sep="\t", index=False, header=True, na_rep = "NaN")


rule add_sample_name_and_hairpin_seq_to_shortstack:
    input:
        RES_DIR + "shortstack/{sample}/Results.txt",
        RES_DIR + "fasta/{sample}.hairpin.fasta"
    output:
        RES_DIR + "shortstack/{sample}/Results.with_sample_name_and_hairpins.tsv"
    message: "Add sample name and discovered hairpin sequences to {wildcards.sample} Shortstack dataframe"
    run:
        add_sample_name_and_hairpin_seq_to_shortstack(
            path_to_shortstack_results = input[0],
            sample_name = wildcards.sample,
            hairpin_fasta_file = input[1],
            outfile = output[0]
            )

##################
# mirbase analysis
##################
rule add_blast_header:
    input:
        hairpin = WORKING_DIR + "blast/{sample}.hairpin_mirbase.txt",
        mature = WORKING_DIR + "blast/{sample}.mature_mirbase.txt"
    output:
        hairpin = RES_DIR + "blast/{sample}.hairpin_mirbase.header.txt",
        mature = RES_DIR + "blast/{sample}.mature_mirbase.header.txt"
    message: "adding blast header for {wildcards.sample}"
    params:
        blast_header = "qseqid \t subject_id \t pct_identity \t aln_length \t n_of_mismatches gap_openings \t q_start \t q_end \t s_start \t s_end \t e_value \t bit_score"
    run:
        add_blast_header_to_file(input[0],output[0]) # hairpin
        add_blast_header_to_file(input[1],output[1]) # mature

rule blast_hairpin_against_mirbase:
    input:
        db = config["refs"]["mirbase"]["hairpin"] + ".nhr",
        fasta = RES_DIR + "fasta/{sample}.hairpin.fasta"
    output:
        WORKING_DIR + "blast/{sample}.hairpin_mirbase.txt"
    message:"blasting {wildcards.sample} hairpins against mirbase"
    conda:
        "envs/blast.yaml"
    params:
        dbname = config["refs"]["mirbase"]["hairpin"],
        max_target_seqs = config["blastn"]["hairpin"]["max_target_seqs"]
    shell:
        "blastn -db {params.dbname} "
        "-max_target_seqs {params.max_target_seqs} "
        "-outfmt 6 "                                  # tabular output format
        "-query {input.fasta} "
        "-out {output}"

rule extract_hairpin_fasta_file:
    input:
        RES_DIR + "shortstack/{sample}/Results.txt" # not used in the actual rule but necessary to chain this rule to the shortstack rule
    output:
        RES_DIR + "fasta/{sample}.hairpin.fasta"
    message: "extracting hairpin sequences for {wildcards.sample} clusters annotated as true MIRNAs by shortstack"
    params:
        mirna_clusterpath = RES_DIR + "shortstack/{sample}/MIRNAs/",
        samples = list(config["samples"])
    run:
        for sample in params[1]:
            # make a list of sequence dictionaries (clusterName:hairpinSequence)
            l = [extract_hairpin_name_and_sequence(cluster,sample) for cluster in collect_clusterfiles_path(params[0])]
            # writes this dictionary to a fasta file
            converts_list_of_sequence_dictionary_to_fasta(l,output[0])

rule blast_mature_mirna_against_mirbase:
    input:
        db = config["refs"]["mirbase"]["mature"] + ".nhr",
        fasta = RES_DIR + "fasta/{sample}.mature_mirnas.fasta"
    output:
        WORKING_DIR + "blast/{sample}.mature_mirbase.txt"
    message:"blasting {wildcards.sample} mature miRNAs against mirbase"
    conda:
        "envs/blast.yaml"
    params:
        dbname = config["refs"]["mirbase"]["mature"],
        qcov_hsp_perc = config["blastn"]["mature"]["qcov_hsp_perc"],
        max_target_seqs = config["blastn"]["mature"]["max_target_seqs"]
    shell:
        "blastn -db {params.dbname} "
        "-task blastn-short "                         # BLASTN program optimized for sequences shorter than 50 bases
        "-qcov_hsp_perc {params.qcov_hsp_perc} "
        "-max_target_seqs {params.max_target_seqs} "
        "-outfmt 6 "                                  # tabular output format
        "-query {input.fasta} "
        "-out {output}"

rule make_mirbase_blastdb:
    input:
        mature = config["refs"]["mirbase"]["mature"],
        hairpin = config["refs"]["mirbase"]["hairpin"]
    output:
        mature = config["refs"]["mirbase"]["mature"] + ".nhr",
        hairpin = config["refs"]["mirbase"]["hairpin"] + ".nhr",
    message: "creating blastdb databases for mature miRNA and hairpins"
    conda:
        "envs/blast.yaml"
    shell:
        "makeblastdb -in {input.mature} -dbtype nucl;"
        "makeblastdb -in {input.hairpin} -dbtype nucl"

rule extract_mature_mirna_fasta_file_from_shortstack_file:
    input:
        RES_DIR + "shortstack/{sample}/Results.txt"
    output:
        RES_DIR + "fasta/{sample}.mature_mirnas.fasta"
    message: "extracting mature miRNA fasta file of {wildcards.sample}"
    run:
        extract_mature_mirna_fasta_file_from_shortstack_file(
            path_to_shortstack_file = input[0],
            out_fasta_file = output[0])



######################
## Shortstack analysis
######################

rule shortstack:
    input:
        reads =  get_trim_or_untrimmed
    output:
        RES_DIR + "shortstack/{sample}/Results.txt"
    message:"Shortstack analysis of {wildcards.sample} using {params.genome} reference"
    params:
        resdir = RES_DIR + "shortstack/{sample}/",
        genome = lambda wildcards: samples_df.loc[wildcards.sample,"genome"]
    threads: 10
    conda:
        "envs/shortstack.yaml"
    shell:
        "ShortStack "
        "--outdir {wildcards.sample} "
        "--bowtie_cores {threads} "
        "--sort_mem 4G "
        "{SHORTSTACK_PARAMS} "
        "--readfile {input.reads} "
        "--genome {params.genome};"
        "cp -r {wildcards.sample}/* {params.resdir};"
        "rm -r {wildcards.sample};"

#############################
## Trim reads for all samples
#############################
rule keep_reads_shorter_than:
    input:
        get_trim_or_untrimmed
    output:
        WORKING_DIR + "trim/{sample}.trimmed.size.fastq"
    message: "Discarding reads longer than {params.max_length} nucleotides"
    params:
        max_length = config["length"]["max_length"]
    conda:
        "envs/bioawk.yaml"
    shell:
        """
        bioawk -c fastx '{{ length($seq) <= {params.max_length} }} {{print "@"$name; print $seq ;print "+";print $qual}}' {input} > {output}
        """


rule trimmomatic:
    input:
        get_fastq_file
#        FQ_DIR + "{sample}.fastq"
    output:
        WORKING_DIR + "trimmed/{sample}.trimmed.fastq",
    message: "trimming {wildcards.sample} on quality and length"
    log:
        RES_DIR + "logs/trimmomatic/{sample}.log"
    params :
        LeadMinTrimQual =           str(config['trimmomatic']['LeadMinTrimQual']),
        TrailMinTrimQual =          str(config['trimmomatic']['TrailMinTrimQual']),
        windowSize =                str(config['trimmomatic']['windowSize']),
        avgMinQual =                str(config['trimmomatic']['avgMinQual']),
        minReadLen =                str(config['length']['min_length']),
        phred = 		            str(config["trimmomatic"]["phred"])
    threads: 10
    conda:
        "envs/trimmomatic.yaml"
    shell:
        "trimmomatic SE {params.phred} -threads {threads} "
        "{input} "
        "{output} "
        "LEADING:{params.LeadMinTrimQual} "
        "TRAILING:{params.TrailMinTrimQual} "
        "SLIDINGWINDOW:{params.windowSize}:{params.avgMinQual} "
        "MINLEN:{params.minReadLen} &>{log}"

#####
## QC
#####
