#!/usr/bin/env Rscript
# =============================================================================
# Load PGS (polygenic score) results into the prs_measurement table
# =============================================================================
#
# PROCESS OVERVIEW
# ----------------
#   1. Read parameters (defaults below, overridable as --name=value).
#   2. Connect to the database (only when writing, or when the ID mapping
#      is read from a DB table).
#   3. Load the sample_code -> patient_id ID mapping and the per-trait calculation dates.
#   4. For every trait folder under `input_dir`:
#        a. find all score files (*.txt.gz) in the folder and its sub-folders,
#        b. read and stack them into one table,
#        c. log row counts (files, distinct samples/PGS, duplicates, unmapped),
#        d. transform the scores into prs_measurement rows,
#        e. write the rows to <db_schema>.<db_table> (and optionally to CSV).
#
# INPUT LAYOUT
# ------------
#   <input_dir>/
#     T2D/                              <- one folder per trait (folder name =
#       aggregated_scores.txt.gz           key into dates_file)
#     CAD/
#       run1/aggregated_scores.txt.gz   <- several files are stacked together
#       run2/aggregated_scores.txt.gz
#
# Score files are tab-separated pgsc_calc output, one row per sample x PGS:
#   sampleset  IID      PGS                       SUM      DENOM  AVG
#   est        V000123  PGS000001_hmPOS_GRCh37    0.4312   1520   0.00028
#
# Mapping file (sample_code = genotype sample ID in the IID column, patient_id = patient ID):
#   sample_code  patient_id
#   V000123      S987654
#
# Dates file (optional, one calculation date per trait folder):
#   trait  date
#   T2D    2025-03-01
#
# OUTPUT: <db_schema>.prs_measurement
# -----------------------------------
#   patient_id  measurement_source_value  pgs_score  pgs_score_percentile  calculation_date
#   S987654     PGS000001                 0.4312     7                     2025-03-01
#
#   patient_id                from the mapping (samples without one are dropped)
#   measurement_source_value  PGS id without the harmonisation suffix
#   pgs_score                 SUM column of the score file
#   pgs_score_percentile      decile 1..10 of pgs_score within the same PGS id
#   calculation_date          date from dates_file for the trait, else default_date
#
# USAGE
# -----
#   Rscript 01_load_pgs_scores/load_pgs_scores.R --input_dir=/home/me/PRS/test \
#     --mapping_file=/home/me/id_mapping.tsv --dates_file=/home/me/dates.tsv \
#     --db_schema=pgs_calculations_work_1 --dry_run=FALSE
#
# Database credentials are read from environment variables (see db_*_env below),
# optionally loaded from an .Renviron file given by --renviron.
# Packages are pinned in renv.lock (install with renv::restore()).

suppressPackageStartupMessages({
  library(DBI)        # generic database interface (connect, read, write tables)
  library(RPostgres)  # PostgreSQL driver for DBI
  library(dplyr)      # data transformation
})

# ---- 1. Parameters ----------------------------------------------------------
# Defaults for every setting. Any of them can be overridden on the command line
# as --name=value; the type (text, number, TRUE/FALSE) follows the default.

params <- list(
  # Input
  renviron          = "",                     # path to .Renviron with DB credentials ("" = skip)
  input_dir         = "",                     # folder containing one sub-folder per trait
  file_pattern      = "\\.txt\\.gz$",         # score files to pick up inside each trait folder
  pgs_suffix        = "_hmPOS_GRCh37$",       # regex stripped from the PGS id

  # sample_code -> patient_id mapping: either a TSV/CSV file or a DB table (schema.table)
  mapping_file      = "",
  mapping_table     = "",
  mapping_from_col  = "sample_code",
  mapping_to_col    = "patient_id",

  # Calculation date: per-trait from dates_file (columns: trait, date), else default_date
  dates_file        = "",
  dates_trait_col   = "trait",
  dates_date_col    = "date",
  default_date      = "",                     # YYYY-MM-DD, used when a trait has no entry
  date_format       = "%Y-%m-%d",

  n_quantiles       = 10,                     # 10 = deciles

  # Output
  db_schema         = "pgs_calculations_work",
  db_table          = "prs_measurement",
  overwrite         = FALSE,                  # TRUE replaces the table instead of appending
  dry_run           = TRUE,                   # TRUE = do not write to the DB
  output_csv_dir    = "",                     # if set, also write one CSV per trait here

  # Environment variables holding the DB connection settings
  db_host_env       = "DB_HOST",
  db_port_env       = "DB_PORT",
  db_name_env       = "DB_NAME",
  db_user_env       = "DB_USER",
  db_password_env   = "DB_PASSWORD"
)

# Override the defaults above with --name=value command-line arguments.
# Unknown names or malformed arguments stop the script.
parse_args <- function(params, args = commandArgs(trailingOnly = TRUE)) {
  for (arg in args) {
    m <- regmatches(arg, regexec("^--([^=]+)=(.*)$", arg))[[1]]
    if (length(m) != 3) stop("Bad argument '", arg, "', expected --name=value")
    key <- m[2]
    val <- m[3]
    if (!key %in% names(params)) stop("Unknown parameter: ", key)
    # convert the text value to the same type as the default
    default <- params[[key]]
    params[[key]] <- if (is.logical(default)) {
      as.logical(toupper(val))
    } else if (is.numeric(default)) {
      as.numeric(val)
    } else {
      val
    }
  }
  params
}

params <- parse_args(params)

# Fail early if the input folder is missing; load DB credentials if requested.
if (params$input_dir == "" || !dir.exists(params$input_dir)) {
  stop("input_dir does not exist: '", params$input_dir, "'")
}
if (params$renviron != "") readRenviron(params$renviron)

# ---- Helpers ----------------------------------------------------------------

# Read a TSV/CSV file (gzipped or not). The separator is chosen by extension.
# All columns are read as text so IDs keep leading zeros; numbers are
# converted later where needed.
read_delim_auto <- function(path) {
  sep <- if (grepl("\\.csv(\\.gz)?$", path)) "," else "\t"
  read.delim(path, sep = sep, stringsAsFactors = FALSE, check.names = FALSE,
             colClasses = "character")
}

# ---- 2. Database connection -------------------------------------------------
# Open a PostgreSQL connection using the environment variables named in params.
connect_db <- function(params) {
  env <- function(name) {
    val <- Sys.getenv(params[[name]])
    if (val == "") stop("Environment variable ", params[[name]], " is not set")
    val
  }
  DBI::dbConnect(
    RPostgres::Postgres(),
    host     = env("db_host_env"),
    port     = as.integer(env("db_port_env")),
    dbname   = env("db_name_env"),
    user     = env("db_user_env"),
    password = env("db_password_env")
  )
}

# ---- 3. ID mapping and calculation dates ------------------------------------

# Load the sample_code -> patient_id mapping from a file or a DB table and return a
# two-column table (sample_code, patient_id): rows with an empty ID are dropped and each
# sample_code is kept once, so the join in transform_pgs() never duplicates rows.
load_mapping <- function(params, db) {
  if (params$mapping_file != "") {
    mapping <- read_delim_auto(params$mapping_file)
  } else if (params$mapping_table != "") {
    if (is.null(db)) stop("mapping_table needs a DB connection")
    # "schema.table" or just "table"
    parts <- strsplit(params$mapping_table, ".", fixed = TRUE)[[1]]
    tbl_id <- if (length(parts) == 2) DBI::Id(schema = parts[1], table = parts[2]) else DBI::Id(table = parts[1])
    cols <- DBI::dbQuoteIdentifier(db, c(params$mapping_from_col, params$mapping_to_col))
    mapping <- DBI::dbGetQuery(db, paste0(
      "SELECT ", paste(cols, collapse = ", "), " FROM ", DBI::dbQuoteIdentifier(db, tbl_id)))
  } else {
    stop("Set either mapping_file or mapping_table")
  }

  missing <- setdiff(c(params$mapping_from_col, params$mapping_to_col), names(mapping))
  if (length(missing) > 0) stop("Mapping is missing column(s): ", paste(missing, collapse = ", "))

  mapping %>%
    transmute(sample_code = as.character(.data[[params$mapping_from_col]]),
              patient_id = as.character(.data[[params$mapping_to_col]])) %>%
    filter(!is.na(sample_code), !is.na(patient_id)) %>%
    distinct(sample_code, .keep_all = TRUE)
}

# Load the dates file as a named vector: trait folder name -> date string.
# Returns NULL when no dates file is given (default_date is used for all).
load_dates <- function(params) {
  if (params$dates_file == "") return(NULL)
  dates <- read_delim_auto(params$dates_file)
  setNames(dates[[params$dates_date_col]], dates[[params$dates_trait_col]])
}

# Calculation date for one trait: its entry in the dates file, else default_date.
# Stops if neither is available so no rows are written without a date.
trait_date <- function(trait_name, dates, params) {
  date_string <- if (!is.null(dates) && trait_name %in% names(dates)) dates[[trait_name]] else params$default_date
  if (is.na(date_string) || date_string == "") {
    stop("No calculation date for trait '", trait_name, "' (add it to dates_file or set default_date)")
  }
  as.Date(date_string, format = params$date_format)
}

# ---- 4c. Logging -------------------------------------------------------------

# Print where input rows go: distinct samples/PGS ids, duplicates and unmapped ids.
# Only the sample_code -> patient_id join removes rows, so these numbers explain the
# difference between input rows and rows written.
log_input_summary <- function(pgs_data, mapping) {
  iid <- as.character(pgs_data$IID)
  n_pairs <- nrow(distinct(pgs_data, IID, PGS))
  unmapped <- unique(iid[!iid %in% mapping$sample_code])
  cat("   distinct IID:", length(unique(iid)),
      "| distinct PGS:", length(unique(pgs_data$PGS)),
      "| distinct IID x PGS:", n_pairs,
      "| duplicate rows:", nrow(pgs_data) - n_pairs, "\n")
  if ("sampleset" %in% names(pgs_data)) {
    cat("   samplesets:", paste(unique(pgs_data$sampleset), collapse = ", "), "\n")
  }
  cat("   IIDs without mapping:", length(unmapped),
      if (length(unmapped) > 0) paste0("(e.g. ", paste(head(unmapped, 5), collapse = ", "), ")"), "\n")
  if (n_pairs < nrow(pgs_data)) {
    warning("Input contains ", nrow(pgs_data) - n_pairs, " duplicate IID x PGS rows", call. = FALSE)
  }
}

# ---- 4d. Transformation: score file rows -> prs_measurement rows -------------

# Score group 1..n of x by quantiles (n = 10 gives deciles, 1 = lowest scores).
# If too many equal scores make two quantile boundaries identical, cut() cannot
# be used, so it falls back to splitting into n equal-sized groups.
quantile_group <- function(x, n) {
  breaks <- quantile(x, probs = seq(0, 1, length.out = n + 1), na.rm = TRUE)
  if (anyDuplicated(breaks)) return(dplyr::ntile(x, n))
  as.integer(cut(x, breaks = breaks, include.lowest = TRUE, labels = FALSE))
}

# Turn the stacked score files of one trait into prs_measurement rows.
# Step numbers refer to the original (screenshot) version of this script.
transform_pgs <- function(pgs_data, mapping, calculation_date, params) {
  required <- c("IID", "PGS", "SUM")
  missing <- setdiff(required, names(pgs_data))
  if (length(missing) > 0) stop("Score file is missing column(s): ", paste(missing, collapse = ", "))

  pgs_data %>%
    # strip the harmonisation suffix from the PGS id
    # (PGS000001_hmPOS_GRCh37 -> PGS000001) and set column types
    mutate(PGS = gsub(params$pgs_suffix, "", PGS),
           IID = as.character(IID),
           SUM = as.numeric(SUM)) %>%
    # 1-2, 6) drop sampleset, DENOM and AVG (keep only what we need)
    select(IID, PGS, SUM) %>%
    # 3-4) map sample_code -> patient_id, drop unmapped
    #      (the only step that removes rows)
    inner_join(mapping, by = c("IID" = "sample_code")) %>%
    # 7) score percentile group, computed separately for each PGS
    #    and only over the mapped patients
    group_by(PGS) %>%
    mutate(pgs_score_percentile = quantile_group(SUM, params$n_quantiles)) %>%
    ungroup() %>%
    # 5, 8, 9) final column names/order; drops IID (sample_code)
    #          and adds the calculation date
    transmute(patient_id,
              measurement_source_value = PGS,
              pgs_score                = SUM,
              pgs_score_percentile,
              calculation_date         = calculation_date)
}

# ---- 4e. Output ---------------------------------------------------------------

# Write one trait's rows: optionally to <output_csv_dir>/<trait>.csv, and to the
# DB table unless dry_run is TRUE. Rows are appended; with overwrite = TRUE the
# table is replaced (main loop does this for the first trait only).
store_pgs <- function(result, trait_name, db, params) {
  if (params$output_csv_dir != "") {
    dir.create(params$output_csv_dir, showWarnings = FALSE, recursive = TRUE)
    out <- file.path(params$output_csv_dir, paste0(trait_name, ".csv"))
    write.csv(result, out, row.names = FALSE)
    cat("  wrote", out, "\n")
  }
  if (params$dry_run) {
    cat("  dry run: skipping DB write of", nrow(result), "rows\n")
    return(invisible())
  }
  DBI::dbWriteTable(db, DBI::Id(schema = params$db_schema, table = params$db_table),
                    result, append = !params$overwrite, overwrite = params$overwrite)
  cat("  wrote", nrow(result), "rows to", paste0(params$db_schema, ".", params$db_table), "\n")
}

# ---- Main ---------------------------------------------------------------------

# 2) Connect only when needed: writing to the DB, or reading the mapping from it.
#    The connection is closed automatically when the script ends.
needs_db <- !params$dry_run || (params$mapping_table != "" && params$mapping_file == "")
db <- if (needs_db) connect_db(params) else NULL
if (!is.null(db)) on.exit(DBI::dbDisconnect(db), add = TRUE)

# 3) Lookups shared by all traits
mapping <- load_mapping(params, db)
dates <- load_dates(params)
cat("Loaded", nrow(mapping), "sample_code -> patient_id mappings\n")

# 4) Every direct sub-folder of input_dir is one trait
subject_folders <- list.dirs(params$input_dir, recursive = FALSE)
cat("Found", length(subject_folders), "trait folders in", params$input_dir, "\n")

for (trait in subject_folders) {
  trait_name <- basename(trait)
  cat("Processing:", trait_name, "\n")

  # 4a) all score files in the trait folder, including sub-folders
  files <- list.files(trait, pattern = params$file_pattern, recursive = TRUE, full.names = TRUE)
  if (length(files) == 0) {
    cat("  no score files found, skipping\n")
    next
  }
  cat("  files:", paste(basename(files), collapse = ", "), "\n")

  # 4b) read every file and stack them into one table
  pgs_list <- lapply(files, read_delim_auto)
  for (i in seq_along(files)) {
    cat("  ", files[i], ":", nrow(pgs_list[[i]]), "rows\n")
  }
  pgs_data <- do.call(rbind, pgs_list)
  rm(pgs_list)

  # 4c) input summary
  log_input_summary(pgs_data, mapping)

  # 4d) transform to prs_measurement rows and log the count per PGS id
  result <- transform_pgs(pgs_data, mapping, trait_date(trait_name, dates, params), params)
  cat("  ", nrow(pgs_data), "input rows ->", nrow(result), "mapped rows\n")
  print(as.data.frame(count(result, measurement_source_value, name = "rows")), row.names = FALSE)

  # 4e) write to the DB (and CSV if requested)
  store_pgs(result, trait_name, db, params)

  # overwrite only on the first write, append afterwards
  params$overwrite <- FALSE

  # free memory before the next (possibly large) trait
  rm(pgs_data, result)
  gc()
}

cat("Processing done.\n")
