-- Mwangaza AV (synthetic case study)
-- STAGE 11 in one file: fake rental quotes (won, lost, expired and open) in the landing area (raw).
-- Run it ONCE, in the mwangaza_av database, AFTER Stage 10. STATUS: run on PostgreSQL 18.6; the project owner reports it ran smoothly (the result table was not shown to Claude).
--
-- What it does, in plain words:
--   1. Stops with an error if Stage 10 has not been run, or if rental quotes already exist.
--   2. Picks about a quarter of the rental bookings and gives each a WON quote. The quote was decided
--      1 to 14 days before the rental started.
--   3. Adds the rental quotes that were NOT won (lost, expired, or still open), so the win rate is realistic.
--   4. Numbers all rental quotes by date (QR-00001 and so on) and writes them to raw.quote.
--   5. The ONLY change to rows that already exist: it fills in quote_number on the rental bookings
--      that came from a quote (it was empty in Stage 10).
--   6. Shows one result table at the end. Every row should say PASS.
--
-- Safe: one all-or-nothing block (BEGIN ... COMMIT). If a line fails, nothing from it is saved.
-- It deletes nothing.
-- The numbers below are a copy of docs/assumptions_register.xlsx. If you change the Excel file,
-- this copy must be updated too.
-- Dates: history runs 2023-10-01 to 2026-09-30. The "as-of" date is 2026-09-30.

BEGIN;

-- Step 1: safety checks
DO $$
BEGIN
    IF to_regclass('generator.rental_booking_profile') IS NULL OR (SELECT count(*) FROM raw.rental_booking) = 0 THEN
        RAISE EXCEPTION 'Stop: Stage 10 has not been run yet. Nothing was changed.';
    END IF;
    IF (SELECT count(*) FROM raw.quote WHERE division = 'rentals') > 0
       OR (SELECT count(*) FROM raw.rental_booking WHERE quote_number IS NOT NULL) > 0 THEN
        RAISE EXCEPTION 'Stop: rental quotes already exist. Nothing was changed.';
    END IF;
END $$;

-- Step 2: more numbers from the register
INSERT INTO generator.parameter (parameter_id, parameter_name, low, central, high, unit) VALUES
    ('R11', 'Share of rental bookings that had a formal quote (the rest are repeat or simple bookings)', 0.15, 0.25, 0.4, '%'),
    ('R12', 'Direct cost of a rental as a share of its price (crew, handling, transport; shown on the quote only)', 0.2, 0.25, 0.35, '%');

ALTER TABLE generator.rental_booking_profile ADD COLUMN quote_number text;

-- A new seed for this stage (register seed plus 0.5)
SELECT setseed(((SELECT central FROM generator.parameter WHERE parameter_id = 'G03') + 0.5)::double precision);

CREATE TEMP TABLE tmp_prm4 ON COMMIT DROP AS
SELECT
    DATE '2023-10-01' AS hist_start,
    DATE '2026-09-30' AS asof,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'C03') AS c03,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'C06') AS c06,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'C04') AS lag_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'C04') AS lag_high,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'R11') AS r11,
    (SELECT low  FROM generator.parameter WHERE parameter_id = 'R12') AS r12_low,
    (SELECT high FROM generator.parameter WHERE parameter_id = 'R12') AS r12_high,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'OF1') AS of1,
    (SELECT central FROM generator.parameter WHERE parameter_id = 'D06') AS d06;

-- Which duplicate code belongs to which real customer (from the Stage 6 answer key)
CREATE TEMP TABLE tmp_dup ON COMMIT DROP AS
SELECT substring(detail from 'Duplicate of (C[0-9]+)') AS orig_code, business_key AS dup_code
FROM generator.planted_error
WHERE planted_id = 'X02';

-- Step 3a: bookings that get a WON quote. The quote is decided (lag days), then the rental starts 1 to 14 days later.
-- A booking is only eligible if its quote date would fall inside the history window.
CREATE TEMP TABLE tmp_won ON COMMIT DROP AS
WITH a AS (
    SELECT bp.booking_number, bp.customer_code, bp.raw_customer_code, bp.office_name, bp.start_date, bp.revenue,
           random() AS r_q, random() AS r_lag, random() AS r_lead, random() AS r_cost
    FROM generator.rental_booking_profile bp
    WHERE NOT bp.is_double_booking_extra
),
b AS (
    SELECT a.*,
           (p.lag_low + (p.lag_high - p.lag_low) * power(a.r_lag, 4))::int AS lag_days,
           (1 + floor(a.r_lead * 14))::int AS lead_days
    FROM a CROSS JOIN tmp_prm4 p
)
SELECT b.*, b.start_date - b.lead_days - b.lag_days AS quote_date
FROM b CROSS JOIN tmp_prm4 p
WHERE b.r_q < p.r11
  AND b.start_date - b.lead_days - b.lag_days >= p.hist_start;

-- Step 3b: quotes that were NOT won: lost, expired, or still open.
-- How many: enough that the won quotes are the register win rate (won / win rate - won).
CREATE TEMP TABLE tmp_oth0 ON COMMIT DROP AS
WITH a AS (
    SELECT i,
           p.hist_start + (random() * (p.asof - p.hist_start))::int AS quote_date,
           random() AS r_lag, random() AS r_exp, random() AS r_cust, random() AS r_dup, random() AS r_off,
           random() AS r_days, random() AS r_n, random() AS r_cost
    FROM tmp_prm4 p
    CROSS JOIN (SELECT count(*) AS n FROM tmp_won) w
    CROSS JOIN LATERAL generate_series(1, round(w.n * (1 / p.c03 - 1))::int) AS i
),
b AS (
    SELECT a.*, (p.lag_low + (p.lag_high - p.lag_low) * power(a.r_lag, 4))::int AS lag_days
    FROM a CROSS JOIN tmp_prm4 p
)
SELECT b.*,
       CASE WHEN b.quote_date + b.lag_days > p.asof THEN 'open'
            WHEN b.r_exp < p.c06 THEN 'expired'
            ELSE 'lost' END AS status,
       CASE WHEN b.r_days < 0.20 THEN 1 WHEN b.r_days < 0.45 THEN 2 WHEN b.r_days < 0.65 THEN 3
            WHEN b.r_days < 0.77 THEN 4 WHEN b.r_days < 0.87 THEN 5 WHEN b.r_days < 0.95 THEN 7 ELSE 10 END AS days,
       (1 + floor(b.r_n * 6))::int AS n_assets
FROM b CROSS JOIN tmp_prm4 p;

-- Customer, office and price for the quotes that were not won
CREATE TEMP TABLE tmp_oth ON COMMIT DROP AS
SELECT o.i, o.quote_date, o.lag_days, o.status,
       pick.customer_code,
       CASE WHEN d.dup_code IS NOT NULL AND o.r_dup < p.d06 THEN d.dup_code ELSE pick.customer_code END AS raw_customer_code,
       CASE WHEN o.r_off < p.of1 THEN 'Nairobi' ELSE 'Mombasa' END AS office_name,
       round((o.days * rates.total)::numeric, 2) AS quoted_price,
       round((o.days * rates.total * (p.r12_low + (p.r12_high - p.r12_low) * power(o.r_cost, 1.9)))::numeric, 2) AS quoted_cost
FROM tmp_oth0 o
CROSS JOIN tmp_prm4 p
CROSS JOIN LATERAL (
    SELECT c.customer_code
    FROM (SELECT cp.customer_code,
                 sum(cp.activity_weight) OVER (ORDER BY cp.customer_code) AS cum,
                 sum(cp.activity_weight) OVER () AS tot
          FROM generator.customer_profile cp
          WHERE cp.created_date <= o.quote_date) c
    WHERE c.cum >= o.r_cust * c.tot
    ORDER BY c.cum
    LIMIT 1
) pick
LEFT JOIN tmp_dup d ON d.orig_code = pick.customer_code
CROSS JOIN LATERAL (
    SELECT sum(x.daily_rate_ex_vat) AS total
    FROM (SELECT daily_rate_ex_vat FROM generator.asset_profile ORDER BY random() LIMIT o.n_assets) x
) rates;

-- Step 4: all rental quotes together, numbered by date
CREATE TEMP TABLE tmp_allq ON COMMIT DROP AS
SELECT 'QR-' || lpad(row_number() OVER (ORDER BY q.quote_date, q.k)::text, 5, '0') AS quote_number, q.*
FROM (
    SELECT w.booking_number AS k, w.booking_number, w.quote_date, w.lag_days, 'won'::text AS status,
           w.customer_code, w.raw_customer_code, w.office_name,
           w.revenue AS quoted_price,
           round((w.revenue * (p.r12_low + (p.r12_high - p.r12_low) * power(w.r_cost, 1.9)))::numeric, 2) AS quoted_cost
    FROM tmp_won w CROSS JOIN tmp_prm4 p
    UNION ALL
    SELECT 'L' || lpad(o.i::text, 6, '0'), NULL, o.quote_date, o.lag_days, o.status,
           o.customer_code, o.raw_customer_code, o.office_name, o.quoted_price, o.quoted_cost
    FROM tmp_oth o
) q;

INSERT INTO generator.quote_profile
    (quote_number, division, customer_code, raw_customer_code, office_name, job_type_name,
     quote_date, lag_days, decision_date, status, quoted_price, quoted_cost)
SELECT quote_number, 'rentals', customer_code, raw_customer_code, office_name, NULL,
       quote_date, lag_days,
       CASE WHEN status IN ('won', 'lost') THEN quote_date + lag_days END,
       status, quoted_price, quoted_cost
FROM tmp_allq;

INSERT INTO raw.quote (quote_number, customer_code, office_name, division, quote_date, decision_date,
                       status, quoted_price_ex_vat, quoted_cost)
SELECT quote_number, raw_customer_code, office_name, division, quote_date::text, decision_date::text,
       status, quoted_price::text, quoted_cost::text
FROM generator.quote_profile
WHERE division = 'rentals'
ORDER BY quote_number;

-- Step 5: fill in the quote number on the bookings that came from a quote (the only change to existing rows)
UPDATE raw.rental_booking b
SET quote_number = m.quote_number
FROM (SELECT quote_number, booking_number FROM tmp_allq WHERE booking_number IS NOT NULL) m
WHERE b.booking_number = m.booking_number;

UPDATE generator.rental_booking_profile bp
SET quote_number = m.quote_number
FROM (SELECT quote_number, booking_number FROM tmp_allq WHERE booking_number IS NOT NULL) m
WHERE bp.booking_number = m.booking_number;

COMMIT;

-- Step 6: the check. One result table. Every row should say PASS.
SELECT what_we_check, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 1 AS n, 'New register numbers copied' AS what_we_check, '2' AS expected,
           (SELECT count(*) FROM generator.parameter WHERE parameter_id IN ('R11', 'R12'))::text AS actual
    UNION ALL
    SELECT 2, 'Won rental quotes equal bookings that carry a quote number',
           (SELECT count(*) FROM raw.quote WHERE division = 'rentals' AND status = 'won')::text,
           (SELECT count(*) FROM raw.rental_booking WHERE quote_number IS NOT NULL)::text
    UNION ALL
    SELECT 3, 'Bookings pointing to a rental quote that does not exist (should be none)', '0',
           (SELECT count(*) FROM raw.rental_booking b
              LEFT JOIN raw.quote q ON q.quote_number = b.quote_number AND q.division = 'rentals'
             WHERE b.quote_number IS NOT NULL AND q.quote_number IS NULL)::text
    UNION ALL
    SELECT 4, 'Won quotes decided on or after the rental start date (should be none)', '0',
           (SELECT count(*) FROM raw.rental_booking b
              JOIN raw.quote q ON q.quote_number = b.quote_number
             WHERE q.decision_date::date >= b.start_date::date)::text
    UNION ALL
    SELECT 5, 'Rental quotes where status and decision date disagree (should be none)', '0',
           (SELECT count(*) FROM raw.quote
             WHERE division = 'rentals' AND (status IN ('won', 'lost')) <> (decision_date IS NOT NULL))::text
    UNION ALL
    SELECT 6, 'Share of bookings with a quote is inside register range R11', 'yes',
           (SELECT CASE WHEN s BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'R11')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'R11')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT (SELECT count(*) FROM raw.rental_booking WHERE quote_number IS NOT NULL)::numeric
                           / (SELECT count(*) FROM generator.rental_booking_profile WHERE NOT is_double_booking_extra) AS s) q)
    UNION ALL
    SELECT 7, 'Rental win rate (won / decided or expired) is inside register range C03', 'yes',
           (SELECT CASE WHEN s BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'C03')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'C03')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT (SELECT count(*) FROM raw.quote WHERE division = 'rentals' AND status = 'won')::numeric
                           / (SELECT count(*) FROM raw.quote WHERE division = 'rentals' AND status IN ('won', 'lost', 'expired')) AS s) q)
    UNION ALL
    SELECT 8, 'Rental quotes dated outside the history window (should be none)', '0',
           (SELECT count(*) FROM raw.quote
             WHERE division = 'rentals'
               AND (quote_date::date < DATE '2023-10-01' OR quote_date::date > DATE '2026-09-30'))::text
    UNION ALL
    SELECT 9, 'Rental quotes whose customer code is not in raw.customer (should be none)', '0',
           (SELECT count(*) FROM raw.quote q
              LEFT JOIN raw.customer c ON c.customer_code = q.customer_code
             WHERE q.division = 'rentals' AND c.customer_code IS NULL)::text
    UNION ALL
    SELECT 10, 'Quote numbers used more than once across all quotes (should be none)', '0',
           (SELECT count(*) - count(DISTINCT quote_number) FROM raw.quote)::text
    UNION ALL
    SELECT 11, 'Average direct-cost share on rental quotes is inside register range R12', 'yes',
           (SELECT CASE WHEN s BETWEEN (SELECT low FROM generator.parameter WHERE parameter_id = 'R12')
                                   AND (SELECT high FROM generator.parameter WHERE parameter_id = 'R12')
                        THEN 'yes' ELSE 'no' END
              FROM (SELECT avg(quoted_cost::numeric / quoted_price::numeric) AS s
                      FROM raw.quote WHERE division = 'rentals' AND quoted_price::numeric > 0) q)
) t
ORDER BY n;
