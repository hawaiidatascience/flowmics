// Import generic module functions
include { initOptions; saveFiles; getSoftwareName } from './functions'

options = initOptions(params.options)

process SUBSET_READS_RDS {
    tag "$meta.id"
    label "process_low"
    publishDir "${params.outdir}",
        saveAs: { filename -> saveFiles(filename:filename, options:params.options,
                                        meta:meta) }

    container "nakor/metaflowmics-script-env:0.0.1"
    conda (params.enable_conda ? "conda-forge::r-stringr bioconda::bioconductor-dada2=1.18 conda-forge::r-seqinr" : null)

    input:
    tuple val(meta), path(rds), path(fasta)

    output:
    tuple val(meta), path("*.RDS"), emit: rds
    path "summary.csv", emit: summary
    // path "*.version.txt", emit: version

    script:
    // def software = getSoftwareName(task.process)
    """
    #!/usr/bin/env Rscript
    library(stringr)
    library(dada2)
    library(seqinr)

    ## Extract non chimeric sequences from derep file
    derep <- readRDS("$rds")
    seq.clean <- names(read.fasta("$fasta", seqtype="DNA"))

    ## Get indices from no chimeric sequences
    indices <- as.numeric(sapply(seq.clean,
        function(x) str_extract(x,"[0-9]+")))

    ## Subset the indices from derep-class object
    derep[["uniques"]] <- derep[["uniques"]][indices]
    derep[["quals"]] <- derep[["quals"]][indices,]
    derep[["map"]] <- derep[["map"]][which(derep[["map"]] %in% indices)]
    
    ## Handle special case where the longest sequence is removed
    seq.lengths <- sapply(names(derep[["uniques"]]),nchar)
    derep[["quals"]] <- derep[["quals"]][,1:max(seq.lengths)]

    saveRDS(derep, "${meta.id}-nochim_R1.RDS")

    # Write counts
    counts <- getUniques(derep)
    data <- sprintf("Chimera,${meta.id},%s,%s",sum(counts),sum(counts>0))
    write(data, "summary.csv")
    """
}

process BUILD_ASV_TABLE {
    tag "asv_table"
    label "process_low"
    publishDir "${params.outdir}",
        saveAs: { filename -> saveFiles(filename:filename, options:params.options,
                                        meta:meta) }

    container "nakor/metaflowmics-script-env:0.0.1"    
    conda (params.enable_conda ? "conda-forge::r-stringr bioconda::bioconductor-dada2=1.18 conda-forge::r-seqinr" : null)

    input:
    path(rds)

    output:
    path "ASVs_duplicates_to_cluster.fasta", emit: fasta_dup
    tuple val(100), path("ASVs-100.fasta"), emit: fasta    
    tuple val(100), path("ASVs-100.{count_table,tsv}"), emit: tsv
    // path "*.version.txt", emit: version

    script:
    // def software = getSoftwareName(task.process)
    """
    #!/usr/bin/env Rscript
    library(dada2)
    library(seqinr)

    # Collect denoised reads
    denoised <- list.files(path=".", pattern="*-denoised.RDS")

    sample_names <- unname(sapply(denoised, function(x) gsub("-denoised.RDS", "", x)))
    merged <- lapply(denoised, function (x) readRDS(x))
    names(merged) <- sample_names
    
    # Retrieve merged object
    asv_table <- makeSequenceTable(merged)
    asv_ids <- sprintf("asv_%s", 1:dim(asv_table)[2])

    # Write ASV sequences
    uniquesToFasta(asv_table, "ASVs-100.fasta", ids=asv_ids)

    # Format count table
    count_table <- cbind(
        asv_ids, 
        colSums(asv_table),
        t(asv_table[rowSums(asv_table)>0,])
    )
    colnames(count_table) <- c("Representative_Sequence", "total", sample_names)

    if ("${params.format.toLowerCase()}" == "mothur") {
        # Write abundances
        write.table(count_table, file="ASVs-100.count_table", quote=F, sep="\\t",
                    row.names=F, col.names=T)
    } else {
        # Write abundances
        write.table(count_table[, -c(2)],"ASVs-100.tsv", quote=F, row.names=F, sep="\\t")

        # Write duplicated fasta sequences with header formatted for VSEARCH
        list.fasta <- list()
        i = 1
        for(seq in colnames(asv_table)) {
            for(sample in rownames(asv_table)) {
                abd = asv_table[sample, seq]
                if(abd > 0) {
                    seq_id = sprintf("asv_%s;sample=%s;size=%s", i, sample, abd)
                    list.fasta[seq_id] = seq
                }
            }
            i <- i+1
        }
        write.fasta(list.fasta, names=names(list.fasta), 
                    file.out='ASVs_duplicates_to_cluster.fasta')
    }
    """
}

process READ_TRACKING {
    tag "read_tracking"
    label "process_low"
    publishDir "${params.outdir}",
        saveAs: { filename -> saveFiles(filename:filename, options:params.options,
                                        meta:meta) }

    container "nakor/metaflowmics-script-env:0.0.1"
    conda (params.enable_conda ? "" : null)

    input:
    path counts

    output:
    file('summary*.csv')

    script:
    // def software = getSoftwareName(task.process)
    """
    #!/usr/bin/env Rscript    

    library(dplyr)
    library(tidyr)

    data <- read.csv('summary.csv', header=F)
    colnames(data) <- c('step', 'sample', 'total', 'nuniq')

    # Order the step according to total count and uniques
    col_order <- data %>% replace_na(list(nuniq=Inf)) %>%
        group_by(step) %>% summarise(m1=sum(total), m2=sum(nuniq)) %>%
        arrange(desc(m1), desc(m2)) %>% 
        pull(step) %>% as.character

    # Reshape the table into wide format
    summary <- data %>% 
      mutate(
        step=factor(step, col_order),
        label=ifelse(is.na(nuniq), total, sprintf("%s (%s uniques)", total, nuniq))
      ) %>% 
      select(step, sample, label) %>%
      arrange(step) %>%
      pivot_wider(names_from=step, values_from=label)

    write.csv(summary, 'summary-per-sample-per-step.csv', quote=F, row.names=F)
    """
}
