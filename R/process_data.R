#' @title Binarise CpG sites
#'
#' @description Script for binarising CpG sites and formatting the coverage file
#'   so it can be directly used from the BPRMeth package. The format of each
#'   file is the following: <chr> <start> <met_level>, where met_level can be
#'   either 0 or 1.
#' @param indir Directory containing the coverage files, output from Bismark.
#' @param outdir Directory to store the output files for each cell with exactly
#'   the same name. If NULL, then a directory called `binarised` inside `indir`
#'   will be create by default.
#' @param cores Number of cores to use for parallel processing. If NULL, no
#'   parallel processing is used.
#' @export
#'
binarise_files <- function(indir, outdir = NULL, cores = NULL) {
  # Whether or not to run on parallel mode
  is_parallel <- TRUE
  if (is.null(cores)) {
    is_parallel <- FALSE
    cores <- 1
  }
  # The out directory will be inside `indir/binarised`
  if (is.null(outdir)) {
    outdir <- paste0(indir, "/binarised")
  }
  # Create out directory if it doesn't exist
  ifelse(!dir.exists(outdir), dir.create(outdir), FALSE)

  # Load cell filenames
  filenames <- list.files(indir)

  i <- 0 # FOR CMD check to pass
  # Parallelise processing
  if (is_parallel) {
    doParallel::registerDoParallel(cores = cores)
    invisible(foreach::foreach(i = 1:length(filenames)) %dopar% {
      # Process each file
      .process_bismark_file(filename = filenames[i], cores = cores)
    })
    doParallel::stopImplicitCluster()
  }else {
    for (i in 1:length(filenames)) {
      # Process each file
      .process_bismark_file(filename = filenames[i], cores = cores)
    }
  }
}


# Private function for reading and processing a coverage bismark file
.process_bismark_file <- function(filename, cores) {
  cell <- sub(".gz","", filename)
  outfile <- sprintf("%s", cell)
  if (file.exists(paste0(outfile, ".gz"))) {
    cat(sprintf("Sample %s already processed, skipping...\n", cell))
  } else {
    cat(sprintf("Processing %s...\n", cell))
    # Load data
    data <- data.table::fread(cmd = sprintf("zcat < %s", filename),
                              verbose = FALSE, showProgress = FALSE)
    # Input format 2 (chr,pos,met_prcg,met_reads,unnmet_reads)
    colnames(data) <- c("chr","pos", "met_prcg", "met_reads","unnmet_reads")
    data[,rate := round((met_reads/(met_reads + unnmet_reads)))] %>%
      .[,c("met_prcg","met_reads","unnmet_reads") := NULL] %>%
      .[, chr := as.factor(sub("chr", "", chr))] %>%
      data.table::setkey(chr, pos)

    # Sanity check
    tmp <- sum((max(data$rate) > 1) | (min(data$rate) < 0))
    if (tmp > 0) {
      cat(sprintf("%s: There are %d CpG sites that have
                  methylation rate higher than 1 or lower than 0\n", cell, tmp))
    }
    # Calculate binary methylation status
    cat(sprintf("%s: There are %0.03f%% of sites with non-binary methylation
                rate\n", cell, mean(!data$rate %in% c(0,1))))
    # Save results
    data.table::fwrite(data, file = outfile, showProgress = FALSE,
                       verbose = FALSE, col.names = FALSE, sep = "\t")
    system(sprintf("pigz -p %d -f %s", cores, outfile))
  }
}


#' @title Create methylation regions for all cells
#'
#' @description Wrapper function for creating methylation regions for all cells,
#'   which is the input object for Melissa prior to filtering.
#'
#' @param met_dir Directory of (binarised) methylation files, each file
#'   corresponds to a single cell.
#' @param anno_file The annotation file with `tab` delimited format:
#'   "chromosome", "start", "end", "strand", "id", "name" (optional). Read the
#'   `BPRMeth` documentation for more details.
#' @param chrom_size_file Optional file name to read genome chromosome sizes.
#' @param chr_discarded Optional vector with chromosomes to be discarded.
#' @param is_centre Logical, whether 'start' and 'end' locations are
#'   pre-centred. If TRUE, the mean of the locations will be chosen as centre.
#'   If FALSE, the 'start' will be chosen as the center; e.g. for genes the
#'   'start' denotes the TSS and we use this as centre to obtain K-bp upstream
#'   and downstream of TSS.
#' @param is_window Whether to consider a predefined window region around
#'   centre. If TRUE, then 'upstream' and 'downstream' parameters are used,
#'   otherwise we consider the whole region from start to end location.
#' @param upstream Integer defining the length of bp upstream of 'centre' for
#'   creating the genomic region. If is_window = FALSE, this parameter is
#'   ignored.
#' @param downstream Integer defining the length of bp downstream of 'centre'
#'   for creating the genomic region. If is_window = FALSE, this parameter is
#'   ignored.
#' @param cov Integer defining the minimum coverage of CpGs that each region
#'   must contain.
#' @param sd_thresh Optional numeric defining the minimum standard deviation of
#'   the methylation change in a region. This is used to filter regions with no
#'   methylation variability.
#'
#' @return A \code{melissa_data_obj} object, with the following elements:
#'   \itemize{ \item{ \code{met}: A list of elements of length N, where N are
#'   the total number of cells. Each element in the list contains another list
#'   of length M, where M is the total number of genomic regions, e.g.
#'   promoters. Each element in the inner list is an \code{I X 2} matrix, where
#'   I are the total number of observations. The first column contains the input
#'   observations x (i.e. CpG locations) and the 2nd column contains the
#'   corresponding methylation level.} \item {\code{anno_region}: The annotation
#'   object.} \item {\code{opts}: A list with the parameters that were used for
#'   creating the object. } }
#'
create_melissa_data_obj <- function(met_dir, anno_file, chrom_size_file = NULL,
    chr_discarded = NULL, is_centre = FALSE, is_window = TRUE, upstream = -5000,
    downstream = 5000, cov = 5, sd_thresh = -1, cores = NULL) {

  # Parameter options
  opts <- list()
  opts$met_files <- list.files(met_dir, pattern = "*.gz", full.names = FALSE)
  opts$cell_names <- sapply(strsplit(opts$met_files, ".", fixed = TRUE), `[`, 1)
  opts$is_centre  <- is_centre   # Whether genomic region is already pre-centred
  opts$is_window  <- is_window   # Use predefined window region
  opts$upstream   <- upstream    # Upstream of centre
  opts$downstream <- downstream  # Downstream of centre
  opts$chrom_size <- chrom_size_file  # Chromosome size file
  opts$chr_discarded <- chr_discarded # Chromosomes to discard
  opts$cov        <- cov         # Regions with at least n CpGs
  opts$sd_thresh  <- sd_thresh   # Variance of methylation within region

  # Read annotation file and create annotation regions
  anno_region <- BPRMeth::read_anno(file = anno_file,
        chrom_size_file = opts$chrom_size, chr_discarded = opts$chr_discarded,
        is_centre = opts$is_centre, is_window = opts$is_window,
        upstream = opts$upstream, downstream = opts$downstream,
        is_anno_region = TRUE, delimiter = "\t")

  # Create methylation regions
  if (is.null(cores)) {
    met <- lapply(X = opts$met_files, FUN = function(n){
      # Read scBS seq data
      met_dt <- BPRMeth::read_met(file = sprintf("zcat < %s/%s", met_dir, n),
                                  type = "sc_seq", strand_info = FALSE)
      # Create promoter methylation regions
      res <- BPRMeth::create_region_object(met_dt = met_dt, anno_dt = anno_region,
                  cov = opts$cov, sd_thresh = opts$sd_thresh,
                  ignore_strand = TRUE, filter_empty_region = FALSE)$met
      names(res) <- NULL
      return(res)
    })
  } else{
    met <- parallel::mclapply(X = io$met_files, FUN = function(n){
      # Read scBS seq data
      met_dt <- BPRMeth::read_met(file = sprintf("zcat < %s/%s", met_dir, n),
                                  type = "sc_seq", strand_info = FALSE)
      # Create promoter methylation regions
      res <- BPRMeth::create_region_object(met_dt = met_dt, anno_dt = anno_region,
                  cov = opts$cov, sd_thresh = opts$sd_thresh,
                  ignore_strand = TRUE, filter_empty_region = FALSE)$met
      names(res) <- NULL
      return(res)
    }, mc.cores = cores)
  }

  # Add cell names to list
  names(met) <- opts$cell_names
  # Store the object
  obj <- structure(list(met = met, anno_region = anno_region, opts = opts),
                   class = "melissa_data_obj")
  return(obj)
}
