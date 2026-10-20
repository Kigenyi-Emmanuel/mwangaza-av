-- Mwangaza AV (synthetic case study)
-- Change note (2026-10-15): the first row of the final check was missing its "actual" label, which made the last
-- statement fail with: column "actual" does not exist. The load is committed before that statement runs.
-- To re-check an existing load, run sql/07_load/run_stage_17_check_only.sql. Re-running this file is harmless:
-- its first safety check stops it when the core tables already hold data.
--
-- STAGE 17 in one file: load the cleaned data from staging into the core tables. Executed on PostgreSQL 18.6;
-- the load committed and the check-only file returned 18 rows, all PASS.
-- Run order: once, in the mwangaza_av database, after Stage 16.
--
-- Purpose:
--   1. Stops with an error if Stage 16 has not been run, or if the core tables already hold data.
--   2. Adds the sector "Unknown" to the sector list (the customers whose sector was missing use it).
--   3. Loads the clean tables in the right order (customers first, payments last). Only the REAL customers are
--      loaded: duplicate customer records stay in staging. Rejected rows stay in staging too.
--      The core tables have strict rules (keys, links, allowed values). If any row broke a rule, the whole
--      load would fail and nothing would be saved. That is the safety net.
--   4. Runs ANALYZE, which lets PostgreSQL learn the size of the new tables so queries run well.
--   5. Checks the load: row counts match staging, the money totals reconcile to the cent against the generator's
--      own totals, and the rules that the tables cannot enforce on their own all hold.
--   6. Returns one result table at the end; every row should read PASS.
--
-- Safety: the load is one all-or-nothing block (BEGIN ... COMMIT). It never changes raw or staging data.
-- It deletes nothing. It adds rows to core tables that are empty now.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF (SELECT count(*) FROM staging.invoice) = 0 OR (SELECT count(*) FROM staging.payment_allocation) = 0 THEN
        RAISE EXCEPTION 'Stop: Stage 16 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM core.customer) > 0 OR (SELECT count(*) FROM core.quote) > 0
       OR (SELECT count(*) FROM core.invoice) > 0 OR (SELECT count(*) FROM core.payment) > 0
       OR (SELECT count(*) FROM core.product) > 0 OR (SELECT count(*) FROM core.asset) > 0 THEN
        RAISE EXCEPTION 'Stop: the core tables already hold data. Nothing was changed.';
    END IF;
END $$;

-- Step 2: the sector list gets one more entry
INSERT INTO core.sector (sector_name) VALUES ('Unknown') ON CONFLICT (sector_name) DO NOTHING;

-- Step 3: master data
INSERT INTO core.customer (customer_code, customer_name, sector_id, payment_terms_days, created_date)
SELECT c.customer_code, c.customer_name, s.sector_id, c.payment_terms_days, c.created_date
FROM staging.customer c
JOIN core.sector s ON s.sector_name = c.sector_name
WHERE c.is_canonical
ORDER BY c.customer_code;

INSERT INTO core.supplier (supplier_code, supplier_name, country)
SELECT supplier_code, supplier_name, country
FROM staging.supplier
ORDER BY supplier_code;

INSERT INTO core.product (sku, product_name, product_category_id, supplier_id, list_price_ex_vat, standard_cost, is_active)
SELECT p.sku, p.product_name, pc.product_category_id, s.supplier_id, p.list_price_ex_vat, p.standard_cost, p.is_active
FROM staging.product p
JOIN core.product_category pc ON pc.product_category_name = p.product_category_name
JOIN core.supplier s ON s.supplier_code = p.supplier_code
ORDER BY p.sku;

INSERT INTO core.asset (asset_tag, asset_name, asset_category_id, purchase_date, purchase_cost, daily_rate_ex_vat, status, retired_date)
SELECT a.asset_tag, a.asset_name, ac.asset_category_id, a.purchase_date, a.purchase_cost, a.daily_rate_ex_vat, a.status, a.retired_date
FROM staging.asset a
JOIN core.asset_category ac ON ac.asset_category_name = a.asset_category_name
ORDER BY a.asset_tag;

-- Step 4: quotes, then the projects division
INSERT INTO core.quote (quote_number, customer_id, office_id, division, quote_date, decision_date, status,
                        quoted_price_ex_vat, quoted_cost)
SELECT q.quote_number, c.customer_id, o.office_id, q.division, q.quote_date, q.decision_date, q.status,
       q.quoted_price_ex_vat, q.quoted_cost
FROM staging.quote q
JOIN core.customer c ON c.customer_code = q.customer_code
JOIN core.office o ON o.office_name = q.office_name
ORDER BY q.quote_number;

INSERT INTO core.job (job_number, quote_id, customer_id, office_id, job_type_id, start_date, end_date, status)
SELECT j.job_number, q.quote_id, c.customer_id, o.office_id, jt.job_type_id, j.start_date, j.end_date, j.status
FROM staging.job j
JOIN core.customer c ON c.customer_code = j.customer_code
JOIN core.office o ON o.office_name = j.office_name
JOIN core.job_type jt ON jt.job_type_name = j.job_type_name
LEFT JOIN core.quote q ON q.quote_number = j.quote_number
ORDER BY j.job_number;

INSERT INTO core.job_cost_line (job_id, cost_category_id, cost_date, description, quantity, unit_cost, product_id)
SELECT j.job_id, cc.cost_category_id, l.cost_date, l.description, l.quantity, l.unit_cost, p.product_id
FROM staging.job_cost_line l
JOIN core.job j ON j.job_number = l.job_number
JOIN core.cost_category cc ON cc.cost_category_name = l.cost_category_name
LEFT JOIN core.product p ON p.sku = l.sku
ORDER BY l.job_number, l.raw_row_id;

-- Step 5: the products division
INSERT INTO core.sales_order (order_number, quote_id, customer_id, office_id, order_date, status)
SELECT s.order_number, q.quote_id, c.customer_id, o.office_id, s.order_date, s.status
FROM staging.sales_order s
JOIN core.customer c ON c.customer_code = s.customer_code
JOIN core.office o ON o.office_name = s.office_name
LEFT JOIN core.quote q ON q.quote_number = s.quote_number
ORDER BY s.order_number;

INSERT INTO core.sales_order_line (sales_order_id, product_id, quantity, unit_price_ex_vat, unit_cost)
SELECT so.sales_order_id, p.product_id, l.quantity, l.unit_price_ex_vat, l.unit_cost
FROM staging.sales_order_line l
JOIN core.sales_order so ON so.order_number = l.order_number
JOIN core.product p ON p.sku = l.sku
ORDER BY l.order_number, l.sku;

INSERT INTO core.stock_movement (product_id, movement_date, movement_type, quantity_change, unit_cost,
                                 sales_order_line_id, job_id)
SELECT p.product_id, m.movement_date, m.movement_type, m.quantity_change, m.unit_cost,
       l.sales_order_line_id, j.job_id
FROM staging.stock_movement m
JOIN core.product p ON p.sku = m.sku
LEFT JOIN core.sales_order so ON so.order_number = m.order_number
LEFT JOIN core.sales_order_line l ON l.sales_order_id = so.sales_order_id AND l.product_id = p.product_id
LEFT JOIN core.job j ON j.job_number = m.job_number
ORDER BY m.movement_date, m.sku, m.raw_row_id;

-- Step 6: the rentals division
INSERT INTO core.rental_booking (booking_number, quote_id, customer_id, office_id, start_date, end_date, status)
SELECT b.booking_number, q.quote_id, c.customer_id, o.office_id, b.start_date, b.end_date, b.status
FROM staging.rental_booking b
JOIN core.customer c ON c.customer_code = b.customer_code
JOIN core.office o ON o.office_name = b.office_name
LEFT JOIN core.quote q ON q.quote_number = b.quote_number
ORDER BY b.booking_number;

INSERT INTO core.rental_booking_line (rental_booking_id, asset_id, daily_rate_ex_vat)
SELECT rb.rental_booking_id, a.asset_id, l.daily_rate_ex_vat
FROM staging.rental_booking_line l
JOIN core.rental_booking rb ON rb.booking_number = l.booking_number
JOIN core.asset a ON a.asset_tag = l.asset_tag
ORDER BY l.booking_number, l.asset_tag;

INSERT INTO core.maintenance_event (asset_id, event_date, event_type, cost_amount, days_out_of_service, rental_booking_id)
SELECT a.asset_id, m.event_date, m.event_type, m.cost_amount, m.days_out_of_service, rb.rental_booking_id
FROM staging.maintenance_event m
JOIN core.asset a ON a.asset_tag = m.asset_tag
LEFT JOIN core.rental_booking rb ON rb.booking_number = m.booking_number
ORDER BY m.event_date, m.asset_tag, m.raw_row_id;

-- Step 7: billing and cash
INSERT INTO core.invoice (invoice_number, division, job_id, sales_order_id, rental_booking_id, customer_id,
                          invoice_date, due_date, amount_ex_vat, vat_amount)
SELECT i.invoice_number, i.division, j.job_id, so.sales_order_id, rb.rental_booking_id, c.customer_id,
       i.invoice_date, i.due_date, i.amount_ex_vat, i.vat_amount
FROM staging.invoice i
JOIN core.customer c ON c.customer_code = i.customer_code
LEFT JOIN core.job j ON j.job_number = i.job_number
LEFT JOIN core.sales_order so ON so.order_number = i.order_number
LEFT JOIN core.rental_booking rb ON rb.booking_number = i.booking_number
ORDER BY i.invoice_number;

INSERT INTO core.payment (payment_reference, customer_id, payment_date, amount, payment_method)
SELECT p.payment_reference, c.customer_id, p.payment_date, p.amount, p.payment_method
FROM staging.payment p
JOIN core.customer c ON c.customer_code = p.customer_code
ORDER BY p.payment_reference;

INSERT INTO core.payment_allocation (payment_id, invoice_id, allocated_amount)
SELECT p.payment_id, i.invoice_id, a.allocated_amount
FROM staging.payment_allocation a
JOIN core.payment p ON p.payment_reference = a.payment_reference
JOIN core.invoice i ON i.invoice_number = a.invoice_number
ORDER BY a.payment_reference, a.invoice_number;

COMMIT;

-- Step 8: let PostgreSQL learn the size of the new tables
ANALYZE;

-- Step 9: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Tables whose core row count differs from the staging row count (should be none; 16 tables compared)' AS what_we_check,
           '0' AS expected,
           (SELECT count(*) FROM (
                SELECT (SELECT count(*) FROM core.customer) AS c, (SELECT count(*) FROM staging.customer WHERE is_canonical) AS s
                UNION ALL SELECT (SELECT count(*) FROM core.supplier), (SELECT count(*) FROM staging.supplier)
                UNION ALL SELECT (SELECT count(*) FROM core.product), (SELECT count(*) FROM staging.product)
                UNION ALL SELECT (SELECT count(*) FROM core.asset), (SELECT count(*) FROM staging.asset)
                UNION ALL SELECT (SELECT count(*) FROM core.quote), (SELECT count(*) FROM staging.quote)
                UNION ALL SELECT (SELECT count(*) FROM core.job), (SELECT count(*) FROM staging.job)
                UNION ALL SELECT (SELECT count(*) FROM core.job_cost_line), (SELECT count(*) FROM staging.job_cost_line)
                UNION ALL SELECT (SELECT count(*) FROM core.sales_order), (SELECT count(*) FROM staging.sales_order)
                UNION ALL SELECT (SELECT count(*) FROM core.sales_order_line), (SELECT count(*) FROM staging.sales_order_line)
                UNION ALL SELECT (SELECT count(*) FROM core.stock_movement), (SELECT count(*) FROM staging.stock_movement)
                UNION ALL SELECT (SELECT count(*) FROM core.rental_booking), (SELECT count(*) FROM staging.rental_booking)
                UNION ALL SELECT (SELECT count(*) FROM core.rental_booking_line), (SELECT count(*) FROM staging.rental_booking_line)
                UNION ALL SELECT (SELECT count(*) FROM core.maintenance_event), (SELECT count(*) FROM staging.maintenance_event)
                UNION ALL SELECT (SELECT count(*) FROM core.invoice), (SELECT count(*) FROM staging.invoice)
                UNION ALL SELECT (SELECT count(*) FROM core.payment), (SELECT count(*) FROM staging.payment)
                UNION ALL SELECT (SELECT count(*) FROM core.payment_allocation), (SELECT count(*) FROM staging.payment_allocation)
            ) x WHERE x.c <> x.s)::text AS actual
    UNION ALL
    SELECT 2, 'Core tables that are still empty (should be none)', '0',
           (SELECT count(*) FROM (
                SELECT count(*) AS c FROM core.customer UNION ALL SELECT count(*) FROM core.supplier
                UNION ALL SELECT count(*) FROM core.product UNION ALL SELECT count(*) FROM core.asset
                UNION ALL SELECT count(*) FROM core.quote UNION ALL SELECT count(*) FROM core.job
                UNION ALL SELECT count(*) FROM core.job_cost_line UNION ALL SELECT count(*) FROM core.sales_order
                UNION ALL SELECT count(*) FROM core.sales_order_line UNION ALL SELECT count(*) FROM core.stock_movement
                UNION ALL SELECT count(*) FROM core.rental_booking UNION ALL SELECT count(*) FROM core.rental_booking_line
                UNION ALL SELECT count(*) FROM core.maintenance_event UNION ALL SELECT count(*) FROM core.invoice
                UNION ALL SELECT count(*) FROM core.payment UNION ALL SELECT count(*) FROM core.payment_allocation
            ) y WHERE y.c = 0)::text
    UNION ALL
    SELECT 3, 'Customers loaded plus duplicate records left in staging equal the raw customer rows',
           (SELECT count(*) FROM raw.customer)::text,
           ((SELECT count(*) FROM core.customer) + (SELECT count(*) FROM staging.customer WHERE NOT is_canonical))::text
    UNION ALL
    SELECT 4, 'Customers in the sector Unknown (planted X05: register D05)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D05')::text,
           (SELECT count(*) FROM core.customer c JOIN core.sector s ON s.sector_id = c.sector_id WHERE s.sector_name = 'Unknown')::text
    UNION ALL
    SELECT 5, 'Rows set aside in staging over the whole project (only the planted duplicate invoices, register D01)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D01')::text,
           (SELECT count(*) FROM staging.rejected_row)::text
    UNION ALL
    SELECT 6, 'Money: invoiced before VAT, core equals the generator total (KES)',
           (SELECT round(sum(amount_ex_vat), 2)::text FROM generator.invoice_profile),
           (SELECT round(sum(amount_ex_vat), 2)::text FROM core.invoice)
    UNION ALL
    SELECT 7, 'Money: divisions whose core billing equals the generator billing (of 3)', '3',
           (SELECT count(*)
              FROM (SELECT division, sum(amount_ex_vat) AS a FROM generator.invoice_profile GROUP BY division) g
              JOIN (SELECT division, sum(amount_ex_vat) AS a FROM core.invoice GROUP BY division) c ON c.division = g.division
             WHERE abs(g.a - c.a) <= 0.01)::text
    UNION ALL
    SELECT 8, 'Money: total paid, core equals staging (KES)',
           (SELECT round(sum(amount), 2)::text FROM staging.payment),
           (SELECT round(sum(amount), 2)::text FROM core.payment)
    UNION ALL
    SELECT 9, 'Money: total allocated equals total paid in core (KES)',
           (SELECT round(sum(amount), 2)::text FROM core.payment),
           (SELECT round(sum(allocated_amount), 2)::text FROM core.payment_allocation)
    UNION ALL
    SELECT 10, 'Money: product sales revenue in core equals the generator total (KES)',
           (SELECT round(sum(revenue), 2)::text FROM generator.sales_order_profile),
           (SELECT round(sum(line_revenue), 2)::text FROM core.sales_order_line)
    UNION ALL
    SELECT 11, 'Money: job cost in core is within 1 KES of staging (rounding of each line to cents)', 'yes',
           (SELECT CASE WHEN abs((SELECT sum(cost_amount) FROM core.job_cost_line)
                                 - (SELECT sum(quantity * unit_cost) FROM staging.job_cost_line)) < 1
                        THEN 'yes' ELSE 'no' END)
    UNION ALL
    SELECT 12, 'Rule the tables cannot enforce: jobs, orders and bookings whose quote is from another division (should be none)', '0',
           ((SELECT count(*) FROM core.job j JOIN core.quote q ON q.quote_id = j.quote_id WHERE q.division <> 'projects')
          + (SELECT count(*) FROM core.sales_order s JOIN core.quote q ON q.quote_id = s.quote_id WHERE q.division <> 'products')
          + (SELECT count(*) FROM core.rental_booking b JOIN core.quote q ON q.quote_id = b.quote_id WHERE q.division <> 'rentals'))::text
    UNION ALL
    SELECT 13, 'Rule the tables cannot enforce: invoices whose customer differs from the customer of their job, order or booking (should be none)', '0',
           (SELECT count(*)
              FROM core.invoice i
              LEFT JOIN core.job j ON j.job_id = i.job_id
              LEFT JOIN core.sales_order so ON so.sales_order_id = i.sales_order_id
              LEFT JOIN core.rental_booking rb ON rb.rental_booking_id = i.rental_booking_id
             WHERE i.customer_id <> coalesce(j.customer_id, so.customer_id, rb.customer_id))::text
    UNION ALL
    SELECT 14, 'Rule the tables cannot enforce: invoices paid more than their total (should be none)', '0',
           (SELECT count(*)
              FROM (SELECT i.invoice_id
                      FROM core.invoice i
                      JOIN core.payment_allocation a ON a.invoice_id = i.invoice_id
                     GROUP BY i.invoice_id, i.total_amount
                    HAVING sum(a.allocated_amount) > i.total_amount + 0.01) d)::text
    UNION ALL
    SELECT 15, 'Rule the tables cannot enforce: payments allocated for more than the payment (should be none)', '0',
           (SELECT count(*)
              FROM (SELECT p.payment_id
                      FROM core.payment p
                      JOIN core.payment_allocation a ON a.payment_id = p.payment_id
                     GROUP BY p.payment_id, p.amount
                    HAVING sum(a.allocated_amount) > p.amount + 0.01) d)::text
    UNION ALL
    SELECT 16, 'Rule the tables cannot enforce: payments from a different customer than the invoice they pay (should be none)', '0',
           (SELECT count(*)
              FROM core.payment_allocation a
              JOIN core.payment p ON p.payment_id = a.payment_id
              JOIN core.invoice i ON i.invoice_id = a.invoice_id
             WHERE p.customer_id <> i.customer_id)::text
    UNION ALL
    SELECT 17, 'Times a product''s stock fell below zero in the core ledger (should be none)', '0',
           (SELECT count(*)
              FROM (SELECT sum(quantity_change) OVER (PARTITION BY product_id
                                                      ORDER BY movement_date, quantity_change DESC, stock_movement_id
                                                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS bal
                      FROM core.stock_movement) s
             WHERE s.bal < 0)::text
    UNION ALL
    SELECT 18, 'Sectors in the sector list (7 original + Unknown)', '8',
           (SELECT count(*) FROM core.sector)::text
) t
ORDER BY n;
