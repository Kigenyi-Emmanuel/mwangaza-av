-- Mwangaza AV (synthetic case study)
-- STAGE 15 in one file: clean quotes, jobs, job costs, sales orders and stock movements into staging.
-- Run order: once, in the mwangaza_av database, after Stage 14. Executed on PostgreSQL 18.6; all 17 built-in checks pass.
-- (Rentals and billing are cleaned in Stage 16, because that is where most of the planted problems are.)
--
-- Purpose:
--   1. Stops with an error if Stage 14 has not been run, or if staging already holds these transactions.
--   2. Reads the text into dates and numbers, row by row (rule DQ02).
--   3. Replaces the customer code of a duplicate customer with the real customer's code, and keeps the
--      original code in its own column (rule DQ05). Every replacement is logged.
--   4. Sets aside, with a reason, any row that cannot be read, breaks a basic rule of the clean tables
--      (for example a decision date before the quote date), or points to something that does not exist.
--      Our generated data should have none of these. The check confirms it.
--   5. Flags any moment when a product's stock would fall below zero (rule DQ12).
--   6. Checks the work against the hidden answer key. For example: did the cleaning find exactly the quotes,
--      jobs and orders that were written under a duplicate customer code, and do the order lines still add up
--      to the revenue the generator recorded?
--   7. Returns one result table at the end; every row should read PASS.
--
-- Safety: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It never changes raw data. It never deletes anything.
-- One wording change: rule DQ02 now also covers rows that break a basic rule of the clean tables.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF (SELECT count(*) FROM staging.customer) = 0 THEN
        RAISE EXCEPTION 'Stop: Stage 14 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM staging.quote) > 0 OR (SELECT count(*) FROM staging.job) > 0
       OR (SELECT count(*) FROM staging.job_cost_line) > 0 OR (SELECT count(*) FROM staging.sales_order) > 0
       OR (SELECT count(*) FROM staging.sales_order_line) > 0 OR (SELECT count(*) FROM staging.stock_movement) > 0 THEN
        RAISE EXCEPTION 'Stop: staging already holds quotes, jobs, orders or stock movements. Nothing was changed.';
    END IF;
END $$;

UPDATE staging.dq_rule
SET description = 'Convert text to dates and numbers. A row that cannot be converted, or that breaks a basic rule of the clean tables (for example a decision date before the quote date), is rejected'
WHERE rule_id = 'DQ02';

-- Step 2: quotes (all three divisions)
CREATE TEMP TABLE tmp_q0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.quote_number, '')) AS quote_number,
       btrim(coalesce(r.customer_code, '')) AS original_code,
       btrim(coalesce(r.office_name, '')) AS office_name,
       lower(btrim(coalesce(r.division, ''))) AS division,
       staging.try_date(r.quote_date) AS quote_date,
       staging.try_date(r.decision_date) AS decision_date,
       (btrim(coalesce(r.decision_date, '')) <> '') AS has_decision_text,
       lower(btrim(coalesce(r.status, ''))) AS status,
       staging.try_numeric(r.quoted_price_ex_vat) AS price,
       staging.try_numeric(r.quoted_cost) AS cost
FROM raw.quote r;

CREATE TEMP TABLE tmp_q1 ON COMMIT DROP AS
SELECT q.*, m.canonical_customer_code AS customer_code,
       coalesce(q.quote_number = '' OR q.original_code = '' OR q.office_name = '' OR q.quote_date IS NULL
                OR q.price IS NULL OR q.cost IS NULL OR q.price < 0 OR q.cost < 0
                OR (q.has_decision_text AND q.decision_date IS NULL)
                OR (q.decision_date IS NOT NULL AND q.decision_date < q.quote_date)
                OR q.status NOT IN ('open', 'won', 'lost', 'expired')
                OR ((q.status IN ('won', 'lost')) <> (q.decision_date IS NOT NULL))
                OR q.division NOT IN ('projects', 'products', 'rentals'), true) AS unreadable,
       (m.canonical_customer_code IS NULL OR q.office_name NOT IN (SELECT office_name FROM core.office)) AS link_missing
FROM tmp_q0 q
LEFT JOIN staging.customer_map m ON m.raw_customer_code = q.original_code;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'quote', raw_row_id, quote_number, 'Unreadable, or breaks a basic rule (dates, amounts, status, division)'
FROM tmp_q1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'quote', raw_row_id, quote_number, 'Customer code or office does not exist'
FROM tmp_q1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.quote
    (raw_row_id, quote_number, customer_code, original_customer_code, office_name, division, quote_date,
     decision_date, status, quoted_price_ex_vat, quoted_cost)
SELECT raw_row_id, quote_number, customer_code, original_code, office_name, division, quote_date,
       decision_date, status, price, cost
FROM tmp_q1 WHERE NOT unreadable AND NOT link_missing;

-- Step 3: jobs
CREATE TEMP TABLE tmp_j0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.job_number, '')) AS job_number,
       NULLIF(btrim(coalesce(r.quote_number, '')), '') AS quote_number,
       btrim(coalesce(r.customer_code, '')) AS original_code,
       btrim(coalesce(r.office_name, '')) AS office_name,
       btrim(coalesce(r.job_type_name, '')) AS job_type_name,
       staging.try_date(r.start_date) AS start_date,
       staging.try_date(r.end_date) AS end_date,
       (btrim(coalesce(r.end_date, '')) <> '') AS has_end_text,
       lower(btrim(coalesce(r.status, ''))) AS status
FROM raw.job r;

CREATE TEMP TABLE tmp_j1 ON COMMIT DROP AS
SELECT j.*, m.canonical_customer_code AS customer_code,
       coalesce(j.job_number = '' OR j.original_code = '' OR j.office_name = '' OR j.job_type_name = ''
                OR j.start_date IS NULL OR (j.has_end_text AND j.end_date IS NULL)
                OR j.status NOT IN ('in_progress', 'completed', 'cancelled')
                OR (j.status = 'completed' AND j.end_date IS NULL)
                OR (j.end_date IS NOT NULL AND j.end_date < j.start_date), true) AS unreadable,
       (m.canonical_customer_code IS NULL
        OR j.office_name NOT IN (SELECT office_name FROM core.office)
        OR j.job_type_name NOT IN (SELECT job_type_name FROM core.job_type)
        OR (j.quote_number IS NOT NULL AND j.quote_number NOT IN (SELECT quote_number FROM staging.quote))) AS link_missing
FROM tmp_j0 j
LEFT JOIN staging.customer_map m ON m.raw_customer_code = j.original_code;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'job', raw_row_id, job_number, 'Unreadable, or breaks a basic rule (dates, status)'
FROM tmp_j1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'job', raw_row_id, job_number, 'Customer, office, job type or quote does not exist'
FROM tmp_j1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.job
    (raw_row_id, job_number, quote_number, customer_code, original_customer_code, office_name, job_type_name,
     start_date, end_date, status)
SELECT raw_row_id, job_number, quote_number, customer_code, original_code, office_name, job_type_name,
       start_date, end_date, status
FROM tmp_j1 WHERE NOT unreadable AND NOT link_missing;

-- Step 4: job cost lines
CREATE TEMP TABLE tmp_l0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.job_number, '')) AS job_number,
       btrim(coalesce(r.cost_category_name, '')) AS category,
       staging.try_date(r.cost_date) AS cost_date,
       NULLIF(btrim(coalesce(r.description, '')), '') AS description,
       staging.try_numeric(r.quantity) AS quantity,
       staging.try_numeric(r.unit_cost) AS unit_cost,
       NULLIF(btrim(coalesce(r.sku, '')), '') AS sku
FROM raw.job_cost_line r;

CREATE TEMP TABLE tmp_l1 ON COMMIT DROP AS
SELECT l.*,
       coalesce(l.job_number = '' OR l.category = '' OR l.cost_date IS NULL OR l.quantity IS NULL
                OR l.quantity <= 0 OR l.unit_cost IS NULL OR l.unit_cost < 0, true) AS unreadable,
       (l.job_number NOT IN (SELECT job_number FROM staging.job)
        OR l.category NOT IN (SELECT cost_category_name FROM core.cost_category)
        OR (l.sku IS NOT NULL AND l.sku NOT IN (SELECT sku FROM staging.product))) AS link_missing
FROM tmp_l0 l;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'job_cost_line', raw_row_id, job_number, 'Unreadable, or quantity or cost not allowed'
FROM tmp_l1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'job_cost_line', raw_row_id, job_number, 'Job, cost category or product does not exist'
FROM tmp_l1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.job_cost_line
    (raw_row_id, job_number, cost_category_name, cost_date, description, quantity, unit_cost, sku)
SELECT raw_row_id, job_number, category, cost_date, description, quantity, unit_cost, sku
FROM tmp_l1 WHERE NOT unreadable AND NOT link_missing;

-- Step 5: sales orders
CREATE TEMP TABLE tmp_o0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.order_number, '')) AS order_number,
       NULLIF(btrim(coalesce(r.quote_number, '')), '') AS quote_number,
       btrim(coalesce(r.customer_code, '')) AS original_code,
       btrim(coalesce(r.office_name, '')) AS office_name,
       staging.try_date(r.order_date) AS order_date,
       lower(btrim(coalesce(r.status, ''))) AS status
FROM raw.sales_order r;

CREATE TEMP TABLE tmp_o1 ON COMMIT DROP AS
SELECT o.*, m.canonical_customer_code AS customer_code,
       coalesce(o.order_number = '' OR o.original_code = '' OR o.office_name = '' OR o.order_date IS NULL
                OR o.status NOT IN ('open', 'delivered', 'cancelled'), true) AS unreadable,
       (m.canonical_customer_code IS NULL
        OR o.office_name NOT IN (SELECT office_name FROM core.office)
        OR (o.quote_number IS NOT NULL AND o.quote_number NOT IN (SELECT quote_number FROM staging.quote))) AS link_missing
FROM tmp_o0 o
LEFT JOIN staging.customer_map m ON m.raw_customer_code = o.original_code;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'sales_order', raw_row_id, order_number, 'Unreadable, or breaks a basic rule (date, status)'
FROM tmp_o1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'sales_order', raw_row_id, order_number, 'Customer, office or quote does not exist'
FROM tmp_o1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.sales_order
    (raw_row_id, order_number, quote_number, customer_code, original_customer_code, office_name, order_date, status)
SELECT raw_row_id, order_number, quote_number, customer_code, original_code, office_name, order_date, status
FROM tmp_o1 WHERE NOT unreadable AND NOT link_missing;

-- Step 6: sales order lines
CREATE TEMP TABLE tmp_ol0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.order_number, '')) AS order_number,
       btrim(coalesce(r.sku, '')) AS sku,
       staging.try_int(r.quantity) AS quantity,
       staging.try_numeric(r.unit_price_ex_vat) AS unit_price,
       staging.try_numeric(r.unit_cost) AS unit_cost
FROM raw.sales_order_line r;

CREATE TEMP TABLE tmp_ol1 ON COMMIT DROP AS
SELECT l.*,
       coalesce(l.order_number = '' OR l.sku = '' OR l.quantity IS NULL OR l.quantity <= 0
                OR l.unit_price IS NULL OR l.unit_price < 0 OR l.unit_cost IS NULL OR l.unit_cost < 0, true) AS unreadable,
       (l.order_number NOT IN (SELECT order_number FROM staging.sales_order)
        OR l.sku NOT IN (SELECT sku FROM staging.product)) AS link_missing
FROM tmp_ol0 l;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'sales_order_line', raw_row_id, order_number, 'Unreadable, or quantity or price not allowed'
FROM tmp_ol1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'sales_order_line', raw_row_id, order_number, 'Order or product does not exist'
FROM tmp_ol1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.sales_order_line (raw_row_id, order_number, sku, quantity, unit_price_ex_vat, unit_cost)
SELECT raw_row_id, order_number, sku, quantity, unit_price, unit_cost
FROM tmp_ol1 WHERE NOT unreadable AND NOT link_missing;

-- Step 7: stock movements
CREATE TEMP TABLE tmp_m0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.sku, '')) AS sku,
       staging.try_date(r.movement_date) AS movement_date,
       lower(btrim(coalesce(r.movement_type, ''))) AS movement_type,
       staging.try_int(r.quantity_change) AS quantity_change,
       staging.try_numeric(r.unit_cost) AS unit_cost,
       NULLIF(btrim(coalesce(r.order_number, '')), '') AS order_number,
       NULLIF(btrim(coalesce(r.job_number, '')), '') AS job_number
FROM raw.stock_movement r;

CREATE TEMP TABLE tmp_m1 ON COMMIT DROP AS
SELECT m.*,
       coalesce(m.sku = '' OR m.movement_date IS NULL OR m.quantity_change IS NULL OR m.quantity_change = 0
                OR m.unit_cost IS NULL OR m.unit_cost < 0
                OR m.movement_type NOT IN ('purchase', 'sale', 'job_use', 'adjustment')
                OR (m.movement_type = 'purchase' AND m.quantity_change <= 0)
                OR (m.movement_type IN ('sale', 'job_use') AND m.quantity_change >= 0)
                OR (m.movement_type = 'sale' AND (m.order_number IS NULL OR m.job_number IS NOT NULL))
                OR (m.movement_type = 'job_use' AND (m.job_number IS NULL OR m.order_number IS NOT NULL))
                OR (m.movement_type IN ('purchase', 'adjustment') AND (m.order_number IS NOT NULL OR m.job_number IS NOT NULL)), true) AS unreadable,
       (m.sku NOT IN (SELECT sku FROM staging.product)
        OR (m.movement_type = 'sale' AND NOT EXISTS (SELECT 1 FROM staging.sales_order_line l
                                                      WHERE l.order_number = m.order_number AND l.sku = m.sku))
        OR (m.movement_type = 'job_use' AND m.job_number NOT IN (SELECT job_number FROM staging.job))) AS link_missing
FROM tmp_m0 m;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'stock_movement', raw_row_id, sku, 'Unreadable, or the sign or links do not match the movement type'
FROM tmp_m1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'stock_movement', raw_row_id, sku, 'Product, order line or job does not exist'
FROM tmp_m1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.stock_movement
    (raw_row_id, sku, movement_date, movement_type, quantity_change, unit_cost, order_number, job_number)
SELECT raw_row_id, sku, movement_date, movement_type, quantity_change, unit_cost, order_number, job_number
FROM tmp_m1 WHERE NOT unreadable AND NOT link_missing;

-- Step 8: log what changed (DQ05) and flag stock that would fall below zero (DQ12)
INSERT INTO staging.dq_issue (rule_id, table_name, raw_row_id, business_key, detail, value_before, value_after)
SELECT 'DQ05', 'quote', raw_row_id, quote_number, 'Customer code of a duplicate customer replaced by the real customer', original_customer_code, customer_code
FROM staging.quote WHERE customer_code <> original_customer_code
UNION ALL
SELECT 'DQ05', 'job', raw_row_id, job_number, 'Customer code of a duplicate customer replaced by the real customer', original_customer_code, customer_code
FROM staging.job WHERE customer_code <> original_customer_code
UNION ALL
SELECT 'DQ05', 'sales_order', raw_row_id, order_number, 'Customer code of a duplicate customer replaced by the real customer', original_customer_code, customer_code
FROM staging.sales_order WHERE customer_code <> original_customer_code;

INSERT INTO staging.dq_issue (rule_id, table_name, raw_row_id, business_key, detail, value_before, value_after)
SELECT 'DQ12', 'stock_movement', s.raw_row_id, s.sku, 'Running stock is below zero after this movement', s.bal::text, NULL
FROM (SELECT raw_row_id, sku,
             sum(quantity_change) OVER (PARTITION BY sku
                                        ORDER BY movement_date, quantity_change DESC, raw_row_id
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS bal
      FROM staging.stock_movement) s
WHERE s.bal < 0;

COMMIT;

-- Step 9: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Quotes: raw rows equal staging rows plus rejected rows' AS what_we_check,
           (SELECT count(*) FROM raw.quote)::text AS expected,
           ((SELECT count(*) FROM staging.quote) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'quote'))::text AS actual
    UNION ALL
    SELECT 2, 'Jobs: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.job)::text,
           ((SELECT count(*) FROM staging.job) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'job'))::text
    UNION ALL
    SELECT 3, 'Job cost lines: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.job_cost_line)::text,
           ((SELECT count(*) FROM staging.job_cost_line) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'job_cost_line'))::text
    UNION ALL
    SELECT 4, 'Sales orders: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.sales_order)::text,
           ((SELECT count(*) FROM staging.sales_order) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'sales_order'))::text
    UNION ALL
    SELECT 5, 'Order lines: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.sales_order_line)::text,
           ((SELECT count(*) FROM staging.sales_order_line) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'sales_order_line'))::text
    UNION ALL
    SELECT 6, 'Stock movements: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.stock_movement)::text,
           ((SELECT count(*) FROM staging.stock_movement) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'stock_movement'))::text
    UNION ALL
    SELECT 7, 'Rows set aside in this stage (our generated data should have none)', '0',
           (SELECT count(*) FROM staging.rejected_row
             WHERE table_name IN ('quote', 'job', 'job_cost_line', 'sales_order', 'sales_order_line', 'stock_movement'))::text
    UNION ALL
    SELECT 8, 'Answer key: quotes written under a duplicate customer code, found by the cleaning',
           (SELECT count(*) FROM generator.quote_profile WHERE raw_customer_code <> customer_code)::text,
           (SELECT count(*) FROM staging.quote WHERE customer_code <> original_customer_code)::text
    UNION ALL
    SELECT 9, 'Answer key: jobs written under a duplicate customer code, found by the cleaning',
           (SELECT count(*) FROM generator.job_profile WHERE raw_customer_code <> customer_code)::text,
           (SELECT count(*) FROM staging.job WHERE customer_code <> original_customer_code)::text
    UNION ALL
    SELECT 10, 'Answer key: sales orders written under a duplicate customer code, found by the cleaning',
           (SELECT count(*) FROM generator.sales_order_profile WHERE raw_customer_code <> customer_code)::text,
           (SELECT count(*) FROM staging.sales_order WHERE customer_code <> original_customer_code)::text
    UNION ALL
    SELECT 11, 'Quotes, jobs and orders whose customer is not a real (canonical) customer (should be none)', '0',
           ((SELECT count(*) FROM staging.quote x LEFT JOIN staging.customer c ON c.customer_code = x.customer_code AND c.is_canonical WHERE c.customer_code IS NULL)
          + (SELECT count(*) FROM staging.job x LEFT JOIN staging.customer c ON c.customer_code = x.customer_code AND c.is_canonical WHERE c.customer_code IS NULL)
          + (SELECT count(*) FROM staging.sales_order x LEFT JOIN staging.customer c ON c.customer_code = x.customer_code AND c.is_canonical WHERE c.customer_code IS NULL))::text
    UNION ALL
    SELECT 12, 'Customer-code replacements logged (rule DQ05)',
           ((SELECT count(*) FROM staging.quote WHERE customer_code <> original_customer_code)
          + (SELECT count(*) FROM staging.job WHERE customer_code <> original_customer_code)
          + (SELECT count(*) FROM staging.sales_order WHERE customer_code <> original_customer_code))::text,
           (SELECT count(*) FROM staging.dq_issue WHERE rule_id = 'DQ05')::text
    UNION ALL
    SELECT 13, 'Jobs that do not point to a WON PROJECTS quote (should be none)', '0',
           (SELECT count(*) FROM staging.job j
              LEFT JOIN staging.quote q ON q.quote_number = j.quote_number
             WHERE j.quote_number IS NULL OR q.division <> 'projects' OR q.status <> 'won')::text
    UNION ALL
    SELECT 14, 'Won projects quotes equal jobs',
           (SELECT count(*) FROM staging.quote WHERE division = 'projects' AND status = 'won')::text,
           (SELECT count(*) FROM staging.job)::text
    UNION ALL
    SELECT 15, 'Order lines add up to the revenue the generator recorded (KES)',
           (SELECT round(sum(revenue), 2)::text FROM generator.sales_order_profile),
           (SELECT round(sum(quantity * unit_price_ex_vat), 2)::text FROM staging.sales_order_line)
    UNION ALL
    SELECT 16, 'Job cost total in raw equals job cost total in staging (KES)',
           (SELECT round(sum(quantity::numeric * unit_cost::numeric), 2)::text FROM raw.job_cost_line),
           (SELECT round(sum(quantity * unit_cost), 2)::text FROM staging.job_cost_line)
    UNION ALL
    SELECT 17, 'Times stock fell below zero (rule DQ12, should be none)', '0',
           (SELECT count(*) FROM staging.dq_issue WHERE rule_id = 'DQ12')::text
) t
ORDER BY n;
