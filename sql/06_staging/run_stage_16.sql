-- Mwangaza AV (synthetic case study)
-- STAGE 16 in one file: clean rentals and billing into staging. STATUS: written, not yet run.
-- Run it ONCE, in the mwangaza_av database, AFTER Stage 15.
-- This is the stage where most of the planted problems are found.
--
-- What it does, in plain words:
--   1. Stops with an error if Stage 15 has not been run, or if staging already holds rentals or billing.
--   2. Rentals: reads bookings, booked assets and repairs into dates and numbers, replaces duplicate customer
--      codes with the real customer (DQ05), and FLAGS assets that are double-booked (DQ11). Double-bookings are
--      real events, so they stay in the data and are marked, not removed.
--   3. Invoices: sets aside invoices that repeat another invoice, and keeps the one with the lowest number
--      (DQ06, planted problem X01). Fixes a due date that comes BEFORE the invoice date by using the invoice
--      date plus the customer's payment terms (DQ07, planted problem X04), and keeps the old value.
--   4. Payments and allocations: reduces an allocation that is larger than its payment to the payment amount
--      (DQ08, planted problem X03), keeps the old value, and flags any invoice paid more than its total (DQ10).
--   5. Checks the work against the hidden answer key: did the cleaning find exactly the planted duplicates,
--      wrong due dates, oversized allocations and double-bookings, with no false alarms, and do the money
--      totals still reconcile to the cent?
--   6. Shows one result table at the end. Every row should say PASS.
--
-- Safe: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It never changes raw data. It never deletes anything.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF (SELECT count(*) FROM staging.sales_order) = 0 THEN
        RAISE EXCEPTION 'Stop: Stage 15 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM staging.rental_booking) > 0 OR (SELECT count(*) FROM staging.invoice) > 0
       OR (SELECT count(*) FROM staging.payment) > 0 OR (SELECT count(*) FROM staging.payment_allocation) > 0
       OR (SELECT count(*) FROM staging.maintenance_event) > 0 OR (SELECT count(*) FROM staging.rental_booking_line) > 0 THEN
        RAISE EXCEPTION 'Stop: staging already holds rentals or billing. Nothing was changed.';
    END IF;
END $$;

-- Step 2a: rental bookings
CREATE TEMP TABLE tmp_b0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.booking_number, '')) AS booking_number,
       NULLIF(btrim(coalesce(r.quote_number, '')), '') AS quote_number,
       btrim(coalesce(r.customer_code, '')) AS original_code,
       btrim(coalesce(r.office_name, '')) AS office_name,
       staging.try_date(r.start_date) AS start_date,
       staging.try_date(r.end_date) AS end_date,
       lower(btrim(coalesce(r.status, ''))) AS status
FROM raw.rental_booking r;

CREATE TEMP TABLE tmp_b1 ON COMMIT DROP AS
SELECT b.*, m.canonical_customer_code AS customer_code,
       coalesce(b.booking_number = '' OR b.original_code = '' OR b.office_name = '' OR b.start_date IS NULL
                OR b.end_date IS NULL OR b.end_date < b.start_date
                OR b.status NOT IN ('confirmed', 'completed', 'cancelled'), true) AS unreadable,
       (m.canonical_customer_code IS NULL
        OR b.office_name NOT IN (SELECT office_name FROM core.office)
        OR (b.quote_number IS NOT NULL AND b.quote_number NOT IN (SELECT quote_number FROM staging.quote))) AS link_missing
FROM tmp_b0 b
LEFT JOIN staging.customer_map m ON m.raw_customer_code = b.original_code;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'rental_booking', raw_row_id, booking_number, 'Unreadable, or breaks a basic rule (dates, status)'
FROM tmp_b1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'rental_booking', raw_row_id, booking_number, 'Customer, office or quote does not exist'
FROM tmp_b1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.rental_booking
    (raw_row_id, booking_number, quote_number, customer_code, original_customer_code, office_name,
     start_date, end_date, status)
SELECT raw_row_id, booking_number, quote_number, customer_code, original_code, office_name,
       start_date, end_date, status
FROM tmp_b1 WHERE NOT unreadable AND NOT link_missing;

-- Step 2b: booked assets
CREATE TEMP TABLE tmp_bl0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.booking_number, '')) AS booking_number,
       btrim(coalesce(r.asset_tag, '')) AS asset_tag,
       staging.try_numeric(r.daily_rate_ex_vat) AS daily_rate
FROM raw.rental_booking_line r;

CREATE TEMP TABLE tmp_bl1 ON COMMIT DROP AS
SELECT l.*,
       coalesce(l.booking_number = '' OR l.asset_tag = '' OR l.daily_rate IS NULL OR l.daily_rate < 0, true) AS unreadable,
       (l.booking_number NOT IN (SELECT booking_number FROM staging.rental_booking)
        OR l.asset_tag NOT IN (SELECT asset_tag FROM staging.asset)) AS link_missing
FROM tmp_bl0 l;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'rental_booking_line', raw_row_id, booking_number, 'Unreadable, or rate not allowed'
FROM tmp_bl1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'rental_booking_line', raw_row_id, booking_number, 'Booking or asset does not exist'
FROM tmp_bl1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.rental_booking_line (raw_row_id, booking_number, asset_tag, daily_rate_ex_vat)
SELECT raw_row_id, booking_number, asset_tag, daily_rate
FROM tmp_bl1 WHERE NOT unreadable AND NOT link_missing;

-- Step 2c: repairs and services
CREATE TEMP TABLE tmp_me0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.asset_tag, '')) AS asset_tag,
       staging.try_date(r.event_date) AS event_date,
       lower(btrim(coalesce(r.event_type, ''))) AS event_type,
       staging.try_numeric(r.cost_amount) AS cost_amount,
       staging.try_int(r.days_out_of_service) AS days_out,
       NULLIF(btrim(coalesce(r.booking_number, '')), '') AS booking_number
FROM raw.maintenance_event r;

CREATE TEMP TABLE tmp_me1 ON COMMIT DROP AS
SELECT m.*,
       coalesce(m.asset_tag = '' OR m.event_date IS NULL OR m.cost_amount IS NULL OR m.cost_amount < 0
                OR m.days_out IS NULL OR m.days_out < 0
                OR m.event_type NOT IN ('routine_service', 'damage_repair', 'loss'), true) AS unreadable,
       (m.asset_tag NOT IN (SELECT asset_tag FROM staging.asset)
        OR (m.booking_number IS NOT NULL AND m.booking_number NOT IN (SELECT booking_number FROM staging.rental_booking))) AS link_missing
FROM tmp_me0 m;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'maintenance_event', raw_row_id, asset_tag, 'Unreadable, or cost, days or type not allowed'
FROM tmp_me1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'maintenance_event', raw_row_id, asset_tag, 'Asset or booking does not exist'
FROM tmp_me1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.maintenance_event
    (raw_row_id, asset_tag, event_date, event_type, cost_amount, days_out_of_service, booking_number)
SELECT raw_row_id, asset_tag, event_date, event_type, cost_amount, days_out, booking_number
FROM tmp_me1 WHERE NOT unreadable AND NOT link_missing;

-- Step 3: invoices
CREATE TEMP TABLE tmp_i0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.invoice_number, '')) AS invoice_number,
       lower(btrim(coalesce(r.division, ''))) AS division,
       NULLIF(btrim(coalesce(r.job_number, '')), '') AS job_number,
       NULLIF(btrim(coalesce(r.order_number, '')), '') AS order_number,
       NULLIF(btrim(coalesce(r.booking_number, '')), '') AS booking_number,
       btrim(coalesce(r.customer_code, '')) AS original_code,
       staging.try_date(r.invoice_date) AS invoice_date,
       staging.try_date(r.due_date) AS due_date,
       staging.try_numeric(r.amount_ex_vat) AS amount,
       staging.try_numeric(r.vat_amount) AS vat
FROM raw.invoice r;

-- A due date before the invoice date is NOT a reason to reject: it is fixed below (DQ07).
CREATE TEMP TABLE tmp_i1 ON COMMIT DROP AS
SELECT i.*, m.canonical_customer_code AS customer_code,
       coalesce(i.invoice_number = '' OR i.original_code = '' OR i.invoice_date IS NULL OR i.due_date IS NULL
                OR i.amount IS NULL OR i.amount < 0 OR i.vat IS NULL OR i.vat < 0
                OR i.division NOT IN ('projects', 'products', 'rentals')
                OR num_nonnulls(i.job_number, i.order_number, i.booking_number) <> 1
                OR NOT ((i.division = 'projects' AND i.job_number IS NOT NULL)
                     OR (i.division = 'products' AND i.order_number IS NOT NULL)
                     OR (i.division = 'rentals' AND i.booking_number IS NOT NULL)), true) AS unreadable,
       (m.canonical_customer_code IS NULL
        OR (i.job_number IS NOT NULL AND i.job_number NOT IN (SELECT job_number FROM staging.job))
        OR (i.order_number IS NOT NULL AND i.order_number NOT IN (SELECT order_number FROM staging.sales_order))
        OR (i.booking_number IS NOT NULL AND i.booking_number NOT IN (SELECT booking_number FROM staging.rental_booking))) AS link_missing
FROM tmp_i0 i
LEFT JOIN staging.customer_map m ON m.raw_customer_code = i.original_code;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'invoice', raw_row_id, invoice_number, 'Unreadable, or amounts, division or source not allowed'
FROM tmp_i1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'invoice', raw_row_id, invoice_number, 'Customer, job, order or booking does not exist'
FROM tmp_i1 WHERE NOT unreadable AND link_missing;

-- Find invoices that repeat another: same source, date, amount and real customer. The lowest number is kept.
CREATE TEMP TABLE tmp_i2 ON COMMIT DROP AS
SELECT v.*,
       row_number() OVER w AS rn,
       first_value(v.invoice_number) OVER w AS first_invoice
FROM tmp_i1 v
WHERE NOT v.unreadable AND NOT v.link_missing
WINDOW w AS (PARTITION BY v.division, v.job_number, v.order_number, v.booking_number,
                          v.invoice_date, v.amount, v.customer_code
             ORDER BY v.invoice_number);

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ06', 'invoice', raw_row_id, invoice_number, 'Repeats invoice ' || first_invoice
FROM tmp_i2 WHERE rn > 1;

INSERT INTO staging.invoice
    (raw_row_id, invoice_number, division, job_number, order_number, booking_number, customer_code,
     original_customer_code, invoice_date, due_date, original_due_date, amount_ex_vat, vat_amount)
SELECT i.raw_row_id, i.invoice_number, i.division, i.job_number, i.order_number, i.booking_number, i.customer_code,
       i.original_code, i.invoice_date,
       CASE WHEN i.due_date < i.invoice_date THEN i.invoice_date + c.payment_terms_days ELSE i.due_date END,
       i.due_date, i.amount, i.vat
FROM tmp_i2 i
JOIN staging.customer c ON c.customer_code = i.customer_code AND c.is_canonical
WHERE i.rn = 1;

-- Step 4: payments
CREATE TEMP TABLE tmp_py0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.payment_reference, '')) AS payment_reference,
       btrim(coalesce(r.customer_code, '')) AS original_code,
       staging.try_date(r.payment_date) AS payment_date,
       staging.try_numeric(r.amount) AS amount,
       lower(btrim(coalesce(r.payment_method, ''))) AS payment_method
FROM raw.payment r;

CREATE TEMP TABLE tmp_py1 ON COMMIT DROP AS
SELECT p.*, m.canonical_customer_code AS customer_code,
       coalesce(p.payment_reference = '' OR p.original_code = '' OR p.payment_date IS NULL OR p.amount IS NULL
                OR p.amount <= 0 OR p.payment_method NOT IN ('bank_transfer', 'mobile_money', 'cheque', 'cash'), true) AS unreadable,
       (m.canonical_customer_code IS NULL) AS link_missing
FROM tmp_py0 p
LEFT JOIN staging.customer_map m ON m.raw_customer_code = p.original_code;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'payment', raw_row_id, payment_reference, 'Unreadable, or amount or method not allowed'
FROM tmp_py1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'payment', raw_row_id, payment_reference, 'Customer does not exist'
FROM tmp_py1 WHERE NOT unreadable AND link_missing;

INSERT INTO staging.payment
    (raw_row_id, payment_reference, customer_code, original_customer_code, payment_date, amount, payment_method)
SELECT raw_row_id, payment_reference, customer_code, original_code, payment_date, amount, payment_method
FROM tmp_py1 WHERE NOT unreadable AND NOT link_missing;

-- Step 5: payment allocations
CREATE TEMP TABLE tmp_al0 ON COMMIT DROP AS
SELECT r.raw_row_id,
       btrim(coalesce(r.payment_reference, '')) AS payment_reference,
       btrim(coalesce(r.invoice_number, '')) AS invoice_number,
       staging.try_numeric(r.allocated_amount) AS allocated
FROM raw.payment_allocation r;

CREATE TEMP TABLE tmp_al1 ON COMMIT DROP AS
SELECT a.*,
       coalesce(a.payment_reference = '' OR a.invoice_number = '' OR a.allocated IS NULL OR a.allocated <= 0, true) AS unreadable,
       (a.payment_reference NOT IN (SELECT payment_reference FROM staging.payment)
        OR a.invoice_number NOT IN (SELECT invoice_number FROM staging.invoice)) AS link_missing
FROM tmp_al0 a;

INSERT INTO staging.rejected_row (rule_id, table_name, raw_row_id, business_key, reason)
SELECT 'DQ02', 'payment_allocation', raw_row_id, payment_reference, 'Unreadable, or amount not allowed'
FROM tmp_al1 WHERE unreadable
UNION ALL
SELECT 'DQ09', 'payment_allocation', raw_row_id, payment_reference, 'Payment or invoice does not exist (for example a rejected duplicate invoice)'
FROM tmp_al1 WHERE NOT unreadable AND link_missing;

-- DQ08: an allocation larger than its payment is reduced to the payment amount, if the payment has only one allocation
CREATE TEMP TABLE tmp_al2 ON COMMIT DROP AS
SELECT a.raw_row_id, a.payment_reference, a.invoice_number, a.allocated AS original_allocated,
       p.amount AS payment_amount,
       count(*) OVER (PARTITION BY a.payment_reference) AS n_alloc,
       CASE WHEN count(*) OVER (PARTITION BY a.payment_reference) = 1 AND a.allocated > p.amount
            THEN p.amount ELSE a.allocated END AS allocated
FROM tmp_al1 a
JOIN staging.payment p ON p.payment_reference = a.payment_reference
WHERE NOT a.unreadable AND NOT a.link_missing;

INSERT INTO staging.payment_allocation
    (raw_row_id, payment_reference, invoice_number, allocated_amount, original_allocated_amount)
SELECT raw_row_id, payment_reference, invoice_number, allocated, original_allocated
FROM tmp_al2;

-- Step 6: log what changed and what is odd
INSERT INTO staging.dq_issue (rule_id, table_name, raw_row_id, business_key, detail, value_before, value_after)
SELECT 'DQ05', 'rental_booking', raw_row_id, booking_number, 'Customer code of a duplicate customer replaced by the real customer', original_customer_code, customer_code
FROM staging.rental_booking WHERE customer_code <> original_customer_code
UNION ALL
SELECT 'DQ05', 'invoice', raw_row_id, invoice_number, 'Customer code of a duplicate customer replaced by the real customer', original_customer_code, customer_code
FROM staging.invoice WHERE customer_code <> original_customer_code
UNION ALL
SELECT 'DQ05', 'payment', raw_row_id, payment_reference, 'Customer code of a duplicate customer replaced by the real customer', original_customer_code, customer_code
FROM staging.payment WHERE customer_code <> original_customer_code
UNION ALL
SELECT 'DQ07', 'invoice', raw_row_id, invoice_number, 'Due date before the invoice date; recomputed from the customer''s payment terms',
       original_due_date::text, due_date::text
FROM staging.invoice WHERE due_date <> original_due_date
UNION ALL
SELECT 'DQ08', 'payment_allocation', raw_row_id, payment_reference, 'Allocation larger than the payment; reduced to the payment amount',
       original_allocated_amount::text, allocated_amount::text
FROM staging.payment_allocation WHERE allocated_amount <> original_allocated_amount;

-- DQ10: any invoice that has been paid more than its total
INSERT INTO staging.dq_issue (rule_id, table_name, raw_row_id, business_key, detail, value_before, value_after)
SELECT 'DQ10', 'invoice', NULL, i.invoice_number, 'Total allocated is more than the invoice total (amount plus VAT)',
       s.paid::text, (i.amount_ex_vat + i.vat_amount)::text
FROM staging.invoice i
JOIN (SELECT invoice_number, sum(allocated_amount) AS paid FROM staging.payment_allocation GROUP BY invoice_number) s
  ON s.invoice_number = i.invoice_number
WHERE s.paid > i.amount_ex_vat + i.vat_amount + 0.01;

-- DQ11: two bookings of the same asset on overlapping dates. Flagged, not removed.
INSERT INTO staging.dq_issue (rule_id, table_name, raw_row_id, business_key, detail, value_before, value_after)
SELECT 'DQ11', 'rental_booking_line', l2.raw_row_id, l2.asset_tag,
       'Overlaps booking ' || b1.booking_number || ' (' || b1.start_date::text || ' to ' || b1.end_date::text || '); this is booking '
       || b2.booking_number || ' (' || b2.start_date::text || ' to ' || b2.end_date::text || ')',
       NULL, NULL
FROM staging.rental_booking_line l1
JOIN staging.rental_booking b1 ON b1.booking_number = l1.booking_number
JOIN staging.rental_booking_line l2 ON l2.asset_tag = l1.asset_tag AND l2.raw_row_id > l1.raw_row_id
JOIN staging.rental_booking b2 ON b2.booking_number = l2.booking_number
WHERE b1.start_date <= b2.end_date AND b2.start_date <= b1.end_date;

COMMIT;

-- Step 7: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'Rental bookings: raw rows equal staging rows plus rejected rows' AS what_we_check,
           (SELECT count(*) FROM raw.rental_booking)::text AS expected,
           ((SELECT count(*) FROM staging.rental_booking) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'rental_booking'))::text AS actual
    UNION ALL
    SELECT 2, 'Booked assets: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.rental_booking_line)::text,
           ((SELECT count(*) FROM staging.rental_booking_line) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'rental_booking_line'))::text
    UNION ALL
    SELECT 3, 'Repairs and services: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.maintenance_event)::text,
           ((SELECT count(*) FROM staging.maintenance_event) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'maintenance_event'))::text
    UNION ALL
    SELECT 4, 'Invoices: raw rows equal staging rows plus rejected rows (the duplicates are among the rejected)',
           (SELECT count(*) FROM raw.invoice)::text,
           ((SELECT count(*) FROM staging.invoice) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'invoice'))::text
    UNION ALL
    SELECT 5, 'Payments: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.payment)::text,
           ((SELECT count(*) FROM staging.payment) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'payment'))::text
    UNION ALL
    SELECT 6, 'Allocations: raw rows equal staging rows plus rejected rows',
           (SELECT count(*) FROM raw.payment_allocation)::text,
           ((SELECT count(*) FROM staging.payment_allocation) + (SELECT count(*) FROM staging.rejected_row WHERE table_name = 'payment_allocation'))::text
    UNION ALL
    SELECT 7, 'Rows set aside in this stage other than the planted duplicate invoices (should be none)', '0',
           (SELECT count(*) FROM staging.rejected_row
             WHERE table_name IN ('rental_booking', 'rental_booking_line', 'maintenance_event', 'invoice', 'payment', 'payment_allocation')
               AND NOT (table_name = 'invoice' AND rule_id = 'DQ06'))::text
    UNION ALL
    SELECT 8, 'Answer key X01: duplicate invoices set aside (register D01)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D01')::text,
           (SELECT count(*) FROM staging.rejected_row WHERE rule_id = 'DQ06')::text
    UNION ALL
    SELECT 9, 'Answer key X01: invoices set aside that were NOT planted duplicates (false alarms, should be none)', '0',
           (SELECT count(*) FROM staging.rejected_row r
             WHERE r.rule_id = 'DQ06'
               AND r.business_key NOT IN (SELECT business_key FROM generator.planted_error WHERE planted_id = 'X01'))::text
    UNION ALL
    SELECT 10, 'Answer key X04: due dates fixed (register D04)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D04')::text,
           (SELECT count(*) FROM staging.dq_issue WHERE rule_id = 'DQ07')::text
    UNION ALL
    SELECT 11, 'Answer key X04: due dates fixed that were NOT planted (false alarms, should be none)', '0',
           (SELECT count(*) FROM staging.dq_issue d
             WHERE d.rule_id = 'DQ07'
               AND d.business_key NOT IN (SELECT business_key FROM generator.planted_error WHERE planted_id = 'X04'))::text
    UNION ALL
    SELECT 12, 'Invoices whose due date after cleaning differs from the true due date the generator recorded (should be none)', '0',
           (SELECT count(*) FROM staging.invoice i
              JOIN generator.invoice_profile ip ON ip.invoice_number = i.invoice_number
             WHERE i.due_date <> ip.due_date)::text
    UNION ALL
    SELECT 13, 'Answer key X03: allocations reduced (register D03)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'D03')::text,
           (SELECT count(*) FROM staging.dq_issue WHERE rule_id = 'DQ08')::text
    UNION ALL
    SELECT 14, 'Answer key X03: allocations reduced that were NOT planted (false alarms, should be none)', '0',
           (SELECT count(*) FROM staging.dq_issue d
             WHERE d.rule_id = 'DQ08'
               AND d.business_key NOT IN (SELECT business_key FROM generator.planted_error WHERE planted_id = 'X03'))::text
    UNION ALL
    SELECT 15, 'Total allocated after cleaning equals total paid (KES)',
           (SELECT round(sum(amount), 2)::text FROM staging.payment),
           (SELECT round(sum(allocated_amount), 2)::text FROM staging.payment_allocation)
    UNION ALL
    SELECT 16, 'Answer key X09: double-booked pairs flagged (register R07)',
           (SELECT central::int FROM generator.parameter WHERE parameter_id = 'R07')::text,
           (SELECT count(*) FROM staging.dq_issue WHERE rule_id = 'DQ11')::text
    UNION ALL
    SELECT 17, 'Answer key X09: planted double-booked assets with no flag (should be none)', '0',
           (SELECT count(*) FROM generator.planted_error pe
             WHERE pe.planted_id = 'X09'
               AND NOT EXISTS (SELECT 1 FROM staging.dq_issue d WHERE d.rule_id = 'DQ11' AND d.business_key = pe.business_key))::text
    UNION ALL
    SELECT 18, 'Answer key: bookings written under a duplicate customer code, found by the cleaning',
           (SELECT count(*) FROM generator.rental_booking_profile WHERE raw_customer_code <> customer_code)::text,
           (SELECT count(*) FROM staging.rental_booking WHERE customer_code <> original_customer_code)::text
    UNION ALL
    SELECT 19, 'Answer key: invoices written under a duplicate customer code, found by the cleaning',
           (SELECT count(*) FROM generator.invoice_profile WHERE raw_customer_code <> customer_code)::text,
           (SELECT count(*) FROM staging.invoice WHERE customer_code <> original_customer_code)::text
    UNION ALL
    SELECT 20, 'Bookings, invoices and payments whose customer is not a real (canonical) customer (should be none)', '0',
           ((SELECT count(*) FROM staging.rental_booking x LEFT JOIN staging.customer c ON c.customer_code = x.customer_code AND c.is_canonical WHERE c.customer_code IS NULL)
          + (SELECT count(*) FROM staging.invoice x LEFT JOIN staging.customer c ON c.customer_code = x.customer_code AND c.is_canonical WHERE c.customer_code IS NULL)
          + (SELECT count(*) FROM staging.payment x LEFT JOIN staging.customer c ON c.customer_code = x.customer_code AND c.is_canonical WHERE c.customer_code IS NULL))::text
    UNION ALL
    SELECT 21, 'Payments whose customer differs from the customer of the invoices they pay (should be none)', '0',
           (SELECT count(*)
              FROM staging.payment p
              JOIN staging.payment_allocation a ON a.payment_reference = p.payment_reference
              JOIN generator.invoice_profile ip ON ip.invoice_number = a.invoice_number
             WHERE p.customer_code <> ip.customer_code)::text
    UNION ALL
    SELECT 22, 'Invoiced before VAT equals the total the generator recorded (KES)',
           (SELECT round(sum(amount_ex_vat), 2)::text FROM generator.invoice_profile),
           (SELECT round(sum(amount_ex_vat), 2)::text FROM staging.invoice)
    UNION ALL
    SELECT 23, 'Invoices paid more than their total (rule DQ10, should be none)', '0',
           (SELECT count(*) FROM staging.dq_issue WHERE rule_id = 'DQ10')::text
    UNION ALL
    SELECT 24, 'Payments whose allocations add up to more than the payment (should be none)', '0',
           (SELECT count(*)
              FROM (SELECT p.payment_reference
                      FROM staging.payment p
                      JOIN staging.payment_allocation a ON a.payment_reference = p.payment_reference
                     GROUP BY p.payment_reference, p.amount
                    HAVING sum(a.allocated_amount) > p.amount + 0.01) d)::text
    UNION ALL
    SELECT 25, 'Invoices that do not have exactly one source, or have a due date before the invoice date (should be none)', '0',
           (SELECT count(*) FROM staging.invoice
             WHERE num_nonnulls(job_number, order_number, booking_number) <> 1 OR due_date < invoice_date)::text
) t
ORDER BY n;
