-- =====================================================================
-- 00_load_raw.sql  —  LOCAL ONLY (DuckDB)
-- In Snowflake, skip this file: sessions, signups and opportunities
-- already exist as tables. Locally, this creates them from the CSVs.
-- Run from the folder that contains the data/ subfolder.
-- =====================================================================

CREATE OR REPLACE TABLE sessions      AS SELECT * FROM read_csv_auto('data/sessions.csv');
CREATE OR REPLACE TABLE signups       AS SELECT * FROM read_csv_auto('data/signups.csv');
CREATE OR REPLACE TABLE opportunities AS SELECT * FROM read_csv_auto('data/opportunities.csv');
