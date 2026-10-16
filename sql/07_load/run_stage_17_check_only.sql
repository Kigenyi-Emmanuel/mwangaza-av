-- Mwangaza AV (synthetic case study)
-- STAGE 17, CHECK ONLY. STATUS: run on PostgreSQL 18.6; the project owner reports 18 rows, all PASS.
-- Run it in the mwangaza_av database after Stage 17 has loaded the core tables.
--
-- It changes NO data. It only (1) runs ANALYZE, which lets PostgreSQL learn the size of the new tables
-- (harmless; it can be repeated), and (2) shows the same check table as the end of run_stage_17.sql.
-- One result table. Every row should say PASS.
-- If the core tables turn out to be EMPTY (every row says FAIL), the load did not complete: tell Claude.

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
