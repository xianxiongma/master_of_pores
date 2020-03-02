#!/usr/bin/env nextflow


/* 
 * Define the pipeline parameters
 *
 */

// Pipeline version
version = '0.1'

params.help            = false
params.resume          = false

log.info """

╔╦╗┌─┐┌─┐┌┬┐┌─┐┬─┐  ┌─┐┌─┐  ╔═╗╔═╗╦═╗╔═╗╔═╗
║║║├─┤└─┐ │ ├┤ ├┬┘  │ │├┤   ╠═╝║ ║╠╦╝║╣ ╚═╗
╩ ╩┴ ┴└─┘ ┴ └─┘┴└─  └─┘└    ╩  ╚═╝╩╚═╚═╝╚═╝
                                                                                       
====================================================
BIOCORE@CRG Preprocessing of Nanopore direct RNA - N F  ~  version ${version}
====================================================

fast5                     : ${params.fast5}
fastq                     : ${params.fastq}
reference                 : ${params.reference}
annotation                : ${params.annotation}

ref_type                  : ${params.ref_type}
seq_type                  : ${params.seq_type}

output                    : ${params.output}
qualityqc                 : ${params.qualityqc}
granularity               : ${params.granularity}

GPU                       : ${params.GPU}
demultiplexing            : ${params.demultiplexing} 
demultiplexing_opt        : ${params.demultiplexing_opt} 
demultifast5		      : ${params.demultifast5}

filter                    : ${params.filter}
filter_opt                : ${params.filter_opt}
mapper                    : ${params.mapper}
mapper_opt                : ${params.mapper_opt}
map_type                  : ${params.map_type}

counter                   : ${ params.counter}
counter_opt               : ${ params.counter_opt}

email                     : ${params.email}
"""

// Help and avoiding typos
if (params.help) exit 1
if (params.resume) exit 1, "Are you making the classical --resume typo? Be careful!!!! ;)"
if (params.granularity == "") params.granularity = 1000000000

// check multi5 and GPU usage. GPU maybe can be removed as param if there is a way to detect it
if (params.GPU != "ON" && params.GPU != "OFF") exit 1, "Please specify ON or OFF in GPU processors are available"

if (params.map_type != "unspliced" && params.map_type != "spliced") exit 1, "Mapping type NOT supported! Please choose either 'spliced' or 'unspliced'"

// check input files
reference = file(params.reference)
if( !reference.exists() ) exit 1, "Missing reference file: ${reference}!"
config_report = file("$baseDir/config.yaml")
if( !config_report.exists() ) exit 1, "Missing config.yaml file!"
logo = file("$baseDir/../docs/logo_small.png")
deeplexicon_folder = file("$baseDir/deeplexicon/")


demultiplexer 		= params.demultiplexing
demultiplexer_opt   = params.demultiplexing_opt
mapper      		= params.mapper
mapper_opt   		= params.mapper_opt
counter_opt   		= params.counter_opt 


// Output folders
outputFastq    = "${params.output}/fastq_files"
outputFast5    = "${params.output}/fast5_files"
outputQual     = "${params.output}/QC_files"
outputMultiQC  = "${params.output}/report"
outputMapping  = "${params.output}/alignment"
outputCounts   = "${params.output}/counts"
outputAssigned = "${params.output}/assigned"
outputReport   = file("${outputMultiQC}/multiqc_report.html")

/*
* move old multiQCreport
*/
if( outputReport.exists() ) {
  log.info "Moving old report to multiqc_report.html multiqc_report.html.old"
  outputReport.moveTo("${outputMultiQC}/multiqc_report.html.old")
}

/*
 * Creates the channels that emits fast5 files
 */
Channel
    .fromPath( params.fast5)                                             
    .into {fast5_4_testing; fast5_4_granularity}

/*
 * Creates the channels that emits fastq files
 */
Channel
    .fromFilePairs( params.fastq, size: 1)                                             
    .ifEmpty { error "Cannot find any file matching: ${params.fastq}" }
    .set {fastq_files_for_demultiplexing}


/*
 * Get the name from the folder
 */
folder_info = params.fast5.tokenize("/")
folder_name = folder_info[-3]


/*
* This is default value in case guppy will be used for RNA demultiplexing
*/
if (demultiplexer == "") {
	demultiplexer = "OFF"
}

if (demultiplexer != "OFF" && demultiplexer != "deeplexicon")
exit 1, "Demultiplexing of RNA can be performed only with deeplexicon. Current value is ${demultiplexer}"

if (params.ref_type == "genome") {
	if (params.annotation != "") {
		annotation = file(params.annotation)
		if( !annotation.exists() ) exit 1, "Missing annotation file: ${params.annotation}!"
	}
}


process testInput {
    tag {"${fast5}"}  
            
    input:
    file(fast5) from fast5_4_testing.first()

    output:
    stdout into multi5_type

    script:
    """
    fast5_type.py ${fast5}
    """
}

multi5_type.map {  it.trim().toInteger() }.into{multi5_type_for_msg; multi5_type_for_bc; multi5_type_for_granularity; multi5_type_for_demultiplexing}
multi5_type_for_msg.map{it == 0 ? "Single Fast5 files detected!": "MultiFast5 files detected!" }.println()

// if you are using GPU analyse the whole dataset, otherwise make batch of 4,000 sequences if they are single fast5
// or single batches of multi fast5 sequences 
multi5_type_for_granularity.merge(fast5_4_granularity.collect()).map{
	(params.GPU == "YES" ? params.granularity  : (it[0] == 0 ? it[1..-1].collate(4000) : it[1..-1].collate(1)) )
}.flatMap().set{fast5_batches}

// create a map id batch -> list of files
def num_batch = -1
fast5_batches.map { 
    num_batch++
    [num_batch, it]
}.set{fast5_4_demulti}

/*
*  Perform demultiplexing (optional) using deeplexicon on basecalled reads
*/
if(demultiplexer == "deeplexicon") {
	process demultiplexing_with_deeplexicon {
		label 'demulti'
   	    tag {"${demultiplexer}-${idfile}"}  
				
		input:
    	set idfile, file(fast5) from fast5_4_demulti
    	val (multi5) from multi5_type_for_bc
        file(deeplexicon_folder)
        
		output:
		set idfile, file ("${idfile}_demux.tsv") into demux_for_fastq_extraction
		file ("${idfile}_demux.tsv") into demux_for_fast5_extraction

		script:
		def model = ''
		def deep_option = 'multi'
		if (multi5 == 0){
			deep_option = 'single'
		}
		"""
		    ln -s ${deeplexicon_folder}/* .
            deeplexicon.py -p ./ ${demultiplexer_opt} -f ${deep_option} -b 4000 -v > ${idfile}_demux.tsv
 		"""
	} 
	
	process extracting_demultiplexed_fastq {
		label 'basecall_cpus'
   	    tag {"${demultiplexer}"}  
				
		input:
    	set idfile, file(demux)  from demux_for_fastq_extraction
        file(fastq) from fastq_files_for_demultiplexing
        
		output:
		set idfile, file ("*.fastq.gz") into fastq_for_filtering

		script:
		"""
            extract_sequence_from_fastq.py ${demux} ${fastq}
			for i in *.fastq; do gzip \$i; done
 		"""
	} 
} else {
	fastq_files_for_demultiplexing.set{ fastq_for_filtering}
}

/*
*  Perform filtering (optional) using nanofilt on fastq files
*/
if (params.filter == "nanofilt") {
	process filtering {
		label 'big_cpus'
   	    tag {"${params.filter}-${fastq_file}".replace('.fastq.gz', '')}  
				
		input:
		set idfile, file(fastq_file) from fastq_for_filtering.transpose()

		output:
		set idfile, file("*-filt.fastq.gz") into fastq_for_next_step

		script:
		output = "${fastq_file}".replace(".fastq.gz", "-filt.fastq.gz")
		"""
			zcat ${fastq_file} | NanoFilt ${params.filter_opt} | gzip > ${output}
		"""
	} 
} else {
	fastq_for_filtering.transpose().into{fastq_files_for_fastqc; fastq_files_for_mapping}
}

// check this
//fastq_for_next_step.map{
//	filepath=it[1]
//    if (demultiplexer != "OFF") {
//        fileparts = filepath.getName().tokenize(".")
// 		["${folder_name}.${fileparts[-3]}", filepath]
//	} else {
//		["${folder_name}", filepath]
//	}
//}.groupTuple().into{fastq_files_for_fastqc; fastq_files_for_mapping; ocazz}
//ocazz.println()

/*
*  Perform fastQC on fastq files
*/

process fastQC {
    tag {idfile}  
    label 'big_cpus'

    publishDir outputQual, pattern: "*_fastqc.html", mode: 'copy'
   
    input:
    set idfile, file(fastq_file) from fastq_files_for_fastqc

    output:
    file ("*_fastqc.*") into fastqc_for_multiqc

    script:
    """
     fastqc ${fastq_file} -t ${task.cpus}
    """
}

/*
*  Perform mapping and sorting
*/
process mapping {
    tag {"${mapper}-${idfile}"}  
    publishDir outputMapping, mode: 'copy'
    label 'big_mem_cpus'

    input:
    file(reference)
    set idfile, file (fastq_file) from fastq_files_for_mapping
    
    output:
    set idfile, file("${idfile}.${mapper}.sorted.bam") optional true into aligned_reads, aligned_reads_for_QC, aligned_reads_for_QC2, aligned_reads_for_counts

    script:    
    if (mapper == "minimap2") {
	    def mappars = (params.map_type == "spliced") ? "-ax splice -k14" : "-ax map-ont"
	    mappars += " ${mapper_opt} "
 	    """
        minimap2 -t ${task.cpus} ${mappars} -uf ${reference} ${fastq_file} | samtools view -@ ${task.cpus} -F4 -hSb - > reads.mapped.bam
        samtools sort -@ ${task.cpus} -o ${idfile}.${mapper}.sorted.bam reads.mapped.bam
        rm reads.mapped.bam
        """
   }
   else if (mapper == "graphmap2"){
	    def mappars = (params.map_type == "spliced") ? "-x rnaseq" : ""
 	    mappars += " ${mapper_opt} "
        """
        graphmap2 align -t ${task.cpus} -r ${reference} ${mappars} -d ${fastq_file}  | samtools view -@ ${task.cpus} -F4 -hSb - > reads.mapped.bam
        samtools sort -@ ${task.cpus} -o ${idfile}.${mapper}.sorted.bam reads.mapped.bam
        rm reads.mapped.bam
        """
   }
   else if (mapper == "graphmap"){
	    def mappars = (params.map_type == "spliced") ? "-x rnaseq" : ""
 	    mappars += " ${mapper_opt} "
        """
        graphmap align -t ${task.cpus} -r ${reference} ${mappars} -d ${fastq_file}  | samtools view -@ ${task.cpus} -F4 -hSb - > reads.mapped.bam
        samtools sort -@ ${task.cpus} -o ${idfile}.${mapper}.sorted.bam reads.mapped.bam
        rm reads.mapped.bam
        """
   } 
   else {
        """
 		echo "nothing to do!"
        """
   }     
}

/*
*  Perform counting (optional)
*/

if ( params.counter == "YES") {
	process counting {
		tag {"${idfile}"}  
		publishDir outputCounts, pattern: "*.count", mode: 'copy'
		publishDir outputAssigned, pattern: "*.assigned", mode: 'copy'

		input:
		set idfile, file(bamfile) from aligned_reads_for_counts

		output:
		file("${idfile}.count") into read_counts
		file("${idfile}.stats") optional true into count_stats
		file("${idfile}.assigned") optional true
		script:    
		if (params.ref_type == "transcriptome") {
			"""
			NanoCount -i ${bamfile} -o ${idfile}.count ${counter_opt};
	awk '{sum+=\$3}END{print FILENAME"\t"sum}' ${idfile}.count |sed s@.count@@g > ${idfile}.stats
	samtools view -F 256 ${bamfile} |cut -f 1,3 > ${idfile}.assigned
			"""
		} else if (params.ref_type == "genome") {
			def anno = unzipBash("${params.annotation}") 
			"""
			samtools view ${bamfile} |htseq-count -f sam - ${anno} -o ${idfile}.sam > ${idfile}.count
			awk '{gsub(/XF:Z:/,"",\$NF); print \$1"\t"\$NF}' ${idfile}.sam |grep -v '__' > ${idfile}.assigned
			rm ${idfile}.sam
			"""		
		}
	}

	/*
	*  Join alnQC 
	*/
	process joinCountQCs {
   
		input:
		file "*" from count_stats.collect()

		output:
		file("counts_mqc.txt") into count_repo_for_multiQC
	
		script:
		"""
	   echo '# id: NanoCount
	# plot_type: \'table\'
	# section_name: Read counts 
	File name	\'Counts\' ' > counts_mqc.txt 
		cat *.stats  >> counts_mqc.txt 
		"""
	}
} else {
   read_counts = Channel.empty()
   count_repo_for_multiQC = Channel.empty()
}


/*
*  Perform alnQC 
*/
process alnQC {
    tag {bamid}  
   
    input:
    set bamid, file(bamfile) from aligned_reads_for_QC

    output:
    file "${bamid}.stat" into single_alnQC_outs
    
    script:
    """
    bam2stats.py ${bamfile} > ${bamid}.stat
    """
}

/*
*  Join alnQC 
*/
process joinAlnQCs {
   
    input:
    file "alnqc_*" from single_alnQC_outs.collect()

    output:
    file("alnQC_mqc.txt") into alnQC_for_multiQC
    
    script:
    """
    echo '# id: alnQC
# plot_type: \'table\'
# section_name: \'Alignment QC\' ' > alnQC_mqc.txt
    cat alnqc_* | head -n 1| sed s@#@@g >> alnQC_mqc.txt
    cat alnqc_* | grep -v "#" >> alnQC_mqc.txt
    """
}

/*
*  Perform alnQC2 
*/

process alnQC2 {
    publishDir outputQual, pattern: "*_plot/*", mode: 'copy'
    label 'big_cpus'
    errorStrategy 'ignore'
    tag {bamid}  
   
    input:
    set bamid, file(bamfile) from aligned_reads_for_QC2

    output:
    file("*_plot/*") optional true
    file("${bamid}_stats_mqc.png") optional true into qc2_for_multiqc
    
    script:
    """
    NanoPlot --bam ${bamfile} -o ${bamid}_plot --maxlength 5000 -t ${task.cpus}
    mkdir tmp_dir
    cp ${bamid}_plot/PercentIdentityvsAverageBaseQuality_kde.png tmp_dir
    cp ${bamid}_plot/LengthvsQualityScatterPlot_dot.png tmp_dir
    cp ${bamid}_plot/HistogramReadlength.png tmp_dir 
    cp ${bamid}_plot/Weighted_HistogramReadlength.png tmp_dir
    gm montage tmp_dir/*.png -tile 2x2 -geometry 800x800 ${bamid}_stats_mqc.png
    rm -fr tmp_dir
    """
}

fastqc_for_multiqc.mix(qc2_for_multiqc,read_counts,count_repo_for_multiQC,alnQC_for_multiQC).set{files_for_report}

/*
*  Perform multiQC report
*/
process multiQC {
    publishDir outputMultiQC, mode: 'copy'
   
    input:
    file(logo)
    file(config_report)
    file("*") from files_for_report.collect()
    
    output:
    file("multiqc_report.html") into multiQC 
    
    script:
    """
     multiqc -c ${config_report} .
    """
}


if (params.email == "yourmail@yourdomain" || params.email == "") { 
    log.info 'Skipping the email\n'
}
else {
    log.info "Sending the email to ${params.email}\n"

    workflow.onComplete {

    def msg = """\
        Pipeline execution summary
        ---------------------------
        Completed at: ${workflow.complete}
        Duration    : ${workflow.duration}
        Success     : ${workflow.success}
        workDir     : ${workflow.workDir}
        exit status : ${workflow.exitStatus}
        Error report: ${workflow.errorReport ?: '-'}
        """
        .stripIndent()

        sendMail(to: params.email, subject: "Master of Pore execution", body: msg,  attach: "${outputMultiQC}/multiqc_report.html")
    }
}

workflow.onComplete {
    println "Pipeline BIOCORE@CRG Master of Pore completed!"
    println "Started at  $workflow.start" 
    println "Finished at $workflow.complete"
    println "Time elapsed: $workflow.duration"
    println "Execution status: ${ workflow.success ? 'OK' : 'failed' }"
}

// make named pipe 
def unzipBash(filename) { 
    cmd = filename.toString()
    if (cmd[-3..-1] == ".gz") {
    	cmd = "<(zcat ${filename})"
    }
    return cmd
}
