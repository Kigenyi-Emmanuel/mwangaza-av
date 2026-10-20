-- Mwangaza AV (synthetic case study)
-- NULL AUDIT of the core tables. READ-ONLY: it only counts. It changes nothing.
-- Run it any time after Stage 17, in the mwangaza_av database. Status: not yet executed.
--
-- Why: some core columns are meant to be empty (NULL) for some rows. This query counts the NULLs in each
-- such column and compares the count with what the design says it should be.
-- PASS means the empty cells are exactly where the design says they should be: no more, no fewer.
-- (Columns declared NOT NULL cannot hold a NULL at all, so they are not listed.)
-- One result table. Every row should say PASS.

SELECT table_name, column_name, nulls_found, nulls_expected, rule,
       CASE WHEN nulls_found = nulls_expected THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'core.invoice' AS table_name, 'job_id' AS column_name,
           (SELECT count(*) FROM core.invoice WHERE job_id IS NULL) AS nulls_found,
           (SELECT count(*) FROM core.invoice WHERE division <> 'projects') AS nulls_expected,
           'Filled only on projects invoices. Empty means "not applicable"' AS rule
    UNION ALL
    SELECT 2, 'core.invoice', 'sales_order_id',
           (SELECT count(*) FROM core.invoice WHERE sales_order_id IS NULL),
           (SELECT count(*) FROM core.invoice WHERE division <> 'products'),
           'Filled only on products invoices. Empty means "not applicable"'
    UNION ALL
    SELECT 3, 'core.invoice', 'rental_booking_id',
           (SELECT count(*) FROM core.invoice WHERE rental_booking_id IS NULL),
           (SELECT count(*) FROM core.invoice WHERE division <> 'rentals'),
           'Filled only on rentals invoices. Empty means "not applicable"'
    UNION ALL
    SELECT 4, 'core.quote', 'decision_date',
           (SELECT count(*) FROM core.quote WHERE decision_date IS NULL),
           (SELECT count(*) FROM core.quote WHERE status IN ('open', 'expired')),
           'Empty while a quote is open or expired. Empty means "not decided"'
    UNION ALL
    SELECT 5, 'core.job', 'end_date',
           (SELECT count(*) FROM core.job WHERE end_date IS NULL),
           (SELECT count(*) FROM core.job WHERE status = 'in_progress'),
           'Empty while a job is in progress. Empty means "not finished yet"'
    UNION ALL
    SELECT 6, 'core.job', 'quote_id',
           (SELECT count(*) FROM core.job WHERE quote_id IS NULL),
           (SELECT count(*) FROM staging.job WHERE quote_number IS NULL),
           'Empty when the job had no quote. Empty means "not applicable"'
    UNION ALL
    SELECT 7, 'core.sales_order', 'quote_id',
           (SELECT count(*) FROM core.sales_order WHERE quote_id IS NULL),
           (SELECT count(*) FROM staging.sales_order WHERE quote_number IS NULL),
           'Empty for counter (walk-in) sales that had no quote'
    UNION ALL
    SELECT 8, 'core.rental_booking', 'quote_id',
           (SELECT count(*) FROM core.rental_booking WHERE quote_id IS NULL),
           (SELECT count(*) FROM staging.rental_booking WHERE quote_number IS NULL),
           'Empty for bookings that had no formal quote'
    UNION ALL
    SELECT 9, 'core.job_cost_line', 'product_id',
           (SELECT count(*) FROM core.job_cost_line WHERE product_id IS NULL),
           (SELECT count(*) FROM staging.job_cost_line WHERE sku IS NULL),
           'Optional link from a job cost to a product. Not used in this project yet'
    UNION ALL
    SELECT 10, 'core.stock_movement', 'sales_order_line_id',
           (SELECT count(*) FROM core.stock_movement WHERE sales_order_line_id IS NULL),
           (SELECT count(*) FROM core.stock_movement WHERE movement_type <> 'sale'),
           'Filled only when stock leaves because of a sale'
    UNION ALL
    SELECT 11, 'core.stock_movement', 'job_id',
           (SELECT count(*) FROM core.stock_movement WHERE job_id IS NULL),
           (SELECT count(*) FROM core.stock_movement WHERE movement_type <> 'job_use'),
           'Filled only when stock is used on a job (not generated in this project yet)'
    UNION ALL
    SELECT 12, 'core.asset', 'retired_date',
           (SELECT count(*) FROM core.asset WHERE retired_date IS NULL),
           (SELECT count(*) FROM core.asset WHERE status <> 'retired'),
           'Filled only for retired assets'
    UNION ALL
    SELECT 13, 'core.maintenance_event', 'rental_booking_id',
           (SELECT count(*) FROM core.maintenance_event WHERE rental_booking_id IS NULL),
           (SELECT count(*) FROM staging.maintenance_event WHERE booking_number IS NULL),
           'Filled only when damage was found on a booking. Empty for services and long repairs'
) t
ORDER BY n;
