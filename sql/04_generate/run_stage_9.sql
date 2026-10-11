-- Mwangaza AV (synthetic case study)
-- STAGE 9 in one file: fake products-division quotes, sales orders and stock movements in the landing area (raw).
-- Run it ONCE, in the mwangaza_av database, AFTER Stage 8. STATUS: written, not yet run.
--
-- What it does, in plain words:
--   1. Stops with an error if Stage 8 has not been run, or if product quotes, orders or stock movements exist.
--   2. Creates about 369 products quotes. About 65 percent are won and become sales orders.
--      It also creates about 360 counter (walk-in) orders that never had a quote. Total: about 600 orders.
--   3. Each order has 1 to 4 product lines, priced with a small discount off the list price.
--   4. Creates the stock ledger: stock bought every quarter, stock sold with each delivered order,
--      and a few stock adjustments. Stock never goes below zero.
--   5. Keeps the planted problem X11: the 10 dead-stock products stop selling 12 months before the
--      as-of date, but still sit in stock (they were over-bought in 2025).
--   6. Shows one result table at the end. Every row should say PASS.
--
-- Safe: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It deletes nothing that exists.
-- The numbers below are a copy of docs/assumptions_register.xlsx. If you change the Excel file,
-- this copy must be updated too.
-- Dates: history runs 2023-10-01 to 2026-09-30. The "as-of" date is 2026-09-30.
-- Revenue of an order is the sum of its lines. Stock leaves only when an order is delivered.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF to_regclass('generator.quote_profile') IS NULL THEN
        RAISE EXCEPTION 'Stop: Stage 8 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM raw.sales_order) > 0 OR (SELECT count(*) FROM raw.sales_order_line) > 0
       OR (SELECT count(*) FROM raw.stock_movement) > 0
       OR (SELECT count(*) FROM raw.quote WHERE division = 'products') > 0 THEN
        RAISE EXCEPTION 'Stop: product quotes, sales orders or stock movements already exist. Nothing was changed.';
    END IF;
    IF to_regclass('generator.sales_order_profile') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the Stage 9 answer-key table already exists. Nothing was changed.';
    END IF;
END $$;

-- Step 2: more numbers from the register
INSERT INTO generator.parameter (parameter_id, parameter_name, low, central, high, unit) VALUES
    ('V01', 'Product sales orders over the window', 450, 600, 800, 'count'),
    ('V02', 'Share of sales orders that come from a quote (the rest are counter or walk-in sales)', 0.3, 0.4, 0.5, '%'),
    ('V03', 'Stock adjustments over the window (count, damage or count differences)', 20, 40, 70, 'count'),
    ('V05', 'Discount given on product sales (share off list price)', 0, 0.05, 0.15, '%'),
    ('V06', 'Stock bought each quarter as a multiple of that quarter''s sales', 1.05, 1.1, 1.2, 'x');

CREATE TABLE generator.sales_order_profile (
    order_number       text PRIMARY KEY,
    quote_number       text,
    customer_code      text NOT NULL,   -- the real customer (never the duplicate code)
    raw_customer_code  text NOT NULL,   -- the code written into raw (may be the duplicate code)
    office_name        text NOT NULL,
    order_date         date NOT NULL,
    status             text NOT NULL,
    revenue            numeric(14,2) NOT NULL,
    cost               numeric(14,2) NOT NULL
);

-- A new seed for this stage (register seed plus 0.3)
SELECT setseed(((SELECT central FROM generator.parameter WHERE parameter_id = 'G03') + 0.3)::double precision);

CREATE TEMP TABLE tmp_prm2 ON COMMIT DROP AS
SELECT
    DATE '2023-10-01' AS hist_start,
    DATE '2026-09-30' AS asof,
    DATE '2025-09-27' AS dead_cutoff,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'C02') AS c02,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'C06') AS c06,
    (SELECT low     FROM generator.parameter WHERE parameter_id = 'C04') AS lag_low,
    (SELECT high    FROM generator.parameter WHERE parameter_id = 'C04') AS lag_high,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'V01') AS v01,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'V02') AS v02,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'V03') AS v03,
    (SELECT low     FROM generator.parameter WHERE parameter_id = 'V05') AS v05_low,
    (SELECT high    FROM generator.parameter WHERE parameter_id = 'V05') AS v05_high,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'V06') AS v06,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'OF1') AS of1,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'D06') AS d06,
    (SELECT low     FROM generator.parameter WHERE parameter_id = 'M10') AS m10_low,
    (SELECT high    FROM generator.parameter WHERE parameter_id = 'M10') AS m10_high;

-- Which duplicate code belongs to which real customer (from the Stage 6 answer key)
CREATE TEMP TABLE tmp_dup ON COMMIT DROP AS
SELECT substring(detail from 'Duplicate of (C[0-9]+)') AS orig_code, business_key AS dup_code
FROM generator.planted_error
WHERE planted_id = 'X02';

-- Step 3a: products quotes. Days to decide uses the same shape as in Stage 8.
CREATE TEMP TABLE tmp_sq ON COMMIT DROP AS
WITH a AS (
    SELECT i,
           p.hist_start + 1 + (random() * (p.asof - p.hist_start - 1))::int AS quote_date,
           random() AS r_lag, random() AS r_win, random() AS r_exp, random() AS r_od
    FROM tmp_prm2 p
    CROSS JOIN LATERAL generate_series(1, round(p.v01 * p.v02 / p.c02)::int) AS i
),
b AS (
    SELECT a.*, (p.lag_low + (p.lag_high - p.lag_low) * power(a.r_lag, 4))::int AS lag_days
    FROM a CROSS JOIN tmp_prm2 p
)
SELECT 'QS-' || lpad(row_number() OVER (ORDER BY b.quote_date, b.i)::text, 5, '0') AS quote_number,
       b.quote_date, b.lag_days,
       CASE WHEN b.quote_date + b.lag_days > p.asof THEN 'open'
            WHEN b.r_win < p.c02 THEN 'won'
            WHEN b.r_exp < p.c06 THEN 'expired'
            ELSE 'lost' END AS status,
       LEAST(b.quote_date + b.lag_days + 3, p.asof) AS eff_date,
       LEAST(b.quote_date + b.lag_days + (b.r_od * 3)::int, p.asof) AS order_date_if_won
FROM b CROSS JOIN tmp_prm2 p;

-- Step 3b: all baskets: one per quote, and one per walk-in order
CREATE TEMP TABLE tmp_bk ON COMMIT DROP AS
SELECT s.quote_number AS bk_id, s.quote_number, s.quote_date AS cust_date, s.lag_days, s.status,
       CASE WHEN s.status = 'won' THEN s.order_date_if_won END AS order_date,
       s.eff_date,
       random() AS r_cust, random() AS r_dup, random() AS r_off, random() AS r_nl
FROM tmp_sq s
UNION ALL
SELECT 'W-' || w.i::text, NULL, w.d, NULL, NULL, w.d, w.d,
       random(), random(), random(), random()
FROM (SELECT i, p.hist_start + 1 + (random() * (p.asof - p.hist_start - 1))::int AS d
      FROM tmp_prm2 p
      CROSS JOIN LATERAL generate_series(1, round(p.v01 * (1 - p.v02))::int) AS i) w;

-- Step 3c: customer and office for each basket (big customers are more likely; only customers that already existed)
CREATE TEMP TABLE tmp_bk2 ON COMMIT DROP AS
SELECT b.*,
       pick.customer_code,
       CASE WHEN d.dup_code IS NOT NULL AND b.r_dup < p.d06 THEN d.dup_code ELSE pick.customer_code END AS raw_customer_code,
       CASE WHEN b.r_off < p.of1 THEN 'Nairobi' ELSE 'Mombasa' END AS office_name
FROM tmp_bk b
CROSS JOIN tmp_prm2 p
CROSS JOIN LATERAL (
    SELECT c.customer_code
    FROM (SELECT cp.customer_code,
                 sum(cp.activity_weight) OVER (ORDER BY cp.customer_code) AS cum,
                 sum(cp.activity_weight) OVER () AS tot
          FROM generator.customer_profile cp
          WHERE cp.created_date <= b.cust_date) c
    WHERE c.cum >= b.r_cust * c.tot
    ORDER BY c.cum
    LIMIT 1
) pick
LEFT JOIN tmp_dup d ON d.orig_code = pick.customer_code;

-- Step 3d: product lines for each basket (1 to 4 lines)
CREATE TEMP TABLE tmp_ln0 ON COMMIT DROP AS
SELECT b.bk_id, b.eff_date, line_no, random() AS r_prod, random() AS r_qty, random() AS r_disc
FROM tmp_bk2 b
CROSS JOIN LATERAL generate_series(1, (1 + floor(b.r_nl * 4))::int) AS line_no;

-- Pick a product for each line: popular products are more likely.
-- Dead-stock products can only be picked up to the cutoff date (planted problem X11).
CREATE TEMP TABLE tmp_ln1 ON COMMIT DROP AS
SELECT l.bk_id,
       pick.sku,
       1 + floor(power(l.r_qty, 2) * qm.qmax)::int AS qty,
       round((pp.list_price_ex_vat * (1 - (p.v05_low + (p.v05_high - p.v05_low) * power(l.r_disc, 2))))::numeric, 2) AS unit_price,
       pp.standard_cost AS unit_cost
FROM tmp_ln0 l
CROSS JOIN tmp_prm2 p
CROSS JOIN LATERAL (
    SELECT c.sku
    FROM (SELECT x.sku,
                 sum(x.sales_weight) OVER (ORDER BY x.sku) AS cum,
                 sum(x.sales_weight) OVER () AS tot
          FROM generator.product_profile x
          WHERE (NOT x.is_dead_stock) OR l.eff_date <= p.dead_cutoff) c
    WHERE c.cum >= l.r_prod * c.tot
    ORDER BY c.cum
    LIMIT 1
) pick
JOIN generator.product_profile pp ON pp.sku = pick.sku
CROSS JOIN LATERAL (
    SELECT CASE pp.category_name
                WHEN 'Cables and connectors'        THEN 40
                WHEN 'Lighting fixtures'            THEN 12
                WHEN 'Control and automation devices' THEN 10
                WHEN 'Microphones'                  THEN 8
                WHEN 'Loudspeakers and amplifiers'  THEN 8
                WHEN 'Displays and projectors'      THEN 6
                WHEN 'Video conferencing'           THEN 4
                ELSE 3 END AS qmax
) qm;

-- If the same product was picked twice in one basket, merge the lines (an order has one line per product)
CREATE TEMP TABLE tmp_ln2 ON COMMIT DROP AS
SELECT bk_id, sku, sum(qty)::int AS qty, max(unit_price) AS unit_price, max(unit_cost) AS unit_cost
FROM tmp_ln1
GROUP BY bk_id, sku;

-- Basket totals
CREATE TEMP TABLE tmp_bt ON COMMIT DROP AS
SELECT bk_id,
       sum(round(qty * unit_price, 2)) AS revenue,
       sum(round(qty * unit_cost, 2))  AS cost
FROM tmp_ln2
GROUP BY bk_id;

-- Step 4a: the quotes go into the answer key and into raw
INSERT INTO generator.quote_profile
    (quote_number, division, customer_code, raw_customer_code, office_name, job_type_name,
     quote_date, lag_days, decision_date, status, quoted_price, quoted_cost)
SELECT s.quote_number, 'products', b.customer_code, b.raw_customer_code, b.office_name, NULL,
       s.quote_date, s.lag_days,
       CASE WHEN s.status IN ('won', 'lost') THEN s.quote_date + s.lag_days END,
       s.status, t.revenue, t.cost
FROM tmp_sq s
JOIN tmp_bk2 b ON b.bk_id = s.quote_number
JOIN tmp_bt t ON t.bk_id = s.quote_number;

INSERT INTO raw.quote (quote_number, customer_code, office_name, division, quote_date, decision_date,
                       status, quoted_price_ex_vat, quoted_cost)
SELECT quote_number, raw_customer_code, office_name, division, quote_date::text, decision_date::text,
       status, quoted_price::text, quoted_cost::text
FROM generator.quote_profile
WHERE division = 'products'
ORDER BY quote_number;

-- Step 4b: sales orders (won quotes + walk-ins), numbered by date
CREATE TEMP TABLE tmp_ord ON COMMIT DROP AS
SELECT 'SO-' || lpad(row_number() OVER (ORDER BY b.order_date, b.bk_id)::text, 5, '0') AS order_number,
       b.bk_id, b.quote_number, b.customer_code, b.raw_customer_code, b.office_name, b.order_date,
       CASE WHEN b.order_date > p.asof - 7 THEN 'open' ELSE 'delivered' END AS status,
       t.revenue, t.cost
FROM tmp_bk2 b
JOIN tmp_bt t ON t.bk_id = b.bk_id
CROSS JOIN tmp_prm2 p
WHERE b.order_date IS NOT NULL;

INSERT INTO generator.sales_order_profile
    (order_number, quote_number, customer_code, raw_customer_code, office_name, order_date, status, revenue, cost)
SELECT order_number, quote_number, customer_code, raw_customer_code, office_name, order_date, status, revenue, cost
FROM tmp_ord;

INSERT INTO raw.sales_order (order_number, quote_number, customer_code, office_name, order_date, status)
SELECT order_number, quote_number, raw_customer_code, office_name, order_date::text, status
FROM tmp_ord
ORDER BY order_number;

INSERT INTO raw.sales_order_line (order_number, sku, quantity, unit_price_ex_vat, unit_cost)
SELECT o.order_number, l.sku, l.qty::text, l.unit_price::text, l.unit_cost::text
FROM tmp_ln2 l
JOIN tmp_ord o ON o.bk_id = l.bk_id
ORDER BY o.order_number, l.sku;

-- Step 5a: stock going out (only for delivered orders), 0 to 2 days after the order date
CREATE TEMP TABLE tmp_sale ON COMMIT DROP AS
SELECT l.sku,
       LEAST(o.order_date + floor(random() * 3)::int, p.asof) AS movement_date,
       -l.qty AS quantity_change,
       l.unit_cost,
       o.order_number
FROM tmp_ln2 l
JOIN tmp_ord o ON o.bk_id = l.bk_id
CROSS JOIN tmp_prm2 p
WHERE o.status = 'delivered';

-- Sales per product per quarter
CREATE TEMP TABLE tmp_pq ON COMMIT DROP AS
SELECT sku, date_trunc('quarter', movement_date::timestamp)::date AS qstart, sum(-quantity_change) AS qty_sales
FROM tmp_sale
GROUP BY sku, date_trunc('quarter', movement_date::timestamp)::date;

-- Step 5b: the full stock ledger
CREATE TEMP TABLE tmp_stock ON COMMIT DROP AS
-- sales
SELECT sku, movement_date, 'sale'::text AS movement_type, quantity_change, unit_cost, order_number
FROM tmp_sale
UNION ALL
-- one purchase per product per quarter with sales: a few days before the quarter starts
SELECT pq.sku,
       CASE WHEN pq.qstart <= p.hist_start THEN p.hist_start ELSE pq.qstart - (random() * 7)::int END,
       'purchase',
       ceil(pq.qty_sales * p.v06)::int + 5,
       round((pp.standard_cost * (1 + p.m10_low + (p.m10_high - p.m10_low) * random()))::numeric, 2),
       NULL
FROM tmp_pq pq
JOIN generator.product_profile pp ON pp.sku = pq.sku
CROSS JOIN tmp_prm2 p
UNION ALL
-- dead-stock products: one big extra purchase in 2025 that never sells
SELECT pp.sku,
       DATE '2025-04-01' + (random() * 167)::int,
       'purchase',
       10 + floor(random() * 31)::int,
       round((pp.standard_cost * (1 + p.m10_low + (p.m10_high - p.m10_low) * random()))::numeric, 2),
       NULL
FROM generator.product_profile pp
CROSS JOIN tmp_prm2 p
WHERE pp.is_dead_stock
UNION ALL
-- stock adjustments: at most one per product per quarter, small (-2, -1 or +1)
SELECT a.sku,
       LEAST(a.qstart + 1 + floor(random() * 80)::int, p.asof),
       'adjustment',
       CASE WHEN a.r < 0.8 THEN -(1 + floor(random() * 2))::int ELSE 1 END,
       pp.standard_cost,
       NULL
FROM (SELECT sku, qstart, random() AS r
      FROM tmp_pq
      ORDER BY random()
      LIMIT (SELECT central::int FROM generator.parameter WHERE parameter_id = 'V03')) a
JOIN generator.product_profile pp ON pp.sku = a.sku
CROSS JOIN tmp_prm2 p;

INSERT INTO raw.stock_movement (sku, movement_date, movement_type, quantity_change, unit_cost, order_number, job_number)
SELECT sku, movement_date::text, movement_type, quantity_change::text, unit_cost::text, order_number, NULL
FROM tmp_stock
ORDER BY movement_date, sku, movement_type;

COMMIT;

-- Step 6: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'New register numbers copied' AS what_we_check, '5' AS expected,
           (SELECT count(*) FROM generator.parameter
             WHERE parameter_id IN ('V01', 'V02', 'V03', 'V05', 'V06'))::text AS actual
    UNION ALL
    SELECT 2, 'Products quotes in raw (orders from quotes divided by win rate, rounded)',
           (SELECT round(v1.central * v2.central / c.central)::int
              FROM generator.parameter v1, generator.parameter v2, generator.parameter c
             WHERE v1.parameter_id = 'V01' AND v2.parameter_id = 'V02' AND c.parameter_id = 'C02')::text,
           (SELECT count(*) FROM raw.quote WHERE division = 'products')::text
    UNION ALL
    SELECT 3, 'Sales orders fall inside the register range V01 (low to high)', 'yes',
           (SELECT CASE WHEN count(*) BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'V01')
                                          AND (SELECT high FROM generator.parameter WHERE parameter_id = 'V01')
                        THEN 'yes' ELSE 'no' END
              FROM raw.sales_order)
    UNION ALL
    SELECT 4, 'Orders that come from a quote equal won products quotes',
           (SELECT count(*) FROM raw.quote WHERE division = 'products' AND status = 'won')::text,
           (SELECT count(*) FROM raw.sales_order WHERE quote_number IS NOT NULL)::text
    UNION ALL
    SELECT 5, 'Order lines whose order is missing (should be none)', '0',
           (SELECT count(*) FROM raw.sales_order_line l
              LEFT JOIN raw.sales_order o ON o.order_number = l.order_number
             WHERE o.order_number IS NULL)::text
    UNION ALL
    SELECT 6, 'Order lines whose product is not in raw.product (should be none)', '0',
           (SELECT count(*) FROM raw.sales_order_line l
              LEFT JOIN raw.product p ON p.sku = l.sku
             WHERE p.sku IS NULL)::text
    UNION ALL
    SELECT 7, 'Products appearing twice on one order (should be none)', '0',
           (SELECT count(*) FROM (SELECT order_number, sku FROM raw.sales_order_line
                                   GROUP BY order_number, sku HAVING count(*) > 1) d)::text
    UNION ALL
    SELECT 8, 'Dead-stock products sold in the last 12 months (should be none)', '0',
           (SELECT count(*)
              FROM raw.sales_order_line l
              JOIN raw.sales_order o ON o.order_number = l.order_number
              JOIN generator.product_profile pp ON pp.sku = l.sku AND pp.is_dead_stock
             WHERE o.order_date::date > DATE '2025-09-30')::text
    UNION ALL
    SELECT 9, 'Times a product''s stock fell below zero (should be none)', '0',
           (SELECT count(*)
              FROM (SELECT sum(quantity_change::int) OVER (PARTITION BY sku
                                                            ORDER BY movement_date::date, quantity_change::int DESC
                                                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS bal
                      FROM raw.stock_movement) s
             WHERE s.bal < 0)::text
    UNION ALL
    SELECT 10, 'Stock-out rows equal order lines on delivered orders',
           (SELECT count(*) FROM raw.sales_order_line l
              JOIN raw.sales_order o ON o.order_number = l.order_number
             WHERE o.status = 'delivered')::text,
           (SELECT count(*) FROM raw.stock_movement WHERE movement_type = 'sale')::text
    UNION ALL
    SELECT 11, 'Stock movements dated after the as-of date (should be none)', '0',
           (SELECT count(*) FROM raw.stock_movement WHERE movement_date::date > DATE '2026-09-30')::text
    UNION ALL
    SELECT 12, 'Dead-stock products with stock still on hand at the end',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'S01')::text,
           (SELECT count(*)
              FROM (SELECT sku, sum(quantity_change::int) AS bal FROM raw.stock_movement GROUP BY sku) b
              JOIN generator.product_profile pp ON pp.sku = b.sku
             WHERE pp.is_dead_stock AND b.bal > 0)::text
) t
ORDER BY n;
