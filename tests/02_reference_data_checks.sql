-- Mwangaza AV (synthetic case study)
-- Checks for the reference data. Run after sql/02_reference/01_load_reference_data.sql.
-- STATUS: run on PostgreSQL 18.6; the project owner reports the counts matched the expected values. Output not yet saved in the repo.
--
-- Expected: sector 7, office 2, job_type 8, cost_category 5, product_category 8, asset_category 6.

SELECT 'sector'            AS table_name, count(*) AS row_count FROM core.sector
UNION ALL SELECT 'office',            count(*) FROM core.office
UNION ALL SELECT 'job_type',          count(*) FROM core.job_type
UNION ALL SELECT 'cost_category',     count(*) FROM core.cost_category
UNION ALL SELECT 'product_category',  count(*) FROM core.product_category
UNION ALL SELECT 'asset_category',    count(*) FROM core.asset_category
ORDER BY table_name;
