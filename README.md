# etl-pgs-calculations

Loads polygenic score (PGS) results from pgsc_calc into the `prs_measurement`
database table.

For each trait folder, the script [load_pgs_scores.R](load_pgs_scores.R):

1. reads all `*.txt.gz` score files (also in sub-folders) and stacks them,
2. maps genotype sample IDs (`vkood`) to patient IDs (`skood`) and drops samples without a mapping,
3. strips the harmonisation suffix from the PGS ID (`PGS000001_hmPOS_GRCh37` → `PGS000001`),
4. computes the score decile (1–10) separately for each PGS ID,
5. adds the calculation date and appends the rows to `<db_schema>.prs_measurement`.

The comments at the top of the script describe the process in more detail.

## Requirements

- R 4.3 or newer
- Packages pinned in [renv.lock](renv.lock) (DBI, RPostgres, dplyr and their dependencies)
- Access to the PostgreSQL database (only when writing to it)

Install the packages once, from the repository folder:

```r
install.packages("renv")   # if not installed yet
renv::restore()
```

## Input

```
<input_dir>/
  T2D/                                <- one folder per trait
    aggregated_scores.txt.gz
  CAD/
    run1/aggregated_scores.txt.gz     <- all files in a trait folder are combined
    run2/aggregated_scores.txt.gz
```

**Score files**: tab-separated pgsc_calc output with at least the columns `IID`, `PGS` and `SUM`:

```
sampleset  IID      PGS                     SUM     DENOM  AVG
est        V000123  PGS000001_hmPOS_GRCh37  0.4312  1520   0.00028
```

**Mapping** from `vkood` to `skood`. Give it either as a TSV/CSV file (`--mapping_file`)
or as a database table (`--mapping_table=schema.table`):

```
vkood    skood
V000123  S987654
```

**Dates file** (optional): one calculation date per trait folder. Traits that are not
in the file get `--default_date`. A trait with neither stops the script.

```
trait  date
T2D    2025-03-01
```

## Output

Table `<db_schema>.prs_measurement` (default schema `pgs_calculations_work`):

| Column | Content |
|---|---|
| `patient_id` | `skood` from the mapping |
| `measurement_source_value` | PGS ID without the suffix |
| `pgs_score` | `SUM` from the score file |
| `pgs_score_percentile` | Decile 1–10 of `pgs_score` within the same PGS ID |
| `calculation_date` | Date from the dates file, or `--default_date` |

## Database credentials

The connection settings are read from environment variables. Put them in an
`.Renviron` file and pass its path with `--renviron`:

```
DB_HOST=...
DB_PORT=5432
DB_NAME=...
DB_USER=...
DB_PASSWORD=...
```

If your `.Renviron` uses other variable names, pass them with `--db_host_env`,
`--db_port_env`, `--db_name_env`, `--db_user_env` and `--db_password_env`.

## How to run

All parameters are passed as `--name=value`.

**1. Test run without writing to the database** (`dry_run` is `TRUE` by default).
This checks the input, prints row counts per file and per PGS ID, and can save the
result as CSV for checking:

```bash
Rscript load_pgs_scores.R \
  --input_dir=/home/me/PRS/test \
  --mapping_file=/home/me/vkood_skood.tsv \
  --dates_file=/home/me/dates.tsv \
  --output_csv_dir=/home/me/PRS/check
```

**2. Write to the database:**

```bash
Rscript load_pgs_scores.R \
  --renviron=/home/me/.Renviron \
  --input_dir=/home/me/PRS/test \
  --mapping_file=/home/me/vkood_skood.tsv \
  --dates_file=/home/me/dates.tsv \
  --db_schema=pgs_calculations_work_1 \
  --dry_run=FALSE
```

Rows are appended to the table. Running the same input twice loads the rows
twice. To replace the table contents instead, add `--overwrite=TRUE`. The first
trait then replaces the table and the following traits are appended.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `input_dir` | — (required) | Folder with one sub-folder per trait |
| `file_pattern` | `\.txt\.gz$` | Regex for score files inside each trait folder |
| `pgs_suffix` | `_hmPOS_GRCh37$` | Regex removed from the PGS ID |
| `mapping_file` | | TSV/CSV file with the ID mapping |
| `mapping_table` | | Database table with the ID mapping (`schema.table`), used if `mapping_file` is not set |
| `mapping_from_col` | `vkood` | Mapping column with the sample ID from the score file |
| `mapping_to_col` | `skood` | Mapping column with the patient ID |
| `dates_file` | | TSV/CSV file with a calculation date per trait |
| `dates_trait_col` | `trait` | Column in the dates file with the trait folder name |
| `dates_date_col` | `date` | Column in the dates file with the date |
| `default_date` | | Date for traits that are not in the dates file |
| `date_format` | `%Y-%m-%d` | Format of the dates |
| `n_quantiles` | `10` | Number of score groups (10 = deciles) |
| `db_schema` | `pgs_calculations_work` | Target schema |
| `db_table` | `prs_measurement` | Target table |
| `dry_run` | `TRUE` | `TRUE` = do not write to the database |
| `overwrite` | `FALSE` | `TRUE` = replace the table instead of appending |
| `output_csv_dir` | | If set, also writes `<trait>.csv` per trait here |
| `renviron` | | `.Renviron` file with the database credentials |
| `db_*_env` | `DB_HOST`, `DB_PORT`, … | Names of the environment variables with the connection settings |

### Reading the log

For each trait the script prints:

- every file it found and its row count,
- the number of distinct `IID`s, PGS IDs and `IID` × PGS pairs, and the number of duplicate rows,
- the number of `IID`s without a mapping, with up to 5 examples,
- the number of rows written per PGS ID.

Only the `vkood` → `skood` mapping removes rows. If far fewer rows are written than
read, check the "IIDs without mapping" line first.
