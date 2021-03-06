#!/usr/bin/env nextflow

/*	This is APHA's nextflow pipeline to process Illumina paired-end data from Mycobacterium bovis isolates.  
*	It will first deduplicate the reads using fastuniq, trim them using trimmomatic and then map to the reference genome.
*	Variant positions wrt the reference are determined, togther with data on the number of reads mapping and the depth of 
*	coverage.  Using a panel of predetermined cluster specific SNPs it will also infer cluster membership.
*
*	written by ellisrichardj, based on pipeline developed by Javier Nunez
*
*	Version 0.1.0	31/07/18	Initial version
*	Version 0.2.0	04/08/18	Added SNP filtering and annotation
*	Version 0.3.0	06/08/18	Generate summary of samples in batch
*	Version 0.4.0	16/08/18	Minor improvements
*	Version 0.5.0	14/09/18	Infer genotypes using genotype-specific SNPs (GSS)
*	Version 0.5.1	21/09/18	Fixed bug that prevented GSS from running correctly
*	Version 0.5.2	01/10/18	Mark shorter split hits as secondary in bam file (-M) and change sam flag filter to 3844
*	Version 0.5.3	15/10/18	Increase min mapQ for mpileup to 60 to ensure unique reads only; add $dependpath variable
*	Version 0.6.0	15/11/18	Assigns clusters (newly defined) in place of inferring historical genotype.
*	Version 0.6.1	15/11/18	Fixed bug which caused sample names to be inconsistently transferred between processes
*	Version 0.6.2	24/11/18	Fixed bug to allow cluster assignment to be collected in a single file
*	Version 0.6.3	26/11/18	Removed 'set' in output declaration as it caused nextflow warning
*	Version 0.7.0	26/11/18	Add process to output phylogenetic tree
*	Version 0.7.1	11/12/18	Used join to ensure inputs are properly linked
*	Version 0.7.2	18/12/18	Changed samtools filter to remove unmapped reads and reads that aligned more than once
*/


params.reads = "$PWD/*_{S*_R1,S*_R2}*.fastq.gz"
params.outdir = "$PWD"

ref = file(params.ref)
refgbk = file(params.refgbk)
stage1pat = file(params.stage1pat)
stage2pat = file(params.stage2pat)

pypath = file(params.pypath)
dependpath = file(params.dependPath)


/*	Collect pairs of fastq files and infer sample names */
Channel
    .fromFilePairs( params.reads, flat: true )
    .ifEmpty { error "Cannot find any reads matching: ${params.reads}" }
	.set { read_pairs } 
	read_pairs.into { read_pairs; raw_reads }


/* remove duplicates from raw data */
process Deduplicate {
	errorStrategy 'ignore'

	maxForks 4

	input:
	set pair_id, file("${pair_id}_*_R1_*.fastq.gz"), file("${pair_id}_*_R2_*.fastq.gz") from read_pairs

	output:
	set pair_id, file("${pair_id}_uniq_R1.fastq"), file("${pair_id}_uniq_R2.fastq") into dedup_read_pairs
	set pair_id, file("${pair_id}_uniq_R1.fastq") into uniq_reads

	"""
	gunzip -c ${pair_id}_*_R1_*.fastq.gz > ${pair_id}_R1.fastq 
	gunzip -c ${pair_id}_*_R2_*.fastq.gz > ${pair_id}_R2.fastq
	echo '${pair_id}_R1.fastq\n${pair_id}_R2.fastq' > fqin.lst
	$dependpath/FastUniq/source/fastuniq -i fqin.lst -o ${pair_id}_uniq_R1.fastq -p ${pair_id}_uniq_R2.fastq
	rm ${pair_id}_R1.fastq
	rm ${pair_id}_R2.fastq
	"""
}	

/* trim adapters and low quality bases from fastq data */
process Trim {
	errorStrategy 'ignore'

	maxForks 1

	input:
	set pair_id, file("${pair_id}_uniq_R1.fastq"), file("${pair_id}_uniq_R2.fastq") from dedup_read_pairs

	output:
	set pair_id, file("${pair_id}_trim_R1.fastq"), file("${pair_id}_trim_R2.fastq") into trim_read_pairs
	set pair_id, file("${pair_id}_trim_R1.fastq"), file("${pair_id}_trim_R2.fastq") into trim_read_pairs2
	set pair_id, file("${pair_id}_trim_R1.fastq") into trim_reads
	
	"""
	java -jar $dependpath/Trimmomatic-0.38/trimmomatic-0.38.jar PE -threads 3 -phred33 ${pair_id}_uniq_R1.fastq ${pair_id}_uniq_R2.fastq  ${pair_id}_trim_R1.fastq ${pair_id}_fail1.fastq ${pair_id}_trim_R2.fastq ${pair_id}_fail2.fastq ILLUMINACLIP:/home/richard/ReferenceSequences/adapter.fasta:2:30:10 SLIDINGWINDOW:10:20 MINLEN:36
	rm ${pair_id}_fail1.fastq
	rm ${pair_id}_fail2.fastq
	"""
}

/* map to reference sequence */
process Map2Ref {
	errorStrategy 'ignore'

	maxForks 1

	input:
	set pair_id, file("${pair_id}_trim_R1.fastq"), file("${pair_id}_trim_R2.fastq") from trim_read_pairs

	output:
	set pair_id, file("${pair_id}.mapped.sorted.bam") into mapped_bam
	set pair_id, file("${pair_id}.mapped.sorted.bam") into bam4stats

	"""
	$dependpath/bwa/bwa mem -T10 -M -t2 $ref  ${pair_id}_trim_R1.fastq ${pair_id}_trim_R2.fastq |
	 samtools view -@2 -ShuF 2308 - |
	 samtools sort -@2 - -o ${pair_id}.mapped.sorted.bam
	"""
}

/* Variant calling */
process VarCall {
	errorStrategy 'ignore'

	maxForks 4

	input:
	set pair_id, file("${pair_id}.mapped.sorted.bam") from mapped_bam

	output:
	set pair_id, file("${pair_id}.pileup.vcf.gz") into vcf
	set pair_id, file("${pair_id}.pileup.vcf.gz") into vcf2
	set pair_id, file("${pair_id}.pileup.vcf.gz") into vcf3

	"""
	samtools index ${pair_id}.mapped.sorted.bam
	samtools mpileup -q 60 -uvf $ref ${pair_id}.mapped.sorted.bam |
	 bcftools call --ploidy Y -cf GQ - -Oz -o ${pair_id}.pileup.vcf.gz
	"""
}

/* Consensus calling */
process VCF2Consensus {
	errorStrategy 'ignore'

	maxForks 2

	input:
	set pair_id, file("${pair_id}.pileup.vcf.gz") from vcf2

	output:
	set pair_id, file("${pair_id}_consensus.fas"), file("${pair_id}.fq"), file("${pair_id}.fasta") into consensus

	"""
	bcftools index ${pair_id}.pileup.vcf.gz
	bcftools view -O v ${pair_id}.pileup.vcf.gz | perl $pypath/vcfutils.pl vcf2fq - > ${pair_id}.fq
	python $pypath/fqTofasta.py ${pair_id}.fq
	bcftools consensus -f $ref -o ${pair_id}_consensus.fas ${pair_id}.pileup.vcf.gz
	"""
}

//	Combine data for generating per sample statistics

raw_reads
	.join(uniq_reads)
	.set { raw_uniq }

trim_reads
	.join(bam4stats)
	.set { trim_bam }

raw_uniq
	.join(trim_bam)
	.set { input4stats }

/* Mapping Statistics*/
process ReadStats{
	errorStrategy 'ignore'

	maxForks 2

	input:
	set pair_id, file("${pair_id}_*_R1_*.fastq.gz"), file("${pair_id}_*_R2_*.fastq.gz"), file("${pair_id}_uniq_R1.fastq"), file("${pair_id}_trim_R1.fastq"), file("${pair_id}.mapped.sorted.bam") from input4stats

	output:
	set pair_id, file("${pair_id}_stats.csv") into stats

	shell:
	'''
	raw_R1=$(zgrep -c "^+\n" !{pair_id}_*_R1_*.fastq.gz)	
	uniq_R1=$(grep -c "^+\n" !{pair_id}_uniq_R1.fastq)
	trim_R1=$(grep -c "^+\n" !{pair_id}_trim_R1.fastq)
	num_map=$(samtools view -c !{pair_id}.mapped.sorted.bam)
	avg_depth=$(samtools depth  !{pair_id}.mapped.sorted.bam  |  awk '{sum+=$3} END { print sum/NR}')

	num_raw=$(($raw_R1*2))
	num_uniq=$(($uniq_R1*2))
	num_trim=$(($trim_R1*2))
	pc_aft_dedup=$(echo "scale=2; ($num_uniq*100/$num_raw)" |bc)
	pc_aft_trim=$(echo "scale=2; ($num_trim*100/$num_raw)" |bc)
	pc_mapped=$(echo "scale=2; ($num_map*100/$num_raw)" |bc)

	echo "Sample,NumRawReads,NumReadsDedup,%afterDedup,NumReadsTrim,%afterTrim,NumReadsMapped,%Mapped,MeanCov" > !{pair_id}_stats.csv
	echo "!{pair_id},"$num_raw","$num_uniq","$pc_aft_dedup","$num_trim","$pc_aft_trim","$num_map","$pc_mapped","$avg_depth"" >> !{pair_id}_stats.csv
	'''
}


/* SNP filtering and annotation */
process SNPfiltAnnot{

	errorStrategy 'ignore'

	maxForks 4

	input:
	set pair_id, file("${pair_id}.pileup.vcf.gz") from vcf3

	output:
	set pair_id, file("${pair_id}.pileup_SN.csv"), file("${pair_id}.pileup_DUO.csv"), file("${pair_id}.pileup_INDEL.csv") into VarTables
	set pair_id, file("${pair_id}.pileup_SN_Annotation.csv") into VarAnnotation

	"""
	bcftools view -O v ${pair_id}.pileup.vcf.gz | python $pypath/snpsFilter.py - ${min_cov_snp} ${alt_prop_snp} ${min_qual_snp}
	mv _DUO.csv ${pair_id}.pileup_DUO.csv
	mv _INDEL.csv ${pair_id}.pileup_INDEL.csv
	mv _SN.csv ${pair_id}.pileup_SN.csv
	python $pypath/annotateSNPs.py ${pair_id}.pileup_SN.csv $refgbk $ref
	"""
}

//	Combine data for assign cluster for each sample

vcf
	.join(stats)
	.set { input4Assign }

/* Assigns cluster by matching patterns of cluster specific SNPs. Also suggests inferred historical genotype */
process AssignClusterCSS{
	errorStrategy 'ignore'

	maxForks 2

	input:
	set pair_id, file("${pair_id}.pileup.vcf.gz"), file("${pair_id}_stats.csv") from input4Assign

	output:
	file("${pair_id}_stage1.csv") into AssignCluster
	file("${pair_id}.meg") into CSSalign

	"""
	gunzip -c ${pair_id}.pileup.vcf.gz > ${pair_id}.pileup.vcf
	python $pypath/Stage1-test.py ${pair_id}_stats.csv ${stage1pat} AF2122.fna test 1 ${min_mean_cov} ${min_cov_snp} ${alt_prop_snp} ${min_qual_snp} ${min_qual_nonsnp} ${pair_id}.pileup.vcf
	mv test/Stage1/test_stage1.meg ${pair_id}.meg 
	mv _stage1.csv ${pair_id}_stage1.csv
	"""
}

/* in-silico Spoligotyping 
process Spoligotype{
	errorStrategy 'ignore'

	maxForks 4

	input:
	set pair_id, file("${pair_id}_trim_R1.fastq"), file("${pair_id}_trim_R2.fastq") from trim_read_pairs2

	output:
	set pair_id, file("${pair_id}_spoligotype.csv") into spoligo

	""" 
	python $pypath/Stage2-test.py ${pair_id}_trim_R1.fastq ${pair_id}_trim_R2.fastq test $stage2pat test 1 ${min_mean_cov} false 1.5 1
	""" 


}*/

/* Combine all cluster assignment data into a single results file */
AssignCluster
	.collectFile( name: 'InferredGenotypes.csv', sort: true, storeDir: "$PWD/Results", keepHeader: true )

/* Combine all alignments into a single results file */
CSSalign
	.collectFile( name: 'AlignedCSS.meg', sort: true, storeDir: "$PWD/Results", keepHeader: true )
	.set { Alignment }

/* Generate phyogenetic tree from alignments 
process DrawTree{

	errorStrategy 'ignore'

	maxForks 2

	input:
	file("AlignedCSS.meg") from Alignment

	output:
	file("Tree.nwk") into Tree

	"""
	megacc -a /home/richard/infer_MP_nucleotide.mao -d AlignedCSS.meg
	"""
}*/


workflow.onComplete {
		log.info "Completed sucessfully:	$workflow.success"		
		log.info "Nextflow Version:	$workflow.nextflow.version"
		log.info "Duration:		$workflow.duration"
		log.info "Output Directory:	$params.outdir"
}
