# Premier League Data Pipeline

An end-to-end data pipeline that pulls Premier League data from the football-data.org API, lands it in Azure, and models it in Snowflake using a Bronze / Silver / Gold (medallion) setup with a star schema in the Gold layer.

I built this to practise the tools that come up most in junior data engineering roles: Azure Data Factory for ingestion and scheduling, Blob Storage as the landing zone, and Snowflake for transformation and modelling.

## Architecture

```
football-data.org API
        |
        v
Azure Data Factory  (3 chained Copy activities, weekly trigger)
        |
        v
Azure Blob Storage  (bronze container, date-stamped JSON files)
        |
        v
Snowflake external stage
        |
        v
BRONZE  ->  SILVER  ->  GOLD
(raw)       (clean)     (star schema + analysis views)
```

## Tech Stack

- **Azure Data Factory** - ingestion and scheduling
- **Azure Blob Storage** - raw landing zone
- **Snowflake** - storage, transformation and modelling
- **SQL** - CTEs, window functions, LATERAL FLATTEN
- **Source:** football-data.org API (free tier)

## How It Works

### 1. Ingestion (Azure Data Factory)

- One pipeline, `pl_ingest_football`, with three Copy activities chained on success: `copy_matches` -> `copy_teams` -> `copy_standings`
- Calls three endpoints: `competitions/PL/matches`, `competitions/PL/teams` and `competitions/PL/standings`
- The API key is sent as an `X-Auth-Token` header in the REST linked service
- Each activity retries twice if the API call fails
- Files are saved with the date in the name, e.g. `matches_20261027.json`, so every load is kept instead of being overwritten
- A weekly schedule trigger runs the pipeline automatically

### 2. Bronze (Raw)

- An external stage points Snowflake at the `bronze` container
- `COPY INTO` loads each file into a raw table (`raw_matches`, `raw_teams`, `raw_standings`) as a single `VARIANT` column
- Each row also stores `file_name` and `loaded_at`, so every record can be traced back to the file it came from
- `COPY INTO` skips files it has already loaded, so re-running it doesn't create duplicates

### 3. Silver (Clean)

- `LATERAL FLATTEN` turns the nested JSON lists into one row per match, team or table position
- Fields are pulled out into typed columns (ints, timestamps, strings)
- Every weekly file contains the full season, so the same match appears in multiple loads. `ROW_NUMBER()` keeps only the latest version of each match, so a match that was SCHEDULED last week and FINISHED this week shows the updated score
- Standings are flattened twice (list of tables -> list of positions) and only the `TOTAL` table is kept. The date is taken from the file name so each week's table is kept as history

| Table | Grain | Rows |
|---|---|---|
| `silver.matches` | one row per match | 380 |
| `silver.teams` | one row per team | 20 |
| `silver.standings` | one row per team per weekly snapshot | 20 per week |

### 4. Gold (Star Schema + Analysis)

```
                 dim_date
                    |
                date_key
                    |
dim_team --- fact_matches --- dim_team
(home_team_id)            (away_team_id)
```

- `fact_matches` holds finished matches only: match_id, date_key, matchday, home/away team IDs, goals, result (H/D/A) and points
- `dim_team` is used twice (home and away), a role-playing dimension
- `dim_date` has one row per match date with day name, month and a weekend flag

| View | What it shows |
|---|---|
| `vw_league_table` | League table calculated from match results (points, goal difference, ranking) |
| `vw_table_check` | My calculated table compared with the official API standings |
| `vw_home_vs_away` | Home win %, draw %, away win % and average goals |
| `vw_team_form` | Each team's last 5 results, e.g. `W W D L W` |

## Data Quality Checks

- No duplicate matches after dedupe (row count = distinct match IDs)
- Every finished match has a score
- Every team in `matches` exists in `teams`
- In standings, won + drawn + lost = games played, and points = 3 x won + drawn
- **League table reconciliation:** I rebuild the table from match results and compare it with the official standings from the API. Any difference in points or games played is flagged as `MISMATCH`

## Screenshots

### ADF Pipeline
![ADF pipeline](images/adf_pipeline.png)

### Successful Run
![Pipeline run](images/adf_run.png)

### Date-Stamped Files in Blob Storage
![Blob files](images/blob_files.png)

### League Table (Calculated in Snowflake)
![League table](images/league_table.png)

### Table Check vs Official Standings
![Table check](images/table_check.png)

## Repo Structure

```
premier-league-data-pipeline/
├── README.md
├── sql/
│   ├── 01_bronze.sql
│   ├── 02_silver.sql
│   └── 03_gold.sql
├── adf/        (pipeline JSON exported from ADF)
└── images/     (screenshots)
```

## How to Run It

1. Get a free API key from football-data.org
2. In Azure, create a resource group, a storage account with a `bronze` container, and a Data Factory
3. In ADF, create a REST linked service (base URL `https://api.football-data.org/v4/`, `X-Auth-Token` header) and a Blob linked service, then build the pipeline as described above
4. Generate a read/list SAS token for the storage account
5. In Snowflake, run `01_bronze.sql` (replace `<your_sas_token_here>` with your token), then `02_silver.sql`, then `03_gold.sql`

Secrets (API key, SAS token) are not committed to this repo.

## Problems I Ran Into

- **Snowflake couldn't connect to the stage** (`General OpenSslEngine problem`). The storage account name in the stage URL was wrong. Fixed by copying the exact Blob endpoint from Azure.
- **A file was saved with the expression as its name.** I'd typed the `@concat(...)` expression straight into the file name box instead of using "Add dynamic content", so ADF treated it as plain text.
- **No default warehouse** on my Snowflake trial, so I created an XSMALL one with auto-suspend at 60 seconds to keep costs down.
- **Files overwritten on every run** at first. Switched to date-stamped file names using a dataset parameter.

## Design Decisions

- **Date-stamped raw files** - raw data is never overwritten, so I keep full history and can reprocess if a later step has a bug
- **Full season pulled every run** - simpler than tracking changes, and dedupe in Silver keeps the latest version of each match
- **Weekly trigger** - enough for this data since every pull has the whole season, and keeps API calls and costs low
- **ADF for ingestion only, Snowflake for transformation** - keeps each tool doing what it's good at
- **Copy activity only, no Data Flows** - Data Flows spin up Spark clusters and cost more than this project needs
