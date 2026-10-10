-- Mwangaza AV (synthetic case study)
-- Step 2: create the four layers as schemas (named folders inside the database).
-- Run while connected to the mwangaza_av database.
-- IF NOT EXISTS makes this safe to run twice. Nothing is dropped.

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS mart;

COMMENT ON SCHEMA raw     IS 'Synthetic data exactly as generated, including planted errors. Never edited.';
COMMENT ON SCHEMA staging IS 'Typed and cleaned copies of raw. Rejected rows are logged, not silently dropped.';
COMMENT ON SCHEMA core    IS 'Normalised model: the company''s day-to-day records. Synthetic data only.';
COMMENT ON SCHEMA mart    IS 'Star schema for reporting. Power BI reads from here. Synthetic data only.';
