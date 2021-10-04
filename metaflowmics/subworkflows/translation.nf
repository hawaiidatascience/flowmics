#!/usr/bin/env nextflow

nextflow.enable.dsl=2
params.options = [:]
params.db = null

module_dir = "../modules"


include{ EMBOSS_TRANSEQ } from "$module_dir/emboss/transeq/main.nf" \
    addParams( options: [publish_dir: "transeq"], table: 5, frames: 6 )
include{ COUNT_KMERS } from "$module_dir/python/kmer_counting/main.nf" \
    addParams( options: [publish_dir: "kmer_orf_picking"],
              k: 2, feature: 'prot' )
include{ KMER_FILTER } from "$module_dir/python/kmer_filter/main.nf" \
    addParams( options: [publish_dir: "kmer_orf_picking"],
              k: 2, feature: 'prot', n_sub: 50 )

workflow TRANSLATE {
    take:
    fasta

    main:
    all_orf = EMBOSS_TRANSEQ( fasta )

    ref = params.db ?
        file(params.db, checkIfExists: true) :
        all_orf.single.map{it[1]}.collectFile(name: "ref.faa").first() // make it a value channel
    
    kmer_db = COUNT_KMERS( ref ).freqs
    
    mult_orf_picked = KMER_FILTER(
        all_orf.multiple,
        kmer_db
    )

    translated = all_orf.single.mix(mult_orf_picked)
		.map{it[1]}
        .collectFile(name: 'translated.faa')
		.first() // make it a value channel

	// put the metadata back
	translated = fasta.combine(translated).map{[it[0], it[2]]}

    emit:
    faa = translated
}
