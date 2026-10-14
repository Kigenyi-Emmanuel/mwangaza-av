-- Mwangaza AV (synthetic case study)
-- STAGE 12 in one file: fake invoices, payments and payment allocations for all three divisions (raw).
-- Run it ONCE, in the mwangaza_av database, AFTER Stage 11. STATUS: run on PostgreSQL 18.6; the project owner reports all 14 checks passed.
--
-- What it does, in plain words:
--   1. Stops with an error if Stage 11 has not been run, or if invoices or payments already exist.
--   2. Raises invoices: projects jobs are billed in 1 to 4 parts, each product order is billed once it is
--      delivered, each rental booking is billed after it ends. VAT is added.
--   3. Decides how fast each customer pays. Most customers follow their sector. Some pay promptly.
--      The 4 habitual late payers marked in Stage 6 pay 60 or more days after the due date.
--   4. Creates the payments. Some invoices are paid in two parts. Some payments cover several invoices.
--      Payments after the as-of date do not exist yet, so the newest invoices stay unpaid.
--   5. Plants three problems on purpose, and records them in the answer key:
--        X01  12 invoices are entered twice (a second invoice number for the same job, order or booking)
--        X03  6 payments have an allocation larger than the payment itself
--        X04  8 invoices have a due date BEFORE the invoice date
--   6. Shows one result table at the end. Every row should say PASS.
--
-- Safe: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It deletes nothing that exists.
-- The numbers below are a copy of docs/assumptions_register.xlsx. If you change the Excel file,
-- this copy must be updated too.
-- Dates: history runs 2023-10-01 to 2026-09-30. The "as-of" date is 2026-09-30.
-- VAT uses register row P11 (16 percent). That rate still has to be verified before it is relied on.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF (SELECT count(*) FROM raw.quote WHERE division = 'rentals') = 0 THEN
        RAISE EXCEPTION 'Stop: Stage 11 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM raw.invoice) > 0 OR (SELECT count(*) FROM raw.payment) > 0
       OR (SELECT count(*) FROM raw.payment_allocation) > 0 THEN
        RAISE EXCEPTION 'Stop: invoices, payments or allocations already exist. Nothing was changed.';
    END IF;
    IF to_regclass('generator.invoice_profile') IS NOT NULL THEN
        RAISE EXCEPTION 'Stop: the Stage 12 answer-key tables already exist. Nothing was changed.';
    END IF;
END $$;

-- Step 2: one more number from the register
INSERT INTO generator.parameter (parameter_id, parameter_name, low, central, high, unit) VALUES
    ('P12', 'Share of the business (by customer activity) that comes from customers who pay promptly, within 30 days of the invoice', 0.3, 0.37, 0.45, '%');

CREATE TABLE generator.payer_profile (
    customer_code  text PRIMARY KEY,
    payer_type     text NOT NULL      -- 'late' (habitual late payer), 'prompt', or 'sector'
);

CREATE TABLE generator.invoice_profile (
    invoice_number     text PRIMARY KEY,
    division           text NOT NULL,
    source_number      text NOT NULL,   -- job number, order number or booking number
    customer_code      text NOT NULL,   -- the real customer (never the duplicate code)
    raw_customer_code  text NOT NULL,   -- the code written into raw (may be the duplicate code)
    invoice_date       date NOT NULL,
    due_date           date NOT NULL,   -- the correct due date (raw may hold a planted wrong one)
    amount_ex_vat      numeric(14,2) NOT NULL,
    vat_amount         numeric(14,2) NOT NULL,
    total_amount       numeric(14,2) NOT NULL,
    payer_type         text NOT NULL,
    first_payment_date date             -- empty if nothing is paid by the as-of date
);

-- A new seed for this stage (register seed minus 0.5, so it stays between -1 and 1)
SELECT setseed(((SELECT central FROM generator.parameter WHERE parameter_id = 'G03') - 0.5)::double precision);

CREATE TEMP TABLE tmp_prm5 ON COMMIT DROP AS
SELECT
    DATE '2023-10-01' AS hist_start,
    DATE '2026-09-30' AS asof,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'P08') AS p08,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'P09') AS p09,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'P11') AS p11,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'P12') AS p12,
    (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D01') AS d01,
    (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D03') AS d03,
    (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D04') AS d04;

-- How fast the sectors pay: low, central, high days (registers P02 to P05) and a shape number k,
-- chosen so the average lands on the central value
CREATE TEMP TABLE tmp_ppar ON COMMIT DROP AS
SELECT s.sector_name, p.low, p.central, p.high, (p.high - p.low) / (p.central - p.low) - 1 AS k
FROM (VALUES ('Government', 'P02'), ('Corporate', 'P03'), ('Hospitality', 'P04'),
             ('Education', 'P05'), ('Non-profit', 'P05'), ('Events and media', 'P05'),
             ('Healthcare', 'P05')) AS s(sector_name, pid)
JOIN generator.parameter p ON p.parameter_id = s.pid;

-- Step 3: who pays how. Habitual late payers first; then customers are picked at random to be prompt
-- payers until they account for the register share (P12) of the business.
INSERT INTO generator.payer_profile (customer_code, payer_type)
SELECT x.customer_code,
       CASE WHEN x.is_habitual_late_payer THEN 'late'
            WHEN x.cumw <= (SELECT p12 FROM tmp_prm5) * x.totw THEN 'prompt'
            ELSE 'sector' END
FROM (
    SELECT cp.customer_code, cp.is_habitual_late_payer,
           sum(CASE WHEN cp.is_habitual_late_payer THEN 0 ELSE cp.activity_weight END)
               OVER (ORDER BY cp.r ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumw,
           sum(CASE WHEN cp.is_habitual_late_payer THEN 0 ELSE cp.activity_weight END) OVER () AS totw
    FROM (SELECT c.*, random() AS r FROM generator.customer_profile c) cp
) x;

-- Step 4a: projects invoices. 1 to 4 invoices per job; the parts add up to the quoted price exactly.
CREATE TEMP TABLE tmp_invp ON COMMIT DROP AS
WITH j AS (
    SELECT jp.job_number, jp.customer_code, jp.raw_customer_code, jp.start_date, jp.planned_end_date,
           jp.quoted_price, (1 + floor(random() * 4))::int AS n
    FROM generator.job_profile jp
),
l AS (
    SELECT j.*, k, random() + 0.5 AS w
    FROM j CROSS JOIN LATERAL generate_series(1, j.n) AS k
),
m AS (
    SELECT l.*,
           round((l.quoted_price * l.w / sum(l.w) OVER (PARTITION BY l.job_number))::numeric, 2) AS amt0
    FROM l
)
SELECT m.job_number AS src, m.customer_code, m.raw_customer_code, m.k,
       CASE WHEN m.k = m.n
            THEN m.quoted_price - coalesce(sum(m.amt0) OVER (PARTITION BY m.job_number ORDER BY m.k
                                                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
            ELSE m.amt0 END AS amount,
       CASE WHEN m.n = 1 THEN m.planned_end_date
            ELSE m.start_date + round((m.planned_end_date - m.start_date) * (m.k - 1)::numeric / (m.n - 1))::int
       END AS inv_date
FROM m;

-- Step 4b: all invoices together (only those dated on or before the as-of date)
CREATE TEMP TABLE tmp_inv0 ON COMMIT DROP AS
SELECT 'projects'::text AS division, src, customer_code, raw_customer_code, k, amount, inv_date
FROM tmp_invp
UNION ALL
SELECT 'products', so.order_number, so.customer_code, so.raw_customer_code, 1, so.revenue,
       LEAST(so.order_date + floor(random() * 3)::int, p.asof)
FROM generator.sales_order_profile so CROSS JOIN tmp_prm5 p
WHERE so.status = 'delivered'
UNION ALL
SELECT 'rentals', bp.booking_number, bp.customer_code, bp.raw_customer_code, 1, bp.revenue,
       LEAST(bp.end_date + floor(random() * 4)::int, p.asof)
FROM generator.rental_booking_profile bp CROSS JOIN tmp_prm5 p;

CREATE TEMP TABLE tmp_inv1 ON COMMIT DROP AS
SELECT 'INV-' || lpad(row_number() OVER (ORDER BY i.inv_date, i.division, i.src, i.k)::text, 6, '0') AS invoice_number,
       i.*,
       cp.sector_name, cp.payment_terms_days, pp.payer_type,
       i.inv_date + cp.payment_terms_days AS due_date,
       round((i.amount * p.p11)::numeric, 2) AS vat,
       random() AS r_pay
FROM tmp_inv0 i
JOIN generator.customer_profile cp ON cp.customer_code = i.customer_code
JOIN generator.payer_profile pp ON pp.customer_code = i.customer_code
CROSS JOIN tmp_prm5 p
WHERE i.inv_date <= p.asof AND i.amount > 0;

-- Step 5a: when each invoice would be paid (days after the invoice date)
CREATE TEMP TABLE tmp_inv2 ON COMMIT DROP AS
SELECT t.*,
       t.inv_date + CASE t.payer_type
            WHEN 'late'   THEN t.payment_terms_days + 60 + floor(t.r_pay * 60)::int
            WHEN 'prompt' THEN 5 + floor(t.r_pay * 26)::int
            ELSE round(pp.low + (pp.high - pp.low) * power(t.r_pay, pp.k))::int END AS pay_date_plan
FROM tmp_inv1 t
JOIN tmp_ppar pp ON pp.sector_name = t.sector_name;

-- Step 5b: invoices that are paid by the as-of date, grouped by customer and week (for bundled payments)
CREATE TEMP TABLE tmp_paid ON COMMIT DROP AS
SELECT t.invoice_number, t.customer_code, t.raw_customer_code, t.pay_date_plan,
       (t.amount + t.vat) AS total,
       ((t.pay_date_plan - p.hist_start) / 7) AS wk
FROM tmp_inv2 t CROSS JOIN tmp_prm5 p
WHERE t.pay_date_plan <= p.asof;

CREATE TEMP TABLE tmp_grp ON COMMIT DROP AS
SELECT customer_code, wk, count(*) AS n, max(pay_date_plan) AS gdate, random() AS r_m,
       row_number() OVER (ORDER BY customer_code, wk) AS gid
FROM tmp_paid
GROUP BY customer_code, wk;

-- Some groups with 2 or more invoices are paid by ONE payment. The chance is set so that bundled payments
-- land near the register share P09 (0.8 is a correction because bundling reduces the number of payments).
CREATE TEMP TABLE tmp_unit ON COMMIT DROP AS
SELECT pd.invoice_number, pd.customer_code, pd.raw_customer_code, pd.pay_date_plan, pd.total,
       g.gid, g.gdate,
       coalesce(g.n >= 2 AND g.r_m < pm.p_merge, false) AS merged,
       random() AS r_split, random() AS r_f, random() AS r_2
FROM tmp_paid pd
JOIN tmp_grp g ON g.customer_code = pd.customer_code AND g.wk = pd.wk
CROSS JOIN (SELECT LEAST(1.0, 0.8 * p.p09 * (SELECT count(*) FROM tmp_paid)
                               / NULLIF((SELECT count(*) FROM tmp_grp WHERE n >= 2), 0)) AS p_merge
            FROM tmp_prm5 p) pm;

-- Some invoices that are paid on their own are paid in two parts. The chance is set so that the share of
-- invoices paid in parts lands near the register share P08.
CREATE TEMP TABLE tmp_par3 ON COMMIT DROP AS
SELECT coalesce(LEAST(0.9, p.p08 / NULLIF((SELECT count(*) FILTER (WHERE NOT merged) FROM tmp_unit)::numeric
                                         / (SELECT count(*) FROM tmp_unit), 0)), 0) AS p_split
FROM tmp_prm5 p;

-- Step 6: allocations (which payment pays which invoice, and how much)
CREATE TEMP TABLE tmp_alloc ON COMMIT DROP AS
-- bundled: one payment per group, on the date of the last invoice of the group
SELECT 'G' || u.gid::text AS unit_id, 1 AS part, u.invoice_number, u.gdate AS pay_date,
       u.total AS amount, u.raw_customer_code
FROM tmp_unit u
WHERE u.merged
UNION ALL
-- single invoice paid in full
SELECT 'S' || u.invoice_number, 1, u.invoice_number, u.pay_date_plan, u.total, u.raw_customer_code
FROM tmp_unit u CROSS JOIN tmp_par3 s
WHERE NOT u.merged AND u.r_split >= s.p_split
UNION ALL
-- single invoice paid in two parts: first part (40 to 80 percent)
SELECT 'S' || u.invoice_number, 1, u.invoice_number, u.pay_date_plan,
       round((u.total * (0.4 + 0.4 * u.r_f))::numeric, 2), u.raw_customer_code
FROM tmp_unit u CROSS JOIN tmp_par3 s
WHERE NOT u.merged AND u.r_split < s.p_split
UNION ALL
-- second part, 10 to 40 days later (only if it falls on or before the as-of date)
SELECT 'S' || u.invoice_number, 2, u.invoice_number, u.pay_date_plan + 10 + floor(u.r_2 * 31)::int,
       u.total - round((u.total * (0.4 + 0.4 * u.r_f))::numeric, 2), u.raw_customer_code
FROM tmp_unit u CROSS JOIN tmp_par3 s CROSS JOIN tmp_prm5 p
WHERE NOT u.merged AND u.r_split < s.p_split
  AND u.pay_date_plan + 10 + floor(u.r_2 * 31)::int <= p.asof;

-- Payments: one per bundle or part
CREATE TEMP TABLE tmp_pay ON COMMIT DROP AS
SELECT 'PAY-' || lpad(row_number() OVER (ORDER BY g.pay_date, g.unit_id, g.part)::text, 6, '0') AS payment_reference,
       g.unit_id, g.part, g.pay_date, g.amount, g.raw_customer_code, g.n_alloc,
       (ARRAY['bank_transfer', 'mobile_money', 'cheque', 'cash'])[
            CASE WHEN g.r < 0.55 THEN 1 WHEN g.r < 0.80 THEN 2 WHEN g.r < 0.95 THEN 3 ELSE 4 END] AS method
FROM (SELECT unit_id, part, pay_date, sum(amount) AS amount, min(raw_customer_code) AS raw_customer_code,
             count(*) AS n_alloc, random() AS r
      FROM tmp_alloc
      GROUP BY unit_id, part, pay_date) g;

-- Planted problems: which invoices are duplicated (rn 1..D01) and which get a wrong due date (the next D04)
CREATE TEMP TABLE tmp_pick_inv ON COMMIT DROP AS
SELECT invoice_number, row_number() OVER (ORDER BY random()) AS rn
FROM tmp_inv2;

-- Planted problem X03: some single-allocation payments get an allocation larger than the payment
CREATE TEMP TABLE tmp_x03 ON COMMIT DROP AS
SELECT payment_reference, 1.10 + 0.4 * random() AS factor
FROM tmp_pay
WHERE n_alloc = 1
ORDER BY random()
LIMIT (SELECT d03 FROM tmp_prm5);

-- Step 7a: the answer key for invoices
INSERT INTO generator.invoice_profile
    (invoice_number, division, source_number, customer_code, raw_customer_code, invoice_date, due_date,
     amount_ex_vat, vat_amount, total_amount, payer_type, first_payment_date)
SELECT t.invoice_number, t.division, t.src, t.customer_code, t.raw_customer_code, t.inv_date, t.due_date,
       t.amount, t.vat, t.amount + t.vat, t.payer_type, f.first_pay
FROM tmp_inv2 t
LEFT JOIN (SELECT invoice_number, min(pay_date) AS first_pay FROM tmp_alloc GROUP BY invoice_number) f
       ON f.invoice_number = t.invoice_number;

-- Step 7b: invoices into raw (originals first, some with a wrong due date; then the duplicates)
INSERT INTO raw.invoice (invoice_number, division, job_number, order_number, booking_number, customer_code,
                         invoice_date, due_date, amount_ex_vat, vat_amount)
SELECT t.invoice_number, t.division,
       CASE WHEN t.division = 'projects' THEN t.src END,
       CASE WHEN t.division = 'products' THEN t.src END,
       CASE WHEN t.division = 'rentals'  THEN t.src END,
       t.raw_customer_code, t.inv_date::text,
       (CASE WHEN k4.rn IS NOT NULL THEN t.inv_date - (1 + floor(t.r_pay * 10)::int) ELSE t.due_date END)::text,
       t.amount::text, t.vat::text
FROM tmp_inv2 t
CROSS JOIN tmp_prm5 p
LEFT JOIN tmp_pick_inv k4 ON k4.invoice_number = t.invoice_number AND k4.rn > p.d01 AND k4.rn <= p.d01 + p.d04
ORDER BY t.invoice_number;

INSERT INTO raw.invoice (invoice_number, division, job_number, order_number, booking_number, customer_code,
                         invoice_date, due_date, amount_ex_vat, vat_amount)
SELECT 'INV-' || lpad(((SELECT count(*) FROM tmp_inv2) + k.rn)::text, 6, '0'), t.division,
       CASE WHEN t.division = 'projects' THEN t.src END,
       CASE WHEN t.division = 'products' THEN t.src END,
       CASE WHEN t.division = 'rentals'  THEN t.src END,
       t.raw_customer_code, t.inv_date::text, t.due_date::text, t.amount::text, t.vat::text
FROM tmp_pick_inv k
JOIN tmp_inv2 t ON t.invoice_number = k.invoice_number
CROSS JOIN tmp_prm5 p
WHERE k.rn <= p.d01
ORDER BY k.rn;

-- Step 7c: payments and allocations into raw
INSERT INTO raw.payment (payment_reference, customer_code, payment_date, amount, payment_method)
SELECT payment_reference, raw_customer_code, pay_date::text, amount::text, method
FROM tmp_pay
ORDER BY payment_reference;

INSERT INTO raw.payment_allocation (payment_reference, invoice_number, allocated_amount)
SELECT p.payment_reference, a.invoice_number,
       (CASE WHEN x.payment_reference IS NOT NULL THEN round((a.amount * x.factor)::numeric, 2) ELSE a.amount END)::text
FROM tmp_alloc a
JOIN tmp_pay p ON p.unit_id = a.unit_id AND p.part = a.part
LEFT JOIN tmp_x03 x ON x.payment_reference = p.payment_reference
ORDER BY p.payment_reference, a.invoice_number;

-- Step 8: write the planted problems into the answer key
INSERT INTO generator.planted_error (planted_id, raw_table, business_key, detail)
SELECT 'X01', 'raw.invoice',
       'INV-' || lpad(((SELECT count(*) FROM tmp_inv2) + k.rn)::text, 6, '0'),
       'Duplicate of ' || k.invoice_number
FROM tmp_pick_inv k CROSS JOIN tmp_prm5 p
WHERE k.rn <= p.d01
UNION ALL
SELECT 'X03', 'raw.payment_allocation', payment_reference, 'Allocated amount is larger than the payment'
FROM tmp_x03
UNION ALL
SELECT 'X04', 'raw.invoice', k.invoice_number, 'Due date is before the invoice date'
FROM tmp_pick_inv k CROSS JOIN tmp_prm5 p
WHERE k.rn > p.d01 AND k.rn <= p.d01 + p.d04;

COMMIT;

-- Step 9: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'New register number copied' AS what_we_check, '1' AS expected,
           (SELECT count(*) FROM generator.parameter WHERE parameter_id = 'P12')::text AS actual
    UNION ALL
    SELECT 2, 'Invoices in raw (invoices + planted duplicates)',
           ((SELECT count(*) FROM generator.invoice_profile)
            + (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D01'))::text,
           (SELECT count(*) FROM raw.invoice)::text
    UNION ALL
    SELECT 3, 'Invoices that do not have exactly one source (should be none)', '0',
           (SELECT count(*) FROM raw.invoice
             WHERE num_nonnulls(job_number, order_number, booking_number) <> 1)::text
    UNION ALL
    SELECT 4, 'Invoices whose job, order or booking is missing (should be none)', '0',
           ((SELECT count(*) FROM raw.invoice i LEFT JOIN raw.job j ON j.job_number = i.job_number
              WHERE i.job_number IS NOT NULL AND j.job_number IS NULL)
          + (SELECT count(*) FROM raw.invoice i LEFT JOIN raw.sales_order s ON s.order_number = i.order_number
              WHERE i.order_number IS NOT NULL AND s.order_number IS NULL)
          + (SELECT count(*) FROM raw.invoice i LEFT JOIN raw.rental_booking b ON b.booking_number = i.booking_number
              WHERE i.booking_number IS NOT NULL AND b.booking_number IS NULL))::text
    UNION ALL
    SELECT 5, 'Finished jobs whose invoices do not add up to the quoted price (should be none)', '0',
           (SELECT count(*)
              FROM generator.job_profile jp
              LEFT JOIN (SELECT ip.source_number, sum(ip.amount_ex_vat) AS billed
                           FROM generator.invoice_profile ip
                          WHERE ip.division = 'projects'
                          GROUP BY ip.source_number) b ON b.source_number = jp.job_number
             WHERE jp.status = 'completed' AND abs(coalesce(b.billed, 0) - jp.quoted_price) > 0.01)::text
    UNION ALL
    SELECT 6, 'Invoices where VAT is not the register rate times the amount (should be none)', '0',
           (SELECT count(*) FROM raw.invoice
             WHERE abs(vat_amount::numeric - round(amount_ex_vat::numeric
                       * (SELECT central FROM generator.parameter WHERE parameter_id = 'P11'), 2)) > 0.01)::text
    UNION ALL
    SELECT 7, 'Invoices with a due date before the invoice date (planted X04)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D04')::text,
           (SELECT count(*) FROM raw.invoice WHERE due_date::date < invoice_date::date)::text
    UNION ALL
    SELECT 8, 'Duplicate invoice pairs found (same source, date and amount) (planted X01)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D01')::text,
           (SELECT count(*)
              FROM (SELECT 1 FROM raw.invoice
                     GROUP BY division, job_number, order_number, booking_number, invoice_date, amount_ex_vat
                    HAVING count(*) > 1) d)::text
    UNION ALL
    SELECT 9, 'Payments with allocations larger than the payment (planted X03)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D03')::text,
           (SELECT count(*)
              FROM (SELECT p.payment_reference
                      FROM raw.payment p
                      JOIN raw.payment_allocation a ON a.payment_reference = p.payment_reference
                     GROUP BY p.payment_reference, p.amount
                    HAVING sum(a.allocated_amount::numeric) > p.amount::numeric + 0.01) d)::text
    UNION ALL
    SELECT 10, 'Allocations pointing to a missing payment or invoice (should be none)', '0',
           ((SELECT count(*) FROM raw.payment_allocation a LEFT JOIN raw.payment p ON p.payment_reference = a.payment_reference
              WHERE p.payment_reference IS NULL)
          + (SELECT count(*) FROM raw.payment_allocation a LEFT JOIN raw.invoice i ON i.invoice_number = a.invoice_number
              WHERE i.invoice_number IS NULL))::text
    UNION ALL
    SELECT 11, 'Share of paid invoices paid over 30 days after the invoice is inside register range P06', 'yes',
           (SELECT CASE WHEN s BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'P06')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'P06')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT count(*) FILTER (WHERE x.d > 30)::numeric / count(*) AS s
                      FROM (SELECT ip.invoice_number, min(py.payment_date::date) - ip.invoice_date AS d
                              FROM generator.invoice_profile ip
                              JOIN raw.payment_allocation a ON a.invoice_number = ip.invoice_number
                              JOIN raw.payment py ON py.payment_reference = a.payment_reference
                             GROUP BY ip.invoice_number, ip.invoice_date) x) q)
    UNION ALL
    SELECT 12, 'Habitual late payers paid less than 60 days after the due date (should be none)', '0',
           (SELECT count(*)
              FROM generator.invoice_profile ip
              JOIN generator.payer_profile pp ON pp.customer_code = ip.customer_code AND pp.payer_type = 'late'
              JOIN raw.payment_allocation a ON a.invoice_number = ip.invoice_number
              JOIN raw.payment py ON py.payment_reference = a.payment_reference
             WHERE py.payment_date::date - ip.due_date < 60)::text
    UNION ALL
    SELECT 13, 'Share of payments that cover several invoices is inside register range P09', 'yes',
           (SELECT CASE WHEN s BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'P09')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'P09')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT (SELECT count(*) FROM (SELECT payment_reference FROM raw.payment_allocation
                                                   GROUP BY payment_reference HAVING count(*) > 1) m)::numeric
                           / (SELECT count(*) FROM raw.payment) AS s) q)
    UNION ALL
    SELECT 14, 'Share of paid invoices paid in parts is inside register range P08', 'yes',
           (SELECT CASE WHEN s BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'P08')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'P08')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT (SELECT count(*) FROM (SELECT invoice_number FROM raw.payment_allocation
                                                   GROUP BY invoice_number HAVING count(*) > 1) m)::numeric
                           / (SELECT count(DISTINCT invoice_number) FROM raw.payment_allocation) AS s) q)
) t
ORDER BY n;
