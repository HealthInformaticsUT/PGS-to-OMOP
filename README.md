# etl-pgs-calculations

Example workflow for loading polygenic score (PGS) results into an OMOP CDM database.
The score files are generated with the
[PGS Catalog Calculator (pgsc_calc) v2.0.0](https://github.com/PGScatalog/pgsc_calc).

## Workflow

```
pgsc_calc score files (*.txt.gz)
        │
        │  Step 1: 01_load_pgs_scores/load_pgs_scores.R
        ▼
pgs_calculations_work.prs_measurement
        │
        │  Step 2: 02_convert_to_omop/measurement-calculations-pgs-scores.sql
        ▼
OMOP CDM measurement table (staging schema)
```

| Step | Folder | What it does |
|---|---|---|
| 1 | [01_load_pgs_scores](01_load_pgs_scores/README.md) | Reads the pgsc_calc score files, maps sample IDs to patient IDs, computes score deciles and writes `pgs_calculations_work.prs_measurement` |
| 2 | [02_convert_to_omop](02_convert_to_omop/README.md) | Inserts each score and its percentile from `pgs_calculations_work.prs_measurement` into the OMOP CDM `measurement` table (SQL, run with `psql`) |

Run the steps in order, from the repository root. Each folder's README describes
the step's input, output and parameters.

## Folder structure

```
etl-pgs-calculations/
  README.md                  <- this file: workflow overview and setup
  renv.lock                  <- R package versions for all steps
  01_load_pgs_scores/
    README.md
    load_pgs_scores.R
  02_convert_to_omop/
    README.md
    measurement-calculations-pgs-scores.sql
    source_to_concept_map_example/
      source_to_concept_map.csv
```

## Requirements

- R 4.3 or newer
- Packages pinned in [renv.lock](renv.lock) (DBI, RPostgres, dplyr and their dependencies)
- Access to the PostgreSQL database
- `psql` client (step 2)

Install the packages once, from the repository root:

```r
install.packages("renv")   # if not installed yet
renv::restore()
```

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
